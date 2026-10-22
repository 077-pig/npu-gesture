`timescale 1ns / 1ps

// 可配置INT8全连接分类器。
//
// 数据组织：
//   每个输入/权重word包含8个INT8元素，低8位是第0个元素；
//   FC每拍完成8次INT8乘法并累加；
//   一个类别完成后立即比较argmax，再处理下一个类别。
//
// 配置：
//   cfg_input_length：输入特征数，允许不是8的倍数，最后一个word自动屏蔽；
//   cfg_class_count：类别数，可配置为5、10或更大值；
//   bias/weight/input均通过本地装载口写入，后续可直接接AXI/DMA。
//
// 该版本输出原始INT32/ACC_WIDTH分类分数并在PL内完成argmax，
// 不需要将每个类别的分数搬回PS。
module fc_classifier_8lane #(
    parameter integer MAX_INPUT_LENGTH = 4096,
    parameter integer MAX_CLASSES      = 256,
    parameter integer ACC_WIDTH        = 40,
    parameter integer MAX_INPUT_WORDS  = (MAX_INPUT_LENGTH + 7) / 8,
    parameter integer INPUT_WORD_ADDR_WIDTH =
        (MAX_INPUT_WORDS <= 1) ? 1 : $clog2(MAX_INPUT_WORDS),
    parameter integer CLASS_ADDR_WIDTH =
        (MAX_CLASSES <= 1) ? 1 : $clog2(MAX_CLASSES)
) (
    input  logic                         clk,
    input  logic                         rst_n,

    input  logic                         input_wr_en,
    input  logic [INPUT_WORD_ADDR_WIDTH-1:0] input_wr_word_addr,
    input  logic [63:0]                  input_wr_data,

    input  logic                         weight_wr_en,
    input  logic [CLASS_ADDR_WIDTH-1:0]  weight_wr_class,
    input  logic [INPUT_WORD_ADDR_WIDTH-1:0] weight_wr_word_addr,
    input  logic [63:0]                  weight_wr_data,

    input  logic                         bias_wr_en,
    input  logic [CLASS_ADDR_WIDTH-1:0]  bias_wr_class,
    input  logic signed [31:0]           bias_wr_data,

    input  logic                         start,
    input  logic [15:0]                  cfg_input_length,
    input  logic [15:0]                  cfg_class_count,

    output logic                         busy,
    output logic                         done,
    output logic                         config_error,
    output logic                         result_valid,
    output logic [CLASS_ADDR_WIDTH-1:0]  result_class,
    output logic signed [ACC_WIDTH-1:0]  result_score,
    // 每个类别计算完成时给出原始score，供调试/逐层验证；板级可不连接。
    output logic                         class_score_valid,
    output logic [CLASS_ADDR_WIDTH-1:0]  class_score_index,
    output logic signed [ACC_WIDTH-1:0]  class_score
);

    // 权重RAM采用同步读。S_READ发出地址，下一拍进入S_COMPUTE使用返回数据。
    // 这样可让8192x64权重存储稳定推断为Block RAM，避免8192项异步
    // 多路选择器和大量RAM64M占用LUT。
    typedef enum logic [1:0] {S_IDLE, S_READ, S_COMPUTE} state_t;
    state_t state;

    (* ram_style = "block" *) logic [63:0] input_mem [0:MAX_INPUT_WORDS-1];
    (* ram_style = "block" *) logic [63:0] weight_mem [0:MAX_CLASSES*MAX_INPUT_WORDS-1];
    (* ram_style = "block" *) logic signed [31:0] bias_mem [0:MAX_CLASSES-1];

    logic [15:0] input_length_reg;
    logic [15:0] class_count_reg;
    logic [15:0] words_per_class_reg;
    logic [CLASS_ADDR_WIDTH-1:0] class_index;
    logic [INPUT_WORD_ADDR_WIDTH-1:0] word_index;
    logic signed [ACC_WIDTH-1:0] accumulator;
    logic signed [ACC_WIDTH-1:0] best_score;
    logic best_valid;

    logic [63:0] current_input_word;
    logic [63:0] current_weight_word;
    // 强制 Vivado 优先将 8x8 乘法映射到 DSP48；若器件/综合策略不支持，
    // 工具仍可回退到 LUT，功能不受影响。
    (* use_dsp = "yes" *) logic signed [15:0] lane_product [0:7];
    logic signed [ACC_WIDTH-1:0] lane_sum;
    logic signed [ACC_WIDTH-1:0] score_next;
    integer lane;
    integer element_index;

    assign busy = (state != S_IDLE);

    always_comb begin
        current_input_word  = '0;
        lane_sum = '0;
        for (lane = 0; lane < 8; lane = lane + 1)
            lane_product[lane] = '0;

        if ((word_index < MAX_INPUT_WORDS) &&
            (class_index < MAX_CLASSES)) begin
            current_input_word = input_mem[word_index];
        end

        for (lane = 0; lane < 8; lane = lane + 1) begin
            element_index = word_index * 8 + lane;
            if (element_index < input_length_reg) begin
                lane_product[lane] =
                    $signed(current_input_word[lane*8 +: 8]) *
                    $signed(current_weight_word[lane*8 +: 8]);
                lane_sum = lane_sum + lane_product[lane];
            end
        end

        score_next = accumulator + lane_sum;
    end

    integer reset_index;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state          <= S_IDLE;
            done           <= 1'b0;
            config_error   <= 1'b0;
            result_valid   <= 1'b0;
            result_class   <= '0;
            result_score   <= '0;
            class_score_valid <= 1'b0;
            class_score_index <= '0;
            class_score <= '0;
            input_length_reg <= '0;
            class_count_reg  <= '0;
            words_per_class_reg <= '0;
            class_index     <= '0;
            word_index      <= '0;
            accumulator     <= '0;
            best_score      <= '0;
            best_valid      <= 1'b0;
            current_weight_word <= '0;
            for (reset_index = 0; reset_index < MAX_CLASSES; reset_index = reset_index + 1)
                bias_mem[reset_index] <= '0;
        end
        else begin
            done         <= 1'b0;
            result_valid <= 1'b0;
            class_score_valid <= 1'b0;

            // 权重、Bias和输入只允许在空闲时装载，避免运行中修改模型。
            if (!busy) begin
                if (input_wr_en && (input_wr_word_addr < MAX_INPUT_WORDS))
                    input_mem[input_wr_word_addr] <= input_wr_data;
                if (weight_wr_en && (weight_wr_class < MAX_CLASSES) &&
                    (weight_wr_word_addr < MAX_INPUT_WORDS))
                    weight_mem[weight_wr_class * MAX_INPUT_WORDS + weight_wr_word_addr]
                        <= weight_wr_data;
                if (bias_wr_en && (bias_wr_class < MAX_CLASSES))
                    bias_mem[bias_wr_class] <= bias_wr_data;
            end

            case (state)
                S_IDLE: begin
                    if (start) begin
                        config_error <= 1'b0;
                        if ((cfg_input_length == 0) ||
                            (cfg_input_length > MAX_INPUT_LENGTH) ||
                            (cfg_class_count == 0) ||
                            (cfg_class_count > MAX_CLASSES)) begin
                            config_error <= 1'b1;
                            done <= 1'b1;
                        end
                        else begin
                            input_length_reg <= cfg_input_length;
                            class_count_reg <= cfg_class_count;
                            // 每个word承载8个元素，向上取整：ceil(length/8)。
                            // 例如 length=16 -> 2，length=10 -> 2，length=1 -> 1。
                            words_per_class_reg <= (cfg_input_length + 7) >> 3;
                            class_index <= '0;
                            word_index <= '0;
                            accumulator <= $signed(bias_mem[0]);
                            best_score <= '0;
                            best_valid <= 1'b0;
                            state <= S_READ;
                        end
                    end
                end

                S_READ: begin
                    // 标准同步RAM读模板：地址在本拍被采样，数据下一拍可用。
                    if ((word_index < MAX_INPUT_WORDS) &&
                        (class_index < MAX_CLASSES))
                        current_weight_word <=
                            weight_mem[class_index * MAX_INPUT_WORDS + word_index];
                    else
                        current_weight_word <= '0;
                    state <= S_COMPUTE;
                end

                S_COMPUTE: begin
                    if (word_index == (words_per_class_reg - 1)) begin
                        class_score_valid <= 1'b1;
                        class_score_index <= class_index;
                        class_score <= score_next;
                        // 当前类别最后一个word，score_next包含本拍乘加结果。
                        if (!best_valid || (score_next > best_score)) begin
                            best_score <= score_next;
                            best_valid <= 1'b1;
                            result_class <= class_index;
                            result_score <= score_next;
                        end

                        if (class_index == (class_count_reg - 1)) begin
                            // 最后一个类别完成，argmax结果在本拍有效。
                            if (!best_valid || (score_next > best_score)) begin
                                result_class <= class_index;
                                result_score <= score_next;
                            end
                            result_valid <= 1'b1;
                            done <= 1'b1;
                            state <= S_IDLE;
                        end
                        else begin
                            class_index <= class_index + 1'b1;
                            word_index <= '0;
                            accumulator <= $signed(bias_mem[class_index + 1'b1]);
                            state <= S_READ;
                        end
                    end
                    else begin
                        word_index <= word_index + 1'b1;
                        accumulator <= score_next;
                        state <= S_READ;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
