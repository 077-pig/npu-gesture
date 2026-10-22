`timescale 1ns / 1ps

// 根据控制器给出的线性HWC16地址取出一个128-bit激活tile。
// 输入坐标仅用于判断padding；乘法和步长计算由Python/PS预先完成。
module conv_activation_fetch_hwc16 #(
    parameter integer ADDR_WIDTH = 16
) (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  clear,
    input  logic [15:0]           cfg_input_width,         //当前层输入特征图的宽度
    input  logic [15:0]           cfg_input_height,        //当前层输入特征图的高度
    input  logic                  req_valid,               //上游提供了一个有效读取请求
    output logic                  req_ready,               //本模块现在能接收一个新请求
    input  logic signed [16:0]    req_in_x,                //要读取的输入横坐标
    input  logic signed [16:0]    req_in_y,                //要读取的输入纵坐标
    input  logic signed [31:0]    req_word_addr,           //已经计算好的HWC16存储字地址
    output logic                  mem_rd_en,               //向RAM发出读取使能
    output logic [ADDR_WIDTH-1:0] mem_rd_addr,             //本次要读取的RAM存储字地址
    input  logic                  mem_rd_valid,            //RAM通知本模块，数据有效
    input  logic signed [127:0]   mem_rd_data,             //RAM返回的一个HWC16存储字
    output logic                  rsp_valid,               //返回数据已经准备好
    input  logic                  rsp_ready,               //下游已经准备好接收返回数据
    output logic signed [127:0]   rsp_tile,                //本次返回的16个INT8激活值
    output logic                  rsp_is_padding           //本次返回的数据是否越界补零产生
);

    typedef enum logic [1:0] {
    S_READY,            //可以接受新请求
    S_WAIT_MEM,         //已向RAM发出读取，等待RAM返回
    S_RESP              //数据已经准备好，等待下游接收
    }state_t;
    state_t state;
    logic coord_valid;

    always_comb begin
        coord_valid = (req_in_x >= 17'sd0) &&
                      (req_in_x < $signed({1'b0, cfg_input_width})) &&
                      (req_in_y >= 17'sd0) &&
                      (req_in_y < $signed({1'b0, cfg_input_height}));
    end             //判断边界
    
    assign req_ready   = (state == S_READY);                                //只有在 S_READY 状态才能接收请求。
    assign mem_rd_en   = (state == S_READY) && req_valid && coord_valid;    //满足：当前可以接收，请求有效，坐标合法，才能读取RAM
    assign mem_rd_addr = req_word_addr[ADDR_WIDTH-1:0];                     
    assign rsp_valid   = (state == S_RESP);                                 
    
    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            state <= S_READY;
            rsp_tile <= '0;
            rsp_is_padding <= 1'b0;
        end 
        else begin
            case (state)
                S_READY: if (req_valid) begin
                            if (coord_valid) begin
                                rsp_is_padding <= 1'b0;
                                state <= S_WAIT_MEM;
                            end 
                            else begin
                            rsp_tile <= '0;
                            rsp_is_padding <= 1'b1;
                            state <= S_RESP;
                            end
                         end
                S_WAIT_MEM: if (mem_rd_valid) begin
                                rsp_tile <= mem_rd_data;
                                state <= S_RESP;
                            end
                S_RESP: if (rsp_ready) state <= S_READY;
                default: state <= S_READY;
            endcase
        end
    end
endmodule