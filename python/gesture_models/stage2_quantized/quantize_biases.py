from __future__ import annotations

from pathlib import Path
import json

import numpy as np
import torch


# ============================================================
# 1. 路径
# ============================================================

# 当前文件：
# gesture_models/stage2_quantized/quantize_biases.py
PROJECT_ROOT = Path(__file__).resolve().parents[2]

FLOAT_MODEL_PATH = (
    PROJECT_ROOT
    / "gesture_models"
    / "stage2_cnn_lif"
    / "cnn_lif_thr05_best.pt"
)

WEIGHT_REPORT_PATH = (
    PROJECT_ROOT
    / "gesture_models"
    / "stage2_quantized"
    / "cnn_lif_int8_parameters.json"
)

ACTIVATION_REPORT_PATH = (
    PROJECT_ROOT
    / "gesture_models"
    / "stage2_quantized"
    / "activation_calibration.json"
)

OUTPUT_DIR = (
    PROJECT_ROOT
    / "gesture_models"
    / "stage2_quantized"
)

OUTPUT_NPZ = (
    OUTPUT_DIR
    / "cnn_lif_int32_biases.npz"
)

OUTPUT_JSON = (
    OUTPUT_DIR
    / "cnn_lif_int32_biases.json"
)


# ============================================================
# 2. 读取JSON报告
# ============================================================

def load_json(path: Path) -> dict:
    if not path.exists():
        raise FileNotFoundError(
            f"找不到文件：{path}"
        )

    with path.open(
        "r",
        encoding="utf-8",
    ) as file:
        return json.load(file)


# ============================================================
# 3. 读取浮点偏置
# ============================================================

def load_float_biases() -> dict[str, np.ndarray]:
    if not FLOAT_MODEL_PATH.exists():
        raise FileNotFoundError(
            f"找不到浮点模型：{FLOAT_MODEL_PATH}"
        )

    checkpoint = torch.load(
        FLOAT_MODEL_PATH,
        map_location="cpu",
    )

    state_dict = checkpoint["model_state_dict"]

    required_biases = [
        "conv1.bias",
        "conv2.bias",
        "conv3.bias",
        "classifier.bias",
    ]

    result = {}

    for name in required_biases:
        if name not in state_dict:
            raise KeyError(
                f"模型中缺少偏置：{name}"
            )

        result[name] = (
            state_dict[name]
            .detach()
            .cpu()
            .numpy()
            .astype(np.float32)
        )

    return result


# ============================================================
# 4. 计算单层INT32偏置
# ============================================================

def quantize_bias(
    float_bias: np.ndarray,
    input_scale: float,
    weight_scale: float,
) -> tuple[np.ndarray, float]:
    """
    偏置量化公式：

        bias_scale = input_scale × weight_scale

        q_bias = round(float_bias / bias_scale)

    硬件中：
        INT8输入 × INT8权重 -> INT32累加
        INT32累加和INT32偏置必须使用同一个比例。
    """

    if input_scale <= 0.0:
        raise ValueError(
            f"input_scale必须大于0，实际为{input_scale}"
        )

    if weight_scale <= 0.0:
        raise ValueError(
            f"weight_scale必须大于0，实际为{weight_scale}"
        )

    bias_scale = input_scale * weight_scale

    quantized = np.rint(
        float_bias / bias_scale
    )

    if np.any(
        quantized < np.iinfo(np.int32).min
    ) or np.any(
        quantized > np.iinfo(np.int32).max
    ):
        raise OverflowError(
            "偏置量化后超出INT32范围"
        )

    quantized = quantized.astype(np.int32)

    return quantized, bias_scale


# ============================================================
# 5. 主程序
# ============================================================

