# 面向边缘推理的可配置 NPU（16×8 脉动阵列 + CNN-LIF 动态手势识别）

2026 年 FPGA 创新设计竞赛参赛作品 · 队伍编号 49454 · 牛刀小试

在 Xilinx Zynq-7020 上实现的可配置 INT8 神经网络处理器：以一套 16×8 权重驻留式脉动阵列
（128 个 PE）为核心，通过层描述表与层参数表把"计算结构"与"模型数据"分离，配合 A/B 特征
缓存乒乓、部分和累加、逐通道重量化与多层调度，用同一套阵列依次完成三层卷积；应用侧以
CNN-LIF 混合网络完成 DVS128 Gesture 的 11 类动态手势识别。

---

## 1. 主要结果

| 项目 | 数值 |
|---|---|
| 软件浮点模型准确率 | 252/288 = **87.50%** |
| FPGA 板端实测准确率 | 248/288 = **86.11%** |
| 器件 / 工具 | XC7Z020-1CLG400C / Vivado 2018.3 |
| 工作频率 | 50 MHz（20 ns），WNS 1.799 ns，WHS 0.033 ns |
| 资源占用 | LUT 29,562（55.57%）、FF 12,516（11.76%）、BRAM 94（67.14%）、DSP 180（81.82%） |
| 阵列理论峰值 | 128 × 50 MHz = 6.4 GMAC/s（12.8 GOPS） |
| 输入压缩 | HWC16 301,989,888 B → 紧凑 DENSE 37,748,736 B → Zero-RLE 18,051,469 B |
| 时序早退 | 处理帧数 4,608 → 3,064（−33.51%），准确率不变 |
| 端到端耗时 | 288 个样本 604.3 s（其中约 88% 为 230400 baud 串口传输） |

---

## 2. 目录结构

```
rtl/          29 个 SystemVerilog 模块（脉动阵列、单层引擎、多层调度、GAP/FC/LIF、AXI 接口）
tb/           29 个 ModelSim 测试平台 + 运行脚本（compile_all.do / run_all.do）+ validation_results.txt
python/       gesture_tools（预处理、训练、量化、参数导出、板端测试脚本）
              gesture_models（AEDAT 读取、事件帧构建、标签表、检查点与量化参数）
              gesture_generated_improved_v2（导出给硬件的权重 HEX 与配置 JSON）
board/        Vivado 板级工程与 IP 封装工程（.xpr / .bd / .xci / .xdc / IP 源文件）
software/     ARM Cortex-A9 裸机程序（GST4 协议、解码、AXI 装载、推理调度）
doc/          技术文档与架构图（png + drawio 源文件）
```

数据集**不在**本仓库内：DVS128 Gesture（Amir et al., CVPR 2017）请自行下载后放在
`data/DVS128Gesture/`。

---

## 3. 复现步骤

### 3.1 软件模型（可选，用于生成参数）

```bash
pip install torch numpy
# 预处理事件数据 → 训练 → 量化 → 导出硬件参数
python python/gesture_tools/build_gesture_cache.py
python python/gesture_tools/train_cnn_lif_v2.py
python python/gesture_tools/export_gesture_hardware_params.py
```
导出结果在 `python/gesture_generated_improved_v2/`（已随仓库提供，可直接使用）。

### 3.2 RTL 仿真

用 ModelSim 打开 `tb/`，执行 `compile_all.do` 与 `run_all.do`；预期结果为
`validation_results.txt` 中的 `ALL TESTS PASSED: 29/29`。

### 3.3 板级工程

1. 用 Vivado 2018.3 打开 `board/gesture_cnn_lif_board.xpr`；
2. 若提示 IP 需要生成，执行 **Tools → Report IP Status → Generate Output Products**；
3. 综合 → 实现 → 生成比特流；
4. 导出硬件（Export Hardware，含 bitstream）到 SDK，导入 `software/` 中的裸机程序。

> 说明：本设计的 UART 走 PS7 的 MIO，**PL 侧无外部引脚**，因此约束文件里只有时钟与 IP 的
> OOC 约束，没有引脚分配——这不是缺文件。

### 3.4 板端测试

上位机通过串口（230400-8-N-1）按 GST4 协议发送 16 帧事件数据：

```bash
python python/gesture_tools/run_testset_288.py --early-stop off            # 完整 16 帧
python python/gesture_tools/run_testset_288.py --early-stop conservative   # 启用早退
```
预期结果：`off` 模式 248/288（86.11%），`conservative` 模式 248/288、处理帧数 3,064。

---

## 4. 环境版本

- Vivado 2018.3（Build 2405991）、Xilinx SDK 2018.3
- ModelSim（任意支持 SystemVerilog 的版本）
- Python 3.x + PyTorch + NumPy

---

## 5. 引用

如使用本项目，请引用数据集原文：

> A. Amir, B. Taba, D. Berg, T. Melano, J. McKinstry, C. Di Nolfo, T. Nayak,
> A. Andreopoulos, G. Garreau, M. Mendoza, J. Kusnitz, M. DeBole, S. K. Esser,
> and D. Modha, "A Low Power, Fully Event-Based Gesture Recognition System,"
> CVPR 2017.

---

## 6. 许可证

MIT License，详见 [LICENSE](LICENSE)。
