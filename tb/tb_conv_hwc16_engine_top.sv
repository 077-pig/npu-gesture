`timescale 1ns / 1ps

module tb_conv_hwc16_engine_top;
    bit tb_passed = 1'b0;
    localparam integer IN_W=3, IN_H=3, K_W=3, K_H=3;
    localparam integer OUT_W=3, OUT_H=3, OUT_CHANNELS=10;
    localparam integer NUM_PIXELS=9, K_TILES=9, EXPECTED_RECORDS=18;

    logic clk, rst_n, start, feature_wr_en;
    logic [15:0] feature_wr_addr;
    logic signed [127:0] feature_wr_data;
    logic busy, done, config_error, wt_ready, wt_valid, out_valid;
    logic signed [127:0] wt_data;
    logic [15:0] wt_req_oc_tile, wt_req_k_tile;
    logic [2:0] wt_req_col;
    logic [11:0] out_pixel_addr;
    logic [15:0] out_oc_base;
    logic [7:0] out_channel_mask;
    logic signed [255:0] out_psum;
    logic feature_mem_rd_en;
    logic [15:0] feature_mem_rd_addr;

    integer expected [0:8][0:9];
    integer wr_pixel, wr_lane, wt_lane, check_lane;
    integer oy, ox, ky, kx, iy, ix, oc, pixel, lane;
    integer receive_count, errors, got, expected_value;
    integer expected_oc_tile, expected_pixel;

    function automatic integer feature_value(input integer y, input integer x, input integer l);
        feature_value = (y*IN_W+x) + (l%4) - 5;
    endfunction

    function automatic integer weight_value(input integer o, input integer kt, input integer l);
        weight_value = (o%3) + (kt%3) + (l%3) - 2;
    endfunction

    conv_hwc16_engine_top #(
        .FEATURE_DEPTH_WORDS(64), .FEATURE_ADDR_WIDTH(16),
        .MAX_OUTPUT_PIXELS(16), .PSUM_ADDR_WIDTH(12),
        .USE_INTERNAL_WEIGHT_BUFFER(1'b0)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .feature_wr_en(feature_wr_en), .feature_wr_addr(feature_wr_addr),
        .feature_wr_data(feature_wr_data),
        .weight_wr_en(1'b0), .weight_wr_addr('0), .weight_wr_data('0),
        .start(start),
        .cfg_input_width(16'(IN_W)), .cfg_input_height(16'(IN_H)),
        .cfg_channel_blocks(16'd1),
        .cfg_kernel_width(16'(K_W)), .cfg_kernel_height(16'(K_H)),
        .cfg_stride(16'd1), .cfg_pad_left(16'd1), .cfg_pad_top(16'd1),
        .cfg_window_base_addr(-32'sd4),
        .cfg_output_x_step_words(32'd1),
        .cfg_output_row_step_words(32'sd1),
        .cfg_kernel_row_step_words(32'sd1),
        .cfg_output_width(16'(OUT_W)), .cfg_output_height(16'(OUT_H)),
        .cfg_output_pixels(32'(NUM_PIXELS)), .cfg_k_tiles(16'(K_TILES)),
        .cfg_output_channels(16'(OUT_CHANNELS)),
        .cfg_weight_base_addr(13'd0),
        .busy(busy), .done(done), .config_error(config_error),
        .wt_ready(wt_ready), .wt_valid(wt_valid), .wt_data(wt_data),
        .wt_req_oc_tile(wt_req_oc_tile), .wt_req_k_tile(wt_req_k_tile),
        .wt_req_col(wt_req_col), .out_valid(out_valid),
        .out_pixel_addr(out_pixel_addr), .out_oc_base(out_oc_base),
        .out_channel_mask(out_channel_mask), .out_psum(out_psum),
        .feature_mem_rd_en(feature_mem_rd_en),
        .feature_mem_rd_addr(feature_mem_rd_addr),
        .feature_mem_rd_valid(1'b0), .feature_mem_rd_data('0)
    );

    always #5 clk=~clk;

    always_comb begin
        wt_valid=wt_ready;
        wt_data='0;
        for (wt_lane=0; wt_lane<16; wt_lane=wt_lane+1)
            wt_data[wt_lane*8 +: 8]=weight_value(
                wt_req_oc_tile*8+wt_req_col, wt_req_k_tile, wt_lane);
    end

    always @(negedge clk) begin
        if (rst_n && out_valid) begin
            expected_oc_tile=receive_count/NUM_PIXELS;
            expected_pixel=receive_count%NUM_PIXELS;
            if (out_pixel_addr !== expected_pixel) errors=errors+1;
            if (out_oc_base !== expected_oc_tile*8) errors=errors+1;
            if (out_channel_mask !== ((expected_oc_tile==0)?8'hff:8'h03)) errors=errors+1;
            for (check_lane=0; check_lane<8; check_lane=check_lane+1) begin
                oc=expected_oc_tile*8+check_lane;
                got=$signed(out_psum[check_lane*32 +: 32]);
                expected_value=(oc<OUT_CHANNELS)?expected[expected_pixel][oc]:0;
                if (got !== expected_value) begin
                    $display("ERROR pixel=%0d oc=%0d got=%0d expected=%0d",
                             expected_pixel,oc,got,expected_value);
                    errors=errors+1;
                end
            end
            receive_count=receive_count+1;
        end
    end

    initial begin
        clk=0; rst_n=0; start=0; feature_wr_en=0;
        feature_wr_addr=0; feature_wr_data='0; receive_count=0; errors=0;

        for (oy=0; oy<OUT_H; oy=oy+1)
            for (ox=0; ox<OUT_W; ox=ox+1) begin
                pixel=oy*OUT_W+ox;
                for (oc=0; oc<OUT_CHANNELS; oc=oc+1) begin
                    expected[pixel][oc]=0;
                    for (ky=0; ky<K_H; ky=ky+1)
                        for (kx=0; kx<K_W; kx=kx+1) begin
                            iy=oy+ky-1; ix=ox+kx-1;
                            if ((iy>=0)&&(iy<IN_H)&&(ix>=0)&&(ix<IN_W))
                                for (lane=0; lane<16; lane=lane+1)
                                    expected[pixel][oc]=expected[pixel][oc]+
                                        feature_value(iy,ix,lane)*
                                        weight_value(oc,ky*K_W+kx,lane);
                        end
                end
            end

        repeat(3) @(negedge clk); rst_n=1;
        for (wr_pixel=0; wr_pixel<9; wr_pixel=wr_pixel+1) begin
            @(negedge clk); feature_wr_en=1; feature_wr_addr=wr_pixel; feature_wr_data='0;
            for (wr_lane=0; wr_lane<16; wr_lane=wr_lane+1)
                feature_wr_data[wr_lane*8 +: 8]=
                    feature_value(wr_pixel/IN_W,wr_pixel%IN_W,wr_lane);
        end
        @(negedge clk); feature_wr_en=0; start=1;
        @(negedge clk); start=0;

        wait(receive_count==EXPECTED_RECORDS);
        wait(done);
        if(config_error) errors=errors+1;
        if(errors!=0) $fatal(1,"TEST FAIL: %0d errors",errors);
        tb_passed = 1'b1;
        $display("TEST PASS: HWC16 buffer to 3x3 convolution, 10 output channels");
        $finish;
    end

    initial begin
        #50000;
        $fatal(1,"TEST TIMEOUT outputs=%0d/%0d busy=%0b",receive_count,EXPECTED_RECORDS,busy);
    end
endmodule
