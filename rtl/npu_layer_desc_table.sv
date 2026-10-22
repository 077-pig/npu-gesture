`timescale 1ns / 1ps

module npu_layer_desc_table #(
    parameter integer MAX_LAYERS = 8,
    parameter integer DESC_WIDTH = 256,
    parameter integer INDEX_WIDTH = (MAX_LAYERS <= 1) ? 1 : $clog2(MAX_LAYERS)
) (
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic                    wr_en,
    input  logic [INDEX_WIDTH-1:0]  wr_index,
    input  logic [DESC_WIDTH-1:0]   wr_data,
    input  logic [INDEX_WIDTH-1:0]  rd_index,
    output logic [DESC_WIDTH-1:0]   rd_data
);

    logic [DESC_WIDTH-1:0] desc_mem [0:MAX_LAYERS-1];
    integer i;
    
    always_comb begin
        if(rd_index < MAX_LAYERS)
            rd_data = desc_mem[rd_index];
        else
            rd_data = '0;
    end
    
    always_ff @(posedge clk) begin
        if(!rst_n) begin
            for(i = 0;i < MAX_LAYERS; i = i + 1)
                desc_mem[i] <= '0;
        end
        else if(wr_en && (wr_index < MAX_LAYERS)) begin
            desc_mem[wr_index] <= wr_data;
        end
    end
    
endmodule