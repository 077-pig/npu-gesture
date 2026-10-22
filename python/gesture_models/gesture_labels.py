from __future__ import annotations

from pathlib import Path
import csv


def read_labels(path: str | Path) -> list[dict[str, int]]:
    """
    读取一个AEDAT文件对应的标签CSV。

    返回类别编号已经转换为0~10。
    """

    path = Path(path)
    result = []

    with path.open(
        "r",
        encoding="utf-8-sig",
        newline="",
    ) as file:

        reader = csv.DictReader(file)

        expected_columns = {
            "class",
            "startTime_usec",
            "endTime_usec",
        }

        actual_columns = set(reader.fieldnames or [])

        if actual_columns != expected_columns:
            raise ValueError(
                f"CSV列名错误: {actual_columns}"
            )

        for row in reader:
            class_id = int(row["class"])
            start_us = int(row["startTime_usec"])
            end_us = int(row["endTime_usec"])

            if not 1 <= class_id <= 11:
                raise ValueError(
                    f"类别编号错误: {class_id}"
                )

            if end_us <= start_us:
                raise ValueError(
                    "结束时间必须大于开始时间"
                )

            result.append(
                {
                    # 原始类别1~11，训练类别改成0~10
                    "label": class_id - 1,
                    "start_us": start_us,
                    "end_us": end_us,
                }
            )

    return result


if __name__ == "__main__":
    sample = (
        Path(__file__).parents[1]
        / "data"
        / "DVS128Gesture"
        / "DvsGesture"
        / "user01_fluorescent_labels.csv"
    )

    labels = read_labels(sample)

    print("标签文件:", sample)
    print("标签数量:", len(labels))
    print("第一条标签:", labels[0])
    print("类别集合:", sorted(set(item["label"] for item in labels)))