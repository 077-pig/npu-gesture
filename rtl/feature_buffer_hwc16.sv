`timescale 1ns / 1ps

// HWC16特征缓存：
//   word_addr = ((y * input_width) + x) * channel_blocks + channel_block
//   每个存储字包含连续16个INT8通道。
// 这是面向本NPU的硬件内部格式，不等同于PyTorch/ONNX的外部张量格式。
module feature_buffer_hwc16 #(
    parameter integer DEPTH_WORDS = 65536,
    parameter integer ADDR_WIDTH  = 16
) (
    input  logic                  clk,
    input  logic                  rst_n,

    input  logic                  wr_en,        //是否写入
    input  logic [ADDR_WIDTH-1:0] wr_addr,      //写到哪个位置
    input  logic signed [127:0]   wr_data,      //写入的128位数据

    input  logic                  rd_en,        //是否读取
    input  logic [ADDR_WIDTH-1:0] rd_addr,      //读哪个位置
    output logic                  rd_valid,     //读出的数据是否有效
    output logic signed [127:0]   rd_data       //读出的128位数据
);

    (* ram_style = "block" *)
    logic signed [127:0] mem [0:DEPTH_WORDS-1];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rd_valid <= 1'b0;
            rd_data  <= '0;
        end
        else begin
            rd_valid <= rd_en;
            if (wr_en)
                mem[wr_addr] <= wr_data;
            if (rd_en)
                rd_data <= mem[rd_addr];
        end
    end

endmodule
