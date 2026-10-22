`timescale 1ns / 1ps

// HWC16全局平均池化与定点重标定。
// 输出公式：q_gap = round(sum * REQUANT_MULTIPLIER / 2^REQUANT_SHIFT)
// 其中sum是一个通道在全部像素上的INT8累加和。
module gap_hwc16_requant #(
    parameter integer FEATURE_ADDR_WIDTH = 12,
    parameter integer MAX_CHANNEL_BLOCKS = 16,
    parameter integer ACC_WIDTH = 32,
    parameter integer REQUANT_MULTIPLIER = 205105,
    parameter integer REQUANT_SHIFT = 20,
    parameter integer BLOCK_INDEX_WIDTH = (MAX_CHANNEL_BLOCKS <= 1) ? 1 : $clog2(MAX_CHANNEL_BLOCKS)
) (
    input logic clk,
    input logic rst_n,
    input logic start,
    input logic [15:0] cfg_width,
    input logic [15:0] cfg_height,
    input logic [15:0] cfg_channel_blocks,
    output logic feature_rd_en,
    output logic [FEATURE_ADDR_WIDTH-1:0] feature_rd_addr,
    input logic feature_rd_valid,
    input logic [127:0] feature_rd_data,
    output logic out_valid,
    output logic [BLOCK_INDEX_WIDTH-1:0] out_block_index,
    output logic [127:0] out_data,
    output logic out_last,
    output logic busy,
    output logic done,
    output logic config_error
);
    typedef enum logic [2:0] {
        S_IDLE, S_REQ, S_WAIT, S_MULT, S_ROUND, S_EMIT, S_DONE
    } state_t;
    state_t state;
    logic [15:0] width_reg, height_reg, blocks_reg;
    logic [31:0] pixel_count_reg, pixel_index;
    logic [15:0] block_index;
    logic signed [ACC_WIDTH-1:0] accum [0:15];
    logic signed [ACC_WIDTH-1:0] final_sum [0:15];
    logic signed [ACC_WIDTH+31:0] product_reg [0:15];
    logic [127:0] emit_data_reg;
    integer i;

    assign busy = (state != S_IDLE) && (state != S_DONE);

    function automatic [7:0] requant_product_u8(
        input logic signed [ACC_WIDTH+31:0] product
    );
        logic signed [ACC_WIDTH+31:0] rounded;
        logic signed [ACC_WIDTH+31:0] magnitude;
        logic signed [ACC_WIDTH+31:0] quotient;
        logic [ACC_WIDTH+31:0] remainder;
        begin
            magnitude = (product < 0) ? -product : product;
            quotient = magnitude >>> REQUANT_SHIFT;
            remainder = magnitude & (({{(ACC_WIDTH+31){1'b0}},1'b1} << REQUANT_SHIFT) - 1'b1);
            // 最近偶数舍入，与Python np.rint/torch.round保持一致。
            if ((remainder > ({{(ACC_WIDTH+31){1'b0}},1'b1} << (REQUANT_SHIFT-1))) ||
                ((remainder == ({{(ACC_WIDTH+31){1'b0}},1'b1} << (REQUANT_SHIFT-1))) && quotient[0]))
                quotient = quotient + 1'b1;
            rounded = (product < 0) ? -quotient : quotient;
            if (rounded < 0)
                requant_product_u8 = 8'd0;
            else if (rounded > 127)
                requant_product_u8 = 8'd127;
            else
                requant_product_u8 = rounded[7:0];
        end
    endfunction

    always_comb begin
        feature_rd_en = 1'b0;
        feature_rd_addr = '0;
        if (state == S_REQ) begin
            feature_rd_en = 1'b1;
            feature_rd_addr = pixel_index * blocks_reg + block_index;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE;
            width_reg <= 0; height_reg <= 0; blocks_reg <= 0;
            pixel_count_reg <= 0; pixel_index <= 0; block_index <= 0;
            emit_data_reg <= 0; out_valid <= 0; out_last <= 0; done <= 0;
            out_block_index <= 0; config_error <= 0;
            for (i = 0; i < 16; i = i + 1) begin
                accum[i] <= '0; final_sum[i] <= '0; product_reg[i] <= '0;
            end
        end else begin
            out_valid <= 1'b0;
            out_last <= 1'b0;
            done <= 1'b0;
            case (state)
                S_IDLE: if (start) begin
                    config_error <= 1'b0;
                    if ((cfg_width == 0) || (cfg_height == 0) ||
                        (cfg_channel_blocks == 0) || (cfg_channel_blocks > MAX_CHANNEL_BLOCKS)) begin
                        config_error <= 1'b1;
                        done <= 1'b1;
                    end else begin
                        width_reg <= cfg_width;
                        height_reg <= cfg_height;
                        blocks_reg <= cfg_channel_blocks;
                        pixel_count_reg <= cfg_width * cfg_height;
                        pixel_index <= 0;
                        block_index <= 0;
                        emit_data_reg <= 0;
                        for (i = 0; i < 16; i = i + 1) begin
                            accum[i] <= '0; final_sum[i] <= '0; product_reg[i] <= '0;
                        end
                        state <= S_REQ;
                    end
                end
                S_REQ: state <= S_WAIT;
                S_WAIT: if (feature_rd_valid) begin
                    for (i = 0; i < 16; i = i + 1) begin
                        if (pixel_index == pixel_count_reg - 1)
                            final_sum[i] <= accum[i] + $signed(feature_rd_data[i*8 +: 8]);
                        accum[i] <= accum[i] + $signed(feature_rd_data[i*8 +: 8]);
                    end
                    if (pixel_index == pixel_count_reg - 1)
                        state <= S_MULT;
                    else begin
                        pixel_index <= pixel_index + 1'b1;
                        state <= S_REQ;
                    end
                end
                S_MULT: begin
                    for (i = 0; i < 16; i = i + 1)
                        product_reg[i] <= final_sum[i] * REQUANT_MULTIPLIER;
                    state <= S_ROUND;
                end
                S_ROUND: begin
                    for (i = 0; i < 16; i = i + 1)
                        emit_data_reg[i*8 +: 8] <= requant_product_u8(product_reg[i]);
                    state <= S_EMIT;
                end
                S_EMIT: begin
                    out_valid <= 1'b1;
                    out_block_index <= block_index[BLOCK_INDEX_WIDTH-1:0];
                    out_data <= emit_data_reg;
                    out_last <= (block_index == blocks_reg - 1);
                    if (block_index == blocks_reg - 1) begin
                        done <= 1'b1;
                        state <= S_DONE;
                    end else begin
                        block_index <= block_index + 1'b1;
                        pixel_index <= 0;
                        emit_data_reg <= 0;
                        for (i = 0; i < 16; i = i + 1) begin
                            accum[i] <= '0; final_sum[i] <= '0; product_reg[i] <= '0;
                        end
                        state <= S_REQ;
                    end
                end
                S_DONE: state <= S_IDLE;
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
