`timescale 1ns/1ps
module tb_gesture_cnn_lif_local_top;
    bit tb_passed = 1'b0;
    logic clk=0,rst_n=0,frame_start=0,sequence_start=0,sequence_end=0;
    logic desc_wr_en=0; logic [2:0] desc_wr_index=0; logic [255:0] desc_wr_data=0;
    logic layer_param_wr_en=0; logic [2:0] layer_param_wr_index=0; logic [95:0] layer_param_wr_data=0;
    logic init_wr_en=0,init_wr_bank=0; logic [5:0] init_wr_addr=0; logic [127:0] init_wr_data=0; logic [15:0] init_wr_strb=0;
    logic conv_weight_wr_en=0; logic [5:0] conv_weight_wr_addr=0; logic signed [127:0] conv_weight_wr_data=0;
    logic quant_wr_en=0; logic [5:0] quant_wr_addr=0; logic signed [31:0] quant_wr_bias=0;
    logic signed [15:0] quant_wr_multiplier=0; logic [5:0] quant_wr_shift=0;
    logic fc_weight_wr_en=0; logic [3:0] fc_weight_wr_class=0; logic [2:0] fc_weight_wr_word_addr=0;
    logic [63:0] fc_weight_wr_data=0; logic fc_bias_wr_en=0; logic [3:0] fc_bias_wr_class=0;
    logic signed [31:0] fc_bias_wr_data=0;
    logic busy,frame_done,error,sequence_done,result_valid; logic [3:0] result_class;
    logic [175:0] spike_counts; logic signed [351:0] membrane_values; logic [2:0] active_layer_index;
    always #5 clk=~clk;
    gesture_cnn_lif_local_top #(.FEATURE_DEPTH_WORDS(64),.FEATURE_ADDR_WIDTH(6),
        .WEIGHT_ADDR_WIDTH(6),.WEIGHT_DEPTH_WORDS(64),.QUANT_ADDR_WIDTH(6)) dut(.*);
    initial begin
        repeat(3) @(negedge clk); rst_n=1;
        @(negedge clk); frame_start=1; sequence_start=1;
        @(negedge clk); frame_start=0; sequence_start=0;
        wait(error); @(negedge clk);
        if(active_layer_index!==0 || frame_done || result_valid || sequence_done)
            $fatal(1,"unexpected output on unconfigured descriptor error path");
        tb_passed = 1'b1;
        $display("TEST PASS: gesture_cnn_lif_local_top error propagation"); $finish;
    end
    initial begin #10000; $fatal(1,"TEST TIMEOUT: gesture_cnn_lif_local_top"); end
endmodule
