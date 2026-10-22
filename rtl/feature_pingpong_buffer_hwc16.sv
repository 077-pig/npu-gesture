`timescale 1ns / 1ps

// 两组HWC16特征缓存，用于多层卷积的A/B乒乓切换。
// bank_select=0选择A，bank_select=1选择B。
// 读口为同步读：rd_en在第N拍有效，rd_valid/rd_data在第N+1拍返回。

module feature_pingpong_buffer_hwc16 #(
    parameter integer DEPTH_WORDS = 4096,
    parameter integer ADDR_WIDTH  = 12,
    parameter integer DATA_WIDTH  = 128
) (
    input  logic                  clk,
    input  logic                  rst_n,

    input  logic                  wr_en,             //当前是否要写入
    input  logic                  wr_bank,           //写A还是写B，0为A，1为B
    input  logic [ADDR_WIDTH-1:0] wr_addr,           //写入哪个储存字
    input  logic [DATA_WIDTH-1:0] wr_data,           //准备写入的数据
    input  logic [DATA_WIDTH/8-1:0] wr_strb,         //哪些部分允许更新

    input  logic                  rd_en,
    input  logic                  rd_bank,
    input  logic [ADDR_WIDTH-1:0] rd_addr,
    output logic                  rd_valid,
    output logic [DATA_WIDTH-1:0] rd_data,

    // 第二个逻辑读口，供GAP/后处理读取最终特征。
    // 卷积和GAP按阶段运行，不会同时读，因此两个逻辑接口在内部复用
    input  logic                  rd2_en,
    input  logic                  rd2_bank,
    input  logic [ADDR_WIDTH-1:0] rd2_addr,
    output logic                  rd2_valid,
    output logic [DATA_WIDTH-1:0] rd2_data
);

    //卷积阵列每次产生8个INT8结果，即64 bit；HWC16的低/高半字分开存储
    //这样00ff/ff00写选通会转化为完整64位RAM写入
    
    (* ram_style = "block" *) logic [63:0] mem_a_low [0:DEPTH_WORDS-1];
    (* ram_style = "block" *) logic [63:0] mem_a_high [0:DEPTH_WORDS-1];
    (* ram_style = "block" *) logic [63:0] mem_b_low [0:DEPTH_WORDS-1];
    (* ram_style = "block" *) logic [63:0] mem_b_high [0:DEPTH_WORDS-1];
    
    logic [63:0]                rd_a_low;
    logic [63:0]                rd_a_high;
    logic [63:0]                rd_b_low; 
    logic [63:0]                rd_b_high;
    //两个逻辑读口，最终拍板的
    logic                       shared_rd_en; 
    logic                       shared_rd_bank;
    logic [ADDR_WIDTH-1:0]      shared_rd_addr;
    logic                       shared_rd_bank_q;
    
    always_comb begin
        if(rd2_en) begin
            shared_rd_en = 1'b1;
            shared_rd_bank = rd2_bank;
            shared_rd_addr = rd2_addr;
        end
        else begin
            shared_rd_en = rd_en;
            shared_rd_bank = rd_bank;
            shared_rd_addr = rd_addr;
        end
    end
    
    // 四个数组各自保持标准的一个写口、一个同步读口。
    always_ff @(posedge clk) begin
        if (wr_en && !wr_bank && (wr_addr < DEPTH_WORDS) && (&wr_strb[7:0]))
            mem_a_low[wr_addr] <= wr_data[63:0];
        if (shared_rd_en && !shared_rd_bank && (shared_rd_addr < DEPTH_WORDS))
            rd_a_low <= mem_a_low[shared_rd_addr];
    end
    always_ff @(posedge clk) begin
        if (wr_en && !wr_bank && (wr_addr < DEPTH_WORDS) && (&wr_strb[15:8]))
            mem_a_high[wr_addr] <= wr_data[127:64];
        if (shared_rd_en && !shared_rd_bank && (shared_rd_addr < DEPTH_WORDS))
            rd_a_high <= mem_a_high[shared_rd_addr];
    end
    always_ff @(posedge clk) begin
        if (wr_en && wr_bank && (wr_addr < DEPTH_WORDS) && (&wr_strb[7:0]))
            mem_b_low[wr_addr] <= wr_data[63:0];
        if (shared_rd_en && shared_rd_bank && (shared_rd_addr < DEPTH_WORDS))
            rd_b_low <= mem_b_low[shared_rd_addr];
    end
    always_ff @(posedge clk) begin
        if (wr_en && wr_bank && (wr_addr < DEPTH_WORDS) && (&wr_strb[15:8]))
            mem_b_high[wr_addr] <= wr_data[127:64];
        if (shared_rd_en && shared_rd_bank && (shared_rd_addr < DEPTH_WORDS))
            rd_b_high <= mem_b_high[shared_rd_addr];
    end
    
    always_ff @ (posedge clk) begin
        if(!rst_n) begin
            rd_valid <= 1'b0;
            rd2_valid <= 1'b0;
            shared_rd_bank_q <= 1'b0;
        end
        else begin
            rd_valid <= rd_en && !rd2_en;
            rd2_valid <= rd2_en;
            if(shared_rd_en)
                shared_rd_bank_q <= shared_rd_bank;
        end
    end
    
    assign rd_data = shared_rd_bank_q ? {rd_b_high,rd_b_low} : {rd_a_high,rd_a_low};
    assign rd2_data = rd_data;
    
endmodule
    