`timescale 1ns / 1ps

// 根据控制器给出的线性HWC16地址取出一个128-bit激活tile。
// 输入坐标仅用于判断padding；乘法和步长计算由Python/PS预先完成。
module conv_activation_fetch_hwc16 #(
    parameter integer ADDR_WIDTH = 16
) (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  clear,
    input  logic [15:0]           cfg_input_width,
    input  logic [15:0]           cfg_input_height,
    input  logic                  req_valid,
    output logic                  req_ready,
    input  logic signed [16:0]    req_in_x,
    input  logic signed [16:0]    req_in_y,
    input  logic signed [31:0]    req_word_addr,
    output logic                  mem_rd_en,
    output logic [ADDR_WIDTH-1:0] mem_rd_addr,
    input  logic                  mem_rd_valid,
    input  logic signed [127:0]   mem_rd_data,
    output logic                  rsp_valid,
    input  logic                  rsp_ready,
    output logic signed [127:0]   rsp_tile,
    output logic                  rsp_is_padding
);
    typedef enum logic [1:0] {S_READY, S_WAIT_MEM, S_RESP} state_t;
    state_t state;
    logic coord_valid;

    always_comb begin
        coord_valid = (req_in_x >= 17'sd0) &&
                      (req_in_x < $signed({1'b0, cfg_input_width})) &&
                      (req_in_y >= 17'sd0) &&
                      (req_in_y < $signed({1'b0, cfg_input_height}));
    end

    assign req_ready   = (state == S_READY);
    assign mem_rd_en   = (state == S_READY) && req_valid && coord_valid;
    assign mem_rd_addr = req_word_addr[ADDR_WIDTH-1:0];
    assign rsp_valid   = (state == S_RESP);

    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            state <= S_READY;
            rsp_tile <= '0;
            rsp_is_padding <= 1'b0;
        end else begin
            case (state)
                S_READY: if (req_valid) begin
                    if (coord_valid) begin
                        rsp_is_padding <= 1'b0;
                        state <= S_WAIT_MEM;
                    end else begin
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
