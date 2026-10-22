`timescale 1ns/1ps
module tb_systolic_array_16x8;
    bit tb_passed = 1'b0;
    logic clk=0,rst_n=0,compute_en=0,load_wt_en=0,swap_wt=0;
    logic [2:0] load_wt_col=0;
    logic signed [127:0] load_wt_bus=0,skewed_act_in=0;
    logic signed [255:0] raw_psum_out;
    integer c,k;
    always #5 clk=~clk;
    systolic_array_16x8 dut(.*);
    initial begin
        repeat(3) @(negedge clk); rst_n=1;
        for(c=0;c<8;c=c+1) begin
            @(negedge clk); load_wt_en=1; load_wt_col=c;
            for(k=0;k<16;k=k+1) load_wt_bus[k*8 +: 8]=c+1;
        end
        @(negedge clk); load_wt_en=0; swap_wt=1;
        @(negedge clk); swap_wt=0; compute_en=1;
        for(k=0;k<16;k=k+1) skewed_act_in[k*8 +: 8]=1;
        repeat(30) @(posedge clk); #1;
        for(c=0;c<8;c=c+1)
            if($signed(raw_psum_out[c*32 +: 32]) !== 16*(c+1))
                $fatal(1,"column %0d got %0d expected %0d",c,$signed(raw_psum_out[c*32 +: 32]),16*(c+1));
        tb_passed = 1'b1;
        $display("TEST PASS: systolic_array_16x8"); $finish;
    end
    initial begin #3000; $fatal(1,"TEST TIMEOUT: systolic_array_16x8"); end
endmodule
