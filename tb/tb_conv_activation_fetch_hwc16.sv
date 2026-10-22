`timescale 1ns/1ps
module tb_conv_activation_fetch_hwc16;
    bit tb_passed = 1'b0;
    logic clk=0, rst_n=0, clear=0;
    logic [15:0] cfg_input_width=4, cfg_input_height=3;
    logic req_valid=0, req_ready;
    logic signed [16:0] req_in_x=0, req_in_y=0;
    logic signed [31:0] req_word_addr=0;
    logic mem_rd_en, mem_rd_valid=0;
    logic [7:0] mem_rd_addr;
    logic signed [127:0] mem_rd_data=0;
    logic rsp_valid, rsp_ready=0, rsp_is_padding;
    logic signed [127:0] rsp_tile;
    localparam logic [127:0] VALUE=128'h1122334455667788_99aabbccddeeff00;
    always #5 clk=~clk;
    conv_activation_fetch_hwc16 #(.ADDR_WIDTH(8)) dut(.*);
    initial begin
        repeat(3) @(negedge clk); rst_n=1;
        @(negedge clk); req_valid=1; req_in_x=2; req_in_y=1; req_word_addr=7;
        #1; if(!req_ready || !mem_rd_en || mem_rd_addr!==7) $fatal(1,"valid request was not issued");
        @(negedge clk); req_valid=0; mem_rd_valid=1; mem_rd_data=VALUE;
        @(negedge clk); mem_rd_valid=0;
        wait(rsp_valid); #1;
        if(rsp_tile!==VALUE || rsp_is_padding) $fatal(1,"memory response mismatch");
        rsp_ready=1; @(negedge clk); rsp_ready=0;
        @(negedge clk); req_valid=1; req_in_x=-1; req_in_y=0; req_word_addr=9;
        #1; if(mem_rd_en) $fatal(1,"padding request accessed memory");
        @(negedge clk); req_valid=0;
        wait(rsp_valid); #1;
        if(rsp_tile!==0 || !rsp_is_padding) $fatal(1,"padding response mismatch");
        rsp_ready=1; @(negedge clk); rsp_ready=0;
        tb_passed = 1'b1;
        $display("TEST PASS: conv_activation_fetch_hwc16"); $finish;
    end
    initial begin #2000; $fatal(1,"TEST TIMEOUT: conv_activation_fetch_hwc16"); end
endmodule
