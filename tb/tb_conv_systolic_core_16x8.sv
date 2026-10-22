`timescale 1ns / 1ps

module tb_conv_systolic_core_16x8;
    bit tb_passed = 1'b0;
    localparam integer NUM_WINDOWS = 4;

    logic clk, rst_n;
    logic load_wt_en;
    logic [2:0] load_wt_col;
    logic signed [127:0] load_wt_bus;
    logic swap_wt, frame_start, in_valid, in_ready, out_valid;
    logic signed [127:0] in_act;
    logic signed [255:0] out_psum;

    integer weight_mem [0:7][0:15];
    integer act_mem [0:NUM_WINDOWS-1][0:15];
    integer expected_mem [0:NUM_WINDOWS-1][0:7];
    integer send_count, receive_count, result_window_id, errors;
    integer c, k, w, got;
    time last_output_time;

    logic signed [31:0] expected0, expected1, expected2, expected3;
    logic signed [31:0] expected4, expected5, expected6, expected7;
    wire signed [31:0] out0 = out_psum[0*32 +: 32];
    wire signed [31:0] out1 = out_psum[1*32 +: 32];
    wire signed [31:0] out2 = out_psum[2*32 +: 32];
    wire signed [31:0] out3 = out_psum[3*32 +: 32];
    wire signed [31:0] out4 = out_psum[4*32 +: 32];
    wire signed [31:0] out5 = out_psum[5*32 +: 32];
    wire signed [31:0] out6 = out_psum[6*32 +: 32];
    wire signed [31:0] out7 = out_psum[7*32 +: 32];

    // 展开skew后的16条lane，便于在波形中观察逐行错拍。
    wire signed [7:0] skew0  = dut.skewed_act[0*8  +: 8];
    wire signed [7:0] skew1  = dut.skewed_act[1*8  +: 8];
    wire signed [7:0] skew2  = dut.skewed_act[2*8  +: 8];
    wire signed [7:0] skew3  = dut.skewed_act[3*8  +: 8];
    wire signed [7:0] skew4  = dut.skewed_act[4*8  +: 8];
    wire signed [7:0] skew5  = dut.skewed_act[5*8  +: 8];
    wire signed [7:0] skew6  = dut.skewed_act[6*8  +: 8];
    wire signed [7:0] skew7  = dut.skewed_act[7*8  +: 8];
    wire signed [7:0] skew8  = dut.skewed_act[8*8  +: 8];
    wire signed [7:0] skew9  = dut.skewed_act[9*8  +: 8];
    wire signed [7:0] skew10 = dut.skewed_act[10*8 +: 8];
    wire signed [7:0] skew11 = dut.skewed_act[11*8 +: 8];
    wire signed [7:0] skew12 = dut.skewed_act[12*8 +: 8];
    wire signed [7:0] skew13 = dut.skewed_act[13*8 +: 8];
    wire signed [7:0] skew14 = dut.skewed_act[14*8 +: 8];
    wire signed [7:0] skew15 = dut.skewed_act[15*8 +: 8];

    conv_systolic_core_16x8 dut (
        .clk(clk), .rst_n(rst_n),
        .load_wt_en(load_wt_en), .load_wt_col(load_wt_col),
        .load_wt_bus(load_wt_bus), .swap_wt(swap_wt),
        .frame_start(frame_start), .in_valid(in_valid), .in_act(in_act),
        .in_ready(in_ready), .out_valid(out_valid), .out_psum(out_psum)
    );

    always #5 clk = ~clk;

    task automatic load_one_column(input integer col_id);
        integer tk;
        begin
            load_wt_bus = '0;
            for (tk = 0; tk < 16; tk = tk + 1)
                load_wt_bus[tk*8 +: 8] = weight_mem[col_id][tk];
            @(negedge clk);
            load_wt_col = col_id;
            load_wt_en = 1'b1;
            @(negedge clk);
            load_wt_en = 1'b0;
        end
    endtask

    // 连续调用时，每个窗口恰好占一个时钟周期。
    task automatic send_one_window(input integer window_id);
        integer tk;
        begin
            // 在下降沿更新输入，使数据在下一个上升沿前稳定半个周期。
            @(negedge clk);
            in_act = '0;
            for (tk = 0; tk < 16; tk = tk + 1)
                in_act[tk*8 +: 8] = act_mem[window_id][tk];
            in_valid = 1'b1;
            send_count = window_id;
        end
    endtask

    // 在下降沿核对，避开DUT上升沿非阻塞赋值的更新时间点。
    always @(negedge clk) begin
        if (rst_n && out_valid) begin
            if ((receive_count > 0) && (($time - last_output_time) != 10ns)) begin
                $display("ERROR output stream contains a bubble: interval=%0t", $time-last_output_time);
                errors = errors + 1;
            end
            last_output_time = $time;
            result_window_id = receive_count;
            expected0 = expected_mem[receive_count][0];
            expected1 = expected_mem[receive_count][1];
            expected2 = expected_mem[receive_count][2];
            expected3 = expected_mem[receive_count][3];
            expected4 = expected_mem[receive_count][4];
            expected5 = expected_mem[receive_count][5];
            expected6 = expected_mem[receive_count][6];
            expected7 = expected_mem[receive_count][7];
            for (c = 0; c < 8; c = c + 1) begin
                got = $signed(out_psum[c*32 +: 32]);
                if (got !== expected_mem[receive_count][c]) begin
                    $display("ERROR window=%0d out=%0d got=%0d expected=%0d",
                             receive_count, c, got, expected_mem[receive_count][c]);
                    errors = errors + 1;
                end else begin
                    $display("PASS  window=%0d out=%0d value=%0d", receive_count, c, got);
                end
            end
            receive_count = receive_count + 1;
        end
    end

    initial begin
        clk = 0; rst_n = 0; load_wt_en = 0; load_wt_col = 0;
        load_wt_bus = '0; swap_wt = 0; frame_start = 0;
        in_valid = 0; in_act = '0; send_count = -1;
        receive_count = 0; result_window_id = -1; errors = 0;
        last_output_time = 0;
        expected0 = 0; expected1 = 0; expected2 = 0; expected3 = 0;
        expected4 = 0; expected5 = 0; expected6 = 0; expected7 = 0;

        for (c = 0; c < 8; c = c + 1)
            for (k = 0; k < 16; k = k + 1)
                weight_mem[c][k] = (c + 1) * ((k % 5) - 2);

        for (w = 0; w < NUM_WINDOWS; w = w + 1)
            for (k = 0; k < 16; k = k + 1)
                act_mem[w][k] = (w + 1) + (k % 7);

        for (w = 0; w < NUM_WINDOWS; w = w + 1)
            for (c = 0; c < 8; c = c + 1) begin
                expected_mem[w][c] = 0;
                for (k = 0; k < 16; k = k + 1)
                    expected_mem[w][c] = expected_mem[w][c] +
                        act_mem[w][k] * weight_mem[c][k];
            end

        repeat (3) @(negedge clk);
        rst_n = 1;

        for (c = 0; c < 8; c = c + 1)
            load_one_column(c);

        @(negedge clk); swap_wt = 1;
        @(negedge clk); swap_wt = 0; frame_start = 1;
        @(negedge clk); frame_start = 0;

        for (w = 0; w < NUM_WINDOWS; w = w + 1)
            send_one_window(w);
        @(negedge clk);
        in_valid = 0; send_count = -1; in_act = '0;

        wait (receive_count == NUM_WINDOWS);
        repeat (2) @(posedge clk);
        if (errors != 0)
            $fatal(1, "TEST FAIL: %0d mismatches", errors);
        tb_passed = 1'b1;
        $display("TEST PASS: 16x8 systolic array, %0d continuous windows", NUM_WINDOWS);
        $finish;
    end

    initial begin
        #2000;
        $fatal(1, "TEST TIMEOUT: receive_count=%0d", receive_count);
    end
endmodule
