from __future__ import annotations

import numpy as np


def events_to_frames(
    events: dict[str, np.ndarray],
    start_us: int,
    end_us: int,
    time_steps: int = 16,
) -> np.ndarray:
    """
    将一个手势时间片段转换成事件帧。

    输入：
        events:
            x
            y
            polarity
            timestamp

    输出：
        shape = [time_steps, 64, 64, 2]
        channel 0：正极性事件
        channel 1：负极性事件
    """

    if end_us <= start_us:
        raise ValueError("结束时间必须大于开始时间")

    x = events["x"]
    y = events["y"]
    polarity = events["polarity"]
    timestamp = events["timestamp"]

    # 只选择当前手势片段
    mask = (
        (timestamp >= start_us)
        & (timestamp < end_us)
    )

    x = x[mask]
    y = y[mask]
    polarity = polarity[mask]
    timestamp = timestamp[mask]

    frames = np.zeros(
        (time_steps, 64, 64, 2),
        dtype=np.uint16,
    )

    if timestamp.size == 0:
        return frames

    # 128×128降采样到64×64
    x64 = x // 2
    y64 = y // 2

    duration = end_us - start_us

    # 计算每个事件属于哪个时间步
    step_index = (
        (timestamp - start_us) * time_steps
    ) // duration

    # 防止边界事件产生time_steps
    step_index = np.minimum(
        step_index,
        time_steps - 1,
    )

    step_index = step_index.astype(np.int64)
    x64 = x64.astype(np.int64)
    y64 = y64.astype(np.int64)

    # polarity=1放到channel 0
    # polarity=0放到channel 1
    channel = (1 - polarity).astype(np.int64)

    # 统计事件数量
    np.add.at(
        frames,
        (
            step_index,
            y64,
            x64,
            channel,
        ),
        1,
    )

    return frames