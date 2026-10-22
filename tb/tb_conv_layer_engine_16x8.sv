`timescale 1ns / 1ps

// 验证内容：
// 1. 2个K分块的INT32部分和累加；
// 2. 10个输出通道被拆成8+2两组；
// 3. 第二组后6路通过channel_mask屏蔽为0；
// 4. 控制器自动完成权重加载、窗口发送、排空和done。
module tb_conv_layer_engine_16x8;
    bit tb_passed = 1'b0;
    localparam integer OUT_W = 2;
    localparam integer OUT_H = 2;
    localparam integer NUM_PIXELS = OUT_W * OUT_H;
    localparam integer K_TILES = 2;
    localparam integer OUT_CHANNELS = 10;
    localparam integer OC_TILES = 2;
    localparam integer EXPECTED_RECORDS = NUM_PIXELS * OC_TILES;

    logic clk;
    logic rst_n;
    logic start;
    logic [15:0] cfg_output_width;
    logic [15:0] cfg_output_height;
    logic [31:0] cfg_output_pixels;
    logic [15:0] cfg_k_tiles;
    logic [15:0] cfg_output_channels;
    logic [15:0] cfg_kernel_width;
    logic [15:0] cfg_kernel_height;
    logic [15:0] cfg_channel_blocks;
    logic busy;
    logic done;
    logic config_error;

    logic wt_ready;
    logic wt_valid;
    logic signed [127:0] wt_data;
    logic [15:0] wt_req_oc_tile;
    logic [15:0] wt_req_k_tile;
    logic [2:0] wt_req_col;

    logic act_ready;
    logic act_valid;
    logic signed [127:0] act_data;
    logic [15:0] act_req_oc_tile;
    logic [15:0] act_req_k_tile;
    logic [15:0] act_req_x;
    logic [15:0] act_req_y;
    logic [31:0] act_req_pixel_addr;
    logic [15:0] act_req_kernel_x;
    logic [15:0] act_req_kernel_y;
    logic [15:0] act_req_channel_block;
    logic signed [16:0] act_req_in_x;
    logic signed [16:0] act_req_in_y;
    logic signed [31:0] act_req_word_addr;

    logic out_valid;
    logic [11:0] out_pixel_addr;
    logic [15:0] out_oc_base;
    logic [7:0] out_channel_mask;
    logic signed [255:0] out_psum;

    integer expected [0:NUM_PIXELS-1][0:OUT_CHANNELS-1];
    integer receive_count;
    integer errors;
    integer wt_lane;
    integer act_lane;
    integer check_lane;
    integer k;
    integer kt;
    integer oc;
    integer pixel;
    integer expected_oc_tile;
    integer expected_pixel;
    integer got;
    integer expected_value;
    integer expected_mask;
    integer completed;

    wire signed [31:0] out0 = out_psum[0*32 +: 32];
    wire signed [31:0] out1 = out_psum[1*32 +: 32];
    wire signed [31:0] out2 = out_psum[2*32 +: 32];
    wire signed [31:0] out3 = out_psum[3*32 +: 32];
    wire signed [31:0] out4 = out_psum[4*32 +: 32];
    wire signed [31:0] out5 = out_psum[5*32 +: 32];
    wire signed [31:0] out6 = out_psum[6*32 +: 32];
    wire signed [31:0] out7 = out_psum[7*32 +: 32];

    function automatic integer make_weight;
        input integer f_oc;
        input integer f_kt;
        input integer f_k;
        begin
            make_weight = (f_oc + 1) + (f_kt * 2) + (f_k % 3) - 1;
        end
    endfunction

    function automatic integer make_activation;
        input integer f_pixel;
        input integer f_kt;
        input integer f_k;
        begin
            make_activation = (f_pixel + 1) + f_kt + (f_k % 5) - 2;
        end
    endfunction

    conv_layer_engine_16x8 #(
        .MAX_OUTPUT_PIXELS (16),
        .ADDR_WIDTH        (12)
    ) dut (
        .clk                 (clk),
        .rst_n               (rst_n),
        .start               (start),
        .cfg_output_width    (cfg_output_width),
        .cfg_output_height   (cfg_output_height),
        .cfg_output_pixels   (cfg_output_pixels),
        .cfg_k_tiles         (cfg_k_tiles),
        .cfg_output_channels (cfg_output_channels),
        .cfg_kernel_width    (cfg_kernel_width),
        .cfg_kernel_height   (cfg_kernel_height),
        .cfg_channel_blocks  (cfg_channel_blocks),
        .cfg_stride          (16'd1),
        .cfg_pad_left        (16'd0),
        .cfg_pad_top         (16'd0),
        .cfg_window_base_addr(32'sd0),
        .cfg_output_x_step_words(32'd1),
        .cfg_output_row_step_words(32'sd1),
        .cfg_kernel_row_step_words(32'sd1),
        .busy                (busy),
        .done                (done),
        .config_error        (config_error),
        .wt_ready            (wt_ready),
        .wt_valid            (wt_valid),
        .wt_data             (wt_data),
        .wt_req_oc_tile      (wt_req_oc_tile),
        .wt_req_k_tile       (wt_req_k_tile),
        .wt_req_col          (wt_req_col),
        .act_ready           (act_ready),
        .act_valid           (act_valid),
        .act_data            (act_data),
        .act_req_oc_tile     (act_req_oc_tile),
        .act_req_k_tile      (act_req_k_tile),
        .act_req_x           (act_req_x),
        .act_req_y           (act_req_y),
        .act_req_pixel_addr  (act_req_pixel_addr),
        .act_req_kernel_x    (act_req_kernel_x),
        .act_req_kernel_y    (act_req_kernel_y),
        .act_req_channel_block(act_req_channel_block),
        .act_req_in_x        (act_req_in_x),
        .act_req_in_y        (act_req_in_y),
        .act_req_word_addr   (act_req_word_addr),
        .out_valid           (out_valid),
        .out_pixel_addr      (out_pixel_addr),
        .out_oc_base         (out_oc_base),
        .out_channel_mask    (out_channel_mask),
        .out_psum            (out_psum)
    );

    always #5 clk = ~clk;

    // 测试平台模拟未来的权重缓存：控制器提出索引后，本周期给回对应列。
    always_comb begin
        wt_valid = wt_ready;
        wt_data = '0;
        for (wt_lane = 0; wt_lane < 16; wt_lane = wt_lane + 1)
            wt_data[wt_lane*8 +: 8] = make_weight(
                wt_req_oc_tile * 8 + wt_req_col,
                wt_req_k_tile,
                wt_lane
            );
    end

    // 测试平台模拟未来的窗口生成器：每次请求返回16个激活元素。
    always_comb begin
        act_valid = act_ready;
        act_data = '0;
        for (act_lane = 0; act_lane < 16; act_lane = act_lane + 1)
            act_data[act_lane*8 +: 8] = make_activation(
                act_req_pixel_addr,
                act_req_k_tile,
                act_lane
            );
    end

    always @(negedge clk) begin
        if (rst_n && done)
            completed = 1;

        if (rst_n && out_valid) begin
            expected_oc_tile = receive_count / NUM_PIXELS;
            expected_pixel   = receive_count % NUM_PIXELS;
            expected_mask    = (expected_oc_tile == 0) ? 8'hff : 8'h03;

            if (out_pixel_addr !== expected_pixel) begin
                $display("ERROR record=%0d pixel got=%0d expected=%0d",
                         receive_count, out_pixel_addr, expected_pixel);
                errors = errors + 1;
            end
            if (out_oc_base !== (expected_oc_tile * 8)) begin
                $display("ERROR record=%0d oc_base got=%0d expected=%0d",
                         receive_count, out_oc_base, expected_oc_tile * 8);
                errors = errors + 1;
            end
            if (out_channel_mask !== expected_mask[7:0]) begin
                $display("ERROR record=%0d mask got=%02x expected=%02x",
                         receive_count, out_channel_mask, expected_mask);
                errors = errors + 1;
            end

            for (check_lane = 0; check_lane < 8; check_lane = check_lane + 1) begin
                oc = expected_oc_tile * 8 + check_lane;
                got = $signed(out_psum[check_lane*32 +: 32]);
                expected_value = (oc < OUT_CHANNELS) ? expected[expected_pixel][oc] : 0;
                if (got !== expected_value) begin
                    $display("ERROR pixel=%0d oc=%0d got=%0d expected=%0d",
                             expected_pixel, oc, got, expected_value);
                    errors = errors + 1;
                end
                else begin
                    $display("PASS  pixel=%0d oc=%0d value=%0d",
                             expected_pixel, oc, got);
                end
            end
            receive_count = receive_count + 1;
        end
    end

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        start = 1'b0;
        cfg_output_width = OUT_W;
        cfg_output_height = OUT_H;
        cfg_output_pixels = NUM_PIXELS;
        cfg_k_tiles = K_TILES;
        cfg_output_channels = OUT_CHANNELS;
        cfg_kernel_width = 2;
        cfg_kernel_height = 1;
        cfg_channel_blocks = 1;
        receive_count = 0;
        errors = 0;
        completed = 0;

        for (pixel = 0; pixel < NUM_PIXELS; pixel = pixel + 1) begin
            for (oc = 0; oc < OUT_CHANNELS; oc = oc + 1) begin
                expected[pixel][oc] = 0;
                for (kt = 0; kt < K_TILES; kt = kt + 1)
                    for (k = 0; k < 16; k = k + 1)
                        expected[pixel][oc] = expected[pixel][oc] +
                            make_activation(pixel, kt, k) * make_weight(oc, kt, k);
            end
        end

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        wait (receive_count == EXPECTED_RECORDS);
        repeat (3) @(negedge clk);

        if (!completed) begin
            $display("ERROR controller did not assert done");
            errors = errors + 1;
        end
        if (config_error) begin
            $display("ERROR controller asserted config_error");
            errors = errors + 1;
        end

        if (errors != 0)
            $fatal(1, "TEST FAIL: %0d errors", errors);
        tb_passed = 1'b1;
        $display("TEST PASS: layer controller + 2 K tiles + 10 output channels");
        $finish;
    end

    initial begin
        #10000;
        $fatal(1, "TEST TIMEOUT: outputs=%0d/%0d busy=%0b done=%0b",
               receive_count, EXPECTED_RECORDS, busy, done);
    end

endmodule
