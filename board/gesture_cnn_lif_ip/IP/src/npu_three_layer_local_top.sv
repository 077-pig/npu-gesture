`timescale 1ns / 1ps

// 三层本地联调顶层：同一个16x8卷积流水线重复运行，A/B缓存交替作为输入/输出。
// 该模块用于在AXI接入前验证真实的层间数据流；三层参数暂由外部提供一组，
// 后续AXI寄存器只需把这些端口替换为层描述表输出即可。
module npu_three_layer_local_top #(
    parameter integer FEATURE_DEPTH_WORDS = 4096,
    parameter integer FEATURE_ADDR_WIDTH  = 12,
    parameter integer MAX_OUTPUT_PIXELS   = 4096,
    parameter integer PSUM_ADDR_WIDTH     = 12,
    parameter integer WEIGHT_MAX_OC_TILES = 16,
    parameter integer WEIGHT_MAX_K_TILES  = 64,
    parameter integer WEIGHT_ADDR_WIDTH   = 13,
    parameter integer WEIGHT_DEPTH_WORDS  = WEIGHT_MAX_OC_TILES * WEIGHT_MAX_K_TILES * 8,
    parameter integer MAX_OUTPUT_CHANNELS = 128,
    parameter integer MAX_QUANT_PARAMS = 1024,
    parameter integer QUANT_ADDR_WIDTH = (MAX_QUANT_PARAMS <= 1) ? 1 : $clog2(MAX_QUANT_PARAMS),
    // 默认保持原MNIST路径的普通GAP；动态手势工程打开此参数后，
    // GAP会直接输出与Python定点模型一致的q_gap。
    parameter bit GAP_REQUANT_ENABLE = 1'b0,
    parameter integer GAP_REQUANT_MULTIPLIER = 205105,
    parameter integer GAP_REQUANT_SHIFT = 20
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         start,
    input  logic [3:0]                   layer_count,

    // 三层卷积完成后启动GAP。宽高和通道块数应与最后一层输出一致。
    input  logic                         gap_start,
    input  logic [15:0]                  gap_width,
    input  logic [15:0]                  gap_height,
    input  logic [15:0]                  gap_channel_blocks,

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

    input  logic                         weight_wr_en,
    input  logic [WEIGHT_ADDR_WIDTH-1:0] weight_wr_addr,
    input  logic signed [127:0]          weight_wr_data,
    input  logic                         quant_wr_en,
    input  logic [QUANT_ADDR_WIDTH-1:0] quant_wr_addr,
    input  logic signed [31:0]            quant_wr_bias,
    input  logic signed [15:0]            quant_wr_multiplier,
    input  logic [5:0]                    quant_wr_shift,
    input  logic signed [15:0]            output_zero_point,
    input  logic                         relu_enable,

    output logic                         busy,
    output logic                         all_done,
    output logic                         error,
    output logic [2:0]                   layer_index,
    output logic                         active_input_bank,
    output logic                         active_output_bank,
    output logic                         gap_busy,
    output logic                         gap_done,
    output logic                         gap_error,
    output logic                         gap_out_valid,
    output logic [((MAX_OUTPUT_CHANNELS + 15) / 16 <= 1 ? 1 : $clog2((MAX_OUTPUT_CHANNELS + 15) / 16))-1:0] gap_out_block_index,
    output logic [127:0]                 gap_out_data,
    output logic                         gap_out_last
);
    localparam integer OC_ADDR_WIDTH = (MAX_OUTPUT_CHANNELS <= 1) ? 1 : $clog2(MAX_OUTPUT_CHANNELS);
    localparam integer GAP_BLOCKS = (MAX_OUTPUT_CHANNELS + 15) / 16;
    localparam integer GAP_BLOCK_INDEX_WIDTH = (GAP_BLOCKS <= 1) ? 1 : $clog2(GAP_BLOCKS);

    logic layer_start, layer_done, layer_error;
    logic [2:0] sched_layer_index;
    logic sched_input_bank, sched_output_bank;

    logic pipe_out_wr_valid;
    logic [PSUM_ADDR_WIDTH+$clog2((MAX_OUTPUT_CHANNELS + 15) / 16)-1:0] pipe_out_wr_addr;
    logic [127:0] pipe_out_wr_data;
    logic [15:0] pipe_out_wr_strb;
    logic pipe_out_wr_last;
    logic pipe_feature_rd_en;
    logic [FEATURE_ADDR_WIDTH-1:0] pipe_feature_rd_addr;
    logic pipe_feature_rd_valid;
    logic signed [127:0] pipe_feature_rd_data;
    logic pipe_wt_ready;
    logic [15:0] pipe_wt_req_oc_tile, pipe_wt_req_k_tile;
    logic [2:0] pipe_wt_req_col;
    logic pipe_busy, pipe_done, pipe_error;

    logic buf_wr_en, buf_wr_bank;
    logic [FEATURE_ADDR_WIDTH-1:0] buf_wr_addr;
    logic [127:0] buf_wr_data;
    logic [15:0] buf_wr_strb;
    logic buf_rd_valid;
    logic [127:0] buf_rd_data;
    logic gap_feature_rd_en;
    logic [FEATURE_ADDR_WIDTH-1:0] gap_feature_rd_addr;
    logic gap_feature_rd_valid;
    logic [127:0] gap_feature_rd_data;
    logic [FEATURE_ADDR_WIDTH-1:0] zero_feature_addr;
    logic [127:0] zero_feature_data;
    logic [255:0] layer_desc;
    logic [255:0] desc_rd_data;
    logic [95:0] layer_param_rd_data;
    logic [15:0] cfg_input_width, cfg_input_height, cfg_channel_blocks;
    logic [15:0] cfg_kernel_width, cfg_kernel_height, cfg_stride;
    logic [15:0] cfg_pad_left, cfg_pad_top;
    logic [15:0] cfg_output_width, cfg_output_height;
    logic [15:0] cfg_k_tiles, cfg_output_channels;
    logic [31:0] cfg_output_pixels;
    logic [31:0] cfg_output_x_step_words;
    logic signed [31:0] cfg_output_row_step_words;
    logic signed [31:0] cfg_kernel_row_step_words;
    logic signed [31:0] cfg_window_base_addr;
    logic [WEIGHT_ADDR_WIDTH-1:0] cfg_weight_base_addr;
    logic [QUANT_ADDR_WIDTH-1:0] cfg_quant_base_addr;
    logic signed [15:0] cfg_output_zero_point;
    logic cfg_relu_enable;

    assign zero_feature_addr = '0;
    assign zero_feature_data = '0;

    // 256位层描述格式（每个字段16位，小端字段编号）：
    // [0]iw [1]ih [2]channel_blocks [3]kw [4]kh [5]stride [6]pad_left [7]pad_top
    // [8]ow [9]oh [10]k_tiles [11]output_channels [12]x_step [13]row_step
    // [14]kernel_row_step [15]window_base低16位（当前本地联调为0）。
    assign layer_desc = desc_rd_data;
    assign cfg_input_width = layer_desc[15:0];
    assign cfg_input_height = layer_desc[31:16];
    assign cfg_channel_blocks = layer_desc[47:32];
    assign cfg_kernel_width = layer_desc[63:48];
    assign cfg_kernel_height = layer_desc[79:64];
    assign cfg_stride = layer_desc[95:80];
    assign cfg_pad_left = layer_desc[111:96];
    assign cfg_pad_top = layer_desc[127:112];
    assign cfg_output_width = layer_desc[143:128];
    assign cfg_output_height = layer_desc[159:144];
    assign cfg_k_tiles = layer_desc[175:160];
    assign cfg_output_channels = layer_desc[191:176];
    assign cfg_output_x_step_words = {16'd0, layer_desc[207:192]};
    assign cfg_output_row_step_words = $signed({{16{layer_desc[223]}}, layer_desc[223:208]});
    assign cfg_kernel_row_step_words = $signed({{16{layer_desc[239]}}, layer_desc[239:224]});
    assign cfg_window_base_addr = $signed({{16{layer_desc[255]}}, layer_desc[255:240]});
    assign cfg_weight_base_addr = layer_param_rd_data[WEIGHT_ADDR_WIDTH-1:0];
    assign cfg_quant_base_addr = layer_param_rd_data[32 +: QUANT_ADDR_WIDTH];
    assign cfg_output_zero_point = $signed(layer_param_rd_data[63:48]);
    assign cfg_relu_enable = layer_param_rd_data[64];
    assign cfg_output_pixels = cfg_output_width * cfg_output_height;

    // 结束/错误直接来自单层流水线；scheduler在下一拍切换到下一层。
    assign layer_done = pipe_done;
    assign layer_error = pipe_error;
    assign layer_index = sched_layer_index;
    assign active_input_bank = sched_input_bank;
    assign active_output_bank = sched_output_bank;

    // 初始化写入只在空闲阶段使用；运行阶段写口属于当前流水线输出。
    assign buf_wr_en   = pipe_out_wr_valid || (init_wr_en && !busy);
    assign buf_wr_bank = pipe_out_wr_valid ? sched_output_bank : init_wr_bank;
    assign buf_wr_addr = pipe_out_wr_valid ? pipe_out_wr_addr[FEATURE_ADDR_WIDTH-1:0] : init_wr_addr;
    assign buf_wr_data = pipe_out_wr_valid ? pipe_out_wr_data : init_wr_data;
    assign buf_wr_strb = pipe_out_wr_valid ? pipe_out_wr_strb : init_wr_strb;

    npu_multilayer_scheduler #(.MAX_LAYERS(8)) u_scheduler (
        .clk(clk), .rst_n(rst_n), .start(start), .layer_count(layer_count),
        .layer_done(layer_done), .layer_error(layer_error),
        .layer_start(layer_start), .active(busy), .all_done(all_done),
        .error(error), .layer_index(sched_layer_index),
        .input_bank(sched_input_bank), .output_bank(sched_output_bank)
    );

    npu_layer_desc_table #(.MAX_LAYERS(8), .DESC_WIDTH(256)) u_desc_table (
        .clk(clk), .rst_n(rst_n), .wr_en(desc_wr_en), .wr_index(desc_wr_index),
        .wr_data(desc_wr_data), .rd_index(sched_layer_index), .rd_data(desc_rd_data)
    );

    npu_layer_param_table #(.MAX_LAYERS(8), .PARAM_WIDTH(96)) u_param_table (
        .clk(clk), .rst_n(rst_n), .wr_en(layer_param_wr_en),
        .wr_index(layer_param_wr_index), .wr_data(layer_param_wr_data),
        .rd_index(sched_layer_index), .rd_data(layer_param_rd_data)
    );

    feature_pingpong_buffer_hwc16 #(
        .DEPTH_WORDS(FEATURE_DEPTH_WORDS), .ADDR_WIDTH(FEATURE_ADDR_WIDTH)
    ) u_feature_ab (
        .clk(clk), .rst_n(rst_n),
        .wr_en(buf_wr_en), .wr_bank(buf_wr_bank), .wr_addr(buf_wr_addr),
        .wr_data(buf_wr_data), .wr_strb(buf_wr_strb),
        .rd_en(pipe_feature_rd_en), .rd_bank(sched_input_bank),
        .rd_addr(pipe_feature_rd_addr), .rd_valid(buf_rd_valid), .rd_data(buf_rd_data),
        .rd2_en(gap_feature_rd_en), .rd2_bank(sched_output_bank),
        .rd2_addr(gap_feature_rd_addr), .rd2_valid(gap_feature_rd_valid),
        .rd2_data(gap_feature_rd_data)
    );

    conv_layer_pipeline_16x8 #(
        .FEATURE_DEPTH_WORDS(FEATURE_DEPTH_WORDS),
        .FEATURE_ADDR_WIDTH(FEATURE_ADDR_WIDTH),
        .MAX_OUTPUT_PIXELS(MAX_OUTPUT_PIXELS),
        .PSUM_ADDR_WIDTH(PSUM_ADDR_WIDTH),
        .WEIGHT_MAX_OC_TILES(WEIGHT_MAX_OC_TILES),
        .WEIGHT_MAX_K_TILES(WEIGHT_MAX_K_TILES),
        .WEIGHT_ADDR_WIDTH(WEIGHT_ADDR_WIDTH),
        .WEIGHT_DEPTH_WORDS(WEIGHT_DEPTH_WORDS),
        .USE_INTERNAL_WEIGHT_BUFFER(1'b1),
        .USE_EXTERNAL_FEATURE_BUFFER(1'b1),
        .MAX_OUTPUT_CHANNELS(MAX_OUTPUT_CHANNELS),
        .MAX_QUANT_PARAMS(MAX_QUANT_PARAMS), .QUANT_ADDR_WIDTH(QUANT_ADDR_WIDTH)
    ) u_pipeline (
        .clk(clk), .rst_n(rst_n),
        .feature_wr_en(1'b0), .feature_wr_addr(zero_feature_addr), .feature_wr_data(zero_feature_data),
        .weight_wr_en(weight_wr_en), .weight_wr_addr(weight_wr_addr), .weight_wr_data(weight_wr_data),
        .start(layer_start),
        .cfg_input_width(cfg_input_width), .cfg_input_height(cfg_input_height),
        .cfg_channel_blocks(cfg_channel_blocks), .cfg_kernel_width(cfg_kernel_width),
        .cfg_kernel_height(cfg_kernel_height), .cfg_stride(cfg_stride),
        .cfg_pad_left(cfg_pad_left), .cfg_pad_top(cfg_pad_top),
        .cfg_window_base_addr(cfg_window_base_addr),
        .cfg_output_x_step_words(cfg_output_x_step_words),
        .cfg_output_row_step_words(cfg_output_row_step_words),
        .cfg_kernel_row_step_words(cfg_kernel_row_step_words),
        .cfg_output_width(cfg_output_width), .cfg_output_height(cfg_output_height),
        .cfg_output_pixels(cfg_output_pixels), .cfg_k_tiles(cfg_k_tiles),
        .cfg_output_channels(cfg_output_channels),
        .cfg_weight_base_addr(cfg_weight_base_addr),
        .cfg_quant_base_addr(cfg_quant_base_addr),
        .wt_valid(pipe_wt_ready), .wt_data(128'h01010101010101010101010101010101),
        .wt_ready(pipe_wt_ready), .wt_req_oc_tile(pipe_wt_req_oc_tile),
        .wt_req_k_tile(pipe_wt_req_k_tile), .wt_req_col(pipe_wt_req_col),
        .quant_wr_en(quant_wr_en), .quant_wr_addr(quant_wr_addr),
        .quant_wr_bias(quant_wr_bias), .quant_wr_multiplier(quant_wr_multiplier),
        .quant_wr_shift(quant_wr_shift), .output_zero_point(cfg_output_zero_point),
        .relu_enable(cfg_relu_enable), .busy(pipe_busy), .done(pipe_done),
        .config_error(pipe_error), .out_wr_valid(pipe_out_wr_valid),
        .out_wr_addr(pipe_out_wr_addr), .out_wr_data(pipe_out_wr_data),
        .out_wr_strb(pipe_out_wr_strb), .out_wr_last(pipe_out_wr_last),
        .feature_mem_rd_en(pipe_feature_rd_en), .feature_mem_rd_addr(pipe_feature_rd_addr),
        .feature_mem_rd_valid(buf_rd_valid), .feature_mem_rd_data(buf_rd_data)
    );

    generate
        if (GAP_REQUANT_ENABLE) begin : gen_gap_requant
            gap_hwc16_requant #(
                .FEATURE_ADDR_WIDTH(FEATURE_ADDR_WIDTH),
                .MAX_CHANNEL_BLOCKS(GAP_BLOCKS),
                .REQUANT_MULTIPLIER(GAP_REQUANT_MULTIPLIER),
                .REQUANT_SHIFT(GAP_REQUANT_SHIFT)
            ) u_gap (
                .clk(clk), .rst_n(rst_n), .start(gap_start),
                .cfg_width(gap_width), .cfg_height(gap_height),
                .cfg_channel_blocks(gap_channel_blocks),
                .feature_rd_en(gap_feature_rd_en), .feature_rd_addr(gap_feature_rd_addr),
                .feature_rd_valid(gap_feature_rd_valid), .feature_rd_data(gap_feature_rd_data),
                .out_valid(gap_out_valid), .out_block_index(gap_out_block_index),
                .out_data(gap_out_data), .out_last(gap_out_last),
                .busy(gap_busy), .done(gap_done), .config_error(gap_error)
            );
        end
        else begin : gen_gap_plain
            gap_hwc16 #(
                .FEATURE_ADDR_WIDTH(FEATURE_ADDR_WIDTH),
                .MAX_CHANNEL_BLOCKS(GAP_BLOCKS)
            ) u_gap (
                .clk(clk), .rst_n(rst_n), .start(gap_start),
                .cfg_width(gap_width), .cfg_height(gap_height),
                .cfg_channel_blocks(gap_channel_blocks),
                .feature_rd_en(gap_feature_rd_en), .feature_rd_addr(gap_feature_rd_addr),
                .feature_rd_valid(gap_feature_rd_valid), .feature_rd_data(gap_feature_rd_data),
                .out_valid(gap_out_valid), .out_block_index(gap_out_block_index),
                .out_data(gap_out_data), .out_last(gap_out_last),
                .busy(gap_busy), .done(gap_done), .config_error(gap_error)
            );
        end
    endgenerate
endmodule
