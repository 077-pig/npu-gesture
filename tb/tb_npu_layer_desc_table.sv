`timescale 1ns/1ps
module tb_npu_layer_desc_table;
    bit tb_passed = 1'b0;
    logic clk=0, rst_n=0, wr_en=0;
    logic [1:0] wr_index=0, rd_index=0;
    logic [255:0] wr_data=0, rd_data;
    always #5 clk=~clk;
    npu_layer_desc_table #(.MAX_LAYERS(4),.INDEX_WIDTH(2)) dut(.*);
    initial begin
        repeat(2) @(negedge clk); rst_n=1;
        rd_index=2; #1; if(rd_data !== 0) $fatal(1,"reset content not zero");
        @(negedge clk); wr_en=1; wr_index=2; wr_data=256'h1234;
        @(negedge clk); wr_en=0; rd_index=2; #1;
        if(rd_data !== 256'h1234) $fatal(1,"descriptor write/read mismatch");
        rd_index=1; #1; if(rd_data !== 0) $fatal(1,"descriptor entries aliased");
        tb_passed = 1'b1;
        $display("TEST PASS: npu_layer_desc_table"); $finish;
    end
    initial begin #1000; $fatal(1,"TEST TIMEOUT: npu_layer_desc_table"); end
endmodule
