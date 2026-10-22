from __future__ import annotations

from pathlib import Path
import json
import sys

import numpy as np
import torch
from torch.utils.data import DataLoader, Dataset


# ============================================================
# 1. 路径
# ============================================================

# 当前文件：
# gesture_models/stage2_quantized/calibrate_activations.py
# parents[0] = stage2_quantized
# parents[1] = gesture_models
# parents[2] = 工程根目录
PROJECT_ROOT = Path(__file__).resolve().parents[2]

# 让本文件能够导入gesture_tools中的CNNLIF类
GESTURE_TOOLS_DIR = PROJECT_ROOT / "gesture_tools"

if str(GESTURE_TOOLS_DIR) not in sys.path:
    sys.path.insert(
        0,
        str(GESTURE_TOOLS_DIR),
    )

from train_cnn_lif_v2 import CNNLIF


CACHE_PATH = (
    Path(__file__).resolve().parents[4]
    / "data"
    / "DVS128Gesture"
    / "frames_t16_uint16.npz"
)

METADATA_PATH = (
    Path(__file__).resolve().parents[4]
    / "data"
    / "DVS128Gesture"
    / "frames_t16_uint16.json"
)

FLOAT_MODEL_PATH = (
    PROJECT_ROOT
    / "gesture_models"
    / "stage2_cnn_lif"
    / "cnn_lif_thr05_best.pt"
)

OUTPUT_PATH = (
    PROJECT_ROOT
    / "gesture_models"
    / "stage2_quantized"
    / "activation_calibration.json"
)


# 训练阶段使用：
# clipped_count / 127
INPUT_SCALE = 1.0 / 127.0


# ============================================================
# 2. 数据集
# ============================================================

class CalibrationDataset(Dataset):
    def __init__(
        self,
        frames: np.ndarray,
        indices: np.ndarray,
    ):
        self.frames = frames
        self.indices = indices

    def __len__(self) -> int:
        return int(self.indices.shape[0])

    def __getitem__(self, position: int):
        sample_index = int(self.indices[position])

        sample = self.frames[sample_index]

        # 与训练代码保持一致
        sample = np.minimum(sample, 127)

        sample = sample.astype(
            np.float32,
            copy=False,
        ) / 127.0

        # [T,H,W,C] -> [T,C,H,W]
        sample = np.transpose(
            sample,
            (0, 3, 1, 2),
        )

        return torch.from_numpy(sample)


# ============================================================
# 3. 生成训练集索引
# ============================================================

def build_training_indices(
    metadata: list[dict],
) -> np.ndarray:
    """
    只使用user01~user19作为校准集。
    不使用验证集和官方测试集。
    """

    indices = []

    for sample_index, item in enumerate(metadata):
        trial_name = item["trial"]

        # 例如：
        # user01_fluorescent.aedat
        user_name = trial_name.split("_")[0]

        user_id = int(
            user_name.replace("user", "")
        )

        if 1 <= user_id <= 19:
            indices.append(sample_index)

    return np.asarray(
        indices,
        dtype=np.int64,
    )


# ============================================================
# 4. 更新最大值
# ============================================================

def update_range(
    range_info: dict,
    name: str,
    tensor: torch.Tensor,
) -> None:
    values = tensor.detach()

    current_min = float(values.min().item())
    current_max = float(values.max().item())
    current_abs_max = float(values.abs().max().item())

    if name not in range_info:
        range_info[name] = {
            "min": current_min,
            "max": current_max,
            "max_abs": current_abs_max,
        }
        return

    range_info[name]["min"] = min(
        range_info[name]["min"],
        current_min,
    )

    range_info[name]["max"] = max(
        range_info[name]["max"],
        current_max,
    )

    range_info[name]["max_abs"] = max(
        range_info[name]["max_abs"],
        current_abs_max,
    )


# ============================================================
# 5. 计算激活scale
# ============================================================

def add_activation_scales(
    range_info: dict,
) -> None:
    for name, item in range_info.items():
        max_abs = float(item["max_abs"])

        if max_abs == 0.0:
            scale = 1.0
        else:
            scale = max_abs / 127.0

        item["int8_scale"] = scale
        item["int8_min"] = -127
        item["int8_max"] = 127


