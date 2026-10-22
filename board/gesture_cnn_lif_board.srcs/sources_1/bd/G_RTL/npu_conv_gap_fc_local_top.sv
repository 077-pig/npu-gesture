`timescale 1ns / 1ps

// V2 本地完整分类数据通路：多层卷积 -> HWC16 GAP -> 8路INT8 FC -> argmax。
// 中间特征始终保留在PL的A/B缓存中；PS侧后续只需配置描述、权重和启动。
module npu_conv_gap_fc_local_top #(
    parameter integer FEATURE_DEPTH_WORDS = 4096,
    parameter integer FEATURE_ADDR_WIDTH  = 12,
    parameter integer MAX_OUTPUT_PIXELS   = 4096,
    parameter integer PSUM_ADDR_WIDTH     = 12,
    parameter integer WEIGHT_MAX_OC_TILES = 16,
    parameter integer WEIGHT_MAX_K_TILES  = 64,
    parameter integer WEIGHT_ADDR_WIDTH   = 13,
    parameter integer WEIGHT_DEPTH_WORDS  = WEIGHT_MAX_OC_TILES * WEIGHT_MAX_K_TILES * 8,
    parameter integer MAX_OUTPUT_CHANNELS = 128,
    parameter integer MAX_QUANT_PARAMS    = 1024,
    parameter integer QUANT_ADDR_WIDTH    = (MAX_QUANT_PARAMS <= 1) ? 1 : $clog2(MAX_QUANT_PARAMS),
    parameter integer FC_MAX_INPUT_LENGTH = 256,
    parameter integer FC_MAX_CLASSES      = 256,
    parameter integer FC_ACC_WIDTH        = 40,
    parameter integer FC_INPUT_WORDS      = (FC_MAX_INPUT_LENGTH + 7) / 8,
    parameter integer FC_INPUT_ADDR_WIDTH = (FC_INPUT_WORDS <= 1) ? 1 : $clog2(FC_INPUT_WORDS),
    parameter integer FC_CLASS_ADDR_WIDTH = (FC_MAX_CLASSES <= 1) ? 1 : $clog2(FC_MAX_CLASSES),
    // 默认保持原有普通GAP；动态手势配置打开后使用定点重标定GAP。
    parameter bit GAP_REQUANT_ENABLE = 1'b0,
    parameter integer GAP_REQUANT_MULTIPLIER = 205105,
    parameter integer GAP_REQUANT_SHIFT = 20
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         start,
    input  logic [3:0]                   layer_count,

    input  logic                         desc_wr_en,
    input  logic [2:0]                   desc_wr_index,
    input  logic [255:0]                 desc_wr_data,
    input  logic                         layer_param_wr_en,
    input  logic [2:0]                   layer_param_wr_index,
    input  logic [95:0]                  layer_param_wr_data,

    input  logic                         init_wr_en,
    input  logic                         init_wr_bank,
    input  logic [FEATURE_ADDR_WIDTH-1:0] init_wr_addr,
    input  logic [127:0]                 init_wr_data,
    input  logic [15:0]                  init_wr_strb,

    input  logic                         conv_weight_wr_en,
    input  logic [WEIGHT_ADDR_WIDTH-1:0] conv_weight_wr_addr,
    input  logic signed [127:0]          conv_weight_wr_data,
    input  logic                         quant_wr_en,
    input  logic [QUANT_ADDR_WIDTH-1:0]   quant_wr_addr,
    input  logic signed [31:0]           quant_wr_bias,
    input  logic signed [15:0]           quant_wr_multiplier,
    input  logic [5:0]                   quant_wr_shift,
    input  logic signed [15:0]           output_zero_point,
    input  logic                         relu_enable,

    // 最后一层输出/GAP配置。
    input  logic [15:0]                  final_output_width,
    input  logic [15:0]                  final_output_height,
    input  logic [15:0]                  final_output_channels,

    // FC模型装载口。输入向量由GAP自动写入，无需外部装载。
    input  logic                         fc_weight_wr_en,
    input  logic [FC_CLASS_ADDR_WIDTH-1:0] fc_weight_wr_class,
    input  logic [FC_INPUT_ADDR_WIDTH-1:0] fc_weight_wr_word_addr,
    input  logic [63:0]                  fc_weight_wr_data,
    input  logic                         fc_bias_wr_en,
    input  logic [FC_CLASS_ADDR_WIDTH-1:0] fc_bias_wr_class,
    input  logic signed [31:0]           fc_bias_wr_data,
    input  logic [15:0]                  fc_class_count,

    output logic                         busy,
    output logic                         done,
    output logic                         error,
    output logic                         result_valid,
    output logic [FC_CLASS_ADDR_WIDTH-1:0] result_class,
    output logic signed [FC_ACC_WIDTH-1:0] result_score,
    output logic                         fc_class_score_valid,
    output logic [FC_CLASS_ADDR_WIDTH-1:0] fc_class_score_index,
    output logic signed [FC_ACC_WIDTH-1:0] fc_class_score,
    output logic [2:0]                   active_layer_index
);

    localparam integer GAP_BLOCKS = (MAX_OUTPUT_CHANNELS + 15) / 16;
    localparam integer GAP_BLOCK_INDEX_WIDTH = (GAP_BLOCKS <= 1) ? 1 : $clog2(GAP_BLOCKS);

    typedef enum logic [3:0] {
        S_IDLE, S_CONV, S_GAP_CAPTURE, S_GAP_LOW, S_GAP_HIGH,
        S_FC_START, S_FC_WAIT, S_FINISH, S_ERROR
    } state_t;
    state_t state;

    logic conv_start;
    logic conv_busy, conv_done, conv_error;
    logic conv_input_bank, conv_output_bank;
    logic gap_start;
    logic gap_busy, gap_done, gap_error;
    logic gap_out_valid, gap_out_last;
    logic [GAP_BLOCK_INDEX_WIDTH-1:0] gap_out_block_index;
    logic [127:0] gap_out_data;

    logic [127:0] gap_word_latched;
    logic [GAP_BLOCK_INDEX_WIDTH-1:0] gap_block_latched;
    logic gap_last_latched;

    logic fc_input_wr_en;
    logic [FC_INPUT_ADDR_WIDTH-1:0] fc_input_wr_addr;
    logic [63:0] fc_input_wr_data;
    logic fc_start;
    logic fc_busy, fc_done, fc_error, fc_result_valid;
    logic [15:0] gap_blocks_cfg;

    assign busy = (state != S_IDLE) && (state != S_FINISH) && (state != S_ERROR);
    logic result_valid_reg;
    assign result_valid = result_valid_reg | fc_result_valid | fc_done;
    assign gap_blocks_cfg = (final_output_channels + 16'd15) >> 4;

    // 一个GAP HWC16输出包含16个INT8，拆成两个FC的8元素word。
    always_comb begin
        fc_input_wr_en = 1'b0;
        fc_input_wr_addr = '0;
        fc_input_wr_data = '0;
        if (state == S_GAP_LOW) begin
            fc_input_wr_en = 1'b1;
            fc_input_wr_addr = gap_block_latched * 2;
            fc_input_wr_data = gap_word_latched[63:0];
        end
        else if (state == S_GAP_HIGH) begin
            fc_input_wr_en = 1'b1;
            fc_input_wr_addr = gap_block_latched * 2 + 1'b1;
            fc_input_wr_data = gap_word_latched[127:64];
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE;
            conv_start <= 1'b0;
            gap_start <= 1'b0;
            fc_start <= 1'b0;
            done <= 1'b0;
            error <= 1'b0;
            gap_word_latched <= '0;
            gap_block_latched <= '0;
            gap_last_latched <= 1'b0;
            result_valid_reg <= 1'b0;
        end
        else begin
            conv_start <= 1'b0;
            gap_start <= 1'b0;
            fc_start <= 1'b0;
            done <= 1'b0;
            if (fc_result_valid || fc_done)
                result_valid_reg <= 1'b1;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        result_valid_reg <= 1'b0;
                        error <= 1'b0;
                        if ((final_output_width == 0) || (final_output_height == 0) ||
                            (final_output_channels == 0) ||
                            (final_output_channels > MAX_OUTPUT_CHANNELS) ||
                            (final_output_channels > FC_MAX_INPUT_LENGTH) ||
                            (fc_class_count == 0) || (fc_class_count > FC_MAX_CLASSES)) begin
                            error <= 1'b1;
                            done <= 1'b1;
                            state <= S_ERROR;
                        end
                        else begin
                            conv_start <= 1'b1;
                            state <= S_CONV;
                        end
                    end
                end

                S_CONV: begin
                    if (conv_error) begin
                        error <= 1'b1;
                        state <= S_ERROR;
                    end
                    else if (conv_done) begin
                        gap_start <= 1'b1;
                        state <= S_GAP_CAPTURE;
                    end
                end

                S_GAP_CAPTURE: begin
                    if (gap_error) begin
                        error <= 1'b1;
                        state <= S_ERROR;
                    end
                    else if (gap_out_valid) begin
                        gap_word_latched <= gap_out_data;
                        gap_block_latched <= gap_out_block_index;
                        gap_last_latched <= gap_out_last;
                        state <= S_GAP_LOW;
                    end
                end

                S_GAP_LOW: state <= S_GAP_HIGH;

                S_GAP_HIGH: begin
                    if (gap_last_latched)
                        state <= S_FC_START;
                    else
                        state <= S_GAP_CAPTURE;
                end

                S_FC_START: begin
                    // 前一拍高64位已在本拍时钟沿写入FC输入缓存。
                    fc_start <= 1'b1;
                    state <= S_FC_WAIT;
                end

                S_FC_WAIT: begin
                    if (fc_error) begin
                        error <= 1'b1;
                        state <= S_ERROR;
                    end
                    else if (fc_done) begin
                        done <= 1'b1;
                        state <= S_FINISH;
                    end
                end

                S_FINISH: state <= S_IDLE;

                S_ERROR: state <= S_IDLE;

                default: state <= S_IDLE;
            endcase
        end
    end

    npu_three_layer_local_top #(
        .FEATURE_DEPTH_WORDS(FEATURE_DEPTH_WORDS),
        .FEATURE_ADDR_WIDTH(FEATURE_ADDR_WIDTH),
        .MAX_OUTPUT_PIXELS(MAX_OUTPUT_PIXELS),
        .PSUM_ADDR_WIDTH(PSUM_ADDR_WIDTH),
        .WEIGHT_MAX_OC_TILES(WEIGHT_MAX_OC_TILES),
        .WEIGHT_MAX_K_TILES(WEIGHT_MAX_K_TILES),
        .WEIGHT_ADDR_WIDTH(WEIGHT_ADDR_WIDTH),
        .WEIGHT_DEPTH_WORDS(WEIGHT_DEPTH_WORDS),
        .MAX_OUTPUT_CHANNELS(MAX_OUTPUT_CHANNELS),
        .MAX_QUANT_PARAMS(MAX_QUANT_PARAMS), .QUANT_ADDR_WIDTH(QUANT_ADDR_WIDTH),
        .GAP_REQUANT_ENABLE(GAP_REQUANT_ENABLE),
        .GAP_REQUANT_MULTIPLIER(GAP_REQUANT_MULTIPLIER),
        .GAP_REQUANT_SHIFT(GAP_REQUANT_SHIFT)
    ) u_conv_gap (
        .clk(clk), .rst_n(rst_n), .start(conv_start), .layer_count(layer_count),
        .gap_start(gap_start), .gap_width(final_output_width),
        .gap_height(final_output_height),
        .gap_channel_blocks(gap_blocks_cfg),
        .desc_wr_en(desc_wr_en), .desc_wr_index(desc_wr_index), .desc_wr_data(desc_wr_data),
        .layer_param_wr_en(layer_param_wr_en),
        .layer_param_wr_index(layer_param_wr_index),
        .layer_param_wr_data(layer_param_wr_data),
        .init_wr_en(init_wr_en), .init_wr_bank(init_wr_bank),
        .init_wr_addr(init_wr_addr), .init_wr_data(init_wr_data), .init_wr_strb(init_wr_strb),
        .weight_wr_en(conv_weight_wr_en), .weight_wr_addr(conv_weight_wr_addr),
        .weight_wr_data(conv_weight_wr_data), .quant_wr_en(quant_wr_en),
        .quant_wr_addr(quant_wr_addr), .quant_wr_bias(quant_wr_bias),
        .quant_wr_multiplier(quant_wr_multiplier), .quant_wr_shift(quant_wr_shift),
        .output_zero_point(output_zero_point), .relu_enable(relu_enable),
        .busy(conv_busy), .all_done(conv_done), .error(conv_error),
        .layer_index(active_layer_index), .active_input_bank(conv_input_bank),
        .active_output_bank(conv_output_bank), .gap_busy(gap_busy), .gap_done(gap_done),
        .gap_error(gap_error), .gap_out_valid(gap_out_valid),
        .gap_out_block_index(gap_out_block_index), .gap_out_data(gap_out_data),
        .gap_out_last(gap_out_last)
    );

    fc_classifier_8lane #(
        .MAX_INPUT_LENGTH(FC_MAX_INPUT_LENGTH), .MAX_CLASSES(FC_MAX_CLASSES),
        .ACC_WIDTH(FC_ACC_WIDTH), .MAX_INPUT_WORDS(FC_INPUT_WORDS),
        .INPUT_WORD_ADDR_WIDTH(FC_INPUT_ADDR_WIDTH),
        .CLASS_ADDR_WIDTH(FC_CLASS_ADDR_WIDTH)
    ) u_fc (
        .clk(clk), .rst_n(rst_n),
        .input_wr_en(fc_input_wr_en), .input_wr_word_addr(fc_input_wr_addr),
        .input_wr_data(fc_input_wr_data),
        .weight_wr_en(fc_weight_wr_en), .weight_wr_class(fc_weight_wr_class),
        .weight_wr_word_addr(fc_weight_wr_word_addr), .weight_wr_data(fc_weight_wr_data),
        .bias_wr_en(fc_bias_wr_en), .bias_wr_class(fc_bias_wr_class),
        .bias_wr_data(fc_bias_wr_data), .start(fc_start),
        .cfg_input_length(final_output_channels), .cfg_class_count(fc_class_count),
        .busy(fc_busy), .done(fc_done), .config_error(fc_error),
        .result_valid(fc_result_valid), .result_class(result_class),
        .result_score(result_score), .class_score_valid(fc_class_score_valid),
        .class_score_index(fc_class_score_index), .class_score(fc_class_score)
    );
endmodule
