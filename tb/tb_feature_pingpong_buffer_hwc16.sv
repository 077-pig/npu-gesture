`timescale 1ns / 1ps

module tb_feature_pingpong_buffer_hwc16;
    bit tb_passed = 1'b0;
    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst_n;
    logic wr_en, wr_bank;
    logic [3:0] wr_addr;
    logic [127:0] wr_data;
    logic [15:0] wr_strb;
    logic rd_en, rd_bank;
    logic [3:0] rd_addr;
    logic rd_valid;
    logic [127:0] rd_data;
    logic rd2_en, rd2_bank, rd2_valid;
    logic [3:0] rd2_addr;
    logic [127:0] rd2_data;
    integer errors;

    feature_pingpong_buffer_hwc16 #(
        .DEPTH_WORDS(16), .ADDR_WIDTH(4), .DATA_WIDTH(128)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .wr_en(wr_en), .wr_bank(wr_bank), .wr_addr(wr_addr), .wr_data(wr_data),
        .wr_strb(wr_strb),
        .rd_en(rd_en), .rd_bank(rd_bank), .rd_addr(rd_addr),
        .rd_valid(rd_valid), .rd_data(rd_data),
        .rd2_en(rd2_en), .rd2_bank(rd2_bank), .rd2_addr(rd2_addr),
        .rd2_valid(rd2_valid), .rd2_data(rd2_data)
    );

    task automatic write_word(input integer bank, input integer addr,
                              input logic [127:0] data);
        begin
            @(negedge clk);
            wr_en = 1'b1;
            wr_bank = bank[0];
            wr_addr = addr[3:0];
            wr_data = data;
            wr_strb = 16'hffff;
            @(negedge clk);
            wr_en = 1'b0;
        end
    endtask

    task automatic read_word(input integer bank, input integer addr,
                             input logic [127:0] expected);
        begin
            @(negedge clk);
            rd_en = 1'b1;
            rd_bank = bank[0];
            rd_addr = addr[3:0];
            @(negedge clk);
            rd_en = 1'b0;
            if (!rd_valid || rd_data !== expected) begin
                $display("ERROR bank=%0d addr=%0d valid=%0b data=%h expected=%h",
                         bank, addr, rd_valid, rd_data, expected);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        rst_n = 1'b0;
        wr_en = 1'b0; wr_bank = 1'b0; wr_addr = '0; wr_data = '0; wr_strb = '0;
        rd_en = 1'b0; rd_bank = 1'b0; rd_addr = '0;
        rd2_en = 1'b0; rd2_bank = 1'b0; rd2_addr = '0;
        errors = 0;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        write_word(0, 0, 128'h0000_0000_0000_0000_1111_2222_3333_4444);
        write_word(1, 0, 128'hAAAA_BBBB_CCCC_DDDD_EEEE_FFFF_0123_4567);
        write_word(0, 5, 128'h1234_5678_9ABC_DEF0_1357_9BDF_2468_ACED);

        read_word(0, 0, 128'h0000_0000_0000_0000_1111_2222_3333_4444);
        read_word(1, 0, 128'hAAAA_BBBB_CCCC_DDDD_EEEE_FFFF_0123_4567);
        read_word(0, 5, 128'h1234_5678_9ABC_DEF0_1357_9BDF_2468_ACED);

        if (errors != 0) $fatal(1, "TEST FAIL: errors=%0d", errors);
        tb_passed = 1'b1;
        $display("TEST PASS: HWC16 A/B ping-pong buffer");
        $finish;
    end

    initial begin
        #2000;
        $fatal(1, "TEST TIMEOUT: feature_pingpong_buffer_hwc16");
    end
endmodule
