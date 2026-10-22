`timescale 1ns / 1ps

// 8路INT32卷积/FC输出后处理，使用4级寄存流水：
//   S1: psum + bias
//   S2: biased * multiplier
//   S3: 舍入 + 算术右移
//   S4: zero-point、ReLU和INT8饱和
// 吞吐率仍为每拍一个8通道tile，延迟增加但可显著缩短组合路径。
module requant_relu_8 (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  in_valid,
    input  logic signed [255:0]   in_psum,
    input  logic signed [255:0]   in_bias,
    input  logic signed [127:0]   in_multiplier,
    input  logic        [47:0]    in_shift,
    input  logic signed [15:0]    output_zero_point,
    input  logic                  relu_enable,
    input  logic        [7:0]     channel_mask,
    output logic                  out_valid,
    output logic signed [63:0]    out_int8
);

    logic                 valid_s1, valid_s2, valid_s3;
    logic signed [32:0]   biased_s1 [0:7];
    logic signed [15:0]   multiplier_s1 [0:7];
    logic        [5:0]    shift_s1 [0:7];
    logic        [7:0]    mask_s1;
    logic signed [15:0]   zero_s1;
    logic                 relu_s1;

    logic signed [48:0]   product_s2 [0:7];
    logic        [5:0]    shift_s2 [0:7];
    logic        [7:0]    mask_s2;
    logic signed [15:0]   zero_s2;
    logic                 relu_s2;

    logic signed [48:0]   shifted_s3 [0:7];
    logic        [7:0]    mask_s3;
    logic signed [15:0]   zero_s3;
    logic                 relu_s3;

    // 各时序进程使用独立循环变量，兼容 Vivado Simulator 2018.3
    // 对 always_ff 单一驱动的严格检查；不改变综合出的数据通路。
    integer i_s1, i_s2, i_s3, i_s4;

    // 不能直接使用“49位数据 >>> 运行时shift”再配合“1 <<< shift”做舍入。
    // Vivado 2018.3会把那种写法展开成非常大的动态移位网络。
    // 这里把移位量展开成常量case；每个分支中的移位量是编译期常量，
    // 综合器不会生成运行时桶形移位器。
    function automatic logic signed [48:0] rounded_shift_right_49(
        input  logic signed [48:0]    value,
        input  logic        [5:0]     shift_amount
    );
        begin
            case (shift_amount)
                 0: rounded_shift_right_49 = value;
                 1: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd0) >>> 1)
                        : ((value + 49'sd1) >>> 1);
                 2: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd1) >>> 2)
                        : ((value + 49'sd2) >>> 2);
                 3: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd3) >>> 3)
                        : ((value + 49'sd4) >>> 3);
                 4: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd7) >>> 4)
                        : ((value + 49'sd8) >>> 4);
                 5: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd15) >>> 5)
                        : ((value + 49'sd16) >>> 5);
                 6: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd31) >>> 6)
                        : ((value + 49'sd32) >>> 6);
                 7: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd63) >>> 7)
                        : ((value + 49'sd64) >>> 7);
                 8: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd127) >>> 8)
                        : ((value + 49'sd128) >>> 8);
                 9: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd255) >>> 9)
                        : ((value + 49'sd256) >>> 9);
                10: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd511) >>> 10)
                        : ((value + 49'sd512) >>> 10);
                11: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd1023) >>> 11)
                        : ((value + 49'sd1024) >>> 11);
                12: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd2047) >>> 12)
                        : ((value + 49'sd2048) >>> 12);
                13: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd4095) >>> 13)
                        : ((value + 49'sd4096) >>> 13);
                14: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd8191) >>> 14)
                        : ((value + 49'sd8192) >>> 14);
                15: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd16383) >>> 15)
                        : ((value + 49'sd16384) >>> 15);
                16: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd32767) >>> 16)
                        : ((value + 49'sd32768) >>> 16);
                17: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd65535) >>> 17)
                        : ((value + 49'sd65536) >>> 17);
                18: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd131071) >>> 18)
                        : ((value + 49'sd131072) >>> 18);
                19: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd262143) >>> 19)
                        : ((value + 49'sd262144) >>> 19);
                20: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd524287) >>> 20)
                        : ((value + 49'sd524288) >>> 20);
                21: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd1048575) >>> 21)
                        : ((value + 49'sd1048576) >>> 21);
                22: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd2097151) >>> 22)
                        : ((value + 49'sd2097152) >>> 22);
                23: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd4194303) >>> 23)
                        : ((value + 49'sd4194304) >>> 23);
                24: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd8388607) >>> 24)
                        : ((value + 49'sd8388608) >>> 24);
                25: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd16777215) >>> 25)
                        : ((value + 49'sd16777216) >>> 25);
                26: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd33554431) >>> 26)
                        : ((value + 49'sd33554432) >>> 26);
                27: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd67108863) >>> 27)
                        : ((value + 49'sd67108864) >>> 27);
                28: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd134217727) >>> 28)
                        : ((value + 49'sd134217728) >>> 28);
                29: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd268435455) >>> 29)
                        : ((value + 49'sd268435456) >>> 29);
                30: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd536870911) >>> 30)
                        : ((value + 49'sd536870912) >>> 30);
                31: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd1073741823) >>> 31)
                        : ((value + 49'sd1073741824) >>> 31);
                32: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd2147483647) >>> 32)
                        : ((value + 49'sd2147483648) >>> 32);
                33: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd4294967295) >>> 33)
                        : ((value + 49'sd4294967296) >>> 33);
                34: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd8589934591) >>> 34)
                        : ((value + 49'sd8589934592) >>> 34);
                35: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd17179869183) >>> 35)
                        : ((value + 49'sd17179869184) >>> 35);
                36: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd34359738367) >>> 36)
                        : ((value + 49'sd34359738368) >>> 36);
                37: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd68719476735) >>> 37)
                        : ((value + 49'sd68719476736) >>> 37);
                38: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd137438953471) >>> 38)
                        : ((value + 49'sd137438953472) >>> 38);
                39: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd274877906943) >>> 39)
                        : ((value + 49'sd274877906944) >>> 39);
                40: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd549755813887) >>> 40)
                        : ((value + 49'sd549755813888) >>> 40);
                41: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd1099511627775) >>> 41)
                        : ((value + 49'sd1099511627776) >>> 41);
                42: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd2199023255551) >>> 42)
                        : ((value + 49'sd2199023255552) >>> 42);
                43: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd4398046511103) >>> 43)
                        : ((value + 49'sd4398046511104) >>> 43);
                44: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd8796093022207) >>> 44)
                        : ((value + 49'sd8796093022208) >>> 44);
                45: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd17592186044415) >>> 45)
                        : ((value + 49'sd17592186044416) >>> 45);
                46: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd35184372088831) >>> 46)
                        : ((value + 49'sd35184372088832) >>> 46);
                47: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd70368744177663) >>> 47)
                        : ((value + 49'sd70368744177664) >>> 47);
                48: rounded_shift_right_49 = value[48]
                        ? ((value + 49'sd140737488355327) >>> 48)
                        : ((value + 49'sd140737488355328) >>> 48);
                default: rounded_shift_right_49 = value[48] ? -49'sd1 : 49'sd0;
            endcase
        end
    endfunction

    function automatic logic signed [7:0] saturate_relu_int8(
        input  logic signed [48:0]    shifted_value,
        input  logic signed [15:0]    zero_point,
        input  logic                  relu_en,
        input  logic                  lane_enable
    );
        logic signed [49:0]   zero_added_value;
        begin
            zero_added_value = shifted_value + zero_point;
            if (!lane_enable)
                saturate_relu_int8 = 8'sd0;
            else if (relu_en && (shifted_value < 0)) begin
                if (zero_point > 127)
                    saturate_relu_int8 = 8'sd127;
                else if (zero_point < -128)
                    saturate_relu_int8 = -8'sd128;
                else
                    saturate_relu_int8 = zero_point[7:0];
            end
            else if (zero_added_value > 127)
                saturate_relu_int8 = 8'sd127;
            else if (zero_added_value < -128)
                saturate_relu_int8 = -8'sd128;
            else
                saturate_relu_int8 = zero_added_value[7:0];
        end
    endfunction

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            valid_s1 <= 1'b0;
            mask_s1  <= '0;
            zero_s1  <= '0;
            relu_s1  <= 1'b0;

            for (i_s1 = 0; i_s1 < 8; i_s1 = i_s1 + 1) begin
                biased_s1[i_s1]     <= '0;
                multiplier_s1[i_s1] <= '0;
                shift_s1[i_s1]      <= '0;
            end
        end
        else begin
            valid_s1 <= in_valid;
            mask_s1  <= channel_mask;
            zero_s1  <= output_zero_point;
            relu_s1  <= relu_enable;

            for (i_s1 = 0; i_s1 < 8; i_s1 = i_s1 + 1) begin
                biased_s1[i_s1]     <=
                    $signed(in_psum[i_s1 * 32 +: 32]) +
                    $signed(in_bias[i_s1 * 32 +: 32]);
                multiplier_s1[i_s1] <= in_multiplier[i_s1 * 16 +: 16];
                shift_s1[i_s1]      <= in_shift[i_s1 * 6 +: 6];
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            valid_s2 <= 1'b0;
            mask_s2  <= '0;
            zero_s2  <= '0;
            relu_s2  <= 1'b0;

            for (i_s2 = 0; i_s2 < 8; i_s2 = i_s2 + 1) begin
                product_s2[i_s2] <= '0;
                shift_s2[i_s2]   <= '0;
            end
        end
        else begin
            valid_s2 <= valid_s1;
            mask_s2  <= mask_s1;
            zero_s2  <= zero_s1;
            relu_s2  <= relu_s1;

            for (i_s2 = 0; i_s2 < 8; i_s2 = i_s2 + 1) begin
                product_s2[i_s2] <= biased_s1[i_s2] * multiplier_s1[i_s2];
                shift_s2[i_s2]   <= shift_s1[i_s2];
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            valid_s3 <= 1'b0;
            mask_s3  <= '0;
            zero_s3  <= '0;
            relu_s3  <= 1'b0;

            for (i_s3 = 0; i_s3 < 8; i_s3 = i_s3 + 1)
                shifted_s3[i_s3] <= '0;
        end
        else begin
            valid_s3 <= valid_s2;
            mask_s3  <= mask_s2;
            zero_s3  <= zero_s2;
            relu_s3  <= relu_s2;

            for (i_s3 = 0; i_s3 < 8; i_s3 = i_s3 + 1)
                shifted_s3[i_s3] <= rounded_shift_right_49(
                    product_s2[i_s3],
                    shift_s2[i_s3]
                );
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            out_int8  <= '0;
        end
        else begin
            out_valid <= valid_s3;

            for (i_s4 = 0; i_s4 < 8; i_s4 = i_s4 + 1)
                out_int8[i_s4 * 8 +: 8] <= saturate_relu_int8(
                    shifted_s3[i_s4],
                    zero_s3,
                    relu_s3,
                    mask_s3[i_s4]
                );
        end
    end

endmodule
