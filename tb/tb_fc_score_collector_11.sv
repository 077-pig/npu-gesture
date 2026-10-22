`timescale 1ns/1ps
module tb_fc_score_collector_11;
    bit tb_passed = 1'b0;
    localparam integer N=11, W=40;
    logic clk=0, rst_n=0, clear=0, class_score_valid=0, scores_valid;
    logic [3:0] class_score_index=0;
    logic signed [W-1:0] class_score=0;
    logic signed [N*W-1:0] scores;
    integer i;
    always #5 clk=~clk;
    fc_score_collector_11 dut(.*);
    initial begin
        repeat(3) @(negedge clk); rst_n=1;
        for(i=0;i<N;i=i+1) begin
            @(negedge clk); class_score_valid=1; class_score_index=i; class_score=i*3-5;
        end
        @(negedge clk); class_score_valid=0;
        if(!scores_valid) $fatal(1,"scores_valid missing on final class");
        for(i=0;i<N;i=i+1)
            if($signed(scores[i*W +: W]) !== i*3-5) $fatal(1,"score %0d mismatch",i);
        @(negedge clk); clear=1;
        @(negedge clk); clear=0;
        if(scores !== 0) $fatal(1,"clear failed");
        tb_passed = 1'b1;
        $display("TEST PASS: fc_score_collector_11"); $finish;
    end
    initial begin #2000; $fatal(1,"TEST TIMEOUT: fc_score_collector_11"); end
endmodule
