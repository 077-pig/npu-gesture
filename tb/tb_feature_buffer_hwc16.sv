`timescale 1ns/1ps
module tb_feature_buffer_hwc16;
    bit tb_passed = 1'b0;
    logic clk=0, rst_n=0, wr_en=0, rd_en=0, rd_valid;
    logic [3:0] wr_addr=0, rd_addr=0;
    logic signed [127:0] wr_data=0, rd_data;
    localparam logic [127:0] VALUE=128'h0123456789abcdef_fedcba9876543210;
    always #5 clk=~clk;
    feature_buffer_hwc16 #(.DEPTH_WORDS(16),.ADDR_WIDTH(4)) dut(.*);
    initial begin
        repeat(3) @(negedge clk); rst_n=1;
        @(negedge clk); wr_en=1; wr_addr=5; wr_data=VALUE;
        @(negedge clk); wr_en=0; rd_en=1; rd_addr=5;
        @(negedge clk); rd_en=0;
        if(!rd_valid || rd_data !== VALUE) $fatal(1,"synchronous read mismatch");
        @(negedge clk);
        if(rd_valid) $fatal(1,"rd_valid was not a one-cycle response");
        tb_passed = 1'b1;
        $display("TEST PASS: feature_buffer_hwc16"); $finish;
    end
    initial begin #1000; $fatal(1,"TEST TIMEOUT: feature_buffer_hwc16"); end
endmodule
