`timescale 1ns / 1ps

module tb_conv_layer_pipeline_16x8;
    bit tb_passed = 1'b0;
    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst_n, start;
    logic feature_wr_en;
    logic [3:0] feature_wr_addr;
    logic signed [127:0] feature_wr_data;
    logic weight_wr_en;
    logic [4:0] weight_wr_addr;
    logic signed [127:0] weight_wr_data;
    logic [15:0] cfg_input_width, cfg_input_height, cfg_channel_blocks;
    logic [15:0] cfg_kernel_width, cfg_kernel_height, cfg_stride;
    logic [15:0] cfg_pad_left, cfg_pad_top;
    logic signed [31:0] cfg_window_base_addr;
    logic [31:0] cfg_output_x_step_words;
    logic signed [31:0] cfg_output_row_step_words, cfg_kernel_row_step_words;
    logic [15:0] cfg_output_width, cfg_output_height;
    logic [31:0] cfg_output_pixels;
    logic [15:0] cfg_k_tiles, cfg_output_channels;
    logic [4:0] cfg_weight_base_addr;
    logic [3:0] cfg_quant_base_addr;
    logic wt_valid, wt_ready;
    logic signed [127:0] wt_data;
    logic [15:0] wt_req_oc_tile, wt_req_k_tile;
    logic [2:0] wt_req_col;
    logic quant_wr_en;
    logic [3:0] quant_wr_addr;
    logic signed [31:0] quant_wr_bias;
    logic signed [15:0] quant_wr_multiplier;
    logic [5:0] quant_wr_shift;
    logic signed [15:0] output_zero_point;
    logic relu_enable;
    logic busy, done, config_error;
    logic out_wr_valid;
    logic [11:0] out_wr_addr;
    logic [127:0] out_wr_data;
    logic [15:0] out_wr_strb;
    logic out_wr_last;
    logic feature_mem_rd_en;
    logic [3:0] feature_mem_rd_addr;
    integer errors;
    integer output_count;
    integer wt_lane;
    integer check_lane;
    integer init_lane;

    conv_layer_pipeline_16x8 #(
        .FEATURE_DEPTH_WORDS(16), .FEATURE_ADDR_WIDTH(4),
        .MAX_OUTPUT_PIXELS(4), .PSUM_ADDR_WIDTH(12),
        .WEIGHT_MAX_OC_TILES(2), .WEIGHT_MAX_K_TILES(1),
        .WEIGHT_ADDR_WIDTH(5), .WEIGHT_DEPTH_WORDS(16),
        .USE_INTERNAL_WEIGHT_BUFFER(1'b0),
        .USE_EXTERNAL_FEATURE_BUFFER(1'b0),
        .MAX_OUTPUT_CHANNELS(16), .MAX_QUANT_PARAMS(16),
        .QUANT_ADDR_WIDTH(4)
    ) dut (
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
        .cfg_weight_base_addr(cfg_weight_base_addr), .cfg_quant_base_addr(cfg_quant_base_addr),
        .wt_valid(wt_valid), .wt_data(wt_data), .wt_ready(wt_ready),
        .wt_req_oc_tile(wt_req_oc_tile), .wt_req_k_tile(wt_req_k_tile),
        .wt_req_col(wt_req_col),
        .quant_wr_en(quant_wr_en), .quant_wr_addr(quant_wr_addr),
        .quant_wr_bias(quant_wr_bias), .quant_wr_multiplier(quant_wr_multiplier),
        .quant_wr_shift(quant_wr_shift), .output_zero_point(output_zero_point),
        .relu_enable(relu_enable),
        .busy(busy), .done(done), .config_error(config_error),
        .out_wr_valid(out_wr_valid), .out_wr_addr(out_wr_addr),
        .out_wr_data(out_wr_data), .out_wr_strb(out_wr_strb),
        .out_wr_last(out_wr_last),
        .feature_mem_rd_en(feature_mem_rd_en),
        .feature_mem_rd_addr(feature_mem_rd_addr),
        .feature_mem_rd_valid(1'b0), .feature_mem_rd_data('0)
    );

    always_comb begin
        wt_valid = wt_ready;
        wt_data = '0;
        for (wt_lane = 0; wt_lane < 16; wt_lane = wt_lane + 1)
            wt_data[wt_lane*8 +: 8] = 8'sd1;
    end

    always @(negedge clk) begin
        if (rst_n && out_wr_valid) begin
            output_count = output_count + 1;
            if (out_wr_addr !== 15'd0)
                errors = errors + 1;
            if (output_count == 1) begin
                if (out_wr_strb !== 16'h00ff || out_wr_last)
                    errors = errors + 1;
                for (check_lane = 0; check_lane < 8; check_lane = check_lane + 1)
                    if (out_wr_data[check_lane*8 +: 8] !== 8'd16)
                        errors = errors + 1;
            end
            else if (output_count == 2) begin
                if (out_wr_strb !== 16'hff00 || !out_wr_last ||
                    out_wr_data[64 +: 8] !== 8'd16 ||
                    out_wr_data[72 +: 8] !== 8'd16 ||
                    out_wr_data[80 +: 48] !== 48'd0)
                    errors = errors + 1;
            end
        end
    end

    initial begin
        rst_n = 1'b0; start = 1'b0;
        feature_wr_en = 1'b0; feature_wr_addr = '0; feature_wr_data = '0;
        weight_wr_en = 1'b0; weight_wr_addr = '0; weight_wr_data = '0;
        cfg_input_width = 16'd1; cfg_input_height = 16'd1;
        cfg_channel_blocks = 16'd1; cfg_kernel_width = 16'd1;
        cfg_kernel_height = 16'd1; cfg_stride = 16'd1;
        cfg_pad_left = 16'd0; cfg_pad_top = 16'd0;
        cfg_window_base_addr = 32'sd0;
        cfg_output_x_step_words = 32'd1;
        cfg_output_row_step_words = 32'sd1;
        cfg_kernel_row_step_words = 32'sd1;
        cfg_output_width = 16'd1; cfg_output_height = 16'd1;
        cfg_output_pixels = 32'd1; cfg_k_tiles = 16'd1;
        cfg_output_channels = 16'd10;
        cfg_weight_base_addr = '0; cfg_quant_base_addr = '0;
        quant_wr_en = 1'b0; quant_wr_addr = '0; quant_wr_bias = '0;
        quant_wr_multiplier = 16'sd1; quant_wr_shift = '0;
        output_zero_point = 16'sd0; relu_enable = 1'b0;
        errors = 0; output_count = 0;

        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        @(negedge clk);
        feature_wr_en = 1'b1;
        feature_wr_addr = 0;
        feature_wr_data = '0;
        for (init_lane = 0; init_lane < 16; init_lane = init_lane + 1)
            feature_wr_data[init_lane*8 +: 8] = 8'sd1;
        @(negedge clk);
        feature_wr_en = 1'b0;

        for (init_lane = 0; init_lane < 16; init_lane = init_lane + 1) begin
            @(negedge clk);
            quant_wr_en = 1'b1;
            quant_wr_addr = init_lane;
            quant_wr_bias = 32'sd0;
            quant_wr_multiplier = 16'sd1;
            quant_wr_shift = 6'd0;
        end
        @(negedge clk);
        quant_wr_en = 1'b0;

        @(negedge clk); start = 1'b1;
        @(negedge clk); start = 1'b0;

        wait(done);
        repeat (3) @(negedge clk);
        if (config_error || output_count != 2 || errors != 0)
            $fatal(1, "TEST FAIL: errors=%0d outputs=%0d", errors, output_count);
        tb_passed = 1'b1;
        $display("TEST PASS: single-layer conv to INT8 HWC16 output");
        $finish;
    end

    initial begin
        #50000;
        $fatal(1, "TEST TIMEOUT: busy=%0b done=%0b outputs=%0d", busy, done, output_count);
    end
endmodule
