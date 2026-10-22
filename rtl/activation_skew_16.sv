`timescale 1ns / 1ps

// 将一个16元素激活向量变成脉动阵列需要的梯形波前：
// lane0延迟0拍，lane1延迟1拍，...，lane15延迟15拍。
module activation_skew_16 (
    input  logic                clk,
    input  logic                rst_n,
    input  logic                clear,          //清空延迟线
    input  logic                in_valid,       //当前输入是否有效
    input  logic signed [127:0] in_act,
    output logic signed [127:0] skewed_act      //错开后的输入
);

    logic signed [7:0] delay_line [1:15][1:15];
    integer lane;
    integer stage;
    integer comb_lane;

    always_ff @(posedge clk) begin
        if(!rst_n || clear) begin
            for(lane = 1; lane < 16; lane = lane + 1)
                for(stage = 1; stage <= lane; stage = stage + 1)
                   delay_line[lane][stage] <= '0;
        end
        else begin
            for(lane = 1; lane < 16; lane = lane + 1) begin
                delay_line[lane][1] <= in_valid ? in_act[lane*8 +: 8] : 8'sd0;
                for(stage = 2; stage <= lane; stage = stage + 1)
                   delay_line[lane][stage] <= delay_line[lane][stage-1];
            end
        end
    end

    always_comb begin
        skewed_act = '0;
        skewed_act[7:0] = in_valid ? in_act[7:0] : 8'sd0;
        for(comb_lane = 1; comb_lane < 16; comb_lane = comb_lane + 1)
           skewed_act[comb_lane*8 +: 8] = delay_line[comb_lane][comb_lane];
    end

endmodule
