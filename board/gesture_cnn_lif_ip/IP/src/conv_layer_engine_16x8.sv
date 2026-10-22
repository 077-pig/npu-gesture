`timescale 1ns / 1ps

// 将卷积层调度、16x8脉动核心和跨K分块累加连接起来。
// 当前上游仍由测试平台/未来的窗口生成器提供权重列和16元素激活tile。
module conv_layer_engine_16x8 #(
    parameter integer MAX_OUTPUT_PIXELS = 4096,
    parameter integer ADDR_WIDTH = 12
) (
    input  logic                clk,
    input  logic                rst_n,

    input  logic                start,
    input  logic [15:0]         cfg_output_width,
    input  logic [15:0]         cfg_output_height,
    input  logic [31:0]         cfg_output_pixels,
    input  logic [15:0]         cfg_k_tiles,
    input  logic [15:0]         cfg_output_channels,
    input  logic [15:0]         cfg_kernel_width,
    input  logic [15:0]         cfg_kernel_height,
    input  logic [15:0]         cfg_channel_blocks,
    input  logic [15:0]         cfg_stride,
    input  logic [15:0]         cfg_pad_left,
    input  logic [15:0]         cfg_pad_top,
    input  logic signed [31:0]  cfg_window_base_addr,
    input  logic [31:0]         cfg_output_x_step_words,
    input  logic signed [31:0]  cfg_output_row_step_words,
    input  logic signed [31:0]  cfg_kernel_row_step_words,
    output logic                busy,
    output logic                done,
    output logic                config_error,

    output logic                wt_ready,
    input  logic                wt_valid,
    input  logic signed [127:0] wt_data,
    output logic [15:0]         wt_req_oc_tile,
    output logic [15:0]         wt_req_k_tile,
    output logic [2:0]          wt_req_col,

    output logic                act_ready,
    input  logic                act_valid,
    input  logic signed [127:0] act_data,
    output logic [15:0]         act_req_oc_tile,
    output logic [15:0]         act_req_k_tile,
    output logic [15:0]         act_req_x,
    output logic [15:0]         act_req_y,
    output logic [31:0]         act_req_pixel_addr,
    output logic [15:0]         act_req_kernel_x,
    output logic [15:0]         act_req_kernel_y,
    output logic [15:0]         act_req_channel_block,
    output logic signed [16:0]  act_req_in_x,
    output logic signed [16:0]  act_req_in_y,
    output logic signed [31:0]  act_req_word_addr,

    output logic                out_valid,
    output logic [ADDR_WIDTH-1:0] out_pixel_addr,
    output logic [15:0]         out_oc_base,
    output logic [7:0]          out_channel_mask,
    output logic signed [255:0] out_psum
);

    logic core_load_wt_en;
    logic [2:0] core_load_wt_col;
    logic core_swap_wt;
    logic core_frame_start;
    logic core_in_ready;
    logic issue_valid;
    logic issue_first_k;
    logic issue_last_k;
    logic issue_last_pixel;
    logic [7:0] issue_channel_mask;

    logic core_out_valid;
    logic signed [255:0] core_out_psum;

    logic tag_out_valid;
    logic [31:0] tag_pixel_addr;
    logic [15:0] tag_oc_tile;
    logic tag_first_k;
    logic tag_last_k;
    logic tag_last_pixel;
    logic [7:0] tag_channel_mask;
    logic tile_result_done;
    logic accum_last_pixel;
    logic final_output_done;

    conv_layer_controller #(
        .MAX_OUTPUT_PIXELS (MAX_OUTPUT_PIXELS)
    ) u_controller (
        .clk                 (clk),
        .rst_n               (rst_n),
        .start               (start),
        .cfg_output_width    (cfg_output_width),
        .cfg_output_height   (cfg_output_height),
        .cfg_output_pixels   (cfg_output_pixels),
        .cfg_k_tiles         (cfg_k_tiles),
        .cfg_output_channels (cfg_output_channels),
        .cfg_kernel_width    (cfg_kernel_width),
        .cfg_kernel_height   (cfg_kernel_height),
        .cfg_channel_blocks  (cfg_channel_blocks),
        .cfg_stride          (cfg_stride),
        .cfg_pad_left        (cfg_pad_left),
        .cfg_pad_top         (cfg_pad_top),
        .cfg_window_base_addr(cfg_window_base_addr),
        .cfg_output_x_step_words(cfg_output_x_step_words),
        .cfg_output_row_step_words(cfg_output_row_step_words),
        .cfg_kernel_row_step_words(cfg_kernel_row_step_words),
        .busy                (busy),
        .done                (done),
        .config_error        (config_error),
        .wt_ready            (wt_ready),
        .wt_valid            (wt_valid),
        .wt_req_oc_tile      (wt_req_oc_tile),
        .wt_req_k_tile       (wt_req_k_tile),
        .wt_req_col          (wt_req_col),
        .act_ready           (act_ready),
        .act_valid           (act_valid),
        .act_req_oc_tile     (act_req_oc_tile),
        .act_req_k_tile      (act_req_k_tile),
        .act_req_x           (act_req_x),
        .act_req_y           (act_req_y),
        .act_req_pixel_addr  (act_req_pixel_addr),
        .act_req_kernel_x    (act_req_kernel_x),
        .act_req_kernel_y    (act_req_kernel_y),
        .act_req_channel_block(act_req_channel_block),
        .act_req_in_x        (act_req_in_x),
        .act_req_in_y        (act_req_in_y),
        .act_req_word_addr   (act_req_word_addr),
        .core_in_ready       (core_in_ready),
        .core_load_wt_en     (core_load_wt_en),
        .core_load_wt_col    (core_load_wt_col),
        .core_swap_wt        (core_swap_wt),
        .core_frame_start    (core_frame_start),
        .issue_valid         (issue_valid),
        .issue_first_k       (issue_first_k),
        .issue_last_k        (issue_last_k),
        .issue_last_pixel    (issue_last_pixel),
        .issue_channel_mask  (issue_channel_mask),
        .tile_result_done    (tile_result_done),
        .final_output_done   (final_output_done)
    );

    conv_systolic_core_16x8 u_core (
        .clk         (clk),
        .rst_n       (rst_n),
        .load_wt_en  (core_load_wt_en),
        .load_wt_col (core_load_wt_col),
        .load_wt_bus (wt_data),
        .swap_wt     (core_swap_wt),
        .frame_start (core_frame_start),
        .in_valid    (issue_valid),
        .in_act      (act_data),
        .in_ready    (core_in_ready),
        .out_valid   (core_out_valid),
        .out_psum    (core_out_psum)
    );

    conv_tag_pipeline #(.TAG_STAGES(23)) u_tag_pipeline (
        .clk              (clk),
        .rst_n            (rst_n),
        .clear            (core_frame_start),
        .in_valid         (issue_valid),
        .in_pixel_addr    (act_req_pixel_addr),
        .in_oc_tile       (act_req_oc_tile),
        .in_first_k       (issue_first_k),
        .in_last_k        (issue_last_k),
        .in_last_pixel    (issue_last_pixel),
        .in_channel_mask  (issue_channel_mask),
        .out_valid        (tag_out_valid),
        .out_pixel_addr   (tag_pixel_addr),
        .out_oc_tile      (tag_oc_tile),
        .out_first_k      (tag_first_k),
        .out_last_k       (tag_last_k),
        .out_last_pixel   (tag_last_pixel),
        .out_channel_mask (tag_channel_mask)
    );

    assign tile_result_done = core_out_valid && tag_out_valid && tag_last_pixel;
    assign final_output_done = out_valid && accum_last_pixel;

    psum_accum_buffer #(
        .MAX_OUTPUT_PIXELS (MAX_OUTPUT_PIXELS),
        .ADDR_WIDTH        (ADDR_WIDTH)
    ) u_psum_accum (
        .clk              (clk),
        .rst_n            (rst_n),
        .in_valid         (core_out_valid && tag_out_valid),
        .in_pixel_addr    (tag_pixel_addr[ADDR_WIDTH-1:0]),
        .in_oc_tile       (tag_oc_tile),
        .in_first_k       (tag_first_k),
        .in_last_k        (tag_last_k),
        .in_last_pixel    (tag_last_pixel),
        .in_channel_mask  (tag_channel_mask),
        .in_psum          (core_out_psum),
        .out_valid        (out_valid),
        .out_pixel_addr   (out_pixel_addr),
        .out_oc_base      (out_oc_base),
        .out_last_pixel   (accum_last_pixel),
        .out_channel_mask (out_channel_mask),
        .out_psum         (out_psum)
    );

endmodule