def main() -> None:
    OUTPUT_DIR.mkdir(
        parents=True,
        exist_ok=True,
    )

    weight_report = load_json(
        WEIGHT_REPORT_PATH
    )

    activation_report = load_json(
        ACTIVATION_REPORT_PATH
    )

    float_biases = load_float_biases()

    activation_ranges = (
        activation_report["ranges"]
    )

    parameter_info = (
        weight_report["parameters"]
    )

    input_scale = float(
        activation_report["input_scale"]
    )

    # 读取四层权重scale
    conv1_weight_scale = float(
        parameter_info["conv1.weight"]["scale"]
    )

    conv2_weight_scale = float(
        parameter_info["conv2.weight"]["scale"]
    )

    conv3_weight_scale = float(
        parameter_info["conv3.weight"]["scale"]
    )

    classifier_weight_scale = float(
        parameter_info["classifier.weight"]["scale"]
    )

    # 读取四层输入激活scale
    conv1_input_scale = input_scale

    conv2_input_scale = float(
        activation_ranges["conv1_relu"]["int8_scale"]
    )

    conv3_input_scale = float(
        activation_ranges["conv2_relu"]["int8_scale"]
    )

    classifier_input_scale = float(
        activation_ranges["gap"]["int8_scale"]
    )

    q_conv1_bias, conv1_bias_scale = quantize_bias(
        float_biases["conv1.bias"],
        conv1_input_scale,
        conv1_weight_scale,
    )

    q_conv2_bias, conv2_bias_scale = quantize_bias(
        float_biases["conv2.bias"],
        conv2_input_scale,
        conv2_weight_scale,
    )

    q_conv3_bias, conv3_bias_scale = quantize_bias(
        float_biases["conv3.bias"],
        conv3_input_scale,
        conv3_weight_scale,
    )

    q_classifier_bias, classifier_bias_scale = quantize_bias(
        float_biases["classifier.bias"],
        classifier_input_scale,
        classifier_weight_scale,
    )

    np.savez(
        OUTPUT_NPZ,
        conv1_bias=q_conv1_bias,
        conv2_bias=q_conv2_bias,
        conv3_bias=q_conv3_bias,
        classifier_bias=q_classifier_bias,
    )

    report = {
        "model": "cnn_lif_threshold_0.5",
        "float_model": str(FLOAT_MODEL_PATH),
        "input_scale": input_scale,
        "biases": {
            "conv1.bias": {
                "shape": list(q_conv1_bias.shape),
                "input_scale": conv1_input_scale,
                "weight_scale": conv1_weight_scale,
                "bias_scale": conv1_bias_scale,
                "dtype": "int32",
                "min": int(q_conv1_bias.min()),
                "max": int(q_conv1_bias.max()),
            },
            "conv2.bias": {
                "shape": list(q_conv2_bias.shape),
                "input_scale": conv2_input_scale,
                "weight_scale": conv2_weight_scale,
                "bias_scale": conv2_bias_scale,
                "dtype": "int32",
                "min": int(q_conv2_bias.min()),
                "max": int(q_conv2_bias.max()),
            },
            "conv3.bias": {
                "shape": list(q_conv3_bias.shape),
                "input_scale": conv3_input_scale,
                "weight_scale": conv3_weight_scale,
                "bias_scale": conv3_bias_scale,
                "dtype": "int32",
                "min": int(q_conv3_bias.min()),
                "max": int(q_conv3_bias.max()),
            },
            "classifier.bias": {
                "shape": list(q_classifier_bias.shape),
                "input_scale": classifier_input_scale,
                "weight_scale": classifier_weight_scale,
                "bias_scale": classifier_bias_scale,
                "dtype": "int32",
                "min": int(q_classifier_bias.min()),
                "max": int(q_classifier_bias.max()),
            },
        },
        "output_npz": str(OUTPUT_NPZ),
    }

    OUTPUT_JSON.write_text(
        json.dumps(
            report,
            indent=2,
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )

    print("INT32偏置量化完成")
    print("------------------------------")

    for name, info in report["biases"].items():
        print(name)
        print("  input_scale:", info["input_scale"])
        print("  weight_scale:", info["weight_scale"])
        print("  bias_scale:", info["bias_scale"])
        print("  int32_min:", info["min"])
        print("  int32_max:", info["max"])

    print()
    print("输出文件：")
    print(OUTPUT_NPZ)
    print(OUTPUT_JSON)


if __name__ == "__main__":
    main()