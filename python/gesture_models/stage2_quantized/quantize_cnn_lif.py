from __future__ import annotations

from pathlib import Path
import json

import numpy as np
import torch


# ============================================================
# 1. 路径
# ============================================================

# 当前文件位于：
# gesture_models/stage2_quantized/quantize_cnn_lif.py
# parents[0] = stage2_quantized
# parents[1] = gesture_models
# parents[2] = 16x8_NPU_CNN工程根目录
PROJECT_ROOT = Path(__file__).resolve().parents[2]

FLOAT_MODEL_PATH = (
    PROJECT_ROOT
    / "gesture_models"
    / "stage2_cnn_lif"
    / "cnn_lif_thr05_best.pt"
)

OUTPUT_DIR = (
    PROJECT_ROOT
    / "gesture_models"
    / "stage2_quantized"
)

OUTPUT_NPZ = OUTPUT_DIR / "cnn_lif_int8_parameters.npz"
OUTPUT_JSON = OUTPUT_DIR / "cnn_lif_int8_parameters.json"


# 输入数据在训练时的处理方式是：
# 原始事件计数先限制到0~127，再除以127
INPUT_SCALE = 1.0 / 127.0


# ============================================================
# 2. 对称INT8量化函数
# ============================================================

def quantize_symmetric_int8(
    tensor: torch.Tensor,
) -> tuple[np.ndarray, float]:
    """
    对一个浮点张量做对称INT8量化。

    量化公式：

        scale = max(abs(x)) / 127
        q     = round(x / scale)

    q的范围限制为[-127, 127]。
    """

    values = tensor.detach().cpu().numpy().astype(
        np.float32,
        copy=False,
    )

    max_abs = float(np.max(np.abs(values)))

    # 全零张量不能除以0
    if max_abs == 0.0:
        scale = 1.0
        quantized = np.zeros_like(
            values,
            dtype=np.int8,
        )
        return quantized, scale

    scale = max_abs / 127.0

    quantized = np.rint(
        values / scale
    )

    quantized = np.clip(
        quantized,
        -127,
        127,
    ).astype(np.int8)

    return quantized, scale


# ============================================================
# 3. 读取浮点模型
# ============================================================

def load_state_dict() -> dict[str, torch.Tensor]:
    if not FLOAT_MODEL_PATH.exists():
        raise FileNotFoundError(
            f"找不到浮点模型：{FLOAT_MODEL_PATH}"
        )

    checkpoint = torch.load(
        FLOAT_MODEL_PATH,
        map_location="cpu",
    )

    if "model_state_dict" not in checkpoint:
        raise KeyError(
            "模型文件中没有model_state_dict字段"
        )

    state_dict = checkpoint["model_state_dict"]

    print("读取浮点模型：")
    print(FLOAT_MODEL_PATH)
    print()

    print("模型参数：")
    for name, tensor in state_dict.items():
        print(
            f"{name:25s}",
            tuple(tensor.shape),
            tensor.dtype,
        )

    print()

    return state_dict


# ============================================================
# 4. 量化所有参数
# ============================================================

def quantize_parameters(
    state_dict: dict[str, torch.Tensor],
):
    output_arrays: dict[str, np.ndarray] = {}
    parameter_info: dict[str, dict] = {}

    for name, tensor in state_dict.items():
        safe_name = name.replace(".", "_")

        values = tensor.detach().cpu().numpy().astype(
            np.float32,
            copy=False,
        )

        # 权重张量：卷积权重和全连接权重
        if tensor.ndim >= 2:
            quantized, scale = (
                quantize_symmetric_int8(tensor)
            )

            output_arrays[
                f"q_{safe_name}"
            ] = quantized

            output_arrays[
                f"float_{safe_name}"
            ] = values

            parameter_info[name] = {
                "kind": "weight",
                "shape": list(values.shape),
                "float_dtype": "float32",
                "quantized_dtype": "int8",
                "scale": scale,
                "min_float": float(values.min()),
                "max_float": float(values.max()),
                "max_abs_float": float(np.max(np.abs(values))),
                "q_min": int(quantized.min()),
                "q_max": int(quantized.max()),
            }

        # 偏置张量：本阶段先保留浮点值
        else:
            output_arrays[
                f"float_{safe_name}"
            ] = values.astype(np.float32)

            parameter_info[name] = {
                "kind": "bias_or_vector",
                "shape": list(values.shape),
                "float_dtype": "float32",
                "quantized_dtype": "not_yet_quantized",
                "note": (
                    "偏置需要结合输入激活scale和权重scale，"
                    "将在激活校准后量化为INT32"
                ),
                "min_float": float(values.min()),
                "max_float": float(values.max()),
            }

    return output_arrays, parameter_info


# ============================================================
# 5. 检查反量化误差
# ============================================================

def calculate_weight_errors(
    output_arrays: dict[str, np.ndarray],
    parameter_info: dict[str, dict],
):
    errors = {}

    for name, info in parameter_info.items():
        if info["kind"] != "weight":
            continue

        safe_name = name.replace(".", "_")

        float_values = output_arrays[
            f"float_{safe_name}"
        ]

        quantized_values = output_arrays[
            f"q_{safe_name}"
        ]

        scale = float(info["scale"])

        restored = (
            quantized_values.astype(np.float32)
            * scale
        )

        absolute_error = np.abs(
            restored - float_values
        )

        errors[name] = {
            "max_absolute_error": float(
                absolute_error.max()
            ),
            "mean_absolute_error": float(
                absolute_error.mean()
            ),
            "rmse": float(
                np.sqrt(
                    np.mean(
                        absolute_error ** 2
                    )
                )
            ),
        }

    return errors


# ============================================================
# 6. 主程序
# ============================================================

def main() -> None:
    OUTPUT_DIR.mkdir(
        parents=True,
        exist_ok=True,
    )

    state_dict = load_state_dict()

    output_arrays, parameter_info = (
        quantize_parameters(state_dict)
    )

    errors = calculate_weight_errors(
        output_arrays,
        parameter_info,
    )

    np.savez(
        OUTPUT_NPZ,
        input_scale=np.asarray(
            INPUT_SCALE,
            dtype=np.float32,
        ),
        **output_arrays,
    )

    report = {
        "model": "cnn_lif_threshold_0.5",
        "input_scale": INPUT_SCALE,
        "quantization": {
            "weight_type": "symmetric_int8",
            "weight_range": [-127, 127],
            "bias_type": "not_quantized_yet",
        },
        "source_model": str(FLOAT_MODEL_PATH),
        "output_npz": str(OUTPUT_NPZ),
        "parameters": parameter_info,
        "weight_errors": errors,
    }

    OUTPUT_JSON.write_text(
        json.dumps(
            report,
            indent=2,
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )

    print()
    print("INT8权重量化完成")
    print("------------------------------")
    print("输入scale:", INPUT_SCALE)
    print("输出文件:", OUTPUT_NPZ)
    print("报告文件:", OUTPUT_JSON)
    print()

    print("量化误差：")
    for name, item in errors.items():
        print(
            name,
            "max_error=",
            item["max_absolute_error"],
            "mean_error=",
            item["mean_absolute_error"],
            "rmse=",
            item["rmse"],
        )


if __name__ == "__main__":
    main()