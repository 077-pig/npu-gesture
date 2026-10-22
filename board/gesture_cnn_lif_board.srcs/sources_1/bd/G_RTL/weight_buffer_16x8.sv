`timescale 1ns / 1ps

// 16x8卷积阵列的权重缓存。
// 一个存储字对应一个输出通道列的16个INT8权重：
//   weight[k*8 +: 8] -> 当前列第k项权重
// 地址布局：
//   ((oc_tile * MAX_K_TILES) + k_tile) * 8 + col
//
// host写口用于DMA/PS装载；engine读口为单拍请求、下一拍返回。
// 地址计算是控制路径，显式使用移位/加法，避免占用DSP48。
(* use_dsp = "no" *)
module weight_buffer_16x8 #(
    parameter integer MAX_OC_TILES = 256,
    parameter integer MAX_K_TILES  = 256,
    parameter integer ADDR_WIDTH   = 19,
    parameter integer DEPTH_WORDS  = MAX_OC_TILES * MAX_K_TILES * 8
) (
    input  logic                clk,
    input  logic                rst_n,

    input  logic                wr_en,
    input  logic [ADDR_WIDTH-1:0] wr_addr,
    input  logic signed [127:0]  wr_data,

    input  logic                req_valid,
    output logic                req_ready,
    input  logic [15:0]          req_oc_tile,
    input  logic [15:0]          req_k_tile,
    input  logic [2:0]           req_col,
    input  logic [ADDR_WIDTH-1:0] req_base_addr,

    output logic                rsp_valid,
    input  logic                 rsp_ready,
    output logic signed [127:0]  rsp_data
);

    (* ram_style = "block" *)
    logic signed [127:0] mem [0:DEPTH_WORDS-1];

    typedef enum logic [1:0] {S_IDLE, S_WAIT, S_RESP} state_t;
    state_t state;
    integer calc_addr;
    logic   req_in_range;
    logic [ADDR_WIDTH-1:0] safe_addr;

    // 当前板级配置使用MAX_K_TILES=64。对2的幂次情况，
    // oc_tile*MAX_K_TILES*8和k_tile*8直接用移位实现。
    localparam bit K_TILES_IS_POW2 = (MAX_K_TILES > 0) &&
                                     ((MAX_K_TILES & (MAX_K_TILES-1)) == 0);
    localparam integer K_TILE_SHIFT = K_TILES_IS_POW2 ? $clog2(MAX_K_TILES) : 0;

    always_comb begin
        req_in_range = (req_oc_tile < MAX_OC_TILES) &&
                       (req_k_tile  < MAX_K_TILES) &&
                       (req_col     < 8);
        if (K_TILES_IS_POW2)
            calc_addr = req_base_addr + (req_oc_tile << (K_TILE_SHIFT + 3)) +
                        (req_k_tile  << 3) + req_col;
        else
            calc_addr = req_base_addr + ((req_oc_tile * MAX_K_TILES) + req_k_tile) * 8 + req_col;
        // 将越界请求折叠到地址0，保持RAM为标准同步读模板，
        // 避免在RAM读数据端增加条件逻辑而导致Vivado改推断为LUTRAM。
        if (req_in_range)
            safe_addr = calc_addr[ADDR_WIDTH-1:0];
        else
            safe_addr = '0;
    end

    assign req_ready = (state == S_IDLE);
    assign rsp_valid = (state == S_RESP);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            rsp_data <= '0;
        end
        else begin
            if (wr_en)
                mem[wr_addr] <= wr_data;

            case (state)
                S_IDLE: begin
                    if (req_valid) begin
                        // 越界请求的safe_addr为0；该地址通常在装载前为0，
                        // 因而不会产生非法索引或X传播。
                        rsp_data <= mem[safe_addr];
                        state <= S_RESP;
                    end
                end
                S_RESP: begin
                    if (rsp_ready)
                        state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
