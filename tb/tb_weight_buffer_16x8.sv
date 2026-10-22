`timescale 1ns / 1ps

module tb_weight_buffer_16x8;
    bit tb_passed = 1'b0;
    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst_n;
    logic wr_en;
    logic [8:0] wr_addr;
    logic signed [127:0] wr_data;
    logic req_valid;
    logic req_ready;
    logic [15:0] req_oc_tile, req_k_tile;
    logic [2:0] req_col;
    logic [8:0] req_base_addr;
    logic rsp_valid;
    logic rsp_ready;
    logic signed [127:0] rsp_data;
    integer errors = 0;

    weight_buffer_16x8 #(
        .MAX_OC_TILES(4), .MAX_K_TILES(4), .ADDR_WIDTH(9), .DEPTH_WORDS(128)
    ) dut (.*);

    function automatic [8:0] addr_of(input integer oc, input integer kt, input integer col);
        addr_of = ((oc * 4) + kt) * 8 + col;
    endfunction

    task automatic write_word(input integer addr, input logic signed [127:0] data);
        begin
            @(negedge clk);
            wr_en = 1'b1;
            wr_addr = addr[8:0];
            wr_data = data;
            @(negedge clk);
            wr_en = 1'b0;
        end
    endtask

    task automatic read_check(input integer oc, input integer kt, input integer col,
                              input logic signed [127:0] expected);
        begin
            while (!req_ready) @(negedge clk);
            @(negedge clk);
            req_valid = 1'b1;
            req_oc_tile = oc[15:0];
            req_k_tile = kt[15:0];
            req_col = col[2:0];
            @(negedge clk);
            req_valid = 1'b0;
            while (!rsp_valid) @(negedge clk);
            if (rsp_data !== expected) begin
                $display("ERROR read oc=%0d kt=%0d col=%0d got=%h expected=%h",
                         oc, kt, col, rsp_data, expected);
                errors = errors + 1;
            end
            rsp_ready = 1'b1;
            @(negedge clk);
            rsp_ready = 1'b0;
        end
    endtask

    integer i;
    logic signed [127:0] value;

    initial begin
        rst_n = 1'b0;
        wr_en = 1'b0;
        wr_addr = '0;
        wr_data = '0;
        req_valid = 1'b0;
        req_oc_tile = '0;
        req_k_tile = '0;
        req_col = '0;
        req_base_addr = '0;
        rsp_ready = 1'b0;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        // 覆盖两个输出通道组、两个K分块和全部8列，检查地址不冲突。
        for (i = 0; i < 16; i = i + 1) begin
            value = '0;
            value[31:0] = 32'h1000 + i;
            write_word(addr_of(i / 8, (i / 2) % 2, i % 8), value);
        end

        // 写入一组明确可追踪的数据。
        write_word(addr_of(0, 0, 3), 128'h0000_0000_0000_0000_0000_0000_1234_5678);
        write_word(addr_of(1, 1, 6), 128'h89ab_cdef_0123_4567_7654_3210_fedc_ba98);

        read_check(0, 0, 3, 128'h0000_0000_0000_0000_0000_0000_1234_5678);
        read_check(1, 1, 6, 128'h89ab_cdef_0123_4567_7654_3210_fedc_ba98);

        if (errors != 0)
            $fatal(1, "TEST FAIL: errors=%0d", errors);
        tb_passed = 1'b1;
        $display("TEST PASS: weight buffer address mapping and synchronous read");
        $finish;
    end

    initial begin #5000; $fatal(1,"TEST TIMEOUT: weight_buffer_16x8"); end

endmodule
