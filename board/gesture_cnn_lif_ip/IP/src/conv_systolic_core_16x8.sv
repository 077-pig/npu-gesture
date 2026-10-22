`timescale 1ns / 1ps

// V2真正的16×8脉动卷积计算核心。
// 每个in_valid周期可接收一个完整的16元素卷积窗口；流水线填满后，
// 每周期输出一个窗口对应的8个INT32输出通道。
module conv_systolic_core_16x8 (
    input  logic                clk,
    input  logic                rst_n,

    input  logic                load_wt_en,
    input  logic [2:0]          load_wt_col,
    input  logic signed [127:0] load_wt_bus,
    input  logic                swap_wt,

    input  logic                frame_start,
    input  logic                in_valid,
    input  logic signed [127:0] in_act,
    output logic                in_ready,

    output logic                out_valid,
    output logic signed [255:0] out_psum
);

    wire signed [127:0] skewed_act;
    wire signed [255:0] raw_psum;

    // 权重装载、切换以及清流水时不接受新窗口。
    assign in_ready = !load_wt_en && !swap_wt && !frame_start;

    activation_skew_16 u_activation_skew (
        .clk        (clk),
        .rst_n      (rst_n),
        .clear      (frame_start),
        .in_valid   (in_valid && in_ready),
        .in_act     (in_act),
        .skewed_act (skewed_act)
    );

    systolic_array_16x8 u_array (
        .clk           (clk),
        .rst_n         (rst_n),
        .compute_en    (1'b1),
        .load_wt_en    (load_wt_en),
        .load_wt_col   (load_wt_col),
        .load_wt_bus   (load_wt_bus),
        .swap_wt       (swap_wt),
        .skewed_act_in (skewed_act),
        .raw_psum_out  (raw_psum)
    );

    output_deskew_8 u_output_deskew (
        .clk              (clk),
        .rst_n            (rst_n),
        .clear            (frame_start),
        .stream_valid     (in_valid && in_ready),
        .raw_psum_in      (raw_psum),
        .out_valid        (out_valid),
        .aligned_psum_out (out_psum)
    );

endmodule
