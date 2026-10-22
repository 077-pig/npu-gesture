`timescale 1ns/1ps
module tb_conv_tag_pipeline;
    bit tb_passed = 1'b0;
    logic clk=0, rst_n=0, clear=0, in_valid=0, in_first_k=0, in_last_k=0, in_last_pixel=0;
    logic [31:0] in_pixel_addr=0, out_pixel_addr;
    logic [15:0] in_oc_tile=0, out_oc_tile;
    logic [7:0] in_channel_mask=0, out_channel_mask;
    logic out_valid, out_first_k, out_last_k, out_last_pixel;
    always #5 clk=~clk;
    conv_tag_pipeline #(.TAG_STAGES(3)) dut(.*);
    initial begin
        repeat(3) @(negedge clk); rst_n=1;
        @(negedge clk); in_valid=1; in_pixel_addr=32'h12345678; in_oc_tile=9;
        in_first_k=1; in_last_k=0; in_last_pixel=1; in_channel_mask=8'h5a;
        @(negedge clk); in_valid=0;
        wait(out_valid); #1;
        if(out_pixel_addr!==32'h12345678 || out_oc_tile!==9 || !out_first_k ||
           out_last_k || !out_last_pixel || out_channel_mask!==8'h5a)
            $fatal(1,"tag payload mismatch");
        @(negedge clk); clear=1;
        @(negedge clk); clear=0;
        if(out_valid) $fatal(1,"clear failed");
        tb_passed = 1'b1;
        $display("TEST PASS: conv_tag_pipeline"); $finish;
    end
    initial begin #1000; $fatal(1,"TEST TIMEOUT: conv_tag_pipeline"); end
endmodule
