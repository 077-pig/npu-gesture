`timescale 1ns/1ps
module tb_pe_int8_dsp;
    bit tb_passed = 1'b0;
    logic clk=0, rst_n=0, compute_en=0, load_shadow_wt=0, swap_wt=0;
    logic signed [7:0] in_weight=0, in_act=0, out_act;
    logic signed [31:0] in_psum=0, out_psum;
    always #5 clk=~clk;
    pe_int8_dsp dut(.*);
    initial begin
        repeat(3) @(negedge clk); rst_n=1;
        @(negedge clk); in_weight=3; load_shadow_wt=1;
        @(negedge clk); load_shadow_wt=0; swap_wt=1;
        @(negedge clk); swap_wt=0; in_act=-4; in_psum=10; compute_en=1;
        @(negedge clk); compute_en=0;
        if(out_act !== -4 || out_psum !== -2)
            $fatal(1,"MAC mismatch act=%0d psum=%0d",out_act,out_psum);
        repeat(2) @(negedge clk);
        if(out_psum !== -2) $fatal(1,"compute_en hold failed");
        rst_n=0; @(negedge clk);
        if(out_act !== 0 || out_psum !== 0) $fatal(1,"reset failed");
        tb_passed = 1'b1;
        $display("TEST PASS: pe_int8_dsp"); $finish;
    end
    initial begin #1000; $fatal(1,"TEST TIMEOUT: pe_int8_dsp"); end
endmodule
