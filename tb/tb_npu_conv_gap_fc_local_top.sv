`timescale 1ns / 1ps

module tb_npu_conv_gap_fc_local_top;
    bit tb_passed = 1'b0;
    localparam integer FEATURE_ADDR_WIDTH = 4;
    localparam integer WEIGHT_ADDR_WIDTH = 5;
    localparam integer MAX_OUTPUT_CHANNELS = 16;
    localparam integer FC_MAX_INPUT_LENGTH = 32;
    localparam integer FC_MAX_CLASSES = 16;
    localparam integer FC_INPUT_ADDR_WIDTH = 2;
    localparam integer FC_CLASS_ADDR_WIDTH = 4;
    localparam integer MAX_QUANT_PARAMS = 64;
    localparam integer QUANT_ADDR_WIDTH = 6;

    logic clk = 0; always #5 clk = ~clk;
    logic rst_n, start;
    logic [3:0] layer_count;
    logic desc_wr_en; logic [2:0] desc_wr_index; logic [255:0] desc_wr_data;
    logic layer_param_wr_en; logic [2:0] layer_param_wr_index; logic [95:0] layer_param_wr_data;
    logic init_wr_en, init_wr_bank; logic [FEATURE_ADDR_WIDTH-1:0] init_wr_addr;
    logic [127:0] init_wr_data; logic [15:0] init_wr_strb;
    logic conv_weight_wr_en; logic [WEIGHT_ADDR_WIDTH-1:0] conv_weight_wr_addr;
    logic signed [127:0] conv_weight_wr_data;
    logic quant_wr_en; logic [QUANT_ADDR_WIDTH-1:0] quant_wr_addr;
    logic signed [31:0] quant_wr_bias; logic signed [15:0] quant_wr_multiplier;
    logic [5:0] quant_wr_shift; logic signed [15:0] output_zero_point; logic relu_enable;
    logic [15:0] final_output_width, final_output_height, final_output_channels;
    logic fc_weight_wr_en; logic [FC_CLASS_ADDR_WIDTH-1:0] fc_weight_wr_class;
    logic [FC_INPUT_ADDR_WIDTH-1:0] fc_weight_wr_word_addr; logic [63:0] fc_weight_wr_data;
    logic fc_bias_wr_en; logic [FC_CLASS_ADDR_WIDTH-1:0] fc_bias_wr_class;
    logic signed [31:0] fc_bias_wr_data; logic [15:0] fc_class_count;
    logic busy, done, error, result_valid;
    logic [FC_CLASS_ADDR_WIDTH-1:0] result_class;
    logic signed [39:0] result_score;
    logic fc_class_score_valid;
    logic [FC_CLASS_ADDR_WIDTH-1:0] fc_class_score_index;
    logic signed [39:0] fc_class_score;
    logic [2:0] active_layer_index;
    integer i, errors;

    npu_conv_gap_fc_local_top #(
        .FEATURE_DEPTH_WORDS(16), .FEATURE_ADDR_WIDTH(FEATURE_ADDR_WIDTH),
        .MAX_OUTPUT_PIXELS(1), .PSUM_ADDR_WIDTH(4),
        .WEIGHT_MAX_OC_TILES(2), .WEIGHT_MAX_K_TILES(1),
        .WEIGHT_ADDR_WIDTH(WEIGHT_ADDR_WIDTH), .WEIGHT_DEPTH_WORDS(16),
        .MAX_OUTPUT_CHANNELS(MAX_OUTPUT_CHANNELS),
        .MAX_QUANT_PARAMS(MAX_QUANT_PARAMS), .QUANT_ADDR_WIDTH(QUANT_ADDR_WIDTH),
        .FC_MAX_INPUT_LENGTH(FC_MAX_INPUT_LENGTH), .FC_MAX_CLASSES(FC_MAX_CLASSES)
    ) dut (.*);

    function automatic [63:0] pack_byte(input integer value);
        integer k;
        begin
            for (k=0; k<8; k=k+1) pack_byte[k*8 +: 8] = value[7:0];
        end
    endfunction

    task automatic write_conv_weight(input integer addr);
        begin
            @(negedge clk); conv_weight_wr_en=1; conv_weight_wr_addr=addr;
            conv_weight_wr_data={16{8'sd1}};
            @(negedge clk); conv_weight_wr_en=0;
        end
    endtask
    task automatic write_quant(input integer addr);
        begin
            @(negedge clk); quant_wr_en=1; quant_wr_addr=addr;
            quant_wr_bias=0; quant_wr_multiplier=1; quant_wr_shift=0;
            @(negedge clk); quant_wr_en=0;
        end
    endtask
    task automatic write_fc_weight(input integer cls, input integer word_addr, input integer value);
        begin
            @(negedge clk); fc_weight_wr_en=1; fc_weight_wr_class=cls;
            fc_weight_wr_word_addr=word_addr; fc_weight_wr_data=pack_byte(value);
            @(negedge clk); fc_weight_wr_en=0;
        end
    endtask
    task automatic write_fc_bias(input integer cls, input integer value);
        begin
            @(negedge clk); fc_bias_wr_en=1; fc_bias_wr_class=cls; fc_bias_wr_data=value;
            @(negedge clk); fc_bias_wr_en=0;
        end
    endtask

    initial begin
        rst_n=0; start=0; layer_count=3; errors=0;
        desc_wr_en=0; desc_wr_index=0; desc_wr_data=0;
        layer_param_wr_en=0; layer_param_wr_index=0; layer_param_wr_data=0;
        init_wr_en=0; init_wr_bank=0; init_wr_addr=0; init_wr_data=0; init_wr_strb=16'hffff;
        conv_weight_wr_en=0; conv_weight_wr_addr=0; conv_weight_wr_data=0;
        quant_wr_en=0; quant_wr_addr=0; quant_wr_bias=0; quant_wr_multiplier=1; quant_wr_shift=0;
        output_zero_point=0; relu_enable=0;
        final_output_width=1; final_output_height=1; final_output_channels=16;
        fc_weight_wr_en=0; fc_weight_wr_class=0; fc_weight_wr_word_addr=0; fc_weight_wr_data=0;
        fc_bias_wr_en=0; fc_bias_wr_class=0; fc_bias_wr_data=0; fc_class_count=5;
        repeat(3) @(negedge clk); rst_n=1;

        for (i=0; i<3; i=i+1) begin
            @(negedge clk); desc_wr_en=1; desc_wr_index=i; desc_wr_data=0;
            desc_wr_data[15:0]=1; desc_wr_data[31:16]=1; desc_wr_data[47:32]=1;
            desc_wr_data[63:48]=1; desc_wr_data[79:64]=1; desc_wr_data[95:80]=1;
            desc_wr_data[143:128]=1; desc_wr_data[159:144]=1;
            desc_wr_data[175:160]=1; desc_wr_data[191:176]=16;
            desc_wr_data[207:192]=1; desc_wr_data[223:208]=1; desc_wr_data[239:224]=1;
        end
        @(negedge clk); desc_wr_en=0;
        for(i=0;i<3;i=i+1) begin
            @(negedge clk); layer_param_wr_en=1; layer_param_wr_index=i;
            layer_param_wr_data=0;
        end
        @(negedge clk); layer_param_wr_en=0;

        @(negedge clk); init_wr_en=1; init_wr_data={16{8'sd1}};
        @(negedge clk); init_wr_en=0;
        for(i=0;i<16;i=i+1) write_conv_weight(i);
        for(i=0;i<16;i=i+1) write_quant(i);

        // 三层卷积最终16个特征均为127。5类权重分别为1..5，class4最大。
        for(i=0;i<5;i=i+1) begin
            write_fc_weight(i,0,i+1); write_fc_weight(i,1,i+1); write_fc_bias(i,0);
        end

        @(negedge clk); start=1;
        @(negedge clk); start=0;
        wait(done);
        // done/result_valid均为时钟沿更新信号，在下降沿采样，避免TB与NBA更新竞争。
        @(negedge clk);
        if(error || !result_valid || result_class!==4 || result_score!==40'sd10160) begin
            $display("ERROR result class=%0d score=%0d valid=%0b err=%0b",result_class,result_score,result_valid,error);
            errors=errors+1;
        end
        if(errors!=0) $fatal(1,"TEST FAIL: end-to-end errors=%0d",errors);
        tb_passed = 1'b1;
        $display("TEST PASS: 3-layer convolution -> GAP -> FC -> argmax");
        $finish;
    end

    initial begin #200000; $fatal(1,"TEST TIMEOUT: npu_conv_gap_fc_local_top"); end
endmodule