# ============================================================
# 6. 主程序
# ============================================================

def main() -> None:
    if not CACHE_PATH.exists():
        raise FileNotFoundError(
            f"找不到缓存：{CACHE_PATH}"
        )

    if not METADATA_PATH.exists():
        raise FileNotFoundError(
            f"找不到元数据：{METADATA_PATH}"
        )

    if not FLOAT_MODEL_PATH.exists():
        raise FileNotFoundError(
            f"找不到浮点模型：{FLOAT_MODEL_PATH}"
        )

    print("读取事件帧缓存...")
    cache = np.load(CACHE_PATH)

    frames = cache["frames"]

    print("frames:", frames.shape)
    print("frames dtype:", frames.dtype)

    with METADATA_PATH.open(
        "r",
        encoding="utf-8",
    ) as file:
        metadata = json.load(file)

    if len(metadata) != len(frames):
        raise ValueError(
            "metadata数量和frames数量不一致"
        )

    train_indices = build_training_indices(
        metadata
    )

    print(
        "激活校准样本数:",
        len(train_indices),
    )

    if len(train_indices) != 984:
        raise ValueError(
            f"训练校准样本数应为984，实际为{len(train_indices)}"
        )

    dataset = CalibrationDataset(
        frames=frames,
        indices=train_indices,
    )

    loader = DataLoader(
        dataset,
        batch_size=8,
        shuffle=False,
        num_workers=0,
    )

    print("读取浮点CNN+LIF模型...")

    checkpoint = torch.load(
        FLOAT_MODEL_PATH,
        map_location="cpu",
    )

    model = CNNLIF(
        class_count=11,
        leak=0.5,
        threshold=0.5,
    )

    model.load_state_dict(
        checkpoint["model_state_dict"]
    )

    model.eval()

    print("模型加载完成")
    print("LIF leak:", model.leak)
    print("LIF threshold:", model.threshold)

    range_info = {}

    processed_batches = 0

    with torch.no_grad():
        for inputs in loader:
            batch_size = inputs.shape[0]
            time_steps = inputs.shape[1]

            # 初始输入范围
            update_range(
                range_info,
                "input",
                inputs,
            )

            for time_index in range(time_steps):
                frame = inputs[:, time_index]

                conv1 = model.conv1(frame)
                relu1 = torch.relu(conv1)

                conv2 = model.conv2(relu1)
                relu2 = torch.relu(conv2)

                conv3 = model.conv3(relu2)
                relu3 = torch.relu(conv3)

                gap = relu3.mean(
                    dim=(2, 3)
                )

                current = model.classifier(gap)

                update_range(
                    range_info,
                    "conv1_relu",
                    relu1,
                )

                update_range(
                    range_info,
                    "conv2_relu",
                    relu2,
                )

                update_range(
                    range_info,
                    "conv3_relu",
                    relu3,
                )

                update_range(
                    range_info,
                    "gap",
                    gap,
                )

                update_range(
                    range_info,
                    "fc_current",
                    current,
                )

            processed_batches += 1

            if processed_batches % 20 == 0:
                print(
                    "已处理batch:",
                    processed_batches,
                    flush=True,
                )

    add_activation_scales(range_info)

    report = {
        "source_model": FLOAT_MODEL_PATH.relative_to(PROJECT_ROOT.parents[1]).as_posix(),
        "calibration_dataset": CACHE_PATH.relative_to(PROJECT_ROOT.parents[1]).as_posix(),
        "calibration_rule": "user01-user19 only",
        "sample_count": int(len(train_indices)),
        "time_steps": 16,
        "input_scale": INPUT_SCALE,
        "ranges": range_info,
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
    print("激活校准完成")
    print("------------------------------")

    for name, item in range_info.items():
        print(name)
        print("  min:", item["min"])
        print("  max:", item["max"])
        print("  max_abs:", item["max_abs"])
        print("  int8_scale:", item["int8_scale"])

    print()
    print("校准报告:")
    print(OUTPUT_PATH)


if __name__ == "__main__":
    main()
