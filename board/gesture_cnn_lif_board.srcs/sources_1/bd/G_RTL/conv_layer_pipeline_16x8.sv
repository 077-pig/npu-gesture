`timescale 1ns / 1ps

// 单层16x8卷积流水线：
//   HWC16卷积顶层 -> bias/量化/ReLU -> HWC16输出打包。
// 该模块仍使用本地特征/权重写口和本地输出写口，暂不包含AXI。
module conv_layer_pipeline_16x8 #(
    parameter integer FEATURE_DEPTH_WORDS = 4096,
    parameter integer FEATURE_ADDR_WIDTH  = 12,
    parameter integer MAX_OUTPUT_PIXELS   = 4096,
    parameter integer PSUM_ADDR_WIDTH     = 12,
    parameter integer WEIGHT_MAX_OC_TILES = 16,
    parameter integer WEIGHT_MAX_K_TILES  = 64,
    parameter integer WEIGHT_ADDR_WIDTH   = 13,
    parameter integer WEIGHT_DEPTH_WORDS  = WEIGHT_MAX_OC_TILES * WEIGHT_MAX_K_TILES * 8,
    parameter bit     USE_INTERNAL_WEIGHT_BUFFER = 1'b1,
    parameter bit     USE_EXTERNAL_FEATURE_BUFFER = 1'b0,
    parameter integer MAX_OUTPUT_CHANNELS = WEIGHT_MAX_OC_TILES * 8,
    parameter integer MAX_QUANT_PARAMS = 1024,
    parameter integer QUANT_ADDR_WIDTH = (MAX_QUANT_PARAMS <= 1) ? 1 : $clog2(MAX_QUANT_PARAMS),
    parameter integer QUANT_BANK_DEPTH = (MAX_QUANT_PARAMS + 7) / 8,
    parameter integer QUANT_BANK_ADDR_WIDTH =
        (QUANT_BANK_DEPTH <= 1) ? 1 : $clog2(QUANT_BANK_DEPTH),
    parameter integer OC_ADDR_WIDTH = (MAX_OUTPUT_CHANNELS <= 1) ? 1 : $clog2(MAX_OUTPUT_CHANNELS)
) (
    input  logic                         clk,
    input  logic                         rst_n,

    input  logic                         feature_wr_en,
    input  logic [FEATURE_ADDR_WIDTH-1:0] feature_wr_addr,
    input  logic signed [127:0]           feature_wr_data,

    input  logic                         weight_wr_en,
    input  logic [WEIGHT_ADDR_WIDTH-1:0] weight_wr_addr,
    input  logic signed [127:0]           weight_wr_data,

    input  logic                         start,
    input  logic [15:0]                   cfg_input_width,
    input  logic [15:0]                   cfg_input_height,
    input  logic [15:0]                   cfg_channel_blocks,
    input  logic [15:0]                   cfg_kernel_width,
    input  logic [15:0]                   cfg_kernel_height,
    input  logic [15:0]                   cfg_stride,
    input  logic [15:0]                   cfg_pad_left,
    input  logic [15:0]                   cfg_pad_top,
    input  logic signed [31:0]            cfg_window_base_addr,
    input  logic [31:0]                   cfg_output_x_step_words,
    input  logic signed [31:0]            cfg_output_row_step_words,
    input  logic signed [31:0]            cfg_kernel_row_step_words,
    input  logic [15:0]                   cfg_output_width,
    input  logic [15:0]                   cfg_output_height,
    input  logic [31:0]                   cfg_output_pixels,
    input  logic [15:0]                   cfg_k_tiles,
    input  logic [15:0]                   cfg_output_channels,
    input  logic [WEIGHT_ADDR_WIDTH-1:0] cfg_weight_base_addr,
    input  logic [QUANT_ADDR_WIDTH-1:0]  cfg_quant_base_addr,

    input  logic                         wt_valid,
    input  logic signed [127:0]           wt_data,
    output logic                         wt_ready,
    output logic [15:0]                   wt_req_oc_tile,
    output logic [15:0]                   wt_req_k_tile,
    output logic [2:0]                    wt_req_col,

    // 每个输出通道一组量化参数的本地装载口。
    input  logic                         quant_wr_en,
    input  logic [QUANT_ADDR_WIDTH-1:0]  quant_wr_addr,
    input  logic signed [31:0]            quant_wr_bias,
    input  logic signed [15:0]            quant_wr_multiplier,
    input  logic [5:0]                    quant_wr_shift,
    input  logic signed [15:0]            output_zero_point,
    input  logic                         relu_enable,

    output logic                         busy,
    output logic                         done,
    output logic                         config_error,

    output logic                         out_wr_valid,
    output logic [PSUM_ADDR_WIDTH+$clog2((MAX_OUTPUT_CHANNELS + 15) / 16)-1:0]
                                          out_wr_addr,
    output logic [127:0]                 out_wr_data,
    output logic [15:0]                  out_wr_strb,
    output logic                         out_wr_last,

    output logic                         feature_mem_rd_en,
    output logic [FEATURE_ADDR_WIDTH-1:0] feature_mem_rd_addr,
    input  logic                         feature_mem_rd_valid,
    input  logic signed [127:0]          feature_mem_rd_data
);

    logic [255:0] bias_bus;
    logic [127:0] multiplier_bus;
    logic [47:0]  shift_bus;
    // 输出通道以8个为一组工作。把量化参数按通道低3位分成8个bank，
    // 每个bank在每个输出tile只读一个地址，避免从1024项寄存器数组
    // 同时异步读取8项而生成巨型1024:1多路选择器。
    (* ram_style = "distributed" *) logic [53:0] quant_bank0 [0:QUANT_BANK_DEPTH-1];
    (* ram_style = "distributed" *) logic [53:0] quant_bank1 [0:QUANT_BANK_DEPTH-1];
    (* ram_style = "distributed" *) logic [53:0] quant_bank2 [0:QUANT_BANK_DEPTH-1];
    (* ram_style = "distributed" *) logic [53:0] quant_bank3 [0:QUANT_BANK_DEPTH-1];
    (* ram_style = "distributed" *) logic [53:0] quant_bank4 [0:QUANT_BANK_DEPTH-1];
    (* ram_style = "distributed" *) logic [53:0] quant_bank5 [0:QUANT_BANK_DEPTH-1];
    (* ram_style = "distributed" *) logic [53:0] quant_bank6 [0:QUANT_BANK_DEPTH-1];
    (* ram_style = "distributed" *) logic [53:0] quant_bank7 [0:QUANT_BANK_DEPTH-1];
    logic [53:0] quant_lane_word [0:7];
    logic [QUANT_ADDR_WIDTH:0] quant_read_full_addr;
    logic [QUANT_BANK_ADDR_WIDTH-1:0] quant_read_bank_addr;
    logic [QUANT_BANK_ADDR_WIDTH-1:0] quant_write_bank_addr;
    logic [53:0] quant_write_word;
    integer qi;

    logic core_out_valid;
    logic conv_busy;
    logic conv_done;
    logic [PSUM_ADDR_WIDTH-1:0] core_pixel_addr;
    logic [15:0] core_oc_base;
    logic [7:0] core_channel_mask;
    logic signed [255:0] core_psum;
    logic postprocess_pending;
    logic final_write_seen;

    // 对外done必须等到最后一个量化结果真正写出，不能直接使用卷积核心done。
    assign busy = conv_busy || postprocess_pending;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            done                <= 1'b0;
            postprocess_pending <= 1'b0;
            final_write_seen    <= 1'b0;
        end
        else begin
            done <= 1'b0;
            if (start) begin
                postprocess_pending <= 1'b1;
                final_write_seen <= 1'b0;
            end
            if (config_error && conv_done) begin
                postprocess_pending <= 1'b0;
                done <= 1'b1;
            end
            else if (out_wr_valid && out_wr_last) begin
                postprocess_pending <= 1'b0;
                done <= 1'b1;
                final_write_seen <= 1'b1;
            end
        end
    end

    always_comb begin
        quant_read_full_addr = cfg_quant_base_addr + core_oc_base;
        quant_read_bank_addr = quant_read_full_addr[QUANT_ADDR_WIDTH:3];
        quant_write_bank_addr = quant_wr_addr[QUANT_ADDR_WIDTH-1:3];
        quant_write_word = {quant_wr_bias, quant_wr_multiplier, quant_wr_shift};
        quant_lane_word[0] = quant_bank0[quant_read_bank_addr];
        quant_lane_word[1] = quant_bank1[quant_read_bank_addr];
        quant_lane_word[2] = quant_bank2[quant_read_bank_addr];
        quant_lane_word[3] = quant_bank3[quant_read_bank_addr];
        quant_lane_word[4] = quant_bank4[quant_read_bank_addr];
        quant_lane_word[5] = quant_bank5[quant_read_bank_addr];
        quant_lane_word[6] = quant_bank6[quant_read_bank_addr];
        quant_lane_word[7] = quant_bank7[quant_read_bank_addr];

        bias_bus       = '0;
        multiplier_bus = '0;
        shift_bus      = '0;
        for (qi = 0; qi < 8; qi = qi + 1) begin
            if ((cfg_quant_base_addr + core_oc_base + qi) < MAX_QUANT_PARAMS) begin
                bias_bus[qi*32 +: 32]       = quant_lane_word[qi][53:22];
                multiplier_bus[qi*16 +: 16] = quant_lane_word[qi][21:6];
                shift_bus[qi*6 +: 6]        = quant_lane_word[qi][5:0];
            end
        end
    end

    always_ff @(posedge clk) begin
        if (quant_wr_en && (quant_wr_addr < MAX_QUANT_PARAMS)) begin
            case (quant_wr_addr[2:0])
                3'd0: quant_bank0[quant_write_bank_addr] <= quant_write_word;
                3'd1: quant_bank1[quant_write_bank_addr] <= quant_write_word;
                3'd2: quant_bank2[quant_write_bank_addr] <= quant_write_word;
                3'd3: quant_bank3[quant_write_bank_addr] <= quant_write_word;
                3'd4: quant_bank4[quant_write_bank_addr] <= quant_write_word;
                3'd5: quant_bank5[quant_write_bank_addr] <= quant_write_word;
                3'd6: quant_bank6[quant_write_bank_addr] <= quant_write_word;
                3'd7: quant_bank7[quant_write_bank_addr] <= quant_write_word;
            endcase
        end
    end

    conv_hwc16_engine_top #(
        .FEATURE_DEPTH_WORDS(FEATURE_DEPTH_WORDS),
        .FEATURE_ADDR_WIDTH(FEATURE_ADDR_WIDTH),
        .MAX_OUTPUT_PIXELS(MAX_OUTPUT_PIXELS),
        .PSUM_ADDR_WIDTH(PSUM_ADDR_WIDTH),
        .WEIGHT_MAX_OC_TILES(WEIGHT_MAX_OC_TILES),
        .WEIGHT_MAX_K_TILES(WEIGHT_MAX_K_TILES),
        .WEIGHT_ADDR_WIDTH(WEIGHT_ADDR_WIDTH),
        .WEIGHT_DEPTH_WORDS(WEIGHT_DEPTH_WORDS),
        .USE_INTERNAL_WEIGHT_BUFFER(USE_INTERNAL_WEIGHT_BUFFER),
        .USE_EXTERNAL_FEATURE_BUFFER(USE_EXTERNAL_FEATURE_BUFFER)
    ) u_conv (
        .clk(clk), .rst_n(rst_n),
        .feature_wr_en(feature_wr_en), .feature_wr_addr(feature_wr_addr),
        .feature_wr_data(feature_wr_data),
        .weight_wr_en(weight_wr_en), .weight_wr_addr(weight_wr_addr),
        .weight_wr_data(weight_wr_data),
        .start(start),
        .cfg_input_width(cfg_input_width), .cfg_input_height(cfg_input_height),
        .cfg_channel_blocks(cfg_channel_blocks),
        .cfg_kernel_width(cfg_kernel_width), .cfg_kernel_height(cfg_kernel_height),
        .cfg_stride(cfg_stride), .cfg_pad_left(cfg_pad_left), .cfg_pad_top(cfg_pad_top),
        .cfg_window_base_addr(cfg_window_base_addr),
        .cfg_output_x_step_words(cfg_output_x_step_words),
        .cfg_output_row_step_words(cfg_output_row_step_words),
        .cfg_kernel_row_step_words(cfg_kernel_row_step_words),
        .cfg_output_width(cfg_output_width), .cfg_output_height(cfg_output_height),
        .cfg_output_pixels(cfg_output_pixels), .cfg_k_tiles(cfg_k_tiles),
        .cfg_output_channels(cfg_output_channels),
        .cfg_weight_base_addr(cfg_weight_base_addr),
        .busy(conv_busy), .done(conv_done), .config_error(config_error),
        .wt_ready(wt_ready), .wt_valid(wt_valid), .wt_data(wt_data),
        .wt_req_oc_tile(wt_req_oc_tile), .wt_req_k_tile(wt_req_k_tile),
        .wt_req_col(wt_req_col),
        .out_valid(core_out_valid), .out_pixel_addr(core_pixel_addr),
        .out_oc_base(core_oc_base), .out_channel_mask(core_channel_mask),
        .out_psum(core_psum),
        .feature_mem_rd_en(feature_mem_rd_en),
        .feature_mem_rd_addr(feature_mem_rd_addr),
        .feature_mem_rd_valid(feature_mem_rd_valid),
        .feature_mem_rd_data(feature_mem_rd_data)
    );

    conv_output_packer_16x8 #(
        .PIXEL_ADDR_WIDTH(PSUM_ADDR_WIDTH),
        .OUTPUT_WORDS_PER_PIXEL((MAX_OUTPUT_CHANNELS + 15) / 16)
    ) u_output_packer (
        .clk(clk), .rst_n(rst_n),
        .in_valid(core_out_valid), .in_pixel_addr(core_pixel_addr),
        .in_oc_base(core_oc_base), .in_channel_mask(core_channel_mask),
        .in_last_pixel(core_out_valid && (core_pixel_addr == cfg_output_pixels - 1)),
        .in_psum(core_psum), .in_bias(bias_bus),
        .in_multiplier(multiplier_bus), .in_shift(shift_bus),
        .output_zero_point(output_zero_point), .relu_enable(relu_enable),
        .output_channels(cfg_output_channels),
        .output_words_per_pixel((cfg_output_channels + 16'd15) >> 4),
        .out_wr_valid(out_wr_valid), .out_wr_addr(out_wr_addr),
        .out_wr_data(out_wr_data), .out_wr_strb(out_wr_strb),
        .out_wr_last(out_wr_last)
    );
endmodule
