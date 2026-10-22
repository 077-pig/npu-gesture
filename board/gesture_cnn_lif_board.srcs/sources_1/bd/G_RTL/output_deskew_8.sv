`timescale 1ns / 1ps

// 阵列第c列比第0列晚c拍到达。这里为第c列再延迟(7-c)拍，
// 将8列结果对齐到同一个周期。
module output_deskew_8 (
    input  logic                clk,
    input  logic                rst_n,
    input  logic                clear,
    input  logic                stream_valid,
    input  logic signed [255:0] raw_psum_in,
    output logic                out_valid,
    output logic signed [255:0] aligned_psum_out
);

    localparam integer TOTAL_LATENCY = 22; // (16-1) + (8-1)

    logic signed [31:0] delay_line [0:6][1:7];
    logic [TOTAL_LATENCY:0] valid_pipe;
    integer col;
    integer stage;
    integer comb_col;

    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            for (col = 0; col < 7; col = col + 1)
                for (stage = 1; stage <= (7-col); stage = stage + 1)
                    delay_line[col][stage] <= '0;
            valid_pipe <= '0;
        end
        else begin
            for (col = 0; col < 7; col = col + 1) begin
                delay_line[col][1] <= raw_psum_in[col*32 +: 32];
                for (stage = 2; stage <= (7-col); stage = stage + 1)
                    delay_line[col][stage] <= delay_line[col][stage-1];
            end
            valid_pipe <= {valid_pipe[TOTAL_LATENCY-1:0], stream_valid};
        end
    end

    always_comb begin
        aligned_psum_out = '0;
        for (comb_col = 0; comb_col < 7; comb_col = comb_col + 1)
            aligned_psum_out[comb_col*32 +: 32] = delay_line[comb_col][7-comb_col];
        aligned_psum_out[7*32 +: 32] = raw_psum_in[7*32 +: 32];
    end

    assign out_valid = valid_pipe[TOTAL_LATENCY];

endmodule
