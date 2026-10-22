from __future__ import annotations

from pathlib import Path
import json
import sys

import numpy as np
import torch
import torch.nn.functional as F


PROJECT_ROOT = Path(__file__).resolve().parents[1]

sys.path.insert(
    0,
    str(PROJECT_ROOT / "gesture_tools"),
)

from train_cnn_lif_v2 import CNNLIF


CACHE_PATH = (
    Path(__file__).resolve().parents[3]
    / "data"
    / "DVS128Gesture"
    / "frames_t16_uint16.npz"
)

METADATA_PATH = (
    Path(__file__).resolve().parents[3]
    / "data"
    / "DVS128Gesture"
    / "frames_t16_uint16.json"
)

FLOAT_MODEL_PATH = (
    PROJECT_ROOT
    / "gesture_models"
    / "stage2_cnn_lif_v2_reconstructed"
    / "cnn_lif_improved_best.pt"
)

WEIGHT_REPORT_PATH = (
    PROJECT_ROOT
    / "gesture_models"
    / "stage2_quantized"
    / "cnn_lif_int8_parameters.json"
)

WEIGHT_NPZ_PATH = (
    PROJECT_ROOT
    / "gesture_models"
    / "stage2_quantized"
    / "cnn_lif_int8_parameters.npz"
)

BIAS_REPORT_PATH = (
    PROJECT_ROOT
    / "gesture_models"
    / "stage2_quantized"
    / "cnn_lif_int32_biases.json"
)

BIAS_NPZ_PATH = (
    PROJECT_ROOT
    / "gesture_models"
    / "stage2_quantized"
    / "cnn_lif_int32_biases.npz"
)

ACTIVATION_REPORT_PATH = (
    PROJECT_ROOT
    / "gesture_models"
    / "stage2_quantized"
    / "activation_calibration.json"
)

OUTPUT_PATH = (
    PROJECT_ROOT
    / "gesture_models"
    / "stage2_quantized"
    / "fixed_point_report.json"
)

TRACE_OUTPUT_PATH = (
    PROJECT_ROOT
    / "gesture_models"
    / "stage2_quantized"
    / "golden_trace_sample0.npz"
)

TRACE_META_PATH = (
    PROJECT_ROOT
    / "gesture_models"
    / "stage2_quantized"
    / "golden_trace_sample0.json"
)


# ============================================================
# 1. 工具函数
# ============================================================

def load_json(path: Path) -> dict:
    if not path.exists():
        raise FileNotFoundError(f"找不到文件：{path}")

    with path.open("r", encoding="utf-8") as file:
        return json.load(file)


def round_int(value):
    """
    使用四舍五入模拟硬件定点舍入。
    """
    return np.rint(value).astype(np.int64)


def saturate_int8(value):
    return np.clip(value, -127, 127).astype(np.int64)


def get_test_indices(metadata: list[dict]) -> np.ndarray:
    """
    使用user24~user29作为官方测试集。
    """

    indices = []

    for index, item in enumerate(metadata):
        trial_name = item["trial"]
        user_name = trial_name.split("_")[0]
        user_id = int(user_name.replace("user", ""))

        if 24 <= user_id <= 29:
            indices.append(index)

    return np.asarray(indices, dtype=np.int64)


# ============================================================
# 2. 单样本浮点推理
# ============================================================

def run_float_one_sample(
    model: CNNLIF,
    frame_sample: np.ndarray,
) -> int:
    """
    输入：
        [16,64,64,2]

    输出：
        11类预测结果
    """

    sample = np.minimum(
        frame_sample,
        127,
    ).astype(np.float32) / 127.0

    sample = np.transpose(
        sample,
        (0, 3, 1, 2),
    )

    tensor = torch.from_numpy(
        sample
    ).unsqueeze(0)

    with torch.no_grad():
        output = model(tensor)

    return int(output.argmax(dim=1).item())


# ============================================================
# 3. 单样本定点推理
# ============================================================

