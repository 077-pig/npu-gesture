from __future__ import annotations

import argparse
from pathlib import Path
import hashlib
import json
import struct

import numpy as np


PROJECT_ROOT = Path(__file__).resolve().parents[1]

GENERATED_DIR = PROJECT_ROOT / "gesture_generated_improved_v2"
GOLDEN_NPZ    = PROJECT_ROOT / "gesture_models" / "rebuild_quant_v2" / "golden_trace_sample0.npz"
CONFIG_JSON = GENERATED_DIR / "gesture_hardware_config.json"

SDK_SRC = (
    PROJECT_ROOT
    .parent
    .parent
    / "board"
    / "gesture_cnn_lif_board"
    / "gesture_cnn_lif_board.sdk"
    / "gesture_cnn_lif_app"
    / "src"
)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while True:
            block = f.read(1024 * 1024)
            if not block:
                break
            h.update(block)
    return h.hexdigest()


def write_conv_weights(config: dict) -> Path:
    src = GENERATED_DIR / "gesture_conv_weights.hex"
    dst = SDK_SRC / "gesture_conv_weights.bin"

    lines = [
        line.strip()
        for line in src.read_text(encoding="ascii").splitlines()
        if line.strip()
    ]

    if len(lines) != 6800:
        raise ValueError(f"卷积权重数量错误：{len(lines)}，应为6800")

    if any(len(line) != 32 for line in lines):
        raise ValueError("卷积权重每行必须是32个十六进制字符")

    # HEX文件显示顺序与AXI小端字节顺序相反。
    # 每个128 bit word需要整体反转16个字节。
    data = b"".join(bytes.fromhex(line)[::-1] for line in lines)

    if len(data) != 6800 * 16:
        raise ValueError(f"卷积权重字节数错误：{len(data)}")

    dst.write_bytes(data)
    return dst


def write_fc_weights() -> Path:
    src = GENERATED_DIR / "gesture_fc_weights.hex"
    dst = SDK_SRC / "gesture_fc_weights.bin"

    lines = [
        line.strip()
        for line in src.read_text(encoding="ascii").splitlines()
        if line.strip()
    ]

    if len(lines) != 88:
        raise ValueError(f"FC权重数量错误：{len(lines)}，应为88")

    if any(len(line) != 16 for line in lines):
        raise ValueError("FC权重每行必须是16个十六进制字符")

    # 每行是一个64 bit word，同样整体按字节反转。
    data = b"".join(bytes.fromhex(line)[::-1] for line in lines)

    if len(data) != 88 * 8:
        raise ValueError(f"FC权重字节数错误：{len(data)}")

    dst.write_bytes(data)
    return dst


def write_layer_desc(config: dict) -> Path:
    dst = SDK_SRC / "gesture_layer_desc.bin"
    records = []

    for layer in config["layers"]:
        fields = layer["descriptor_fields"]

        if len(fields) != 16:
            raise ValueError("每层描述符必须包含16个字段")

        records.append(struct.pack("<16H", *[int(x) & 0xFFFF for x in fields]))

    data = b"".join(records)

    if len(data) != 3 * 32:
        raise ValueError(f"层描述文件大小错误：{len(data)}")

    dst.write_bytes(data)
    return dst


def write_layer_param(config: dict) -> Path:
    dst = SDK_SRC / "gesture_layer_param.bin"
    records = []

    for layer in config["layers"]:
        weight_base = int(layer["weight_base"])
        quant_base = int(layer["quant_base"])

        # RTL的96 bit格式：
        # [31:0]  权重基地址
        # [47:32] 量化参数基地址
        # [63:48] 输出zero-point
        # [64]    ReLU使能
        # [95:65] 保留
        records.append(
            struct.pack(
                "<I H h B 3x",
                weight_base,
                quant_base,
                0,
                1,
            )
        )

    data = b"".join(records)

    if len(data) != 3 * 12:
        raise ValueError(f"层参数文件大小错误：{len(data)}")

    dst.write_bytes(data)
    return dst


