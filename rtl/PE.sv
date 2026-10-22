`timescale 1ns/1ps

//单个权重驻留PE：每周期完成一次 INT8  ×  INT8  +  INT32
//数据寄存器使用同步复位，便于vivado将MAC映射到DSP48E1

module PE (
    input logic         clk,            //时钟信号
    input logic         rst_n,          //复位清零，低电平有效
    input logic         compute_en,     //使能信号，是否允许本拍计算
    
    input logic         load_shadow_wt, //把权重放入备用抽屉
    input logic         swap_wt,        //将备用权重转移到主权重
    input logic signed[7:0] in_weight,  //准备装入的8位权重
    
    input logic signed[7:0] in_act,     //当前输入激活值
    input logic signed[31:0] in_pusm,   //传入的部分和
    output logic signed[7:0] out_act,   //传给右边的激活值
    
    output logic signed[31:0] out_pusm  //传给下面的新部分和
);

    logic signed[7:0] weight_reg;       //权重寄存器
    logic signed[7:0] shadow_weight_reg;//备用权重寄存器
    
    (* use_dsp = "yes" *)
    logic signed[31:0] mac_value;
    
    always_comb begin
        mac_value = $signed(in_pusm) + 
                    ($signed(in_act) * $signed(weight_reg));    //真正核心
    end
    
    always_ff @(posedge clk) begin
        if(!rst_n) begin
            weight_reg <= '0;
            shadow_weight_reg <= '0;
            out_act <= '0;
            out_pusm <= '0;
        end
    else begin
        if(swap_wt)
            weight_reg <= shadow_weight_reg;
        else if(load_shadow_wt) 
            shadow_weight_reg <= in_weight;
        
        if(compute_en) begin
            out_act <= in_act;
            out_pusm <= mac_value;
        end
    end
    end
    
endmodule