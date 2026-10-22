`timescale 1ns / 1ps

module tb_requant_relu_8;
    bit tb_passed = 1'b0;
    logic clk=0, rst_n, in_valid, out_valid, relu_enable;
    logic signed [255:0] in_psum, in_bias;
    logic signed [127:0] in_multiplier;
    logic [47:0] in_shift;
    logic signed [15:0] output_zero_point;
    logic [7:0] channel_mask;
    logic signed [63:0] out_int8;
    integer errors, lane, got;
    integer expected [0:7];

    always #5 clk=~clk;
    requant_relu_8 dut(.*);

    task automatic drive_lane(input integer l, input integer psum,
                              input integer bias, input integer mult,
                              input integer shift);
        begin
            in_psum[l*32 +: 32]=psum;
            in_bias[l*32 +: 32]=bias;
            in_multiplier[l*16 +: 16]=mult;
            in_shift[l*6 +: 6]=shift;
        end
    endtask

    task automatic check_output;
        begin
            wait(out_valid);
            @(negedge clk);
            for(lane=0;lane<8;lane=lane+1) begin
                got=$signed(out_int8[lane*8 +: 8]);
                if(got!==expected[lane]) begin
                    $display("ERROR lane=%0d got=%0d expected=%0d",lane,got,expected[lane]);
                    errors=errors+1;
                end
            end
        end
    endtask

    initial begin
        rst_n=0; in_valid=0; in_psum='0; in_bias='0; in_multiplier='0;
        in_shift='0; output_zero_point=0; relu_enable=0; channel_mask=8'hff; errors=0;
        repeat(3) @(negedge clk); rst_n=1;

        // 基本缩放、bias、正负舍入和上下限饱和。
        drive_lane(0, 100, 28, 1, 1); expected[0]=64;
        drive_lane(1, 101, 0, 1, 1); expected[1]=51;
        drive_lane(2,-101, 0, 1, 1); expected[2]=-51;
        drive_lane(3,1000, 0, 1, 0); expected[3]=127;
        drive_lane(4,-1000,0, 1, 0); expected[4]=-128;
        drive_lane(5, 20,-4, 3, 2); expected[5]=12;
        drive_lane(6,-100, 0, 1, 1); expected[6]=-50;
        drive_lane(7,  -5, 0, 1, 2); expected[7]=-1;
        @(negedge clk); in_valid=1;
        @(negedge clk); in_valid=0;
        check_output();

        // ReLU、zero point和无效通道屏蔽。
        relu_enable=1; output_zero_point=3; channel_mask=8'h7f;
        drive_lane(0,-20,0,1,0); expected[0]=3;
        drive_lane(1, 10,0,1,0); expected[1]=13;
        drive_lane(2,124,0,1,0); expected[2]=127;
        drive_lane(3,125,0,1,0); expected[3]=127;
        drive_lane(4,  0,0,1,0); expected[4]=3;
        drive_lane(5, -2,0,1,0); expected[5]=3;
        drive_lane(6, -4,0,1,0); expected[6]=3;
        drive_lane(7, 55,0,1,0); expected[7]=0;
        @(negedge clk); in_valid=1;
        @(negedge clk); in_valid=0;
        check_output();

        if(errors!=0) $fatal(1,"TEST FAIL: requant errors=%0d",errors);
        tb_passed = 1'b1;
        $display("TEST PASS: 8-lane bias, requant, saturation and ReLU");
        $finish;
    end

    initial begin #2000; $fatal(1,"TEST TIMEOUT: requant_relu_8"); end
endmodule
