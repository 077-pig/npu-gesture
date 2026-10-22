`timescale 1ns / 1ps

module tb_conv_output_packer_16x8;
    bit tb_passed = 1'b0;
    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst_n;
    logic in_valid;
    logic [11:0] in_pixel_addr;
    logic [15:0] in_oc_base;
    logic [7:0] in_channel_mask;
    logic in_last_pixel;
    logic signed [255:0] in_psum;
    logic signed [255:0] in_bias;
    logic signed [127:0] in_multiplier;
    logic [47:0] in_shift;
    logic signed [15:0] output_zero_point;
    logic relu_enable;
    logic [15:0] output_channels;
    logic [15:0] output_words_per_pixel;
    logic out_wr_valid;
    logic [12:0] out_wr_addr;
    logic [127:0] out_wr_data;
    logic [15:0] out_wr_strb;
    logic out_wr_last;

    integer errors;
    integer seen;

    conv_output_packer_16x8 #(
        .PIXEL_ADDR_WIDTH(12),
        .OUTPUT_WORDS_PER_PIXEL(2)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_pixel_addr(in_pixel_addr),
        .in_oc_base(in_oc_base), .in_channel_mask(in_channel_mask),
        .in_last_pixel(in_last_pixel), .in_psum(in_psum),
        .in_bias(in_bias), .in_multiplier(in_multiplier),
        .in_shift(in_shift), .output_zero_point(output_zero_point),
        .relu_enable(relu_enable), .output_channels(output_channels),
        .output_words_per_pixel(output_words_per_pixel),
        .out_wr_valid(out_wr_valid), .out_wr_addr(out_wr_addr),
        .out_wr_data(out_wr_data), .out_wr_strb(out_wr_strb), .out_wr_last(out_wr_last)
    );

    task automatic drive_tile(input integer pixel, input integer oc,
                              input integer last_pixel);
        integer lane;
        begin
            @(negedge clk);
            in_valid = 1'b1;
            in_pixel_addr = pixel[11:0];
            in_oc_base = oc[15:0];
            in_channel_mask = (oc == 8) ? 8'h03 : 8'hff;
            in_last_pixel = last_pixel;
            in_psum = '0;
            for (lane = 0; lane < 8; lane = lane + 1)
                in_psum[lane*32 +: 32] = oc + lane + pixel;
            @(negedge clk);
            in_valid = 1'b0;
            in_last_pixel = 1'b0;
        end
    endtask

    always @(negedge clk) begin
        if (rst_n && out_wr_valid) begin
            seen = seen + 1;
            if (seen == 1) begin
                if (out_wr_addr !== 15'd0) errors = errors + 1;
                // pixel0低8通道半字写。
                if (out_wr_data[7:0] !== 8'd0 ||
                    out_wr_data[15:8] !== 8'd1 ||
                    out_wr_data[63:56] !== 8'd7 ||
                    out_wr_strb !== 16'h00ff ||
                    out_wr_last !== 1'b0)
                    errors = errors + 1;
            end
            else if (seen == 2) begin
                if (out_wr_addr !== 15'd0) errors = errors + 1;
                if (out_wr_data[71:64] !== 8'd8 || out_wr_strb !== 16'hff00)
                    errors = errors + 1;
            end
            else if (seen == 3) begin
                if (out_wr_addr !== 15'd1 || out_wr_data[7:0] !== 8'd1 ||
                    out_wr_strb !== 16'h00ff)
                    errors = errors + 1;
            end
            else if (seen == 4) begin
                if (out_wr_addr !== 15'd1 || out_wr_data[71:64] !== 8'd9 ||
                    out_wr_strb !== 16'hff00 || out_wr_last !== 1'b1)
                    errors = errors + 1;
            end
            else if (seen == 5) begin
                if (out_wr_addr !== 15'd2 || out_wr_data[7:0] !== 8'd2 ||
                    out_wr_strb !== 16'h00ff || out_wr_last !== 1'b1)
                    errors = errors + 1;
            end
        end
    end

    initial begin
        rst_n = 1'b0;
        in_valid = 1'b0;
        in_pixel_addr = '0;
        in_oc_base = '0;
        in_channel_mask = '0;
        in_last_pixel = 1'b0;
        in_psum = '0;
        in_bias = '0;
        // multiplier=1，shift=0，输出等于输入低8位；本测试值均在INT8范围内。
        in_multiplier = '0;
        in_shift = '0;
        output_zero_point = 16'sd0;
        relu_enable = 1'b0;
        output_channels = 16'd10; output_words_per_pixel = 16'd1;
        errors = 0;
        seen = 0;
        for (integer lane = 0; lane < 8; lane = lane + 1)
            in_multiplier[lane*16 +: 16] = 16'sd1;

        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        // pixel0的低8和高8通道合并成一个HWC16字。
        drive_tile(0, 0, 1'b0);
        drive_tile(0, 8, 1'b0);
        // pixel1的低8和高8通道合并，最后一个高tile携带last标志。
        drive_tile(1, 0, 1'b0);
        drive_tile(1, 8, 1'b1);
        // 切换到8通道层，验证低半字自动补零的情况。
        @(negedge clk);
        output_channels = 16'd8; output_words_per_pixel = 16'd1;
        drive_tile(2, 0, 1'b1);

        repeat (4) @(negedge clk);
        if (seen != 5) errors = errors + 1;
        if (errors != 0) $fatal(1, "TEST FAIL: errors=%0d outputs=%0d", errors, seen);
        tb_passed = 1'b1;
        $display("TEST PASS: INT8 requant and HWC16 packing");
        $finish;
    end

    initial begin
        #2000;
        $fatal(1, "TEST TIMEOUT: conv_output_packer_16x8");
    end
endmodule
