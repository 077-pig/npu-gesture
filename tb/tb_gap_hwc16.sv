`timescale 1ns / 1ps

module tb_gap_hwc16;
    bit tb_passed = 1'b0;
    localparam integer FEATURE_ADDR_WIDTH = 6;
    localparam integer MAX_CHANNEL_BLOCKS = 4;
    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst_n, start;
    logic [15:0] cfg_width, cfg_height, cfg_channel_blocks;
    logic feature_rd_en;
    logic [FEATURE_ADDR_WIDTH-1:0] feature_rd_addr;
    logic feature_rd_valid;
    logic [127:0] feature_rd_data;
    logic out_valid;
    logic [$clog2(MAX_CHANNEL_BLOCKS)-1:0] out_block_index;
    logic [127:0] out_data;
    logic out_last, busy, done, config_error;
    logic [127:0] mem [0:63];
    integer errors, i, addr;
    integer output_count;

    // 在输出有效所在周期的下降沿采样，避开非阻塞赋值更新的竞态。
    always @(negedge clk) begin
        if (out_valid) begin
            output_count = output_count + 1;
            // 四个像素的每个通道平均值为 base+6：
            // block0 lane0..15 = 7..22，block1 lane0..15 = 23..38。
            for (i = 0; i < 16; i = i + 1) begin
                if (out_block_index == 0) begin
                    if (out_data[i*8 +: 8] !== (7+i)) errors = errors + 1;
                end
                else if (out_block_index == 1) begin
                    if (out_data[i*8 +: 8] !== (23+i)) errors = errors + 1;
                end
            end
        end
    end

    gap_hwc16 #(
        .FEATURE_ADDR_WIDTH(FEATURE_ADDR_WIDTH),
        .MAX_CHANNEL_BLOCKS(MAX_CHANNEL_BLOCKS)
    ) dut (.*);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            feature_rd_valid <= 1'b0;
            feature_rd_data <= '0;
        end
        else begin
            feature_rd_valid <= feature_rd_en;
            if (feature_rd_en)
                feature_rd_data <= mem[feature_rd_addr];
        end
    end

    function automatic [127:0] make_word(input integer base);
        integer k;
        begin
            make_word = '0;
            for (k = 0; k < 16; k = k + 1)
                make_word[k*8 +: 8] = (base + k) & 8'hff;
        end
    endfunction

    initial begin
        rst_n = 1'b0; start = 1'b0;
        cfg_width = 2; cfg_height = 2; cfg_channel_blocks = 2;
        errors = 0; output_count = 0;
        for (i = 0; i < 64; i = i + 1) mem[i] = '0;

        // 2x2图像、32通道。每个像素的block0为1..16，block1为17..32，
        // 第二个像素整体加4，四个像素平均后应为base+6。
        for (i = 0; i < 4; i = i + 1) begin
            mem[i*2+0] = make_word(1 + i*4);
            mem[i*2+1] = make_word(17 + i*4);
        end

        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk); start = 1'b1;
        @(negedge clk); start = 1'b0;

        wait(done);
        @(negedge clk);
        if (!out_last || config_error || busy || output_count != 2) begin
            errors = errors + 1;
        end
        if (errors != 0) $fatal(1, "TEST FAIL: GAP errors=%0d", errors);
        tb_passed = 1'b1;
        $display("TEST PASS: HWC16 GAP 2x2x32");
        $finish;
    end

    initial begin
        // 低资源GAP使用一个32位逐位除法器复用16个通道，
        // 两个channel block需要约1100拍，放宽仿真超时。
        #20000;
        $fatal(1, "TEST TIMEOUT: busy=%0b done=%0b", busy, done);
    end
endmodule
