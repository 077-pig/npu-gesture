`timescale 1ns/1ps
module tb_activation_skew_16;
    bit tb_passed = 1'b0;
    logic clk=0, rst_n=0, clear=0, in_valid=0;
    logic signed [127:0] in_act;
    logic signed [127:0] skewed_act;
    integer i;
    always #5 clk=~clk;
    activation_skew_16 dut(.*);

    initial begin
        in_act='0;
        repeat(3) @(negedge clk); rst_n=1;
        for(i=0;i<16;i=i+1) in_act[i*8 +: 8]=i+1;
        in_valid=1;
        repeat(20) @(posedge clk);
        #1;
        for(i=0;i<16;i=i+1)
            if($signed(skewed_act[i*8 +: 8]) !== i+1)
                $fatal(1,"lane %0d got %0d expected %0d",i,$signed(skewed_act[i*8 +: 8]),i+1);
        @(negedge clk); in_valid=0;
        repeat(16) @(posedge clk); #1;
        if(skewed_act !== 0) $fatal(1,"pipeline did not drain to zero");
        @(negedge clk); clear=1;
        @(negedge clk); clear=0;
        if(skewed_act !== 0) $fatal(1,"clear failed");
        tb_passed = 1'b1;
        $display("TEST PASS: activation_skew_16"); $finish;
    end
    initial begin #2000; $fatal(1,"TEST TIMEOUT: activation_skew_16"); end
endmodule
