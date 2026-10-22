`timescale 1ns / 1ps

// V2 HWC16卷积数据通路顶层：
// 特征写入 -> HWC16 BRAM -> padding/地址取数 -> 16x8卷积 -> 跨K累加。
// 默认参数按Zynq-7020片上RAM容量设置；更大的张量由软件分块后重复启动。
module conv_hwc16_engine_top #(
    parameter integer FEATURE_DEPTH_WORDS = 4096,
    parameter integer FEATURE_ADDR_WIDTH  = 12,
    parameter integer MAX_OUTPUT_PIXELS   = 4096,
    parameter integer PSUM_ADDR_WIDTH     = 12,
    parameter integer WEIGHT_MAX_OC_TILES = 16,
    parameter integer WEIGHT_MAX_K_TILES  = 64,
    parameter integer WEIGHT_ADDR_WIDTH   = 13,
    parameter integer WEIGHT_DEPTH_WORDS  = WEIGHT_MAX_OC_TILES * WEIGHT_MAX_K_TILES * 8,
    parameter bit     USE_INTERNAL_WEIGHT_BUFFER = 1'b1,
    parameter bit     USE_EXTERNAL_FEATURE_BUFFER = 1'b0
) (
    input  logic                  clk,
    input  logic                  rst_n,

    input  logic                  feature_wr_en,
    input  logic [FEATURE_ADDR_WIDTH-1:0] feature_wr_addr,
    input  logic signed [127:0]   feature_wr_data,

    // 由PS/DMA装载的线性权重写口。地址由Python打包工具生成。
    input  logic                  weight_wr_en,
    input  logic [WEIGHT_ADDR_WIDTH-1:0] weight_wr_addr,
    input  logic signed [127:0]   weight_wr_data,

    input  logic                  start,
    input  logic [15:0]           cfg_input_width,
    input  logic [15:0]           cfg_input_height,
    input  logic [15:0]           cfg_channel_blocks,
    input  logic [15:0]           cfg_kernel_width,
    input  logic [15:0]           cfg_kernel_height,
    input  logic [15:0]           cfg_stride,
    input  logic [15:0]           cfg_pad_left,
    input  logic [15:0]           cfg_pad_top,
    input  logic signed [31:0]    cfg_window_base_addr,
    input  logic [31:0]           cfg_output_x_step_words,
    input  logic signed [31:0]    cfg_output_row_step_words,
    input  logic signed [31:0]    cfg_kernel_row_step_words,
    input  logic [15:0]           cfg_output_width,
    input  logic [15:0]           cfg_output_height,
    input  logic [31:0]           cfg_output_pixels,
    input  logic [15:0]           cfg_k_tiles,
    input  logic [15:0]           cfg_output_channels,
    input  logic [WEIGHT_ADDR_WIDTH-1:0] cfg_weight_base_addr,

    output logic                  busy,
    output logic                  done,
    output logic                  config_error,

    output logic                  wt_ready,
    input  logic                  wt_valid,
    input  logic signed [127:0]   wt_data,
    output logic [15:0]           wt_req_oc_tile,
    output logic [15:0]           wt_req_k_tile,
    output logic [2:0]            wt_req_col,

    output logic                  out_valid,
    output logic [PSUM_ADDR_WIDTH-1:0] out_pixel_addr,
    output logic [15:0]           out_oc_base,
    output logic [7:0]            out_channel_mask,
    output logic signed [255:0]   out_psum,

    // 外部A/B特征缓存模式：取数请求由本模块发出，数据由外部缓存同步返回。
    output logic                  feature_mem_rd_en,
    output logic [FEATURE_ADDR_WIDTH-1:0] feature_mem_rd_addr,
    input  logic                  feature_mem_rd_valid,
    input  logic signed [127:0]   feature_mem_rd_data
);

    logic feature_rd_en;
    logic [FEATURE_ADDR_WIDTH-1:0] feature_rd_addr;
    logic feature_rd_valid;
    logic signed [127:0] feature_rd_data;

    logic engine_act_ready;
    logic engine_act_valid;
    logic signed [127:0] engine_act_data;
    logic [15:0] act_req_oc_tile;
    logic [15:0] act_req_k_tile;
    logic [15:0] act_req_x;
    logic [15:0] act_req_y;
    logic [31:0] act_req_pixel_addr;
    logic [15:0] act_req_kernel_x;
    logic [15:0] act_req_kernel_y;
    logic [15:0] act_req_channel_block;
    logic signed [16:0] act_req_in_x;
    logic signed [16:0] act_req_in_y;
    logic signed [31:0] act_req_word_addr;
    logic fetch_req_ready;
    logic fetch_padding;

    logic weight_req_valid;
    logic weight_req_ready;
    logic weight_rsp_valid;
    logic weight_rsp_ready;
    logic signed [127:0] weight_rsp_data;
    logic layer_wt_valid;
    logic signed [127:0] layer_wt_data;

    weight_buffer_16x8 #(
        .MAX_OC_TILES (WEIGHT_MAX_OC_TILES),
        .MAX_K_TILES  (WEIGHT_MAX_K_TILES),
        .ADDR_WIDTH   (WEIGHT_ADDR_WIDTH),
        .DEPTH_WORDS  (WEIGHT_DEPTH_WORDS)
    ) u_weight_buffer (
        .clk        (clk),
        .rst_n      (rst_n),
        .wr_en      (weight_wr_en),
        .wr_addr    (weight_wr_addr),
        .wr_data    (weight_wr_data),
        .req_valid  (weight_req_valid),
        .req_ready  (weight_req_ready),
        .req_oc_tile(wt_req_oc_tile),
        .req_k_tile (wt_req_k_tile),
        .req_col    (wt_req_col),
        .req_base_addr(cfg_weight_base_addr),
        .rsp_valid  (weight_rsp_valid),
        .rsp_ready  (weight_rsp_ready),
        .rsp_data   (weight_rsp_data)
    );

    // 内部缓存模式用于板级运行；参数置0时保留旧的外部供权重方式，
    // 便于与早期仿真环境兼容。
    // 请求由层控制器的装载状态驱动，缓存内部用req_ready完成真正握手。
    // 不把req_ready串回请求条件，减少一条不必要的组合反馈路径。
    // 仅在控制器请求且权重缓存可接收时发起请求；rsp_ready必须保持到返回拍，
    // 否则缓存会在S_RESP阶段被提前释放，导致后续列读到X。
    assign weight_req_valid = USE_INTERNAL_WEIGHT_BUFFER && wt_ready && weight_req_ready;
    assign weight_rsp_ready = USE_INTERNAL_WEIGHT_BUFFER && wt_ready;
    assign layer_wt_valid   = USE_INTERNAL_WEIGHT_BUFFER ? weight_rsp_valid : wt_valid;
    assign layer_wt_data    = USE_INTERNAL_WEIGHT_BUFFER ? weight_rsp_data  : wt_data;

    generate
        if (!USE_EXTERNAL_FEATURE_BUFFER) begin : G_INTERNAL_FEATURE
            feature_buffer_hwc16 #(
                .DEPTH_WORDS (FEATURE_DEPTH_WORDS),
                .ADDR_WIDTH  (FEATURE_ADDR_WIDTH)
            ) u_feature_buffer (
                .clk(clk), .rst_n(rst_n),
                .wr_en(feature_wr_en), .wr_addr(feature_wr_addr), .wr_data(feature_wr_data),
                .rd_en(feature_rd_en), .rd_addr(feature_rd_addr),
                .rd_valid(feature_rd_valid), .rd_data(feature_rd_data)
            );
            assign feature_mem_rd_en   = 1'b0;
            assign feature_mem_rd_addr = '0;
        end
        else begin : G_EXTERNAL_FEATURE
            assign feature_mem_rd_en   = feature_rd_en;
            assign feature_mem_rd_addr = feature_rd_addr;
            assign feature_rd_valid     = feature_mem_rd_valid;
            assign feature_rd_data      = feature_mem_rd_data;
        end
    endgenerate

    conv_activation_fetch_hwc16 #(.ADDR_WIDTH(FEATURE_ADDR_WIDTH)) u_activation_fetch (
        .clk(clk), .rst_n(rst_n), .clear(start),
        .cfg_input_width(cfg_input_width), .cfg_input_height(cfg_input_height),
        .req_valid(engine_act_ready), .req_ready(fetch_req_ready),
        .req_in_x(act_req_in_x), .req_in_y(act_req_in_y),
        .req_word_addr(act_req_word_addr),
        .mem_rd_en(feature_rd_en), .mem_rd_addr(feature_rd_addr),
        .mem_rd_valid(feature_rd_valid), .mem_rd_data(feature_rd_data),
        .rsp_valid(engine_act_valid), .rsp_ready(engine_act_ready),
        .rsp_tile(engine_act_data), .rsp_is_padding(fetch_padding)
    );

    conv_layer_engine_16x8 #(
        .MAX_OUTPUT_PIXELS(MAX_OUTPUT_PIXELS), .ADDR_WIDTH(PSUM_ADDR_WIDTH)
    ) u_layer_engine (
        .clk(clk), .rst_n(rst_n), .start(start),
        .cfg_output_width(cfg_output_width), .cfg_output_height(cfg_output_height),
        .cfg_output_pixels(cfg_output_pixels), .cfg_k_tiles(cfg_k_tiles),
        .cfg_output_channels(cfg_output_channels),
        .cfg_kernel_width(cfg_kernel_width), .cfg_kernel_height(cfg_kernel_height),
        .cfg_channel_blocks(cfg_channel_blocks),
        .cfg_stride(cfg_stride), .cfg_pad_left(cfg_pad_left), .cfg_pad_top(cfg_pad_top),
        .cfg_window_base_addr(cfg_window_base_addr),
        .cfg_output_x_step_words(cfg_output_x_step_words),
        .cfg_output_row_step_words(cfg_output_row_step_words),
        .cfg_kernel_row_step_words(cfg_kernel_row_step_words),
        .busy(busy), .done(done), .config_error(config_error),
        .wt_ready(wt_ready), .wt_valid(layer_wt_valid), .wt_data(layer_wt_data),
        .wt_req_oc_tile(wt_req_oc_tile), .wt_req_k_tile(wt_req_k_tile),
        .wt_req_col(wt_req_col),
        .act_ready(engine_act_ready), .act_valid(engine_act_valid),
        .act_data(engine_act_data), .act_req_oc_tile(act_req_oc_tile),
        .act_req_k_tile(act_req_k_tile), .act_req_x(act_req_x), .act_req_y(act_req_y),
        .act_req_pixel_addr(act_req_pixel_addr),
        .act_req_kernel_x(act_req_kernel_x), .act_req_kernel_y(act_req_kernel_y),
        .act_req_channel_block(act_req_channel_block),
        .act_req_in_x(act_req_in_x), .act_req_in_y(act_req_in_y),
        .act_req_word_addr(act_req_word_addr),
        .out_valid(out_valid), .out_pixel_addr(out_pixel_addr),
        .out_oc_base(out_oc_base), .out_channel_mask(out_channel_mask),
        .out_psum(out_psum)
    );

endmodule
