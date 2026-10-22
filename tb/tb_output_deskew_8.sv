`timescale 1ns/1ps
module tb_output_deskew_8;
    bit tb_passed = 1'b0;
    logic clk=0, rst_n=0, clear=0, stream_valid=0;
    logic signed [255:0] raw_psum_in, aligned_psum_out;
    logic out_valid;
    integer i, seen=0;
    always #5 clk=~clk;
    output_deskew_8 dut(.*);
    initial begin
        raw_psum_in='0;
        for(i=0;i<8;i=i+1) raw_psum_in[i*32 +: 32]=100+i;
        repeat(3) @(negedge clk); rst_n=1; stream_valid=1;
        repeat(30) begin
            @(negedge clk);
            if(out_valid) begin
                seen=seen+1;
                for(i=0;i<8;i=i+1)
                    if($signed(aligned_psum_out[i*32 +: 32]) !== 100+i)
                        $fatal(1,"lane %0d mismatch",i);
            end
        end
        stream_valid=0;
        if(seen==0) $fatal(1,"no valid output observed");
        @(negedge clk); clear=1;
        @(negedge clk); clear=0;
        if(out_valid) $fatal(1,"clear did not remove valid state");
        tb_passed = 1'b1;
        $display("TEST PASS: output_deskew_8"); $finish;
    end
    initial begin #2000; $fatal(1,"TEST TIMEOUT: output_deskew_8"); end
endmodule
