from pathlib import Path
from contextlib import ExitStack
import argparse
import json
import struct
import time
import zlib

import numpy as np
import serial


PROJECT_ROOT = Path(__file__).resolve().parents[1]
CACHE_PATH = (
    Path(__file__).resolve().parents[3]
    / "data"
    / "DVS128Gesture"
    / "frames_t16_uint16.npz"
)

DEFAULT_PORT = "COM10"
DEFAULT_BAUDRATE = 230400

STREAM_MAGIC = b"GST4"
RESPONSE_MAGIC = b"RSP4"
ACK = b"A"
NAK = b"N"
EARLY_ACK = b"E"

PROTOCOL_VERSION = 4
ENCODING_DENSE = 0
ENCODING_ZERO_RLE = 1

HEADER_STRUCT = struct.Struct("<4sHHHHHHIII")
FRAME_LENGTH_STRUCT = struct.Struct("<I")
# GST2 structures above remain for the codec's legacy layout regression test.
V4_HEADER_STRUCT = struct.Struct("<4sHHHHHHIIII")
V4_FRAME_STRUCT = struct.Struct("<II")
V4_RESPONSE_STRUCT = struct.Struct("<4sIIIII11H11iI")


def validate_early_result(counts, processed_frames, total_frames):
    """检查早退返回结果；连续3帧由板端维护。"""
    if not 8 <= processed_frames <= total_frames:
        return False

    if len(counts) != 11:
        return False

    if any(
        not 0 <= count <= processed_frames
        for count in counts
    ):
        return False

    winner = max(
        range(11),
        key=lambda index: counts[index],
    )

    runner_up = max(
        counts[index]
        for index in range(11)
        if index != winner
    )

    return counts[winner] - runner_up >= 3


def conservative_winner(counts, processed_frames, total_frames):
    """Return a winner only when no legal remaining spikes can change it."""
    if len(counts) != 11:
        raise ValueError("脉冲计数必须包含11类")
    if not 0 < processed_frames <= total_frames:
        raise ValueError("已处理帧数超出范围")
    if any(not 0 <= count <= processed_frames for count in counts):
        raise ValueError("计数超出每类每帧至多一个脉冲的约束")

    winner = max(range(11), key=lambda index: counts[index])
    remaining = total_frames - processed_frames

    for index, count in enumerate(counts):
        if index == winner:
            continue
        possible = count + remaining
        if possible >= counts[winner]:
            return None

    return winner


def make_header(encoding, width, height, channels, time_steps, sample_index,
                payload_bytes, early_stop):
    raw = V4_HEADER_STRUCT.pack(STREAM_MAGIC, PROTOCOL_VERSION, encoding,
                                width, height, channels, time_steps, sample_index,
                                payload_bytes, int(early_stop), 0)
    return raw[:-4] + struct.pack("<I", zlib.crc32(raw[:-4]))


def frame_crc(sample_index, frame_index, payload):
    prefix = struct.pack("<III", sample_index, frame_index, len(payload))
    return zlib.crc32(payload, zlib.crc32(prefix))

def encode_zero_rle(raw):
    """Encode bytes as alternating zero/literal runs of at most 128 values.

    Command bit 7 is zero for a zero run and one for a literal run.  The low
    seven bits store run_length - 1.  Literal bytes immediately follow their
    command.  This format is independent of image size and channel count.
    """

    values = memoryview(raw)
    output = bytearray()
    position = 0

    while position < len(values):
        is_zero = values[position] == 0
        end = position + 1

        while (
            end < len(values)
            and end - position < 128
            and (values[end] == 0) == is_zero
        ):
            end += 1

        run_length = end - position

        if is_zero:
            output.append(run_length - 1)
        else:
            output.append(0x80 | (run_length - 1))
            output.extend(values[position:end])

        position = end

    return bytes(output)


def read_exact(port, size):
    data = bytearray()

    while len(data) < size:
        block = port.read(size - len(data))

        if not block:
            raise TimeoutError(
                f"串口接收超时，需要{size}字节，"
                f"实际收到{len(data)}字节"
            )

        data.extend(block)

    return bytes(data)


def pack_sample(sample, requested_encoding):
    """Pack [T,H,W,C] without HWC16 padding and select an encoding."""

    if sample.ndim != 4:
        raise ValueError(f"样本必须是[T,H,W,C]，实际为{sample.shape}")
    if requested_encoding not in ("auto", "dense", "rle"):
        raise ValueError(f"不支持的编码：{requested_encoding}")
    if not np.issubdtype(sample.dtype, np.integer) or np.any(sample < 0):
        raise ValueError("当前输入必须是非负整数事件计数；有符号输入需扩展数据类型协议")

    sample = np.minimum(sample, 127)
    sample = sample.astype(np.uint8, copy=False)

    dense_frames = [
        np.ascontiguousarray(frame).tobytes(order="C")
        for frame in sample
    ]

    if requested_encoding == "dense":
        return ENCODING_DENSE, dense_frames

    rle_frames = [encode_zero_rle(frame) for frame in dense_frames]

    if requested_encoding == "rle":
        return ENCODING_ZERO_RLE, rle_frames

    dense_size = sum(map(len, dense_frames))
    rle_size = sum(map(len, rle_frames))

    if rle_size < dense_size:
        return ENCODING_ZERO_RLE, rle_frames

    return ENCODING_DENSE, dense_frames


