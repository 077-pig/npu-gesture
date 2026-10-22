`timescale 1ns/1ps
module tb_gap_hwc16_requant;
    bit tb_passed = 1'b0;
    logic clk=0,rst_n=0,start=0,feature_rd_valid=0;
    logic [15:0] cfg_width=2,cfg_height=1,cfg_channel_blocks=1;
    logic feature_rd_en,out_valid,out_last,busy,done,config_error;
    logic [3:0] feature_rd_addr;
    logic [127:0] feature_rd_data=0,out_data;
    logic [0:0] out_block_index;
    logic [127:0] mem[0:15];
    integer i;
    always #5 clk=~clk;
    gap_hwc16_requant #(.FEATURE_ADDR_WIDTH(4),.MAX_CHANNEL_BLOCKS(1),
        .REQUANT_MULTIPLIER(1),.REQUANT_SHIFT(0),.BLOCK_INDEX_WIDTH(1)) dut(.*);
    always_ff @(posedge clk) begin
        feature_rd_valid<=feature_rd_en;
        if(feature_rd_en) feature_rd_data<=mem[feature_rd_addr];
    end
    initial begin
        mem[0]='0; mem[1]='0;
        for(i=0;i<16;i=i+1) begin mem[0][i*8 +: 8]=i+1; mem[1][i*8 +: 8]=i+3; end
        repeat(3) @(negedge clk); rst_n=1;
        @(negedge clk); start=1;
        @(negedge clk); start=0;
        wait(out_valid); #1;
        if(out_block_index!==0 || !out_last) $fatal(1,"GAP output metadata mismatch");
        for(i=0;i<16;i=i+1)
            if(out_data[i*8 +: 8] !== 2*i+4) $fatal(1,"GAP lane %0d mismatch",i);
        wait(done); @(negedge clk);
        if(config_error || busy) $fatal(1,"GAP completion state mismatch");
        cfg_width=0; @(negedge clk); start=1; @(negedge clk); start=0;
        if(!done || !config_error) $fatal(1,"invalid GAP configuration not rejected");
        tb_passed = 1'b1;
        $display("TEST PASS: gap_hwc16_requant"); $finish;
    end
    initial begin #5000; $fatal(1,"TEST TIMEOUT: gap_hwc16_requant"); end
endmodule
