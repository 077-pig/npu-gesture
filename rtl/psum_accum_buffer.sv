`timescale 1ns / 1ps

// 对同一输出像素的多个K分块结果进行INT32累加。
// first_k覆盖旧值，last_k输出最终值，因此每次新任务不需要清空整块存储器。
module psum_accum_buffer #(
    parameter integer MAX_OUTPUT_PIXELS = 4096,         //最多支持4096个输出像素
    parameter integer ADDR_WIDTH = 12                   //像素地址宽度
) (
    input  logic                     clk,
    input  logic                     rst_n,

    input  logic                     in_valid,          //当前送进来的部分和是否有效
    input  logic [ADDR_WIDTH-1:0]    in_pixel_addr,     //这个部分和属于哪个输出像素
    input  logic [15:0]              in_oc_tile,        //这是第几组输出通道
    input  logic                     in_first_k,        //是不是当前输出的第一个K分块
    input  logic                     in_last_k,         //是不是当前输出的最后一个K分块
    input  logic                     in_last_pixel,     //是不是整层卷积的最后一个输出像素
    input  logic [7:0]               in_channel_mask,   //8个输出通道哪些有效
    input  logic signed [255:0]      in_psum,           //部分和

    output logic                     out_valid,
    output logic [ADDR_WIDTH-1:0]    out_pixel_addr,
    output logic [15:0]              out_oc_base,       //这组通道的起始编号
    output logic                     out_last_pixel,
    output logic [7:0]               out_channel_mask,
    output logic signed [255:0]      out_psum
);

    logic                  stage_valid;
    logic [ADDR_WIDTH-1:0] stage_pixel_addr;
    logic [15:0]           stage_oc_tile;
    logic                  stage_first_k;
    logic                  stage_last_k;
    logic                  stage_last_pixel;
    logic [7:0]            stage_channel_mask;
    logic signed [255:0]   stage_psum;
    
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            out_valid        <= 1'b0;
            out_pixel_addr   <= '0;
            out_oc_base      <= '0;
            out_last_pixel   <= 1'b0;
            out_channel_mask <= '0;
            stage_valid        <= 1'b0;
            stage_pixel_addr   <= '0;
            stage_oc_tile      <= '0;
            stage_first_k      <= 1'b0;
            stage_last_k       <= 1'b0;
            stage_last_pixel   <= 1'b0;
            stage_channel_mask <= '0;
            stage_psum         <= '0;
        end
        else begin
            out_valid <= 1'b0;
            out_last_pixel <= 1'b0;
            stage_valid        <= in_valid;
            stage_pixel_addr   <= in_pixel_addr;
            stage_oc_tile      <= in_oc_tile;
            stage_first_k      <= in_first_k;
            stage_last_k       <= in_last_k;
            stage_last_pixel   <= in_last_pixel;
            stage_channel_mask <= in_channel_mask;
            stage_psum         <= in_psum;

            if (stage_valid && stage_last_k) begin          //中转站有效，且这是最后一个像素
                out_valid        <= 1'b1;
                out_pixel_addr   <= stage_pixel_addr;
                out_oc_base      <= {stage_oc_tile[12:0], 3'b000};
                out_last_pixel   <= stage_last_pixel;
                out_channel_mask <= stage_channel_mask;
            end
        end
    end
    
    genvar bank;
    generate
        for (bank = 0; bank < 8; bank = bank + 1) begin : PSUM_BANK
            (* ram_style = "block" *)
            logic signed [31:0] mem [0:MAX_OUTPUT_PIXELS-1];                //内存
            logic signed [31:0] read_data;                                  //需要的读取数据
            
            always_ff @ (posedge clk) begin
                if(!rst_n) begin                                            //复位
                    read_data <= 32'sd0;
                    out_psum[bank*32 +: 32] <= 32'sd0;
                end
                else begin
                    if(in_valid)                                            //输入有效
                    read_data <= mem [in_pixel_addr];                       //读取数据
                    
                    if(stage_valid) begin                                   //中转数据有效
                        if(!stage_channel_mask[bank]) begin                 //输入的通道无效
                            if(!stage_last_k)                               //不是最后一个K块
                                mem [stage_pixel_addr] <= 32'sd0;           //说明没有进行到最后计算，内存归零就行
                            if(stage_last_k)                                //是最后一个K块
                                out_psum[bank*32 +: 32] <= 32'sd0;          //进行到了最后计算，最后结果归零
                        end
                        else if(stage_first_k) begin                        //输入的通道有效且是第一个K块
                            if(stage_last_k)                                //且是最后一个K块，说明这次就一个K块
                                out_psum[bank*32 +: 32] <= stage_psum[bank*32 +: 32];               //直接输出，输出为中转的部分和
                            else                                                                    //不是最后一块
                                mem[stage_pixel_addr] <= stage_psum[bank*32 +: 32];                 //那就继续将部分和放在内存里计算
                        end
                        else begin                                                                  //如果是中间的有效通道
                            if(stage_last_k)                                                        //如果是最后一块
                                out_psum[bank*32 +: 32] <= read_data + stage_psum[bank*32 +: 32];   //输出结果是将内存的部分和与这次的相加输出
                            else                                                                    //如果不是最后一块
                                mem[stage_pixel_addr] <= read_data + stage_psum[bank*32 +: 32];     //那就继续放在内存的相加
                        end
                    end
                end 
            end
        end
    endgenerate
    
endmodule