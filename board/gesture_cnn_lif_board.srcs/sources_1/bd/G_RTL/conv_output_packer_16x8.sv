`timescale 1ns / 1ps

// 16x8卷积输出后处理与HWC16半字写入适配器。
// 卷积输出顺序为oc_tile优先，所以用16字节写使能分别更新HWC16低/高64 bit。
module conv_output_packer_16x8 #(
    parameter integer PIXEL_ADDR_WIDTH = 12,
    parameter integer OUTPUT_WORDS_PER_PIXEL = 8
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         in_valid,
    input  logic [PIXEL_ADDR_WIDTH-1:0]  in_pixel_addr,
    input  logic [15:0]                  in_oc_base,
    input  logic [7:0]                   in_channel_mask,
    input  logic                         in_last_pixel,
    input  logic signed [255:0]          in_psum,
    input  logic signed [255:0]          in_bias,
    input  logic signed [127:0]          in_multiplier,
    input  logic [47:0]                  in_shift,
    input  logic signed [15:0]           output_zero_point,
    input  logic                         relu_enable,
    input  logic [15:0]                  output_channels,
    input  logic [15:0]                  output_words_per_pixel,
    output logic                         out_wr_valid,
    output logic [PIXEL_ADDR_WIDTH+$clog2(OUTPUT_WORDS_PER_PIXEL)-1:0] out_wr_addr,
    output logic [127:0]                 out_wr_data,
    output logic [15:0]                  out_wr_strb,
    output logic                         out_wr_last
);

    logic                         q_valid;
    logic signed [63:0]           q_int8;
    logic [PIXEL_ADDR_WIDTH-1:0]  meta_pixel_addr [0:3];
    logic [15:0]                  meta_oc_base [0:3];
    logic                         meta_last_pixel [0:3];

    requant_relu_8 u_requant (
        .clk(clk), .rst_n(rst_n), .in_valid(in_valid), .in_psum(in_psum),
        .in_bias(in_bias), .in_multiplier(in_multiplier), .in_shift(in_shift),
        .output_zero_point(output_zero_point), .relu_enable(relu_enable),
        .channel_mask(in_channel_mask), .out_valid(q_valid), .out_int8(q_int8)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (integer m = 0; m < 4; m = m + 1) begin
                meta_pixel_addr[m] <= '0;
                meta_oc_base[m] <= '0;
                meta_last_pixel[m] <= 1'b0;
            end
        end
        else begin
            meta_pixel_addr[0] <= in_pixel_addr;
            meta_oc_base[0] <= in_oc_base;
            meta_last_pixel[0] <= in_last_pixel;
            for (integer m = 1; m < 4; m = m + 1) begin
                meta_pixel_addr[m] <= meta_pixel_addr[m-1];
                meta_oc_base[m] <= meta_oc_base[m-1];
                meta_last_pixel[m] <= meta_last_pixel[m-1];
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            out_wr_valid <= 1'b0;
            out_wr_addr  <= '0;
            out_wr_data  <= '0;
            out_wr_strb  <= '0;
            out_wr_last  <= 1'b0;
        end
        else begin
            out_wr_valid <= q_valid;
            out_wr_last  <= 1'b0;
            if (q_valid) begin
                out_wr_addr <= (meta_pixel_addr[3] * output_words_per_pixel) +
                               (meta_oc_base[3] >> 4);
                if (!meta_oc_base[3][3]) begin
                    out_wr_data <= {64'd0, q_int8};
                    out_wr_strb <= 16'h00ff;
                end
                else begin
                    out_wr_data <= {q_int8, 64'd0};
                    out_wr_strb <= 16'hff00;
                end
                out_wr_last <= meta_last_pixel[3] &&
                               ((meta_oc_base[3] + 16'd8) >= output_channels);
            end
        end
    end
endmodule