def write_input_sample() -> Path:
    dst = SDK_SRC / "gesture_input_sample0.bin"
    golden = np.load(GOLDEN_NPZ, allow_pickle=False)

    sample = np.asarray(golden["sample"])

    if sample.shape != (16, 64, 64, 2):
        raise ValueError(f"输入形状错误：{sample.shape}")

    if sample.dtype != np.uint16:
        raise ValueError(f"输入类型错误：{sample.dtype}")

    if int(sample.max()) > 255:
        raise ValueError("输入数据超过8 bit，不能直接装入当前RTL")

    # 每个64 bit输入word对应一个像素位置：
    # byte[0] = channel 0
    # byte[1] = channel 1
    # byte[2:16] = 0
    packed = np.zeros((16, 64 * 64, 16), dtype=np.uint8)
    packed[:, :, 0:2] = sample.reshape(16, 64 * 64, 2).astype(np.uint8)

    data = packed.tobytes(order="C")

    if len(data) != 16 * 4096 * 16:
        raise ValueError(f"输入文件大小错误：{len(data)}")

    dst.write_bytes(data)
    return dst


def write_sdk_header(config: dict) -> Path:
    dst = SDK_SRC / "gesture_sdk_params.h"
    golden = np.load(GOLDEN_NPZ, allow_pickle=False)

    quant = config["quant_params"]
    fc = config["fc"]
    spike_counts = golden["spike_counts"].astype(np.int16).tolist()

    if len(quant) != 112:
        raise ValueError(f"量化参数数量错误：{len(quant)}")

    if len(fc["bias"]) != 11:
        raise ValueError("FC偏置数量错误")

    if len(spike_counts) != 11:
        raise ValueError("脉冲计数数量错误")

    lines = []
    lines.append("#ifndef GESTURE_SDK_PARAMS_H")
    lines.append("#define GESTURE_SDK_PARAMS_H")
    lines.append("")
    lines.append("#include <stdint.h>")
    lines.append("")
    lines.append("#define GESTURE_LAYER_COUNT 3u")
    lines.append("#define GESTURE_CONV_WORD_COUNT 6800u")
    lines.append("#define GESTURE_QUANT_COUNT 112u")
    lines.append("#define GESTURE_FC_CLASS_COUNT 11u")
    lines.append("#define GESTURE_FC_WORD_COUNT 88u")
    input_config = config["input"]
    input_width = int(input_config["width"])
    input_height = int(input_config["height"])
    input_channels = int(input_config["channels"])
    time_steps = int(input_config["time_steps"])
    input_channel_blocks = (input_channels + 15) // 16
    feature_words = input_width * input_height * input_channel_blocks

    lines.append(f"#define GESTURE_INPUT_WIDTH {input_width}u")
    lines.append(f"#define GESTURE_INPUT_HEIGHT {input_height}u")
    lines.append(f"#define GESTURE_INPUT_CHANNELS {input_channels}u")
    lines.append(f"#define GESTURE_FRAME_COUNT {time_steps}u")
    lines.append(f"#define GESTURE_FEATURE_WORDS_PER_FRAME {feature_words}u")
    lines.append("#define GESTURE_FEATURE_DEPTH_WORDS 4096u")
    lines.append("#define GESTURE_EXPECTED_CLASS 0u")
    lines.append("")
    lines.append("typedef struct {")
    lines.append("    int32_t bias;")
    lines.append("    int16_t multiplier;")
    lines.append("    uint8_t shift;")
    lines.append("} gesture_quant_param_t;")
    lines.append("")
    lines.append(
        "static const gesture_quant_param_t "
        "gesture_quant_params[GESTURE_QUANT_COUNT] = {"
    )

    for item in quant:
        lines.append(
            "    {%d, %d, %d},"
            % (
                int(item["bias"]),
                int(item["multiplier"]),
                int(item["shift"]),
            )
        )

    lines.append("};")
    lines.append("")

    bias_text = ", ".join(str(int(x)) for x in fc["bias"])
    count_text = ", ".join(str(int(x)) for x in spike_counts)

    lines.append(
        "static const int32_t gesture_fc_bias"
        "[GESTURE_FC_CLASS_COUNT] = "
        "{%s};" % bias_text
    )
    lines.append(
        "static const uint16_t gesture_expected_counts"
        "[GESTURE_FC_CLASS_COUNT] = "
        "{%s};" % count_text
    )
    lines.append("")
    lines.append("#endif")
    lines.append("")

    dst.write_text("\n".join(lines), encoding="ascii")
    return dst


