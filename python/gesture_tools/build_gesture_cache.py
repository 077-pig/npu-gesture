from __future__ import annotations

from pathlib import Path
import json
import sys

import numpy as np


PROJECT_ROOT = Path(__file__).parents[1]

# 让当前脚本能够找到gesture_models目录中的三个文件
sys.path.insert(
    0,
    str(PROJECT_ROOT / "gesture_models"),
)

from aedat_reader import read_aedat
from gesture_labels import read_labels
from event_frame import events_to_frames


def read_trial_list(path: Path) -> list[str]:
    """
    读取官方训练集或测试集文件列表。
    """
    trials = []

    with path.open(
        "r",
        encoding="utf-8-sig",
    ) as file:
        for line in file:
            line = line.strip()

            if not line:
                continue

            if line.startswith("#"):
                continue

            trials.append(line)

    return trials


def main() -> None:
    data_root = Path(__file__).resolve().parents[3] / "data" / "DVS128Gesture"
    dataset_root = data_root / "DvsGesture"
    output_path = data_root / "frames_t16_uint16.npz"
    metadata_path = data_root / "frames_t16_uint16.json"

    train_trials = read_trial_list(
        dataset_root / "trials_to_train.txt"
    )

    test_trials = read_trial_list(
        dataset_root / "trials_to_test.txt"
    )

    # 检查训练trial和测试trial是否重复
    overlap = set(train_trials) & set(test_trials)

    if overlap:
        raise ValueError(
            f"训练集和测试集存在重复trial: {sorted(overlap)}"
        )

    all_trials = []

    for trial in train_trials:
        all_trials.append(
            {
                "name": trial,
                "split": 0,
            }
        )

    for trial in test_trials:
        all_trials.append(
            {
                "name": trial,
                "split": 1,
            }
        )

    frame_list = []
    label_list = []
    split_list = []
    metadata_list = []

    total_trials = len(all_trials)

    for trial_index, trial_info in enumerate(
        all_trials,
        start=1,
    ):
        trial_name = trial_info["name"]
        split = trial_info["split"]

        aedat_path = dataset_root / trial_name

        label_path = (
            dataset_root
            / f"{Path(trial_name).stem}_labels.csv"
        )

        if not aedat_path.exists():
            raise FileNotFoundError(
                f"找不到AEDAT文件: {aedat_path}"
            )

        if not label_path.exists():
            raise FileNotFoundError(
                f"找不到标签文件: {label_path}"
            )

        print(
            f"[{trial_index}/{total_trials}] "
            f"读取 {trial_name}",
            flush=True,
        )

        events = read_aedat(aedat_path)
        labels = read_labels(label_path)

        for segment_index, item in enumerate(
            labels,
            start=1,
        ):
            frames = events_to_frames(
                events=events,
                start_us=item["start_us"],
                end_us=item["end_us"],
                time_steps=16,
            )

            if frames.shape != (
                16,
                64,
                64,
                2,
            ):
                raise ValueError(
                    f"帧形状错误: {frames.shape}"
                )

            if frames.dtype != np.uint16:
                raise ValueError(
                    f"帧数据类型错误: {frames.dtype}"
                )

            frame_list.append(frames)
            label_list.append(item["label"])
            split_list.append(split)

            metadata_list.append(
                {
                    "sample_index": len(frame_list) - 1,
                    "trial": trial_name,
                    "segment": segment_index,
                    "label": item["label"],
                    "start_us": item["start_us"],
                    "end_us": item["end_us"],
                    "split": (
                        "train"
                        if split == 0
                        else "test"
                    ),
                }
            )

    print("正在合并所有样本...", flush=True)

    frames_array = np.stack(
        frame_list,
        axis=0,
    ).astype(
        np.uint16,
        copy=False,
    )

    labels_array = np.asarray(
        label_list,
        dtype=np.uint8,
    )

    splits_array = np.asarray(
        split_list,
        dtype=np.uint8,
    )

    if frames_array.shape != (
        1464,
        16,
        64,
        64,
        2,
    ):
        raise ValueError(
            f"最终帧数据形状错误: {frames_array.shape}"
        )

    if labels_array.shape != (1464,):
        raise ValueError(
            f"标签数量错误: {labels_array.shape}"
        )

    if splits_array.shape != (1464,):
        raise ValueError(
            f"划分数量错误: {splits_array.shape}"
        )

    if np.any(labels_array > 10):
        raise ValueError(
            "标签必须是0~10"
        )

    output_path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    np.savez(
        output_path,
        frames=frames_array,
        labels=labels_array,
        splits=splits_array,
    )

    metadata_path.write_text(
        json.dumps(
            metadata_list,
            indent=2,
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )

    print()
    print("完整数据集处理完成")
    print("frames形状:", frames_array.shape)
    print("frames类型:", frames_array.dtype)
    print("labels形状:", labels_array.shape)
    print("splits形状:", splits_array.shape)
    print(
        "训练样本:",
        int(np.sum(splits_array == 0)),
    )
    print(
        "测试样本:",
        int(np.sum(splits_array == 1)),
    )
    print(
        "类别编号:",
        sorted(np.unique(labels_array).tolist()),
    )
    print(
        "最大事件计数:",
        int(frames_array.max()),
    )
    print(
        "缓存文件:",
        output_path,
    )
    print(
        "元数据文件:",
        metadata_path,
    )


if __name__ == "__main__":
    main()
