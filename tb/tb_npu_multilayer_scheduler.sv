`timescale 1ns / 1ps

module tb_npu_multilayer_scheduler;
    bit tb_passed = 1'b0;
    localparam integer MAX_LAYERS = 8;
    localparam integer INDEX_WIDTH = 3;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst_n;
    logic start;
    logic [INDEX_WIDTH:0] layer_count;
    logic layer_done, layer_error;
    logic layer_start, active, all_done, error;
    logic [INDEX_WIDTH-1:0] layer_index;
    logic input_bank, output_bank;

    logic desc_wr_en;
    logic [INDEX_WIDTH-1:0] desc_wr_index, desc_rd_index;
    logic [255:0] desc_wr_data, desc_rd_data;
    integer errors;
    integer starts;
    logic saw_all_done;

    npu_multilayer_scheduler #(.MAX_LAYERS(MAX_LAYERS)) u_sched (
        .clk(clk), .rst_n(rst_n), .start(start), .layer_count(layer_count),
        .layer_done(layer_done), .layer_error(layer_error),
        .layer_start(layer_start), .active(active), .all_done(all_done),
        .error(error), .layer_index(layer_index),
        .input_bank(input_bank), .output_bank(output_bank)
    );

    npu_layer_desc_table #(.MAX_LAYERS(MAX_LAYERS)) u_desc (
        .clk(clk), .rst_n(rst_n), .wr_en(desc_wr_en), .wr_index(desc_wr_index),
        .wr_data(desc_wr_data), .rd_index(desc_rd_index), .rd_data(desc_rd_data)
    );

    assign desc_rd_index = layer_index;

    always @(negedge clk) begin
        if (rst_n && all_done) saw_all_done = 1'b1;
        if (rst_n && layer_start) begin
            starts = starts + 1;
            if (starts == 1 && (layer_index !== 0 || input_bank !== 0 || output_bank !== 1))
                errors = errors + 1;
            if (starts == 2 && (layer_index !== 1 || input_bank !== 1 || output_bank !== 0))
                errors = errors + 1;
            if (starts == 3 && (layer_index !== 2 || input_bank !== 0 || output_bank !== 1))
                errors = errors + 1;
        end
    end

    task automatic finish_current_layer;
        begin
            @(negedge clk);
            layer_done = 1'b1;
            @(negedge clk);
            layer_done = 1'b0;
        end
    endtask

    initial begin
        rst_n = 1'b0;
        start = 1'b0;
        layer_count = 4'd3;
        layer_done = 1'b0;
        layer_error = 1'b0;
        desc_wr_en = 1'b0;
        desc_wr_index = '0;
        desc_wr_data = '0;
        errors = 0;
        starts = 0;
        saw_all_done = 1'b0;

        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        // 写入三层描述，验证表项不会互相覆盖。
        for (integer n = 0; n < 3; n = n + 1) begin
            @(negedge clk);
            desc_wr_en = 1'b1;
            desc_wr_index = n[INDEX_WIDTH-1:0];
            desc_wr_data = '0;
            desc_wr_data[15:0] = 16'h100 + n;
        end
        @(negedge clk);
        desc_wr_en = 1'b0;

        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        finish_current_layer();
        finish_current_layer();
        finish_current_layer();

        repeat (2) @(negedge clk);
        if (!saw_all_done || active || error || starts != 3)
            errors = errors + 1;
        #1;
        if (desc_rd_data[15:0] !== 16'h0102)
            errors = errors + 1;

        if (errors != 0) $fatal(1, "TEST FAIL: errors=%0d starts=%0d", errors, starts);
        tb_passed = 1'b1;
        $display("TEST PASS: configurable 3-layer scheduler and descriptor table");
        $finish;
    end

    initial begin
        #3000;
        $fatal(1, "TEST TIMEOUT: npu_multilayer_scheduler");
    end
endmodule
