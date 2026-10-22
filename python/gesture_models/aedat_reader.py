from __future__ import annotations

from pathlib import Path
import struct

import numpy as np


PACKET_HEADER = struct.Struct("<HHIIIIII")


def _skip_text_header(stream) -> None:
    """
    AEDAT 3.1文件开头包含以#开头的文本说明。
    读取到第一个二进制字节时停止。
    """
    while True:
        position = stream.tell()
        first = stream.read(1)

        if not first:
            return

        if first != b"#":
            stream.seek(position)
            return

        stream.readline()


def read_aedat(path: str | Path) -> dict[str, np.ndarray]:
    """
    读取AEDAT 3.1中的Polarity Events。

    返回：
        x          : 横坐标，范围0~127
        y          : 纵坐标，范围0~127
        polarity   : 极性，0或1
        timestamp  : 微秒时间戳
    """

    path = Path(path)

    x_list = []
    y_list = []
    polarity_list = []
    timestamp_list = []

    with path.open("rb") as stream:
        _skip_text_header(stream)

        while True:
            raw_header = stream.read(PACKET_HEADER.size)

            if not raw_header:
                break

            if len(raw_header) != PACKET_HEADER.size:
                raise ValueError("AEDAT包头长度不足")

            (
                event_type,
                event_source,
                event_size,
                timestamp_offset,
                timestamp_overflow,
                event_capacity,
                event_number,
                event_valid,
            ) = PACKET_HEADER.unpack(raw_header)

            if event_size < 8:
                raise ValueError(f"非法事件大小: {event_size}")

            payload_size = event_size * event_number
            payload = stream.read(payload_size)

            if len(payload) != payload_size:
                raise ValueError("AEDAT数据包长度不足")

            # 1表示Polarity Events
            if event_type != 1:
                continue

            if timestamp_offset + 4 > event_size:
                raise ValueError("时间戳字段超出事件长度")

            event_dtype = np.dtype(
                {
                    "names": ["data", "timestamp"],
                    "formats": ["<u4", "<u4"],
                    "offsets": [0, timestamp_offset],
                    "itemsize": event_size,
                }
            )

            records = np.frombuffer(
                payload,
                dtype=event_dtype,
                count=event_number,
            )

            data = records["data"]

            # AEDAT有效位为最低位
            valid_mask = (data & 0x1) != 0

            data = data[valid_mask]
            timestamp = records["timestamp"][valid_mask].astype(np.int64)

            x = ((data >> 17) & 0x1FFF).astype(np.int16)
            y = ((data >> 2) & 0x1FFF).astype(np.int16)
            polarity = ((data >> 1) & 0x1).astype(np.int8)

            timestamp = timestamp + (
                int(timestamp_overflow) << 31
            )

            x_list.append(x)
            y_list.append(y)
            polarity_list.append(polarity)
            timestamp_list.append(timestamp)

    def concatenate(chunks, dtype):
        if not chunks:
            return np.empty(0, dtype=dtype)

        return np.concatenate(chunks).astype(dtype, copy=False)

    x = concatenate(x_list, np.int16)
    y = concatenate(y_list, np.int16)
    polarity = concatenate(polarity_list, np.int8)
    timestamp = concatenate(timestamp_list, np.int64)

    if np.any(x < 0) or np.any(x >= 128):
        raise ValueError("x坐标超出0~127")

    if np.any(y < 0) or np.any(y >= 128):
        raise ValueError("y坐标超出0~127")

    if np.any((polarity != 0) & (polarity != 1)):
        raise ValueError("极性不是0或1")

    # 官方数据可能存在包边界时间戳回退，因此进行稳定排序
    if timestamp.size > 1:
        if np.any(timestamp[1:] < timestamp[:-1]):
            order = np.argsort(timestamp, kind="stable")

            x = x[order]
            y = y[order]
            polarity = polarity[order]
            timestamp = timestamp[order]

    return {
        "x": x,
        "y": y,
        "polarity": polarity,
        "timestamp": timestamp,
    }


if __name__ == "__main__":
    sample = (
        Path(__file__).parents[1]
        / "data"
        / "DVS128Gesture"
        / "DvsGesture"
        / "user01_fluorescent.aedat"
    )

    events = read_aedat(sample)

    print("文件:", sample)
    print("事件数量:", len(events["x"]))
    print("x范围:", int(events["x"].min()), int(events["x"].max()))
    print("y范围:", int(events["y"].min()), int(events["y"].max()))
    print("极性:", np.unique(events["polarity"]))
    print(
        "时间范围:",
        int(events["timestamp"].min()),
        int(events["timestamp"].max()),
    )