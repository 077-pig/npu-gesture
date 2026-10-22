`timescale 1ns / 1ps

// 将像素地址、K分块标记和通道掩码延迟到与核心out_valid同一周期。
module conv_tag_pipeline #(
    parameter integer TAG_STAGES = 23
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        clear,
    input  logic        in_valid,
    input  logic [31:0] in_pixel_addr,
    input  logic [15:0] in_oc_tile,
    input  logic        in_first_k,
    input  logic        in_last_k,
    input  logic        in_last_pixel,
    input  logic [7:0]  in_channel_mask,

    output logic        out_valid,
    output logic [31:0] out_pixel_addr,
    output logic [15:0] out_oc_tile,
    output logic        out_first_k,
    output logic        out_last_k,
    output logic        out_last_pixel,
    output logic [7:0]  out_channel_mask
);

    logic [TAG_STAGES-1:0] valid_pipe;
    logic [31:0] pixel_pipe [0:TAG_STAGES-1];
    logic [15:0] oc_pipe [0:TAG_STAGES-1];
    logic first_pipe [0:TAG_STAGES-1];
    logic last_pipe [0:TAG_STAGES-1];
    logic last_pixel_pipe [0:TAG_STAGES-1];
    logic [7:0] mask_pipe [0:TAG_STAGES-1];
    integer stage;

    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            valid_pipe <= '0;
            for (stage = 0; stage < TAG_STAGES; stage = stage + 1) begin
                pixel_pipe[stage]      <= '0;
                oc_pipe[stage]         <= '0;
                first_pipe[stage]      <= 1'b0;
                last_pipe[stage]       <= 1'b0;
                last_pixel_pipe[stage] <= 1'b0;
                mask_pipe[stage]       <= '0;
            end
        end
        else begin
            valid_pipe[0]      <= in_valid;
            pixel_pipe[0]      <= in_pixel_addr;
            oc_pipe[0]         <= in_oc_tile;
            first_pipe[0]      <= in_first_k;
            last_pipe[0]       <= in_last_k;
            last_pixel_pipe[0] <= in_last_pixel;
            mask_pipe[0]       <= in_channel_mask;

            for (stage = 1; stage < TAG_STAGES; stage = stage + 1) begin
                valid_pipe[stage]      <= valid_pipe[stage-1];
                pixel_pipe[stage]      <= pixel_pipe[stage-1];
                oc_pipe[stage]         <= oc_pipe[stage-1];
                first_pipe[stage]      <= first_pipe[stage-1];
                last_pipe[stage]       <= last_pipe[stage-1];
                last_pixel_pipe[stage] <= last_pixel_pipe[stage-1];
                mask_pipe[stage]       <= mask_pipe[stage-1];
            end
        end
    end

    assign out_valid        = valid_pipe[TAG_STAGES-1];
    assign out_pixel_addr   = pixel_pipe[TAG_STAGES-1];
    assign out_oc_tile      = oc_pipe[TAG_STAGES-1];
    assign out_first_k      = first_pipe[TAG_STAGES-1];
    assign out_last_k       = last_pipe[TAG_STAGES-1];
    assign out_last_pixel   = last_pixel_pipe[TAG_STAGES-1];
    assign out_channel_mask = mask_pipe[TAG_STAGES-1];

endmodule