def run_fixed_one_sample(
    frame_sample: np.ndarray,
    q_weights: dict,
    q_biases: dict,
    scales: dict,
    threshold_q_override: int | None = None,
) -> tuple[int, dict]:
    """
    使用整数权重、整数偏置和整数膜电位执行16步推理。

    返回：
        prediction
        trace
    """

    # 输入事件计数本身就是0~127的INT8值
    input_scale = scales["input"]

    conv1_output_scale = scales["conv1_relu"]
    conv2_output_scale = scales["conv2_relu"]
    conv3_output_scale = scales["conv3_relu"]
    gap_scale = scales["gap"]
    current_scale = scales["fc_current"]

    conv1_weight_scale = scales["conv1_weight"]
    conv2_weight_scale = scales["conv2_weight"]
    conv3_weight_scale = scales["conv3_weight"]
    fc_weight_scale = scales["fc_weight"]

    q_conv1_weight = torch.from_numpy(
        q_weights["conv1.weight"]
    ).float()

    q_conv2_weight = torch.from_numpy(
        q_weights["conv2.weight"]
    ).float()

    q_conv3_weight = torch.from_numpy(
        q_weights["conv3.weight"]
    ).float()

    q_fc_weight = torch.from_numpy(
        q_weights["classifier.weight"]
    ).float()

    q_conv1_bias = torch.from_numpy(
        q_biases["conv1.bias"]
    ).float()

    q_conv2_bias = torch.from_numpy(
        q_biases["conv2.bias"]
    ).float()

    q_conv3_bias = torch.from_numpy(
        q_biases["conv3.bias"]
    ).float()

    q_fc_bias = torch.from_numpy(
        q_biases["classifier.bias"]
    ).float()

    threshold_float = 0.5
    threshold_q = (
        int(threshold_q_override)
        if threshold_q_override is not None
        else int(np.rint(threshold_float / current_scale))
    )

    membrane = np.zeros(
        11,
        dtype=np.int64,
    )

    spike_counts = np.zeros(
        11,
        dtype=np.int64,
    )

    trace = {
        "conv1_relu": [],
        "conv2_relu": [],
        "conv3_relu": [],
        "gap": [],
        "membrane": [],
        "spikes": [],
        "current": [],
    }

    for time_index in range(16):
        frame = np.minimum(
            frame_sample[time_index],
            127,
        ).astype(np.int64)

        # [H,W,C] -> [1,C,H,W]
        q_input = np.transpose(
            frame,
            (2, 0, 1),
        )[None, :, :, :]

        q_input_tensor = torch.from_numpy(
            q_input.astype(np.float32)
        )

        # ----------------------------------------------------
        # Conv1
        # ----------------------------------------------------
        acc1 = F.conv2d(
            q_input_tensor,
            q_conv1_weight,
            q_conv1_bias,
            stride=2,
            padding=1,
        )

        acc1 = torch.round(acc1)

        real1 = (
            acc1
            * input_scale
            * conv1_weight_scale
        )

        q_relu1 = torch.round(
            real1 / conv1_output_scale
        )

        q_relu1 = torch.clamp(
            q_relu1,
            0,
            127,
        )

        # ----------------------------------------------------
        # Conv2
        # ----------------------------------------------------
        acc2 = F.conv2d(
            q_relu1,
            q_conv2_weight,
            q_conv2_bias,
            stride=2,
            padding=1,
        )

        acc2 = torch.round(acc2)

        real2 = (
            acc2
            * conv1_output_scale
            * conv2_weight_scale
        )

        q_relu2 = torch.round(
            real2 / conv2_output_scale
        )

        q_relu2 = torch.clamp(
            q_relu2,
            0,
            127,
        )

        # ----------------------------------------------------
        # Conv3
        # ----------------------------------------------------
        acc3 = F.conv2d(
            q_relu2,
            q_conv3_weight,
            q_conv3_bias,
            stride=2,
            padding=1,
        )

        acc3 = torch.round(acc3)

        real3 = (
            acc3
            * conv2_output_scale
            * conv3_weight_scale
        )

        q_relu3 = torch.round(
            real3 / conv3_output_scale
        )

        q_relu3 = torch.clamp(
            q_relu3,
            0,
            127,
        )

        # ----------------------------------------------------
        # GAP
        # ----------------------------------------------------
        real3_numpy = q_relu3.numpy()[0]
        real3_numpy = (
            real3_numpy
            * conv3_output_scale
        )

        gap_real = real3_numpy.mean(
            axis=(1, 2)
        )

        q_gap = np.rint(
            gap_real / gap_scale
        ).astype(np.int64)

        q_gap = np.clip(
            q_gap,
            0,
            127,
        )

        # 保存逐层定点输出，供后续 RTL 行为仿真逐层对拍。
        # 这些数组仍保持整数域，不经过再次浮点格式化。
        trace["conv1_relu"].append(
            q_relu1.numpy()[0].astype(np.int16).tolist()
        )
        trace["conv2_relu"].append(
            q_relu2.numpy()[0].astype(np.int16).tolist()
        )
        trace["conv3_relu"].append(
            q_relu3.numpy()[0].astype(np.int16).tolist()
        )
        trace["gap"].append(
            q_gap.astype(np.int16).tolist()
        )

        # ----------------------------------------------------
        # FC
        # ----------------------------------------------------
        q_gap_tensor = torch.from_numpy(
            q_gap.astype(np.float32)
        ).reshape(1, 64)

        acc_fc = F.linear(
            q_gap_tensor,
            q_fc_weight,
            q_fc_bias,
        )

        acc_fc = torch.round(acc_fc)

        current_real = (
            acc_fc.numpy()[0]
            * gap_scale
            * fc_weight_scale
        )

        q_current = np.rint(
            current_real / current_scale
        ).astype(np.int64)

        # ----------------------------------------------------
        # LIF
        # ----------------------------------------------------
        membrane = np.rint(
            membrane * 0.5
        ).astype(np.int64)

        membrane = membrane + q_current

        spikes = (
            membrane >= threshold_q
        ).astype(np.int64)

        membrane = (
            membrane
            - spikes * threshold_q
        )

        spike_counts = (
            spike_counts
            + spikes
        )

        trace["membrane"].append(
            membrane.copy().tolist()
        )

        trace["spikes"].append(
            spikes.tolist()
        )

        trace["current"].append(
            q_current.tolist()
        )

    prediction = int(
        np.argmax(spike_counts)
    )

    trace["spike_counts"] = (
        spike_counts.tolist()
    )

    return prediction, trace


