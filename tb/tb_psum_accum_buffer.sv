`timescale 1ns/1ps
module tb_psum_accum_buffer;
    bit tb_passed = 1'b0;
    logic clk=0,rst_n=0,in_valid=0,in_first_k=0,in_last_k=0,in_last_pixel=0;
    logic [3:0] in_pixel_addr=0,out_pixel_addr;
    logic [15:0] in_oc_tile=0,out_oc_base;
    logic [7:0] in_channel_mask=8'hff,out_channel_mask;
    logic signed [255:0] in_psum=0,out_psum;
    logic out_valid,out_last_pixel;
    integer i;
    always #5 clk=~clk;
    psum_accum_buffer #(.MAX_OUTPUT_PIXELS(16),.ADDR_WIDTH(4)) dut(.*);
    task send(input logic first_k,input logic last_k,input integer base);
        begin
            @(negedge clk); in_valid=1; in_first_k=first_k; in_last_k=last_k;
            for(i=0;i<8;i=i+1) in_psum[i*32 +: 32]=base+i;
            @(negedge clk); in_valid=0; in_first_k=0; in_last_k=0;
        end
    endtask
    initial begin
        repeat(3) @(negedge clk); rst_n=1;
        in_pixel_addr=3; in_oc_tile=2; in_last_pixel=1;
        send(1,0,10); repeat(2) @(negedge clk); send(0,1,1);
        wait(out_valid); #1;
        if(out_pixel_addr!==3 || out_oc_base!==16 || !out_last_pixel || out_channel_mask!==8'hff)
            $fatal(1,"output metadata mismatch");
        for(i=0;i<8;i=i+1)
            if($signed(out_psum[i*32 +: 32]) !== 11+2*i)
                $fatal(1,"lane %0d accumulation mismatch got=%0d",i,$signed(out_psum[i*32 +: 32]));
        tb_passed = 1'b1;
        $display("TEST PASS: psum_accum_buffer"); $finish;
    end
    initial begin #3000; $fatal(1,"TEST TIMEOUT: psum_accum_buffer"); end
endmodule
