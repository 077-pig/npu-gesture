`timescale 1ns / 1ps

module tb_npu_three_layer_local_top;
    bit tb_passed = 1'b0;
    localparam integer FEATURE_ADDR_WIDTH = 4;
    localparam integer WEIGHT_ADDR_WIDTH = 5;
    localparam integer MAX_OUTPUT_CHANNELS = 16;
    localparam integer MAX_QUANT_PARAMS = 64;
    localparam integer QUANT_ADDR_WIDTH = 6;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst_n, start;
    logic [3:0] layer_count;
    logic gap_start;
    logic [15:0] gap_width, gap_height, gap_channel_blocks;
    logic desc_wr_en;
    logic [2:0] desc_wr_index;
    logic [255:0] desc_wr_data;
    logic layer_param_wr_en; logic [2:0] layer_param_wr_index; logic [95:0] layer_param_wr_data;
    logic init_wr_en, init_wr_bank;
    logic [FEATURE_ADDR_WIDTH-1:0] init_wr_addr;
    logic [127:0] init_wr_data;
    logic [15:0] init_wr_strb;
    logic weight_wr_en;
    logic [WEIGHT_ADDR_WIDTH-1:0] weight_wr_addr;
    logic signed [127:0] weight_wr_data;
    logic quant_wr_en;
    logic [QUANT_ADDR_WIDTH-1:0] quant_wr_addr;
    logic signed [31:0] quant_wr_bias;
    logic signed [15:0] quant_wr_multiplier;
    logic [5:0] quant_wr_shift;
    logic signed [15:0] output_zero_point;
    logic relu_enable;
    logic busy, all_done, error;
    logic [2:0] layer_index;
    logic active_input_bank, active_output_bank;
    logic gap_busy, gap_done, gap_error, gap_out_valid, gap_out_last;
    logic [((MAX_OUTPUT_CHANNELS + 15) / 16 <= 1 ? 1 : $clog2((MAX_OUTPUT_CHANNELS + 15) / 16))-1:0] gap_out_block_index;
    logic [127:0] gap_out_data;
    integer errors;
    integer i;

    npu_three_layer_local_top #(
        .FEATURE_DEPTH_WORDS(16), .FEATURE_ADDR_WIDTH(FEATURE_ADDR_WIDTH),
        .MAX_OUTPUT_PIXELS(1), .PSUM_ADDR_WIDTH(4),
        .WEIGHT_MAX_OC_TILES(2), .WEIGHT_MAX_K_TILES(1),
        .WEIGHT_ADDR_WIDTH(WEIGHT_ADDR_WIDTH), .WEIGHT_DEPTH_WORDS(16),
        .MAX_OUTPUT_CHANNELS(MAX_OUTPUT_CHANNELS),
        .MAX_QUANT_PARAMS(MAX_QUANT_PARAMS), .QUANT_ADDR_WIDTH(QUANT_ADDR_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .layer_count(layer_count),
        .gap_start(gap_start), .gap_width(gap_width), .gap_height(gap_height),
        .gap_channel_blocks(gap_channel_blocks),
        .desc_wr_en(desc_wr_en), .desc_wr_index(desc_wr_index), .desc_wr_data(desc_wr_data),
        .layer_param_wr_en(layer_param_wr_en), .layer_param_wr_index(layer_param_wr_index),
        .layer_param_wr_data(layer_param_wr_data),
        .init_wr_en(init_wr_en), .init_wr_bank(init_wr_bank),
        .init_wr_addr(init_wr_addr), .init_wr_data(init_wr_data), .init_wr_strb(init_wr_strb),
        .weight_wr_en(weight_wr_en), .weight_wr_addr(weight_wr_addr), .weight_wr_data(weight_wr_data),
        .quant_wr_en(quant_wr_en), .quant_wr_addr(quant_wr_addr),
        .quant_wr_bias(quant_wr_bias), .quant_wr_multiplier(quant_wr_multiplier),
        .quant_wr_shift(quant_wr_shift), .output_zero_point(output_zero_point),
        .relu_enable(relu_enable), .busy(busy), .all_done(all_done), .error(error),
        .layer_index(layer_index), .active_input_bank(active_input_bank),
        .active_output_bank(active_output_bank), .gap_busy(gap_busy), .gap_done(gap_done),
        .gap_error(gap_error), .gap_out_valid(gap_out_valid),
        .gap_out_block_index(gap_out_block_index), .gap_out_data(gap_out_data),
        .gap_out_last(gap_out_last)
    );

    task automatic write_weight(input integer addr);
        begin
            @(negedge clk);
            weight_wr_en = 1'b1;
            weight_wr_addr = addr[WEIGHT_ADDR_WIDTH-1:0];
            weight_wr_data = {16{8'sd1}};
            @(negedge clk);
            weight_wr_en = 1'b0;
        end
    endtask

    task automatic write_quant(input integer addr);
        begin
            @(negedge clk);
            quant_wr_en = 1'b1;
            quant_wr_addr = addr[QUANT_ADDR_WIDTH-1:0];
            quant_wr_bias = 32'sd0;
            quant_wr_multiplier = 16'sd1;
            quant_wr_shift = 6'd0;
            @(negedge clk);
            quant_wr_en = 1'b0;
        end
    endtask

    initial begin
        rst_n = 1'b0; start = 1'b0; layer_count = 4'd3;
        gap_start = 1'b0; gap_width = 16'd1; gap_height = 16'd1; gap_channel_blocks = 16'd1;
        desc_wr_en = 1'b0; desc_wr_index = '0; desc_wr_data = '0;
        layer_param_wr_en=1'b0; layer_param_wr_index='0; layer_param_wr_data='0;
        init_wr_en = 1'b0; init_wr_bank = 1'b0; init_wr_addr = '0;
        init_wr_data = '0; init_wr_strb = 16'hffff;
        weight_wr_en = 1'b0; weight_wr_addr = '0; weight_wr_data = '0;
        quant_wr_en = 1'b0; quant_wr_addr = '0; quant_wr_bias = '0;
        quant_wr_multiplier = 16'sd1; quant_wr_shift = '0;
        output_zero_point = 16'sd0; relu_enable = 1'b0; errors = 0;

        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        // 三层描述：每层1x1、1像素、16输入/输出通道。
        // 字段按RTL中的256位格式写入，三层各自使用不同输出步长字段以验证读取。
        for (i = 0; i < 3; i = i + 1) begin
            @(negedge clk);
            desc_wr_en = 1'b1;
            desc_wr_index = i[2:0];
            desc_wr_data = '0;
            desc_wr_data[15:0] = 16'd1;
            desc_wr_data[31:16] = 16'd1;
            desc_wr_data[47:32] = 16'd1;
            desc_wr_data[63:48] = 16'd1;
            desc_wr_data[79:64] = 16'd1;
            desc_wr_data[95:80] = 16'd1;
            desc_wr_data[143:128] = 16'd1;
            desc_wr_data[159:144] = 16'd1;
            desc_wr_data[175:160] = 16'd1;
            desc_wr_data[191:176] = 16'd16;
            desc_wr_data[207:192] = 16'd1;
            desc_wr_data[223:208] = 16'd1;
            desc_wr_data[239:224] = 16'd1;
        end
        @(negedge clk); desc_wr_en = 1'b0;

        for (i = 0; i < 3; i = i + 1) begin
            @(negedge clk); layer_param_wr_en=1'b1; layer_param_wr_index=i;
            layer_param_wr_data='0; layer_param_wr_data[31:0]=0;
            layer_param_wr_data[47:32]=0; layer_param_wr_data[63:48]=0;
            layer_param_wr_data[64]=0;
        end
        @(negedge clk); layer_param_wr_en=1'b0;

        // A[0]中写入16个INT8值1。
        @(negedge clk);
        init_wr_en = 1'b1;
        init_wr_bank = 1'b0;
        init_wr_addr = '0;
        init_wr_data = {16{8'sd1}};
        @(negedge clk);
        init_wr_en = 1'b0;

        // 两个输出tile、每个tile 8列权重，全部为1。
        for (i = 0; i < 16; i = i + 1)
            write_weight(i);
        for (i = 0; i < MAX_OUTPUT_CHANNELS; i = i + 1)
            write_quant(i);

        @(negedge clk); start = 1'b1;
        @(negedge clk); start = 1'b0;
        wait(all_done);
        repeat (2) @(negedge clk);

        if (error || busy || layer_index !== 3'd2 || active_output_bank !== 1'b1)
            errors = errors + 1;
        // 第三层结束后B[0]应含16个饱和到127的INT8结果。
        for (i = 0; i < 8; i = i + 1)
            if (dut.u_feature_ab.mem_b_low[0][i*8 +: 8] !== 8'sd127)
                errors = errors + 1;
        for (i = 0; i < 8; i = i + 1)
            if (dut.u_feature_ab.mem_b_high[0][i*8 +: 8] !== 8'sd127)
                errors = errors + 1;

        // 三层卷积完成后，对最终B bank启动1x1x16 GAP，检查仍在PL内输出。
        @(negedge clk); gap_start = 1'b1;
        @(negedge clk); gap_start = 1'b0;
        wait(gap_done);
        @(negedge clk);
        if (gap_error || gap_busy || !gap_out_last || gap_out_data[7:0] !== 8'd127)
            errors = errors + 1;

        if (errors != 0)
            $fatal(1, "TEST FAIL: errors=%0d layer=%0d bank=%0d", errors, layer_index, active_output_bank);
        tb_passed = 1'b1;
        $display("TEST PASS: 3-layer A/B convolution dataflow");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "TEST TIMEOUT: busy=%0b all_done=%0b layer=%0d", busy, all_done, layer_index);
    end
endmodule