# ============================================================
# 4. 主程序
# ============================================================

def main() -> None:
    for path in [
        CACHE_PATH,
        METADATA_PATH,
        FLOAT_MODEL_PATH,
        WEIGHT_REPORT_PATH,
        WEIGHT_NPZ_PATH,
        BIAS_REPORT_PATH,
        BIAS_NPZ_PATH,
        ACTIVATION_REPORT_PATH,
    ]:
        if not path.exists():
            raise FileNotFoundError(
                f"缺少文件：{path}"
            )

    cache = np.load(CACHE_PATH)

    frames = cache["frames"]
    labels = cache["labels"]

    metadata = load_json(
        METADATA_PATH
    )

    test_indices = get_test_indices(
        metadata
    )

    if len(test_indices) != 288:
        raise ValueError(
            f"测试集样本数应为288，实际为{len(test_indices)}"
        )

    weight_report = load_json(
        WEIGHT_REPORT_PATH
    )

    activation_report = load_json(
        ACTIVATION_REPORT_PATH
    )

    q_weights_file = np.load(
        WEIGHT_NPZ_PATH
    )

    q_biases_file = np.load(
        BIAS_NPZ_PATH
    )

    q_weights = {
        "conv1.weight": q_weights_file[
            "q_conv1_weight"
        ],
        "conv2.weight": q_weights_file[
            "q_conv2_weight"
        ],
        "conv3.weight": q_weights_file[
            "q_conv3_weight"
        ],
        "classifier.weight": q_weights_file[
            "q_classifier_weight"
        ],
    }

    q_biases = {
        "conv1.bias": q_biases_file[
            "conv1_bias"
        ],
        "conv2.bias": q_biases_file[
            "conv2_bias"
        ],
        "conv3.bias": q_biases_file[
            "conv3_bias"
        ],
        "classifier.bias": q_biases_file[
            "classifier_bias"
        ],
    }

    scales = {
        "input": float(
            activation_report["input_scale"]
        ),
        "conv1_relu": float(
            activation_report["ranges"][
                "conv1_relu"
            ]["int8_scale"]
        ),
        "conv2_relu": float(
            activation_report["ranges"][
                "conv2_relu"
            ]["int8_scale"]
        ),
        "conv3_relu": float(
            activation_report["ranges"][
                "conv3_relu"
            ]["int8_scale"]
        ),
        "gap": float(
            activation_report["ranges"][
                "gap"
            ]["int8_scale"]
        ),
        "fc_current": float(
            activation_report["ranges"][
                "fc_current"
            ]["int8_scale"]
        ),
        "conv1_weight": float(
            weight_report["parameters"][
                "conv1.weight"
            ]["scale"]
        ),
        "conv2_weight": float(
            weight_report["parameters"][
                "conv2.weight"
            ]["scale"]
        ),
        "conv3_weight": float(
            weight_report["parameters"][
                "conv3.weight"
            ]["scale"]
        ),
        "fc_weight": float(
            weight_report["parameters"][
                "classifier.weight"
            ]["scale"]
        ),
    }

    checkpoint = torch.load(
        FLOAT_MODEL_PATH,
        map_location="cpu",
    )

    float_model = CNNLIF(
        class_count=11,
        leak=0.5,
        threshold=0.5,
    )

    float_model.load_state_dict(
        checkpoint["model_state_dict"]
    )

    float_model.eval()

    float_correct = 0
    fixed_correct = 0
    prediction_mismatch = 0

    records = []

    for count, sample_index in enumerate(
        test_indices,
        start=1,
    ):
        sample = frames[sample_index]
        label = int(labels[sample_index])

        float_prediction = (
            run_float_one_sample(
                float_model,
                sample,
            )
        )

        fixed_prediction, trace = (
            run_fixed_one_sample(
                sample,
                q_weights,
                q_biases,
                scales,
            )
        )

        # 只导出测试集第一个样本，作为后续 RTL 逐层对拍的黄金数据。
        # 使用 NPZ 保存大数组，避免把完整张量写入主报告 JSON。
        if count == 1:
            np.savez_compressed(
                TRACE_OUTPUT_PATH,
                sample=np.asarray(sample, dtype=np.uint16),
                conv1_relu=np.asarray(trace["conv1_relu"], dtype=np.int16),
                conv2_relu=np.asarray(trace["conv2_relu"], dtype=np.int16),
                conv3_relu=np.asarray(trace["conv3_relu"], dtype=np.int16),
                gap=np.asarray(trace["gap"], dtype=np.int16),
                current=np.asarray(trace["current"], dtype=np.int16),
                membrane=np.asarray(trace["membrane"], dtype=np.int16),
                spikes=np.asarray(trace["spikes"], dtype=np.int8),
                spike_counts=np.asarray(trace["spike_counts"], dtype=np.int16),
            )
            TRACE_META_PATH.write_text(
                json.dumps(
                    {
                        "sample_index": int(sample_index),
                        "label": label,
                        "float_prediction": int(float_prediction),
                        "fixed_prediction": int(fixed_prediction),
                        "time_steps": 16,
                        "input_shape": [16, 64, 64, 2],
                        "conv1_relu_shape": [16, 16, 32, 32],
                        "conv2_relu_shape": [16, 32, 16, 16],
                        "conv3_relu_shape": [16, 64, 8, 8],
                        "gap_shape": [16, 64],
                        "current_shape": [16, 11],
                        "membrane_shape": [16, 11],
                        "spikes_shape": [16, 11],
                        "scales": scales,
                    },
                    indent=2,
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )
            print("黄金对拍数据:", TRACE_OUTPUT_PATH)
            print("黄金数据说明:", TRACE_META_PATH)

        float_correct += (
            float_prediction == label
        )

        fixed_correct += (
            fixed_prediction == label
        )

        prediction_mismatch += (
            float_prediction != fixed_prediction
        )

        records.append(
            {
                "sample_index": int(sample_index),
                "label": label,
                "float_prediction": float_prediction,
                "fixed_prediction": fixed_prediction,
                "spike_counts": trace[
                    "spike_counts"
                ],
            }
        )

        if count % 20 == 0:
            print(
                f"已完成 {count}/288",
                flush=True,
            )

    float_accuracy = float_correct / 288.0
    fixed_accuracy = fixed_correct / 288.0

    report = {
        "samples": 288,
        "float_accuracy": float_accuracy,
        "fixed_accuracy": fixed_accuracy,
        "prediction_mismatch_count": prediction_mismatch,
        "threshold_float": 0.5,
        "leak": 0.5,
        "records": records,
    }

    OUTPUT_PATH.write_text(
        json.dumps(
            report,
            indent=2,
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )

    print()
    print("定点推理完成")
    print("------------------------------")
    print("浮点准确率:", float_accuracy)
    print("定点准确率:", fixed_accuracy)
    print("浮点/定点预测不一致数:", prediction_mismatch)
    print("报告文件:", OUTPUT_PATH)


if __name__ == "__main__":
    main()