def parse_arguments():
    parser = argparse.ArgumentParser(
        description="通过GST4协议运行测试集，采集脉冲计数和膜电位",
    )
    parser.add_argument("--port", default=DEFAULT_PORT)
    parser.add_argument("--baudrate", type=int, default=DEFAULT_BAUDRATE)
    parser.add_argument("--limit", type=int, default=None,
                        help="只测试前N个样本，首次上板建议设为1")
    parser.add_argument("--early-stop", choices=("off", "conservative"),
                        default="conservative", help="off完整16帧；conservative保守早停")
    parser.add_argument("--results", type=Path, help="保存逐样本JSONL记录（不覆盖已有文件）")
    parser.add_argument(
        "--encoding",
        choices=("auto", "dense", "rle"),
        default="auto",
        help="auto自动选择较小格式；dense为紧凑稠密；rle为零游程稀疏编码",
    )
    return parser.parse_args()


def receive_response(port):
    raw = read_exact(port, V4_RESPONSE_STRUCT.size)
    fields = V4_RESPONSE_STRUCT.unpack(raw)
    if fields[0] != RESPONSE_MAGIC:
        raise RuntimeError(f"结果标识异常：{fields[0]!r}，请确认GST4固件已运行")
    if zlib.crc32(raw[:-4]) != fields[-1]:
        raise RuntimeError("结果CRC32校验失败")
    return (
        fields[1], fields[2], fields[3], fields[4], fields[5],
        fields[6:17], fields[17:28],
    )


def send_sample(port, sample_index, encoding, frame_payloads, width, height,
                channels, early_stop):
    """One transaction; E stops transmission before the next frame length."""
    time_steps = len(frame_payloads)
    port.write(make_header(encoding, width, height, channels, time_steps,
                           sample_index, sum(map(len, frame_payloads)), early_stop))
    port.flush()
    ack = read_exact(port, 1)
    if ack != ACK:
        if ack == NAK:
            raise RuntimeError(f"板端拒绝样本头，status={receive_response(port)[2]}")
        raise RuntimeError(f"样本头确认异常：{ack!r}；检查波特率/固件/启动输出")
    sent_bytes = 0
    processed = 0
    stopped = False
    for index, payload in enumerate(frame_payloads):
        port.write(V4_FRAME_STRUCT.pack(len(payload), frame_crc(sample_index, index, payload)))
        port.flush()
        ack = read_exact(port, 1)
        if ack != ACK:
            if ack == NAK:
                raise RuntimeError(f"板端拒绝帧长度，status={receive_response(port)[2]}")
            raise RuntimeError(f"帧长度确认异常：{ack!r}")
        port.write(payload)
        port.flush()
        sent_bytes += len(payload)
        processed += 1
        ack = read_exact(port, 1)
        if ack == EARLY_ACK:
            stopped = True
            break
        if ack != ACK:
            if ack == NAK:
                raise RuntimeError(f"板端处理帧失败，status={receive_response(port)[2]}")
            raise RuntimeError(f"帧完成确认异常：{ack!r}")
    returned, predicted, status, used, reason, counts, membranes = receive_response(port)
    if returned != sample_index or status != 0:
        raise RuntimeError(f"样本返回编号/状态错误：index={returned}, status={status}")
    if used != processed or not 0 <= predicted < 11:
        raise RuntimeError("返回帧数或类别无效")
    if stopped:
        if not early_stop or used >= time_steps or reason != 1:
            raise RuntimeError("提前结束信息不一致")

        if not validate_early_result(counts, used, time_steps):
            raise RuntimeError(
                f"板端早停不满足条件：帧数={used}/{time_steps}，"
                f"counts={list(counts)}；要求至少第8帧且领先至少3个脉冲"
            )
    else:
        if reason != 0 or used != time_steps:
            raise RuntimeError("完整推理信息不一致")
    # Lowest-index winner on ties, matching the RTL scanner.
    if any(not 0 <= count <= used for count in counts):
        raise RuntimeError("计数超出硬件约束")
    if max(range(11), key=lambda i: counts[i]) != predicted:
        raise RuntimeError("类别与脉冲计数不一致")
    return predicted, counts, membranes, used, reason, sent_bytes


