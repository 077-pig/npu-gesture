`timescale 1ns/1ps
module tb_npu_layer_param_table;
    bit tb_passed = 1'b0;
    logic clk=0, rst_n=0, wr_en=0;
    logic [1:0] wr_index=0, rd_index=0;
    logic [95:0] wr_data=0, rd_data;
    always #5 clk=~clk;
    npu_layer_param_table #(.MAX_LAYERS(4),.INDEX_WIDTH(2)) dut(.*);
    initial begin
        repeat(2) @(negedge clk); rst_n=1;
        @(negedge clk); wr_en=1; wr_index=3; wr_data=96'hfeed_beef_1234_5678_abcd_ef01;
        @(negedge clk); wr_en=0; rd_index=3; #1;
        if(rd_data !== 96'hfeed_beef_1234_5678_abcd_ef01) $fatal(1,"parameter write/read mismatch");
        rd_index=0; #1; if(rd_data !== 0) $fatal(1,"parameter entries aliased");
        tb_passed = 1'b1;
        $display("TEST PASS: npu_layer_param_table"); $finish;
    end
    initial begin #1000; $fatal(1,"TEST TIMEOUT: npu_layer_param_table"); end
endmodule
