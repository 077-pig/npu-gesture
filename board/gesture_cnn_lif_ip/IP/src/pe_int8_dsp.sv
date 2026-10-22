`timescale 1ns / 1ps

// 单个权重驻留PE：每周期完成一次 INT8 × INT8 + INT32。
// 数据寄存器使用同步复位，便于Vivado将MAC映射到DSP48E1。
module pe_int8_dsp (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               compute_en,

    input  logic               load_shadow_wt,
    input  logic               swap_wt,
    input  logic signed [7:0]  in_weight,

    input  logic signed [7:0]  in_act,
    input  logic signed [31:0] in_psum,
    output logic signed [7:0]  out_act,
    output logic signed [31:0] out_psum
);

    logic signed [7:0] weight_reg;
    logic signed [7:0] shadow_weight_reg;

    // 该属性是综合提示，最终DSP数量必须以Vivado报告为准。
    (* use_dsp = "yes" *)
    logic signed [31:0] mac_value;

    always_comb begin
        mac_value = $signed(in_psum) +
                    ($signed(in_act) * $signed(weight_reg));
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            weight_reg        <= '0;
            shadow_weight_reg <= '0;
            out_act           <= '0;
            out_psum          <= '0;
        end
        else begin
            if (swap_wt)
                weight_reg <= shadow_weight_reg;
            else if (load_shadow_wt)
                shadow_weight_reg <= in_weight;

            if (compute_en) begin
                out_act  <= in_act;
                out_psum <= mac_value;
            end
        end
    end

endmodule
