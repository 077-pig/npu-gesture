from __future__ import annotations

"""导出DVS128 Gesture定点模型的硬件参数。

本脚本只生成参数文件，不修改RTL、Vivado工程或板级SDK。
权重布局与现有16x8 NPU的软件打包约定一致：
  一个128 bit权重word包含16个INT8，低8 bit对应第0个输入通道。
"""

import argparse
from pathlib import Path
import json
import os
import sys

import numpy as np


PROJECT_ROOT = Path(__file__).resolve().parents[1]
QUANT_DIR   = PROJECT_ROOT / "gesture_models" / "rebuild_quant_v2"
OUTPUT_DIR  = PROJECT_ROOT / "gesture_generated_improved_v2"                     # 原: gesture_generated

WEIGHT_NPZ = QUANT_DIR / "cnn_lif_int8_parameters.npz"
WEIGHT_JSON = QUANT_DIR / "cnn_lif_int8_parameters.json"
BIAS_NPZ = QUANT_DIR / "cnn_lif_int32_biases.npz"
ACTIVATION_JSON = QUANT_DIR / "activation_calibration.json"

MAX_K_TILES = 64
OUTPUT_LANES = 8
INPUT_LANES = 16
WEIGHT_CAPACITY = 8192


def load_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as file:
        return json.load(file)


def pack_word(values: list[int]) -> str:
    if len(values) != INPUT_LANES:
        raise ValueError("一个卷积权重word必须包含16个INT8")
    # 低8 bit是values[0]，HEX显示时从高lane写到低lane。
    return "".join(f"{int(v) & 0xFF:02X}" for v in reversed(values))


def pack_conv_layer(weights_oihw: np.ndarray, base: int) -> tuple[dict[int, str], dict]:
    if weights_oihw.ndim != 4:
        raise ValueError(f"卷积权重必须是四维，实际为{weights_oihw.shape}")
    output_channels, input_channels, kernel_height, kernel_width = weights_oihw.shape
    weights = np.transpose(weights_oihw, (0, 2, 3, 1))  # [O,H,W,I]
    input_blocks = (input_channels + INPUT_LANES - 1) // INPUT_LANES
    k_tiles = kernel_height * kernel_width * input_blocks
    output_tiles = (output_channels + OUTPUT_LANES - 1) // OUTPUT_LANES
    if k_tiles > MAX_K_TILES:
        raise ValueError(f"k_tiles={k_tiles}超过硬件上限{MAX_K_TILES}")

    words: dict[int, str] = {}
    for output_tile in range(output_tiles):
        for k_tile in range(k_tiles):
            kernel_y = k_tile // (kernel_width * input_blocks)
            remainder = k_tile % (kernel_width * input_blocks)
            kernel_x = remainder // input_blocks
            input_block = remainder % input_blocks
            for column in range(OUTPUT_LANES):
                output_channel = output_tile * OUTPUT_LANES + column
                lanes = []
                for lane in range(INPUT_LANES):
                    input_channel = input_block * INPUT_LANES + lane
                    if output_channel < output_channels and input_channel < input_channels:
                        value = int(weights[output_channel, kernel_y, kernel_x, input_channel])
                    else:
                        value = 0
                    lanes.append(value)
                address = base + output_tile * MAX_K_TILES * OUTPUT_LANES + k_tile * OUTPUT_LANES + column
                words[address] = pack_word(lanes)

    return words, {
        "input_channels": int(input_channels),
        "output_channels": int(output_channels),
        "kernel_height": int(kernel_height),
        "kernel_width": int(kernel_width),
        "input_blocks": int(input_blocks),
        "k_tiles": int(k_tiles),
        "output_tiles": int(output_tiles),
        "weight_base": int(base),
    }