def main():
    arguments = parse_arguments()
    data = np.load(CACHE_PATH)

    frames = data["frames"]
    labels = data["labels"]
    splits = data["splits"]

    if frames.ndim != 5:
        raise ValueError(f"frames必须是[N,T,H,W,C]，实际为{frames.shape}")

    _, time_steps, height, width, channels = frames.shape

    for name, value in (
        ("time_steps", time_steps),
        ("height", height),
        ("width", width),
        ("channels", channels),
    ):
        if not 0 < value <= 0xFFFF:
            raise ValueError(f"{name}超出GST4协议范围：{value}")

    test_indices = np.flatnonzero(splits == 1)

    if len(test_indices) != 288:
        raise ValueError(
            f"测试集数量错误：{len(test_indices)}"
        )
    if arguments.limit is not None:
        if arguments.limit <= 0:
            raise ValueError("--limit必须为正整数")
        test_indices = test_indices[:arguments.limit]

    print(f"测试样本数：{len(test_indices)}")
    print(f"输入：{width}x{height}x{channels}，时间步：{time_steps}")
    print(f"编码：{arguments.encoding}")
    print(f"串口：{arguments.port}")
    print(f"波特率：{arguments.baudrate}")
    print(f"协议：GST4，早停：{arguments.early_stop}")

    correct = 0
    total = 0
    confusion = np.zeros((11, 11), dtype=np.int64)
    total_wire_payload = 0
    total_dense_payload = 0
    total_processed_frames = 0
    early_stopped_samples = 0
    test_start = time.perf_counter()

    with ExitStack() as stack:
        results_file = None
        if arguments.results is not None:
            results_file = stack.enter_context(arguments.results.open("x", encoding="utf-8"))
        port = stack.enter_context(serial.Serial(
            port=arguments.port,
            baudrate=arguments.baudrate,
            timeout=300,
            write_timeout=300,
        ))

        port.reset_input_buffer()
        port.reset_output_buffer()

        for position, sample_index in enumerate(
            test_indices,
            start=1,
        ):
            sample_index = int(sample_index)
            label = int(labels[sample_index])

            encoding, frame_payloads = pack_sample(
                frames[sample_index],
                arguments.encoding,
            )

            payload_bytes = sum(map(len, frame_payloads))
            dense_bytes = time_steps * width * height * channels
            encoding_name = (
                "RLE" if encoding == ENCODING_ZERO_RLE else "DENSE"
            )

            print(
                f"[{position}/{len(test_indices)}] "
                f"sample={sample_index}, "
                f"label={label}, "
                f"编码={encoding_name}, "
                f"数据={payload_bytes}/{dense_bytes}字节, "
                f"发送中...",
                flush=True,
            )

            predicted, counts, membranes, used_frames, reason, sent_bytes = send_sample(
                port, sample_index, encoding, frame_payloads, width, height,
                channels, arguments.early_stop == "conservative",
            )
            total_processed_frames += used_frames
            early_stopped_samples += int(reason == 1)
            if results_file is not None:
                results_file.write(json.dumps({
                    "sample_index": sample_index, "label": label,
                    "predicted": predicted, "counts": list(counts),
                    "membranes": list(membranes),
                    "processed_frames": used_frames, "time_steps": time_steps,
                    "reason": reason, "sent_payload_bytes": sent_bytes,
                    "early_stop_mode": arguments.early_stop,
                    "baudrate": arguments.baudrate,
                }, ensure_ascii=False) + "\n")
                results_file.flush()

            predicted = int(predicted)
            is_correct = predicted == label

            if is_correct:
                correct += 1

            total += 1
            total_wire_payload += sent_bytes
            total_dense_payload += dense_bytes
            confusion[label, predicted] += 1

            accuracy = correct / total

            print(
                f"预测={predicted}, "
                f"标签={label}, "
                f"{'正确' if is_correct else '错误'}, "
                f"当前准确率={accuracy:.4f}, "
                f"帧数={used_frames}/{time_steps}, "
                f"结束={'保守早停' if reason else '完整'}, "
                f"counts={list(counts)}, "
                f"membranes={list(membranes)}",
                flush=True,
            )

    final_accuracy = correct / total
    elapsed = time.perf_counter() - test_start

    print()
    print("====================================")
    print("测试集运行完成")
    print(f"总样本数：{total}")
    print(f"正确数：{correct}")
    print(f"错误数：{total - correct}")
    print(f"准确率：{final_accuracy:.6f}")
    print(f"准确率百分比：{final_accuracy * 100:.2f}%")
    print(f"总耗时：{elapsed:.3f}秒")
    print(f"端到端吞吐量：{total / elapsed:.6f}个手势/秒")
    print(f"实际处理帧数：{total_processed_frames}，平均{total_processed_frames / total:.3f}帧/手势")
    print(f"早停样本数：{early_stopped_samples}/{total}")
    print(f"端到端实际处理帧率：{total_processed_frames / elapsed:.6f}帧/秒")
    print(
        "有效载荷压缩比："
        f"{total_wire_payload / total_dense_payload:.4f} "
        f"({total_wire_payload}/{total_dense_payload}字节)"
    )
    print("混淆矩阵：")
    print(confusion)
    print("====================================")


if __name__ == "__main__":
    main()
