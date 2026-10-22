`timescale 1ns / 1ps

// 多层卷积顺序调度器。
// 同一个卷积核心反复运行，每完成一层就交换输入/输出bank。

module npu_multilayer_scheduler #(
    parameter integer MAX_LAYERS = 8,
    parameter integer LAYER_INDEX_WIDTH = (MAX_LAYERS <= 1) ? 1 : $clog2(MAX_LAYERS)
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         start,
    input  logic [LAYER_INDEX_WIDTH:0]   layer_count,
    input  logic                         layer_done,
    input  logic                         layer_error,

    output logic                         layer_start,
    output logic                         active,
    output logic                         all_done,
    output logic                         error,
    output logic [LAYER_INDEX_WIDTH-1:0] layer_index,
    output logic                         input_bank,
    output logic                         output_bank
);

     always_ff @(posedge clk) begin
        if (!rst_n) begin
            layer_start <= 1'b0;
            active      <= 1'b0;
            all_done    <= 1'b0;
            error       <= 1'b0;
            layer_index <= '0;
            input_bank  <= 1'b0;
            output_bank <= 1'b1;
        end
        else begin
            layer_start <= 1'b0;
            all_done    <= 1'b0;

            if (!active) begin
                if (start) begin
                    error    <= 1'b0;

                    if ((layer_count == 0) || (layer_count > MAX_LAYERS)) begin
                        active      <= 1'b0;
                        all_done    <= 1'b0;
                        error       <= 1'b1;
                        layer_index <= '0;
                    end
                    else begin
                        active      <= 1'b1;
                        layer_index <= '0;
                        input_bank  <= 1'b0;
                        output_bank <= 1'b1;
                        layer_start <= 1'b1;
                    end
                end
            end
            else if (layer_error) begin
                active   <= 1'b0;
                error    <= 1'b1;
            end
            else if (layer_done) begin
                if ((layer_index + 1'b1) >= layer_count) begin
                    active   <= 1'b0;
                    all_done <= 1'b1;
                    layer_start <= 1'b0;
                end
                else begin
                    layer_index <= layer_index + 1'b1;
                    input_bank  <= ~input_bank;
                    output_bank <= ~output_bank;
                    layer_start <= 1'b1;
                end
            end
        end
    end
endmodule