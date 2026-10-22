`timescale 1ns / 1ps

// 对同一输出像素的多个K分块结果进行INT32累加。
// first_k覆盖旧值，last_k输出最终值，因此每次新任务不需要清空整块存储器。
module psum_accum_buffer #(
    parameter integer MAX_OUTPUT_PIXELS = 4096,
    parameter integer ADDR_WIDTH = 12
) (
    input  logic                clk,
    input  logic                rst_n,

    input  logic                in_valid,
    input  logic [ADDR_WIDTH-1:0] in_pixel_addr,
    input  logic [15:0]         in_oc_tile,
    input  logic                in_first_k,
    input  logic                in_last_k,
    input  logic                in_last_pixel,
    input  logic [7:0]          in_channel_mask,
    input  logic signed [255:0] in_psum,

    output logic                out_valid,
    output logic [ADDR_WIDTH-1:0] out_pixel_addr,
    output logic [15:0]         out_oc_base,
    output logic                out_last_pixel,
    output logic [7:0]          out_channel_mask,
    output logic signed [255:0] out_psum
);

    logic                 stage_valid;
    logic [ADDR_WIDTH-1:0] stage_pixel_addr;
    logic [15:0]          stage_oc_tile;
    logic                 stage_first_k;
    logic                 stage_last_k;
    logic                 stage_last_pixel;
    logic [7:0]           stage_channel_mask;
    logic signed [255:0]  stage_psum;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            out_valid        <= 1'b0;
            out_pixel_addr   <= '0;
            out_oc_base      <= '0;
            out_last_pixel   <= 1'b0;
            out_channel_mask <= '0;
            stage_valid        <= 1'b0;
            stage_pixel_addr   <= '0;
            stage_oc_tile      <= '0;
            stage_first_k      <= 1'b0;
            stage_last_k       <= 1'b0;
            stage_last_pixel   <= 1'b0;
            stage_channel_mask <= '0;
            stage_psum         <= '0;
        end
        else begin
            out_valid <= 1'b0;
            out_last_pixel <= 1'b0;
            stage_valid        <= in_valid;
            stage_pixel_addr   <= in_pixel_addr;
            stage_oc_tile      <= in_oc_tile;
            stage_first_k      <= in_first_k;
            stage_last_k       <= in_last_k;
            stage_last_pixel   <= in_last_pixel;
            stage_channel_mask <= in_channel_mask;
            stage_psum         <= in_psum;

            if (stage_valid && stage_last_k) begin
                out_valid        <= 1'b1;
                out_pixel_addr   <= stage_pixel_addr;
                out_oc_base      <= {stage_oc_tile[12:0], 3'b000};
                out_last_pixel   <= stage_last_pixel;
                out_channel_mask <= stage_channel_mask;
            end
        end
    end

    // 每路32-bit部分和使用一个独立bank，避免Vivado 2018.3把整个
    // 8x4096x32数组视为一个超过工具上限的单变量。
    genvar bank;
    generate
        for (bank = 0; bank < 8; bank = bank + 1) begin : PSUM_BANK
            (* ram_style = "block" *)
            logic signed [31:0] mem [0:MAX_OUTPUT_PIXELS-1];
            logic signed [31:0] read_data;

            always_ff @(posedge clk) begin
                if (!rst_n) begin
                    read_data <= 32'sd0;
                    out_psum[bank*32 +: 32] <= 32'sd0;
                end
                else begin
                    if (in_valid)
                        read_data <= mem[in_pixel_addr];

                    if (stage_valid) begin
                        if (!stage_channel_mask[bank]) begin
                            if (!stage_last_k)
                                mem[stage_pixel_addr] <= 32'sd0;
                            if (stage_last_k)
                                out_psum[bank*32 +: 32] <= 32'sd0;
                        end
                        else if (stage_first_k) begin
                            if (stage_last_k)
                                out_psum[bank*32 +: 32] <=
                                    stage_psum[bank*32 +: 32];
                            else
                                mem[stage_pixel_addr] <=
                                    stage_psum[bank*32 +: 32];
                        end
                        else begin
                            if (stage_last_k)
                                out_psum[bank*32 +: 32] <=
                                    read_data + stage_psum[bank*32 +: 32];
                            else
                                mem[stage_pixel_addr] <=
                                    read_data + stage_psum[bank*32 +: 32];
                        end
                    end
                end
            end
        end
    endgenerate

endmodule
