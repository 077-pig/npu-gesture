`timescale 1ns/1ps
module tb_conv_layer_controller;
    bit tb_passed = 1'b0;
    logic clk=0, rst_n=0, start=0;
    logic [15:0] cfg_output_width=2,cfg_output_height=1,cfg_k_tiles=1,cfg_output_channels=10;
    logic [15:0] cfg_kernel_width=1,cfg_kernel_height=1,cfg_channel_blocks=1,cfg_stride=1;
    logic [15:0] cfg_pad_left=0,cfg_pad_top=0;
    logic [31:0] cfg_output_pixels=2,cfg_output_x_step_words=1;
    logic signed [31:0] cfg_window_base_addr=0,cfg_output_row_step_words=2,cfg_kernel_row_step_words=1;
    logic busy,done,config_error,wt_ready,wt_valid=1,act_ready,act_valid=1,core_in_ready=1;
    logic [15:0] wt_req_oc_tile,wt_req_k_tile,act_req_oc_tile,act_req_k_tile;
    logic [2:0] wt_req_col,core_load_wt_col;
    logic [15:0] act_req_x,act_req_y,act_req_kernel_x,act_req_kernel_y,act_req_channel_block;
    logic [31:0] act_req_pixel_addr;
    logic signed [16:0] act_req_in_x,act_req_in_y;
    logic signed [31:0] act_req_word_addr;
    logic core_load_wt_en,core_swap_wt,core_frame_start,issue_valid;
    logic issue_first_k,issue_last_k,issue_last_pixel;
    logic [7:0] issue_channel_mask;
    logic tile_result_done=0,final_output_done=1;
    integer weights=0,issues=0,tiles=0;
    logic tile_done_pending=0;
    always #5 clk=~clk;
    conv_layer_controller #(.MAX_OUTPUT_PIXELS(8)) dut(.*);
    always @(negedge clk) begin
        tile_result_done=tile_done_pending;
        tile_done_pending=0;
        if(rst_n && core_load_wt_en) weights=weights+1;
        if(rst_n && issue_valid) begin
            issues=issues+1;
            if(act_req_oc_tile==0 && issue_channel_mask!==8'hff) $fatal(1,"first tile mask mismatch");
            if(act_req_oc_tile==1 && issue_channel_mask!==8'h03) $fatal(1,"last tile mask mismatch");
            if(issue_last_pixel) begin tile_done_pending=1; tiles=tiles+1; end
        end
    end
    initial begin
        repeat(3) @(negedge clk); rst_n=1;
        @(negedge clk); start=1;
        @(negedge clk); start=0;
        wait(done); @(negedge clk);
        if(config_error || busy || weights!=16 || issues!=4 || tiles!=2)
            $fatal(1,"normal schedule mismatch weights=%0d issues=%0d tiles=%0d",weights,issues,tiles);
        cfg_output_width=0;
        @(negedge clk); start=1;
        @(negedge clk); start=0;
        if(!config_error || !done || busy) $fatal(1,"invalid configuration was not rejected");
        tb_passed = 1'b1;
        $display("TEST PASS: conv_layer_controller"); $finish;
    end
    initial begin #10000; $fatal(1,"TEST TIMEOUT: conv_layer_controller"); end
endmodule
