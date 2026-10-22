`timescale 1ns / 1ps

// HWC16 全局平均池化。
//
// 输入按连续的 HWC16 word 排列：
//   word_addr = pixel_index * channel_blocks + channel_block
//   每个 word 的16个字节对应连续16个通道。
//
// 模块一次处理一个 channel block，遍历所有像素并累加16个INT8通道，
// 最后除以 pixel_count，向零截断并饱和为INT8，输出一个128bit HWC16 word。
// feature_rd_valid/data 为同步RAM读返回接口，通常比 feature_rd_en 晚一拍。
module gap_hwc16 #(
    parameter integer FEATURE_ADDR_WIDTH = 12,
    parameter integer MAX_CHANNEL_BLOCKS = 16,
    parameter integer ACC_WIDTH = 32,
    parameter integer BLOCK_INDEX_WIDTH = (MAX_CHANNEL_BLOCKS <= 1) ? 1 : $clog2(MAX_CHANNEL_BLOCKS)
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         start,
    input  logic [15:0]                  cfg_width,
    input  logic [15:0]                  cfg_height,
    input  logic [15:0]                  cfg_channel_blocks,

    output logic                         feature_rd_en,
    output logic [FEATURE_ADDR_WIDTH-1:0] feature_rd_addr,
    input  logic                         feature_rd_valid,
    input  logic [127:0]                 feature_rd_data,

    output logic                         out_valid,
    output logic [BLOCK_INDEX_WIDTH-1:0] out_block_index,
    output logic [127:0]                 out_data,
    output logic                         out_last,
    output logic                         busy,
    output logic                         done,
    output logic                         config_error
);

    localparam integer DIV_COUNT_WIDTH = (ACC_WIDTH <= 1) ? 1 : $clog2(ACC_WIDTH);

    typedef enum logic [2:0] {
        S_IDLE, S_REQ, S_WAIT, S_DIV_PREP, S_DIV_RUN, S_EMIT, S_DONE
    } state_t;
    state_t state;

    logic [15:0] width_reg, height_reg, blocks_reg;
    logic [31:0] pixel_count_reg;
    logic [31:0] pixel_index;
    logic [15:0] block_index;
    logic signed [ACC_WIDTH-1:0] accum [0:15];

    // 一个逐位无符号除法器在16个通道之间复用。
    // 与原来的16个并行“/”相比，延迟增加，但GAP每层只执行一次，
    // 可以节省大量LUT，并且对任意width*height仍保持精确整数除法。
    logic [3:0] div_lane;
    logic [DIV_COUNT_WIDTH-1:0] div_iteration;
    logic div_negative;
    logic [ACC_WIDTH-1:0] div_dividend;
    logic [ACC_WIDTH-1:0] div_quotient;
    logic [ACC_WIDTH:0] div_remainder;
    logic [ACC_WIDTH:0] div_divisor;
    logic [127:0] emit_data_reg;

    logic [ACC_WIDTH:0] div_remainder_shift;
    logic [ACC_WIDTH:0] div_remainder_next;
    logic [ACC_WIDTH-1:0] div_dividend_next;
    logic [ACC_WIDTH-1:0] div_quotient_next;
    logic div_subtract;
    logic [7:0] div_result_byte;

    integer lane_seq;

    assign busy = (state != S_IDLE) && (state != S_DONE);

    // 当前请求地址。最后一层特征缓存按 HWC16 word 连续存储。
    always_comb begin
        feature_rd_en = 1'b0;
        feature_rd_addr = '0;
        if (state == S_REQ) begin
            feature_rd_en = 1'b1;
            feature_rd_addr = pixel_index * blocks_reg + block_index;
        end
    end

    // 恢复除法：每拍产生一个商bit，一共运行ACC_WIDTH拍。
    always_comb begin
        div_remainder_shift = {
            div_remainder[ACC_WIDTH-1:0], div_dividend[ACC_WIDTH-1]
        };
        div_subtract = (div_remainder_shift >= div_divisor);
        div_remainder_next = div_subtract
            ? (div_remainder_shift - div_divisor)
            : div_remainder_shift;
        div_dividend_next = {div_dividend[ACC_WIDTH-2:0], 1'b0};
        div_quotient_next = {div_quotient[ACC_WIDTH-2:0], div_subtract};

        if (div_negative) begin
            if (div_quotient_next > 128)
                div_result_byte = 8'h80;
            else if (div_quotient_next == 0)
                div_result_byte = 8'h00;
            else
                div_result_byte = (~div_quotient_next[7:0]) + 1'b1;
        end
        else begin
            if (div_quotient_next > 127)
                div_result_byte = 8'h7f;
            else
                div_result_byte = div_quotient_next[7:0];
        end
    end

    integer reset_lane;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE;
            width_reg <= '0;
            height_reg <= '0;
            blocks_reg <= '0;
            pixel_count_reg <= '0;
            pixel_index <= '0;
            block_index <= '0;
            div_lane <= '0;
            div_iteration <= '0;
            div_negative <= 1'b0;
            div_dividend <= '0;
            div_quotient <= '0;
            div_remainder <= '0;
            div_divisor <= '0;
            emit_data_reg <= '0;
            out_valid <= 1'b0;
            out_block_index <= '0;
            out_data <= '0;
            out_last <= 1'b0;
            done <= 1'b0;
            config_error <= 1'b0;
            for (reset_lane = 0; reset_lane < 16; reset_lane = reset_lane + 1)
                accum[reset_lane] <= '0;
        end
        else begin
            out_valid <= 1'b0;
            out_last <= 1'b0;
            done <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        config_error <= 1'b0;
                        if ((cfg_width == 0) || (cfg_height == 0) ||
                            (cfg_channel_blocks == 0) ||
                            (cfg_channel_blocks > MAX_CHANNEL_BLOCKS)) begin
                            config_error <= 1'b1;
                            done <= 1'b1;
                        end
                        else begin
                            width_reg <= cfg_width;
                            height_reg <= cfg_height;
                            blocks_reg <= cfg_channel_blocks;
                            pixel_count_reg <= cfg_width * cfg_height;
                            pixel_index <= '0;
                            block_index <= '0;
                            emit_data_reg <= '0;
                            for (reset_lane = 0; reset_lane < 16; reset_lane = reset_lane + 1)
                                accum[reset_lane] <= '0;
                            state <= S_REQ;
                        end
                    end
                end

                S_REQ: begin
                    state <= S_WAIT;
                end

                S_WAIT: begin
                    if (feature_rd_valid) begin
                        for (lane_seq = 0; lane_seq < 16; lane_seq = lane_seq + 1)
                            accum[lane_seq] <= accum[lane_seq] + $signed(feature_rd_data[lane_seq*8 +: 8]);

                        if (pixel_index == (pixel_count_reg - 1)) begin
                            div_lane <= '0;
                            state <= S_DIV_PREP;
                        end
                        else begin
                            pixel_index <= pixel_index + 1'b1;
                            state <= S_REQ;
                        end
                    end
                end

                S_DIV_PREP: begin
                    div_iteration <= '0;
                    div_quotient <= '0;
                    div_remainder <= '0;
                    div_divisor <= pixel_count_reg;
                    div_negative <= accum[div_lane][ACC_WIDTH-1];
                    if (accum[div_lane][ACC_WIDTH-1])
                        div_dividend <= (~accum[div_lane]) + 1'b1;
                    else
                        div_dividend <= accum[div_lane];
                    state <= S_DIV_RUN;
                end

                S_DIV_RUN: begin
                    div_dividend <= div_dividend_next;
                    div_quotient <= div_quotient_next;
                    div_remainder <= div_remainder_next;
                    if (div_iteration == (ACC_WIDTH - 1)) begin
                        emit_data_reg[div_lane*8 +: 8] <= div_result_byte;
                        if (div_lane == 15) begin
                            state <= S_EMIT;
                        end
                        else begin
                            div_lane <= div_lane + 1'b1;
                            state <= S_DIV_PREP;
                        end
                    end
                    else begin
                        div_iteration <= div_iteration + 1'b1;
                    end
                end

                S_EMIT: begin
                    // 非阻塞赋值的上一拍累加结果在这里已经可见。
                    out_valid <= 1'b1;
                    out_block_index <= block_index[BLOCK_INDEX_WIDTH-1:0];
                    out_data <= emit_data_reg;
                    out_last <= (block_index == (blocks_reg - 1));
                    if (block_index == (blocks_reg - 1)) begin
                        done <= 1'b1;
                        state <= S_DONE;
                    end
                    else begin
                        block_index <= block_index + 1'b1;
                        pixel_index <= '0;
                        emit_data_reg <= '0;
                        for (reset_lane = 0; reset_lane < 16; reset_lane = reset_lane + 1)
                            accum[reset_lane] <= '0;
                        state <= S_REQ;
                    end
                end

                S_DONE: begin
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
