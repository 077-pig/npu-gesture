`timescale 1ns / 1ps

// V2卷积层调度器：输出通道组 -> K分块 -> 输出像素。
// HWC16地址采用软件预计算步长和硬件加法，不在PL中进行动态乘法。
module conv_layer_controller #(
    parameter integer MAX_OUTPUT_PIXELS = 4096
) (
    input logic clk, rst_n, start,
    input logic [15:0] cfg_output_width, cfg_output_height,
    input logic [31:0] cfg_output_pixels,
    input logic [15:0] cfg_k_tiles, cfg_output_channels,
    input logic [15:0] cfg_kernel_width, cfg_kernel_height,
    input logic [15:0] cfg_channel_blocks, cfg_stride,
    input logic [15:0] cfg_pad_left, cfg_pad_top,
    input logic signed [31:0] cfg_window_base_addr,
    input logic [31:0] cfg_output_x_step_words,
    input logic signed [31:0] cfg_output_row_step_words,
    input logic signed [31:0] cfg_kernel_row_step_words,

    output logic busy, done, config_error,
    output logic wt_ready,
    input logic wt_valid,
    output logic [15:0] wt_req_oc_tile, wt_req_k_tile,
    output logic [2:0] wt_req_col,
    output logic act_ready,
    input logic act_valid,
    output logic [15:0] act_req_oc_tile, act_req_k_tile,
    output logic [15:0] act_req_x, act_req_y,
    output logic [31:0] act_req_pixel_addr,
    output logic [15:0] act_req_kernel_x, act_req_kernel_y,
    output logic [15:0] act_req_channel_block,
    output logic signed [16:0] act_req_in_x, act_req_in_y,
    output logic signed [31:0] act_req_word_addr,

    input logic core_in_ready,
    output logic core_load_wt_en,
    output logic [2:0] core_load_wt_col,
    output logic core_swap_wt, core_frame_start, issue_valid,
    output logic issue_first_k, issue_last_k, issue_last_pixel,
    output logic [7:0] issue_channel_mask,
    input logic tile_result_done, final_output_done
);
    typedef enum logic [2:0] {S_IDLE,S_LOAD_WT,S_SWAP_WT,S_FRAME_START,
                              S_STREAM,S_DRAIN,S_FINISH} state_t;
    state_t state;
    logic [15:0] output_width_reg, k_tiles_reg, output_channels_reg;
    logic [15:0] oc_tiles_reg, kernel_width_reg, channel_blocks_reg, stride_reg;
    logic [31:0] output_pixels_reg;
    logic signed [16:0] pad_left_neg_reg, pad_top_neg_reg;
    logic signed [31:0] window_base_addr_reg;
    logic [31:0] output_x_step_words_reg;
    logic signed [31:0] output_row_step_words_reg, kernel_row_step_words_reg;
    logic [15:0] oc_tile, k_tile, out_x, out_y;
    logic [31:0] pixel_addr;
    logic [2:0] wt_col;
    logic [15:0] k_kernel_x, k_kernel_y, k_channel_block;
    logic signed [16:0] kernel_start_x, kernel_start_y, stream_in_x, stream_in_y;
    logic signed [31:0] kernel_word_addr, stream_word_addr;
    integer mask_lane;

    assign busy = (state != S_IDLE);
    assign wt_req_oc_tile=oc_tile; assign wt_req_k_tile=k_tile; assign wt_req_col=wt_col;
    assign act_req_oc_tile=oc_tile; assign act_req_k_tile=k_tile;
    assign act_req_x=out_x; assign act_req_y=out_y; assign act_req_pixel_addr=pixel_addr;
    assign act_req_kernel_x=k_kernel_x; assign act_req_kernel_y=k_kernel_y;
    assign act_req_channel_block=k_channel_block;
    assign act_req_in_x=stream_in_x; assign act_req_in_y=stream_in_y;
    assign act_req_word_addr=stream_word_addr;
    // 权重缓存返回有一拍延迟，LOAD状态需保持请求/接收握手直到本列真正返回。
    assign wt_ready=(state==S_LOAD_WT);
    assign act_ready=(state==S_STREAM)&&core_in_ready;
    assign core_load_wt_en=wt_ready&&wt_valid; assign core_load_wt_col=wt_col;
    assign core_swap_wt=(state==S_SWAP_WT); assign core_frame_start=(state==S_FRAME_START);
    assign issue_valid=act_ready&&act_valid;
    assign issue_first_k=(k_tile==0); assign issue_last_k=(k_tile==(k_tiles_reg-1));
    assign issue_last_pixel=(pixel_addr==(output_pixels_reg-1));

    always_comb begin
        issue_channel_mask=0;
        for(mask_lane=0;mask_lane<8;mask_lane=mask_lane+1)
            if(({oc_tile,3'b000}+mask_lane)<output_channels_reg)
                issue_channel_mask[mask_lane]=1'b1;
    end

    always_ff @(posedge clk) begin
        if(!rst_n) begin
            state<=S_IDLE; done<=0; config_error<=0;
            output_width_reg<=0; output_pixels_reg<=0; k_tiles_reg<=0;
            output_channels_reg<=0; oc_tiles_reg<=0; kernel_width_reg<=0;
            channel_blocks_reg<=0; stride_reg<=0; pad_left_neg_reg<=0; pad_top_neg_reg<=0;
            window_base_addr_reg<=0; output_x_step_words_reg<=0;
            output_row_step_words_reg<=0; kernel_row_step_words_reg<=0;
            oc_tile<=0; k_tile<=0; out_x<=0; out_y<=0; pixel_addr<=0; wt_col<=0;
            k_kernel_x<=0; k_kernel_y<=0; k_channel_block<=0;
            kernel_start_x<=0; kernel_start_y<=0; stream_in_x<=0; stream_in_y<=0;
            kernel_word_addr<=0; stream_word_addr<=0;
        end else begin
            done<=0;
            case(state)
                S_IDLE: if(start) begin
                    config_error<=0;
                    if((cfg_output_width==0)||(cfg_output_height==0)||(cfg_output_pixels==0)||
                       (cfg_output_pixels>MAX_OUTPUT_PIXELS)||(cfg_k_tiles==0)||
                       (cfg_output_channels==0)||(cfg_kernel_width==0)||(cfg_kernel_height==0)||
                       (cfg_channel_blocks==0)||(cfg_stride==0)||
                       (cfg_output_x_step_words==0)||(cfg_output_row_step_words==0)||
                       (cfg_kernel_row_step_words==0)) begin
                        config_error<=1; done<=1;
                    end else begin
                        output_width_reg<=cfg_output_width; output_pixels_reg<=cfg_output_pixels;
                        k_tiles_reg<=cfg_k_tiles; output_channels_reg<=cfg_output_channels;
                        oc_tiles_reg<=(cfg_output_channels+7)>>3; kernel_width_reg<=cfg_kernel_width;
                        channel_blocks_reg<=cfg_channel_blocks; stride_reg<=cfg_stride;
                        pad_left_neg_reg<=-$signed({1'b0,cfg_pad_left});
                        pad_top_neg_reg<=-$signed({1'b0,cfg_pad_top});
                        window_base_addr_reg<=cfg_window_base_addr;
                        output_x_step_words_reg<=cfg_output_x_step_words;
                        output_row_step_words_reg<=cfg_output_row_step_words;
                        kernel_row_step_words_reg<=cfg_kernel_row_step_words;
                        oc_tile<=0; k_tile<=0; out_x<=0; out_y<=0; pixel_addr<=0; wt_col<=0;
                        k_kernel_x<=0; k_kernel_y<=0; k_channel_block<=0;
                        kernel_start_x<=-$signed({1'b0,cfg_pad_left});
                        kernel_start_y<=-$signed({1'b0,cfg_pad_top});
                        stream_in_x<=-$signed({1'b0,cfg_pad_left});
                        stream_in_y<=-$signed({1'b0,cfg_pad_top});
                        kernel_word_addr<=cfg_window_base_addr; stream_word_addr<=cfg_window_base_addr;
                        state<=S_LOAD_WT;
                    end
                end
                S_LOAD_WT: if(wt_valid) begin
                    if(wt_col==7) begin wt_col<=0; state<=S_SWAP_WT; end
                    else wt_col<=wt_col+1;
                end
                S_SWAP_WT: state<=S_FRAME_START;
                S_FRAME_START: begin
                    out_x<=0; out_y<=0; pixel_addr<=0;
                    stream_in_x<=kernel_start_x; stream_in_y<=kernel_start_y;
                    stream_word_addr<=kernel_word_addr; state<=S_STREAM;
                end
                S_STREAM: if(issue_valid) begin
                    if(issue_last_pixel) state<=S_DRAIN;
                    else begin
                        pixel_addr<=pixel_addr+1;
                        if(out_x==(output_width_reg-1)) begin
                            out_x<=0; out_y<=out_y+1; stream_in_x<=kernel_start_x;
                            stream_in_y<=stream_in_y+$signed({1'b0,stride_reg});
                            stream_word_addr<=stream_word_addr+output_row_step_words_reg;
                        end else begin
                            out_x<=out_x+1; stream_in_x<=stream_in_x+$signed({1'b0,stride_reg});
                            stream_word_addr<=stream_word_addr+$signed(output_x_step_words_reg);
                        end
                    end
                end
                S_DRAIN: if(tile_result_done) begin
                    if(k_tile!=(k_tiles_reg-1)) begin
                        k_tile<=k_tile+1;
                        if(k_channel_block==(channel_blocks_reg-1)) begin
                            k_channel_block<=0;
                            if(k_kernel_x==(kernel_width_reg-1)) begin
                                k_kernel_x<=0; k_kernel_y<=k_kernel_y+1;
                                kernel_start_x<=pad_left_neg_reg; kernel_start_y<=kernel_start_y+1;
                                kernel_word_addr<=kernel_word_addr+kernel_row_step_words_reg;
                            end else begin
                                k_kernel_x<=k_kernel_x+1; kernel_start_x<=kernel_start_x+1;
                                kernel_word_addr<=kernel_word_addr+1;
                            end
                        end else begin
                            k_channel_block<=k_channel_block+1; kernel_word_addr<=kernel_word_addr+1;
                        end
                        state<=S_LOAD_WT;
                    end else if(oc_tile!=(oc_tiles_reg-1)) begin
                        oc_tile<=oc_tile+1; k_tile<=0; k_kernel_x<=0; k_kernel_y<=0; k_channel_block<=0;
                        kernel_start_x<=pad_left_neg_reg; kernel_start_y<=pad_top_neg_reg;
                        kernel_word_addr<=window_base_addr_reg; state<=S_LOAD_WT;
                    end else state<=S_FINISH;
                end
                S_FINISH: if(final_output_done) begin state<=S_IDLE; done<=1; end
                default: state<=S_IDLE;
            endcase
        end
    end
endmodule
