# ModelSim 模块级仿真说明

本目录包含 `G_RTL` 中 29 个 SystemVerilog 模块的一对一测试文件。测试文件名统一为 `tb_<RTL模块名>.sv`。所有测试都包含结果检查；数据不符或超时会调用 `$fatal`，不能仅靠波形外观判定通过。

验证范围：这是定向模块测试，不是穷尽验证，也没有重跑整个手势测试集。`tb_gesture_cnn_lif_local_top` 当前检查未配置描述符时的错误传播；AXI 顶层 TB 检查寄存器读写、错误状态和中断清除。三层卷积至 GAP、FC 的数值链路及 LIF 时序分别由其他 TB 检查，不能据此宣称完整 CNN-SNN 顶层已完成真实数据端到端验证。

## 一、编译全部 RTL 和 TB

1. 打开 ModelSim。
2. 点击菜单 `File` -> `Change Directory...`。
3. 选择项目中的 `game/sim/TB` 文件夹，点击 `选择文件夹`。
4. 在下方 `Transcript` 窗口输入：

   ```tcl
   do compile_all.do
   ```

5. 按 Enter。最后出现 `COMPILE PASS: 29 RTL files and 29 testbenches`，表示编译成功。

脚本会在 `TB` 中重新建立 ModelSim 的 `work` 仿真库，不会修改 `G_RTL` 源码。

## 二、运行全部 29 项测试

编译完成后，在 `Transcript` 输入：

```tcl
do run_all.do
```

每项应出现 `TEST PASS`，最后应出现：

```text
ALL TESTS PASSED: 29/29
```

脚本会检查每个 TB 的 `tb_passed` 标志，并将逐项结果保存到本目录 `validation_results.txt`。仅正常停止或打印文字，不会被当作通过。

## 三、查看某一个模块的波形

例如查看 `pe_int8_dsp`：

1. 在 `Transcript` 输入：

   ```tcl
   set TOP tb_pe_int8_dsp
   ```

2. 按 Enter，再输入：

   ```tcl
   do wave_one.do
   ```

3. 按 Enter。脚本会装载该 TB、加入其全部信号、运行到结束并缩放到完整时间范围。
4. 如果没有看到波形窗口，点击菜单 `View` -> `Wave`。

查看其他模块时，只需把 `TOP` 改为相应 TB 名。例如：

```tcl
set TOP tb_npu_three_layer_local_top
do wave_one.do
```

## 四、只运行一个测试，不自动加入波形

```tcl
set TOP tb_fc_classifier_8lane
do run_one.do
```

若修改了 RTL 或 TB，应先重新执行 `do compile_all.do`，再运行测试。
