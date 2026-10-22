`timescale 1ns / 1ps

// 将fc_classifier_8lane串行给出的11个类别分数打包为一个向量。
module fc_score_collector_11 #(
    parameter integer CLASS_COUNT = 11,
    parameter integer SCORE_WIDTH = 40,
    parameter integer CLASS_INDEX_WIDTH = (CLASS_COUNT <= 1) ? 1 : $clog2(CLASS_COUNT)
) (
    input logic clk,
    input logic rst_n,
    input logic clear,
    input logic class_score_valid,
    input logic [CLASS_INDEX_WIDTH-1:0] class_score_index,
    input logic signed [SCORE_WIDTH-1:0] class_score,
    output logic scores_valid,
    output logic signed [CLASS_COUNT*SCORE_WIDTH-1:0] scores
);
    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            scores_valid <= 1'b0;
            scores <= '0;
        end else begin
            scores_valid <= 1'b0;
            if (class_score_valid && (class_score_index < CLASS_COUNT)) begin
                scores[class_score_index*SCORE_WIDTH +: SCORE_WIDTH] <= class_score;
                if (class_score_index == CLASS_COUNT-1)
                    scores_valid <= 1'b1;
            end
        end
    end
endmodule