def make_descriptor(layer: dict) -> list[int]:
    input_blocks = (layer["in_channels"] + INPUT_LANES - 1) // INPUT_LANES
    k_tiles = layer["kernel_width"] * layer["kernel_height"] * input_blocks
    output_x_step = layer["stride"] * input_blocks
    output_row_step = (layer["in_width"] - (layer["out_width"] - 1)) * layer["stride"] * input_blocks
    kernel_row_step = (layer["in_width"] - layer["kernel_width"]) * input_blocks + 1
    window_base = -(layer["pad_top"] * layer["in_width"] + layer["pad_left"]) * input_blocks
    fields = [
        layer["in_width"], layer["in_height"], input_blocks,
        layer["kernel_width"], layer["kernel_height"], layer["stride"],
        layer["pad_left"], layer["pad_top"], layer["out_width"], layer["out_height"],
        k_tiles, layer["out_channels"], output_x_step, output_row_step,
        kernel_row_step, window_base,
    ]
    for value in fields:
        if not (-32768 <= int(value) <= 65535):
            raise ValueError(f"层描述字段超出16 bit范围：{value}")
    return [int(value) & 0xFFFF for value in fields]


def choose_multiplier(ratio: float, preferred_shift: int) -> tuple[int, int, float]:
    multiplier = int(np.rint(ratio * (1 << preferred_shift)))
    if not (-32768 <= multiplier <= 32767):
        raise ValueError(f"multiplier超出INT16：ratio={ratio}, shift={preferred_shift}, multiplier={multiplier}")
    represented = multiplier / float(1 << preferred_shift)
    return multiplier, preferred_shift, represented


