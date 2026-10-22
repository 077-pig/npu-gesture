`timescale 1ns / 1ps

// 每层模型参数表，与256bit几何描述表分离。
// 当前96bit格式：
// [31:0]  卷积权重word基地址
// [47:32] 量化参数基地址
// [63:48] 输出zero-point（有符号）
// [64]    ReLU使能
// [95:65] 保留，后续可扩展激活类型、池化方式、权重来源等。
module npu_layer_param_table #(
    parameter integer MAX_LAYERS = 8,
    parameter integer PARAM_WIDTH = 96,
    parameter integer INDEX_WIDTH = (MAX_LAYERS <= 1) ? 1 : $clog2(MAX_LAYERS)
) (
    input logic clk,
    input logic rst_n,
    input logic wr_en,
    input logic [INDEX_WIDTH-1:0] wr_index,
    input logic [PARAM_WIDTH-1:0] wr_data,
    input logic [INDEX_WIDTH-1:0] rd_index,
    output logic [PARAM_WIDTH-1:0] rd_data
);
    logic [PARAM_WIDTH-1:0] param_mem [0:MAX_LAYERS-1];
    integer i;
    always_comb begin
        if (rd_index < MAX_LAYERS) rd_data = param_mem[rd_index];
        else rd_data = '0;
    end
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (i=0; i<MAX_LAYERS; i=i+1) param_mem[i] <= '0;
        end
        else if (wr_en && (wr_index < MAX_LAYERS)) param_mem[wr_index] <= wr_data;
    end
endmodule
