`timescale 1ns / 1ps

module tb_fc_classifier_8lane;
    bit tb_passed = 1'b0;
    localparam integer MAX_INPUT_LENGTH = 32;
    localparam integer MAX_CLASSES = 16;
    localparam integer INPUT_WORD_ADDR_WIDTH = 2;
    localparam integer CLASS_ADDR_WIDTH = 4;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst_n;
    logic input_wr_en;
    logic [INPUT_WORD_ADDR_WIDTH-1:0] input_wr_word_addr;
    logic [63:0] input_wr_data;
    logic weight_wr_en;
    logic [CLASS_ADDR_WIDTH-1:0] weight_wr_class;
    logic [INPUT_WORD_ADDR_WIDTH-1:0] weight_wr_word_addr;
    logic [63:0] weight_wr_data;
    logic bias_wr_en;
    logic [CLASS_ADDR_WIDTH-1:0] bias_wr_class;
    logic signed [31:0] bias_wr_data;
    logic start;
    logic [15:0] cfg_input_length, cfg_class_count;
    logic busy, done, config_error, result_valid;
    logic [CLASS_ADDR_WIDTH-1:0] result_class;
    logic signed [39:0] result_score;
    logic class_score_valid;
    logic [CLASS_ADDR_WIDTH-1:0] class_score_index;
    logic signed [39:0] class_score;
    integer errors;
    integer i;

    // 将同一个有符号INT8值明确打包到64bit word的8个lane。
    function automatic [63:0] pack_byte(input integer value);
        integer k;
        begin
            pack_byte = '0;
            for (k = 0; k < 8; k = k + 1)
                pack_byte[k*8 +: 8] = value[7:0];
        end
    endfunction

    fc_classifier_8lane #(
        .MAX_INPUT_LENGTH(MAX_INPUT_LENGTH), .MAX_CLASSES(MAX_CLASSES),
        .ACC_WIDTH(40)
    ) dut (.*);

    task automatic write_input_word(input integer addr, input logic [63:0] data);
        begin
            @(negedge clk);
            input_wr_en = 1'b1;
            input_wr_word_addr = addr[INPUT_WORD_ADDR_WIDTH-1:0];
            input_wr_data = data;
            @(negedge clk);
            input_wr_en = 1'b0;
        end
    endtask

    task automatic write_weight_word(input integer cls, input integer addr,
                                     input logic [63:0] data);
        begin
            @(negedge clk);
            weight_wr_en = 1'b1;
            weight_wr_class = cls[CLASS_ADDR_WIDTH-1:0];
            weight_wr_word_addr = addr[INPUT_WORD_ADDR_WIDTH-1:0];
            weight_wr_data = data;
            @(negedge clk);
            weight_wr_en = 1'b0;
        end
    endtask

    task automatic write_bias(input integer cls, input integer value);
        begin
            @(negedge clk);
            bias_wr_en = 1'b1;
            bias_wr_class = cls[CLASS_ADDR_WIDTH-1:0];
            bias_wr_data = value;
            @(negedge clk);
            bias_wr_en = 1'b0;
        end
    endtask

    task automatic run_fc(input integer input_len, input integer classes,
                          input integer expected_class, input integer expected_score);
        begin
            @(negedge clk);
            cfg_input_length = input_len;
            cfg_class_count = classes;
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            wait(result_valid);
            if (result_class !== expected_class || result_score !== expected_score ||
                !done || config_error) begin
                $display("ERROR FC len=%0d classes=%0d class=%0d/%0d score=%0d/%0d done=%0b err=%0b",
                         input_len, classes, result_class, expected_class,
                         result_score, expected_score, done, config_error);
                errors = errors + 1;
            end
            @(negedge clk);
        end
    endtask

    initial begin
        rst_n = 1'b0;
        input_wr_en = 1'b0; input_wr_word_addr = '0; input_wr_data = '0;
        weight_wr_en = 1'b0; weight_wr_class = '0; weight_wr_word_addr = '0; weight_wr_data = '0;
        bias_wr_en = 1'b0; bias_wr_class = '0; bias_wr_data = '0;
        start = 1'b0; cfg_input_length = '0; cfg_class_count = '0;
        errors = 0;

        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        // 输入向量：[1,2,...,16]，两个8元素word。
        write_input_word(0, 64'h0807060504030201);
        write_input_word(1, 64'h100F0E0D0C0B0A09);

        // 5类：class0分数=16，class1=32，class2=48，class3=64，class4=80，argmax=4。
        for (i = 0; i < 5; i = i + 1) begin
            write_weight_word(i, 0, pack_byte(i+1));
            write_weight_word(i, 1, pack_byte(i+1));
            write_bias(i, 0);
        end
        run_fc(16, 5, 4, 680);

        // 10类、输入长度10：class7权重最大，最后一个word只使用低2路。
        for (i = 0; i < 10; i = i + 1) begin
            write_weight_word(i, 0, pack_byte((i == 7) ? 3 : 1));
            write_weight_word(i, 1, pack_byte((i == 7) ? 3 : 1));
            write_bias(i, 0);
        end
        run_fc(10, 10, 7, 3*(1+2+3+4+5+6+7+8+9+10));

        // 第0类最大：验证argmax初始化和首类边界。
        write_weight_word(0, 0, pack_byte(5));
        write_weight_word(1, 0, pack_byte(1));
        write_weight_word(2, 0, pack_byte(1));
        run_fc(1, 3, 0, 5);

        // 最后一类最大：验证class_count-1边界。
        write_weight_word(0, 0, pack_byte(1));
        write_weight_word(1, 0, pack_byte(1));
        write_weight_word(2, 0, pack_byte(6));
        run_fc(1, 3, 2, 6);

        // 分数相等时保持较小类别编号（严格大于才更新）。
        write_weight_word(0, 0, pack_byte(2));
        write_weight_word(1, 0, pack_byte(2));
        run_fc(1, 2, 0, 2);

        // 输入长度不是8的倍数，且只使用最后word的低1 lane。
        write_input_word(0, 64'h0807060504030201);
        write_input_word(1, 64'h0000000000000009);
        write_weight_word(0, 0, pack_byte(0));
        write_weight_word(0, 1, pack_byte(7));
        run_fc(9, 1, 0, 63);

        // 非法配置必须立即报错，不进入busy。
        @(negedge clk); cfg_input_length = 0; cfg_class_count = 10; start = 1'b1;
        @(negedge clk); start = 1'b0;
        if (!config_error || busy || !done) errors = errors + 1;

        // 非法输入长度和类别数也必须立即报错。
        @(negedge clk); cfg_input_length = MAX_INPUT_LENGTH + 1; cfg_class_count = 1; start = 1'b1;
        @(negedge clk); start = 1'b0;
        if (!config_error || busy || !done) errors = errors + 1;
        @(negedge clk); cfg_input_length = 8; cfg_class_count = MAX_CLASSES + 1; start = 1'b1;
        @(negedge clk); start = 1'b0;
        if (!config_error || busy || !done) errors = errors + 1;

        if (errors != 0) $fatal(1, "TEST FAIL: FC errors=%0d", errors);
        tb_passed = 1'b1;
        $display("TEST PASS: configurable 5/10-class FC argmax");
        $finish;
    end

    initial begin
        #20000;
        $fatal(1, "TEST TIMEOUT: busy=%0b done=%0b", busy, done);
    end
endmodule