def main() -> None:
    parser = argparse.ArgumentParser(
        description="导出动态手势CNN+LIF的硬件参数"
    )
    parser.add_argument(
        "--quant-dir",
        type=Path,
        default=QUANT_DIR,
        help="量化文件目录，默认使用旧基线目录",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=OUTPUT_DIR,
        help="导出文件目录，默认使用旧输出目录",
    )
    args = parser.parse_args()

    quant_dir = args.quant_dir.resolve()
    output_dir = args.output_dir.resolve()
    weight_npz = quant_dir / "cnn_lif_int8_parameters.npz"
    weight_json = quant_dir / "cnn_lif_int8_parameters.json"
    bias_npz = quant_dir / "cnn_lif_int32_biases.npz"
    activation_json = quant_dir / "activation_calibration.json"

    for path in (weight_npz, weight_json, bias_npz, activation_json):
        if not path.exists():
            raise FileNotFoundError(f"缺少量化文件：{path}")

    weights = np.load(weight_npz)
    biases = np.load(bias_npz)
    weight_report = load_json(weight_json)
    activation = load_json(activation_json)
    ranges = activation["ranges"]

    input_scale = float(activation["input_scale"])
    output_scales = [
        float(ranges["conv1_relu"]["int8_scale"]),
        float(ranges["conv2_relu"]["int8_scale"]),
        float(ranges["conv3_relu"]["int8_scale"]),
    ]
    input_scales = [input_scale, output_scales[0], output_scales[1]]
    weight_names = ["conv1.weight", "conv2.weight", "conv3.weight", "classifier.weight"]
    weight_scales = [float(weight_report["parameters"][name]["scale"]) for name in weight_names]

    layer_specs = [
        {"in_width": 64, "in_height": 64, "in_channels": 2, "out_width": 32, "out_height": 32, "out_channels": 16, "kernel_width": 3, "kernel_height": 3, "stride": 2, "pad_left": 1, "pad_top": 1, "weight_base": 0, "quant_base": 0},
        {"in_width": 32, "in_height": 32, "in_channels": 16, "out_width": 16, "out_height": 16, "out_channels": 32, "kernel_width": 3, "kernel_height": 3, "stride": 2, "pad_left": 1, "pad_top": 1, "weight_base": 1024, "quant_base": 16},
        {"in_width": 16, "in_height": 16, "in_channels": 32, "out_width": 8, "out_height": 8, "out_channels": 64, "kernel_width": 3, "kernel_height": 3, "stride": 2, "pad_left": 1, "pad_top": 1, "weight_base": 3072, "quant_base": 48},
    ]

    packed_words: dict[int, str] = {}
    layer_reports = []
    quant_records = []
    qweight_keys = ["q_conv1_weight", "q_conv2_weight", "q_conv3_weight"]
    qbias_keys = ["conv1_bias", "conv2_bias", "conv3_bias"]

    for index, layer in enumerate(layer_specs):
        words, report = pack_conv_layer(weights[qweight_keys[index]], layer["weight_base"])
        overlap = set(packed_words).intersection(words)
        if overlap:
            raise ValueError(f"卷积权重地址重叠：{sorted(overlap)[:5]}")
        packed_words.update(words)
        layer_reports.append({**layer, **report, "descriptor_fields": make_descriptor(layer)})

        ratio = input_scales[index] * weight_scales[index] / output_scales[index]
        multiplier, shift, represented = choose_multiplier(ratio, 22)
        for channel, bias in enumerate(biases[qbias_keys[index]]):
            quant_records.append({"address": layer["quant_base"] + channel, "bias": int(bias), "multiplier": multiplier, "shift": shift, "ratio": ratio, "represented_ratio": represented})

    fc_ratio = float(ranges["gap"]["int8_scale"]) * weight_scales[3] / float(ranges["fc_current"]["int8_scale"])
    fc_multiplier, fc_shift, fc_repr = choose_multiplier(fc_ratio, 20)

    output_dir.mkdir(parents=True, exist_ok=True)
    dense_words = [packed_words.get(address, "0" * 32) for address in range(max(packed_words) + 1)]
    (output_dir / "gesture_conv_weights.hex").write_text(
        "\n".join(dense_words) + "\n",
        encoding="ascii",
    )

    fc_weights = weights["q_classifier_weight"].astype(np.int8)
    fc_lines = []
    for row in fc_weights:
        padded = np.pad(row, (0, (-len(row)) % 8))
        fc_lines.extend("".join(f"{int(v) & 0xFF:02X}" for v in reversed(padded[i:i + 8])) for i in range(0, len(padded), 8))
    (output_dir / "gesture_fc_weights.hex").write_text(
        "\n".join(fc_lines) + "\n",
        encoding="ascii",
    )

    (output_dir / "gesture_hardware_config.json").write_text(json.dumps({
        "source_quant_dir": Path(os.path.relpath(quant_dir, PROJECT_ROOT.parents[1])).as_posix(),
        "input": {"width": 64, "height": 64, "channels": 2, "time_steps": 16},
        "layers": layer_reports,
        "quant_params": quant_records,
        "fc": {"input_length": 64, "classes": 11, "weight_scale": weight_scales[3], "bias": biases["classifier_bias"].astype(int).tolist(), "multiplier": fc_multiplier, "shift": fc_shift, "ratio": fc_ratio, "represented_ratio": fc_repr},
        "lif": {"leak_numerator": 1, "leak_denominator": 2, "threshold_float": 0.5, "current_scale": float(ranges["fc_current"]["int8_scale"]), "threshold_q": int(np.rint(0.5 / float(ranges["fc_current"]["int8_scale"])))},
        "capacity_check": {"conv_weight_words_used": len(dense_words), "conv_weight_capacity": WEIGHT_CAPACITY, "fc_weight_words": len(fc_lines)},
    }, indent=2, ensure_ascii=False), encoding="utf-8")

    print("动态手势硬件参数导出完成")
    print("卷积权重word:", len(dense_words), "/", WEIGHT_CAPACITY)
    print("FC权重word:", len(fc_lines))
    print("输出目录:", output_dir)
    print("注意：这些文件还不能直接让现有RTL执行LIF；LIF时间步控制仍需单独实现。")


if __name__ == "__main__":
    main()