def write_blob_assembly(paths: list[Path]) -> Path:
    dst = SDK_SRC / "gesture_data_blob.S"

    names = [
        "gesture_input_sample0",
        "gesture_conv_weights",
        "gesture_fc_weights",
        "gesture_layer_desc",
        "gesture_layer_param",
    ]

    lines = [
        '    .section .rodata.gesture_data,"a",%progbits',
        "    .balign 16",
        "",
    ]

    for symbol, path in zip(names, paths):
        asm_path = path.resolve().as_posix()
        lines.extend(
            [
                f"    .global {symbol}",
                f"    .global {symbol}_end",
                f"{symbol}:",
                f'    .incbin "{asm_path}"',
                f"{symbol}_end:",
                "    .balign 16",
                "",
            ]
        )

    lines.append('    .section .note.GNU-stack,"",%progbits')
    lines.append("")

    dst.write_text("\n".join(lines), encoding="ascii")
    return dst


def main() -> None:
    global GENERATED_DIR, GOLDEN_NPZ, CONFIG_JSON, SDK_SRC

    parser = argparse.ArgumentParser(
        description="根据硬件参数生成动态手势SDK数据文件"
    )
    parser.add_argument(
        "--generated-dir",
        type=Path,
        default=GENERATED_DIR,
        help="硬件参数目录，默认使用旧输出目录",
    )
    parser.add_argument(
        "--golden",
        type=Path,
        default=GOLDEN_NPZ,
        help="golden_trace_sample0.npz路径",
    )
    parser.add_argument(
        "--sdk-src",
        type=Path,
        default=SDK_SRC,
        help="SDK文件输出目录，默认使用板级工程src",
    )
    args = parser.parse_args()

    GENERATED_DIR = args.generated_dir.resolve()
    GOLDEN_NPZ = args.golden.resolve()
    SDK_SRC = args.sdk_src.resolve()
    CONFIG_JSON = GENERATED_DIR / "gesture_hardware_config.json"

    if not CONFIG_JSON.exists():
        raise FileNotFoundError(CONFIG_JSON)

    if not GOLDEN_NPZ.exists():
        raise FileNotFoundError(GOLDEN_NPZ)

    SDK_SRC.mkdir(parents=True, exist_ok=True)

    config = json.loads(CONFIG_JSON.read_text(encoding="utf-8"))

    conv = write_conv_weights(config)
    fc = write_fc_weights()
    desc = write_layer_desc(config)
    layer_param = write_layer_param(config)
    input_sample = write_input_sample()
    header = write_sdk_header(config)
    blob = write_blob_assembly(
        [input_sample, conv, fc, desc, layer_param]
    )

    output_files = [
        input_sample,
        conv,
        fc,
        desc,
        layer_param,
        header,
        blob,
    ]

    manifest = {}
    for path in output_files:
        manifest[path.name] = {
            "bytes": path.stat().st_size,
            "sha256": sha256_file(path),
        }

    manifest_path = SDK_SRC / "gesture_data_manifest.json"
    manifest_path.write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )

    print("自己的SDK数据文件生成完成")
    print(f"输出目录：{SDK_SRC}")

    for path in output_files:
        print(f"{path.name}: {path.stat().st_size} bytes")


if __name__ == "__main__":
    main()
