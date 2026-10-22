`timescale 1ns/1ps
module tb_lif_output_11;
    bit tb_passed = 1'b0;
    localparam integer N=3,W=16,M=16;
    logic clk=0,rst_n=0,sequence_start=0,current_valid=0,sequence_end=0;
    logic signed [N*W-1:0] in_score=0;
    logic processing_busy,spike_valid,sequence_done,result_valid;
    logic [N-1:0] spikes;
    logic [1:0] result_class;
    logic [N*16-1:0] spike_counts;
    logic signed [N*M-1:0] membrane_values;
    always #5 clk=~clk;
    lif_output_11 #(.CLASS_COUNT(N),.SCORE_WIDTH(W),.MEMBRANE_WIDTH(M),
        .MULTIPLIER(1),.SHIFT(0),.THRESHOLD_Q(5)) dut(.*);
    task send_frame(input integer a,input integer b,input integer c,input logic first,input logic last);
        begin
            @(negedge clk); in_score='0; in_score[0*W +: W]=a; in_score[1*W +: W]=b;
            in_score[2*W +: W]=c; sequence_start=first; sequence_end=last; current_valid=1;
            @(negedge clk); current_valid=0; sequence_start=0; sequence_end=0;
            wait(spike_valid); @(negedge clk);
        end
    endtask
    initial begin
        repeat(3) @(negedge clk); rst_n=1;
        send_frame(6,4,10,1,0);
        if(spikes!==3'b101 || spike_counts[15:0]!==1 || spike_counts[31:16]!==0 ||
           spike_counts[47:32]!==1) $fatal(1,"first LIF frame mismatch");
        send_frame(4,4,0,0,1);
        if(!sequence_done || !result_valid || result_class!==0) $fatal(1,"sequence result mismatch");
        if(spike_counts[15:0]!==1 || spike_counts[31:16]!==1 || spike_counts[47:32]!==1)
            $fatal(1,"final spike counts mismatch");
        if($signed(membrane_values[15:0])!==4 || $signed(membrane_values[31:16])!==1 ||
           $signed(membrane_values[47:32])!==2) $fatal(1,"final membrane mismatch");
        tb_passed = 1'b1;
        $display("TEST PASS: lif_output_11"); $finish;
    end
    initial begin #10000; $fatal(1,"TEST TIMEOUT: lif_output_11"); end
endmodule
