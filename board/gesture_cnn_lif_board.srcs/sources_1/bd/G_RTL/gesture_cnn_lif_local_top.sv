`timescale 1ns / 1ps

// 动态手势CNN+LIF本地顶层。
// 每次frame_start处理一个时间步：三层卷积 -> requant GAP -> FC -> LIF。
// 第0时间步置sequence_start，第15时间步置sequence_end。
module gesture_cnn_lif_local_top #(
    parameter integer FEATURE_DEPTH_WORDS = 4096,
    parameter integer FEATURE_ADDR_WIDTH = 12,
    parameter integer WEIGHT_ADDR_WIDTH = 13,
    parameter integer WEIGHT_DEPTH_WORDS = 8192,
    parameter integer QUANT_ADDR_WIDTH = 10,
    parameter integer FC_INPUT_ADDR_WIDTH = 3,
    parameter integer FC_CLASS_ADDR_WIDTH = 4,
    parameter integer FC_ACC_WIDTH = 40
) (
    input logic clk,
    input logic rst_n,
    input logic frame_start,
    input logic sequence_start,
    input logic sequence_end,

    input logic desc_wr_en,
    input logic [2:0] desc_wr_index,
    input logic [255:0] desc_wr_data,
    input logic layer_param_wr_en,
    input logic [2:0] layer_param_wr_index,
    input logic [95:0] layer_param_wr_data,

    input logic init_wr_en,
    input logic init_wr_bank,
    input logic [FEATURE_ADDR_WIDTH-1:0] init_wr_addr,
    input logic [127:0] init_wr_data,
    input logic [15:0] init_wr_strb,

    input logic conv_weight_wr_en,
    input logic [WEIGHT_ADDR_WIDTH-1:0] conv_weight_wr_addr,
    input logic signed [127:0] conv_weight_wr_data,
    input logic quant_wr_en,
    input logic [QUANT_ADDR_WIDTH-1:0] quant_wr_addr,
    input logic signed [31:0] quant_wr_bias,
    input logic signed [15:0] quant_wr_multiplier,
    input logic [5:0] quant_wr_shift,

    input logic fc_weight_wr_en,
    input logic [FC_CLASS_ADDR_WIDTH-1:0] fc_weight_wr_class,
    input logic [FC_INPUT_ADDR_WIDTH-1:0] fc_weight_wr_word_addr,
    input logic [63:0] fc_weight_wr_data,
    input logic fc_bias_wr_en,
    input logic [FC_CLASS_ADDR_WIDTH-1:0] fc_bias_wr_class,
    input logic signed [31:0] fc_bias_wr_data,

    output logic busy,
    output logic frame_done,
    output logic error,
    output logic sequence_done,
    output logic result_valid,
    output logic [3:0] result_class,
    output logic [175:0] spike_counts,
    output logic signed [11*32-1:0] membrane_values,
    output logic [2:0] active_layer_index
);
    logic core_result_valid;
    logic [FC_CLASS_ADDR_WIDTH-1:0] core_result_class;
    logic signed [FC_ACC_WIDTH-1:0] core_result_score;
    logic fc_class_score_valid;
    logic [FC_CLASS_ADDR_WIDTH-1:0] fc_class_score_index;
    logic signed [FC_ACC_WIDTH-1:0] fc_class_score;

    logic collector_clear;
    logic scores_valid;
    logic signed [11*FC_ACC_WIDTH-1:0] scores;
    logic sequence_start_latched;
    logic sequence_end_latched;
    logic core_busy;
    logic core_frame_done;
    logic core_error;
    logic lif_processing_busy;
    logic lif_spike_valid;
    logic [10:0] lif_spikes;

    assign busy = core_busy || lif_processing_busy;
    assign frame_done = lif_spike_valid;
    assign error = core_error;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            collector_clear <= 1'b0;
            sequence_start_latched <= 1'b0;
            sequence_end_latched <= 1'b0;
        end else begin
            collector_clear <= frame_start;
            if (frame_start) begin
                sequence_start_latched <= sequence_start;
                sequence_end_latched <= sequence_end;
            end
            if (scores_valid) begin
                sequence_start_latched <= 1'b0;
                sequence_end_latched <= 1'b0;
            end
        end
    end

    npu_conv_gap_fc_local_top #(
        .FEATURE_DEPTH_WORDS(FEATURE_DEPTH_WORDS),
        .FEATURE_ADDR_WIDTH(FEATURE_ADDR_WIDTH),
        .WEIGHT_ADDR_WIDTH(WEIGHT_ADDR_WIDTH),
        .WEIGHT_DEPTH_WORDS(WEIGHT_DEPTH_WORDS),
        .MAX_OUTPUT_CHANNELS(128),
        .MAX_QUANT_PARAMS(1024),
        .QUANT_ADDR_WIDTH(QUANT_ADDR_WIDTH),
        .FC_MAX_INPUT_LENGTH(64),
        .FC_MAX_CLASSES(16),
        .FC_ACC_WIDTH(FC_ACC_WIDTH),
        .FC_INPUT_WORDS(8),
        .FC_INPUT_ADDR_WIDTH(FC_INPUT_ADDR_WIDTH),
        .FC_CLASS_ADDR_WIDTH(FC_CLASS_ADDR_WIDTH),
        .GAP_REQUANT_ENABLE(1'b1),
        .GAP_REQUANT_MULTIPLIER(448712),
        .GAP_REQUANT_SHIFT(20)
    ) u_frame_core (
        .clk(clk), .rst_n(rst_n), .start(frame_start), .layer_count(4'd3),
        .desc_wr_en(desc_wr_en), .desc_wr_index(desc_wr_index), .desc_wr_data(desc_wr_data),
        .layer_param_wr_en(layer_param_wr_en), .layer_param_wr_index(layer_param_wr_index),
        .layer_param_wr_data(layer_param_wr_data),
        .init_wr_en(init_wr_en), .init_wr_bank(init_wr_bank), .init_wr_addr(init_wr_addr),
        .init_wr_data(init_wr_data), .init_wr_strb(init_wr_strb),
        .conv_weight_wr_en(conv_weight_wr_en), .conv_weight_wr_addr(conv_weight_wr_addr),
        .conv_weight_wr_data(conv_weight_wr_data), .quant_wr_en(quant_wr_en),
        .quant_wr_addr(quant_wr_addr), .quant_wr_bias(quant_wr_bias),
        .quant_wr_multiplier(quant_wr_multiplier), .quant_wr_shift(quant_wr_shift),
        .output_zero_point(16'sd0), .relu_enable(1'b1),
        .final_output_width(16'd8), .final_output_height(16'd8),
        .final_output_channels(16'd64),
        .fc_weight_wr_en(fc_weight_wr_en), .fc_weight_wr_class(fc_weight_wr_class),
        .fc_weight_wr_word_addr(fc_weight_wr_word_addr), .fc_weight_wr_data(fc_weight_wr_data),
        .fc_bias_wr_en(fc_bias_wr_en), .fc_bias_wr_class(fc_bias_wr_class),
        .fc_bias_wr_data(fc_bias_wr_data), .fc_class_count(16'd11),
        .busy(core_busy), .done(core_frame_done), .error(core_error),
        .result_valid(core_result_valid), .result_class(core_result_class),
        .result_score(core_result_score), .fc_class_score_valid(fc_class_score_valid),
        .fc_class_score_index(fc_class_score_index), .fc_class_score(fc_class_score),
        .active_layer_index(active_layer_index)
    );

    fc_score_collector_11 #(
        .CLASS_COUNT(11), .SCORE_WIDTH(FC_ACC_WIDTH),
        .CLASS_INDEX_WIDTH(FC_CLASS_ADDR_WIDTH)
    ) u_collector (
        .clk(clk), .rst_n(rst_n), .clear(collector_clear),
        .class_score_valid(fc_class_score_valid),
        .class_score_index(fc_class_score_index), .class_score(fc_class_score),
        .scores_valid(scores_valid), .scores(scores)
    );

    lif_output_11 #(
        .CLASS_COUNT(11), .SCORE_WIDTH(FC_ACC_WIDTH),
        .MULTIPLIER(6906), .SHIFT(20), .THRESHOLD_Q(5)
    ) u_lif (
        .clk(clk), .rst_n(rst_n),
        .sequence_start(sequence_start_latched),
        .current_valid(scores_valid), .sequence_end(sequence_end_latched),
        .in_score(scores), .processing_busy(lif_processing_busy),
        .spike_valid(lif_spike_valid), .spikes(lif_spikes),
        .sequence_done(sequence_done), .result_valid(result_valid),
        .result_class(result_class), .spike_counts(spike_counts),
        .membrane_values(membrane_values)
    );
endmodule
