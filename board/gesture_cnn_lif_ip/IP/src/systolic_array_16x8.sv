`timescale 1ns / 1ps

// 16行(K维) × 8列(输出通道)的权重驻留脉动阵列。
// 每列的16个权重通过128-bit总线一次装入shadow寄存器，8列共8拍。
module systolic_array_16x8 (
    input  logic                clk,
    input  logic                rst_n,
    input  logic                compute_en,

    input  logic                load_wt_en,
    input  logic [2:0]          load_wt_col,
    input  logic signed [127:0] load_wt_bus,
    input  logic                swap_wt,

    input  logic signed [127:0] skewed_act_in,
    output logic signed [255:0] raw_psum_out
);

    wire signed [7:0]  act_net  [0:15][0:8];
    wire signed [31:0] psum_net [0:16][0:7];

    genvar r;
    genvar c;
    generate
        for (r = 0; r < 16; r = r + 1) begin : INPUT_ROWS
            assign act_net[r][0] = skewed_act_in[r*8 +: 8];
        end

        for (c = 0; c < 8; c = c + 1) begin : INPUT_COLS
            assign psum_net[0][c] = 32'sd0;
            assign raw_psum_out[c*32 +: 32] = psum_net[16][c];
        end

        for (r = 0; r < 16; r = r + 1) begin : ROW
            for (c = 0; c < 8; c = c + 1) begin : COL
                pe_int8_dsp u_pe (
                    .clk            (clk),
                    .rst_n          (rst_n),
                    .compute_en     (compute_en),
                    .load_shadow_wt (load_wt_en && (load_wt_col == c)),
                    .swap_wt        (swap_wt),
                    .in_weight      (load_wt_bus[r*8 +: 8]),
                    .in_act         (act_net[r][c]),
                    .in_psum        (psum_net[r][c]),
                    .out_act        (act_net[r][c+1]),
                    .out_psum       (psum_net[r+1][c])
                );
            end
        end
    endgenerate

endmodule
