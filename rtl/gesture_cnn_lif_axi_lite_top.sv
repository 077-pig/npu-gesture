`timescale 1ns / 1ps

// 动态手势 CNN+LIF 的独立 AXI4-Lite 顶层。
// 保留原 npu_v2_axi_lite_top（MNIST）不变；本顶层每次启动只处理一帧，
// 软件依次装入 16 帧，并在第 0/15 帧启动时携带 sequence_start/end。
module gesture_cnn_lif_axi_lite_top #(
    parameter integer FEATURE_DEPTH_WORDS = 4096,
    parameter integer FEATURE_ADDR_WIDTH  = 12,
    parameter integer WEIGHT_ADDR_WIDTH   = 13,
    parameter integer WEIGHT_DEPTH_WORDS  = 8192,
    parameter integer QUANT_ADDR_WIDTH    = 10,
    parameter integer FC_INPUT_ADDR_WIDTH = 3,
    parameter integer FC_CLASS_ADDR_WIDTH = 4,
    parameter integer FC_ACC_WIDTH        = 40
) (
    input  logic         s_axi_aclk,
    input  logic         s_axi_aresetn,
    input  logic [11:0]  s_axi_awaddr,
    input  logic         s_axi_awvalid,
    output logic         s_axi_awready,
    input  logic [31:0]  s_axi_wdata,
    input  logic [3:0]   s_axi_wstrb,
    input  logic         s_axi_wvalid,
    output logic         s_axi_wready,
    output logic [1:0]   s_axi_bresp,
    output logic         s_axi_bvalid,
    input  logic         s_axi_bready,
    input  logic [11:0]  s_axi_araddr,
    input  logic         s_axi_arvalid,
    output logic         s_axi_arready,
    output logic [31:0]  s_axi_rdata,
    output logic [1:0]   s_axi_rresp,
    output logic         s_axi_rvalid,
    input  logic         s_axi_rready,
    output logic         irq
);
    // 字地址；软件侧使用字节偏移（例如 A_STATUS 对应 0x04）。
    localparam [9:0] A_CONTROL=10'h000, A_STATUS=10'h001;
    localparam [9:0] A_RESULT=10'h002, A_FRAME_INDEX=10'h003;
    localparam [9:0] A_COUNT_INDEX=10'h004, A_COUNT_DATA=10'h005;
    localparam [9:0] A_LOAD_TARGET=10'h008, A_LOAD_ADDR=10'h009;
    localparam [9:0] A_DATA0=10'h00a, A_DATA1=10'h00b, A_DATA2=10'h00c, A_DATA3=10'h00d;
    localparam [9:0] A_DATA4=10'h00e, A_DATA5=10'h00f, A_DATA6=10'h010, A_DATA7=10'h011;
    localparam [9:0] A_COMMIT=10'h012, A_VERSION=10'h013;

    localparam [7:0] T_FEATURE=0, T_CONV_WEIGHT=1, T_QUANT=2, T_DESC=3;
    localparam [7:0] T_LAYER_PARAM=4, T_FC_WEIGHT=5, T_FC_BIAS=6;

    logic aw_pending, w_pending;
    logic [11:0] awaddr_hold;
    logic [31:0] wdata_hold;
    logic [3:0] wstrb_hold;
    wire wr_fire = aw_pending && w_pending && !s_axi_bvalid;
    wire [9:0] wr_word = awaddr_hold[11:2];
    integer bi;

    logic [7:0] load_target_reg;
    logic [31:0] load_addr_reg;
    logic [31:0] data_reg [0:7];
    logic [3:0] frame_index_reg;
    logic [3:0] count_index_reg;
    logic frame_start_pulse, sequence_start_pulse, sequence_end_pulse;
    logic frame_done_sticky, error_sticky, sequence_done_sticky;
    logic result_valid_sticky, load_reject_sticky;
    logic core_error_d;

    logic core_busy, core_frame_done, core_error, core_sequence_done, core_result_valid;
    logic [3:0] core_result_class;
    logic [175:0] core_spike_counts;
    logic [2:0] active_layer_index;

    logic desc_wr_en; logic [2:0] desc_wr_index; logic [255:0] desc_wr_data;
    logic layer_param_wr_en; logic [2:0] layer_param_wr_index; logic [95:0] layer_param_wr_data;
    logic init_wr_en, init_wr_bank; logic [FEATURE_ADDR_WIDTH-1:0] init_wr_addr;
    logic [127:0] init_wr_data; logic [15:0] init_wr_strb;
    logic conv_weight_wr_en; logic [WEIGHT_ADDR_WIDTH-1:0] conv_weight_wr_addr;
    logic signed [127:0] conv_weight_wr_data;
    logic quant_wr_en; logic [QUANT_ADDR_WIDTH-1:0] quant_wr_addr;
    logic signed [31:0] quant_wr_bias; logic signed [15:0] quant_wr_multiplier;
    logic [5:0] quant_wr_shift;
    logic fc_weight_wr_en; logic [FC_CLASS_ADDR_WIDTH-1:0] fc_weight_wr_class;
    logic [FC_INPUT_ADDR_WIDTH-1:0] fc_weight_wr_word_addr;
    logic [63:0] fc_weight_wr_data;
    logic fc_bias_wr_en; logic [FC_CLASS_ADDR_WIDTH-1:0] fc_bias_wr_class;
    logic signed [31:0] fc_bias_wr_data;

    function automatic [31:0] merge_wstrb(
        input [31:0] oldv, input [31:0] newv, input [3:0] strb
    );
        integer k;
        begin
            merge_wstrb=oldv;
            for(k=0;k<4;k=k+1)
                if(strb[k]) merge_wstrb[k*8 +: 8]=newv[k*8 +: 8];
        end
    endfunction

    assign s_axi_awready = !aw_pending && !s_axi_bvalid;
    assign s_axi_wready  = !w_pending && !s_axi_bvalid;
    assign s_axi_bresp   = 2'b00;
    assign s_axi_arready = !s_axi_rvalid;
    assign s_axi_rresp   = 2'b00;
    assign irq = frame_done_sticky || error_sticky || sequence_done_sticky ||
                 load_reject_sticky;

    always_ff @(posedge s_axi_aclk) begin
        if(!s_axi_aresetn) begin
            aw_pending<=0; w_pending<=0; s_axi_bvalid<=0;
            awaddr_hold<=0; wdata_hold<=0; wstrb_hold<=0;
        end else begin
            if(s_axi_awvalid && s_axi_awready) begin
                aw_pending<=1; awaddr_hold<=s_axi_awaddr;
            end
            if(s_axi_wvalid && s_axi_wready) begin
                w_pending<=1; wdata_hold<=s_axi_wdata; wstrb_hold<=s_axi_wstrb;
            end
            if(wr_fire) begin
                aw_pending<=0; w_pending<=0; s_axi_bvalid<=1;
            end else if(s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid<=0;
            end
        end
    end

    always_ff @(posedge s_axi_aclk) begin
        if(!s_axi_aresetn) begin
            load_target_reg<=0; load_addr_reg<=0; frame_index_reg<=0; count_index_reg<=0;
            frame_start_pulse<=0; sequence_start_pulse<=0; sequence_end_pulse<=0;
            frame_done_sticky<=0; error_sticky<=0; sequence_done_sticky<=0;
            result_valid_sticky<=0; load_reject_sticky<=0; core_error_d<=0;
            desc_wr_en<=0; layer_param_wr_en<=0; init_wr_en<=0;
            conv_weight_wr_en<=0; quant_wr_en<=0; fc_weight_wr_en<=0; fc_bias_wr_en<=0;
            init_wr_bank<=0; init_wr_addr<=0; init_wr_data<=0; init_wr_strb<=0;
            conv_weight_wr_addr<=0; conv_weight_wr_data<=0;
            quant_wr_addr<=0; quant_wr_bias<=0; quant_wr_multiplier<=0; quant_wr_shift<=0;
            desc_wr_index<=0; desc_wr_data<=0; layer_param_wr_index<=0; layer_param_wr_data<=0;
            fc_weight_wr_class<=0; fc_weight_wr_word_addr<=0; fc_weight_wr_data<=0;
            fc_bias_wr_class<=0; fc_bias_wr_data<=0;
            for(bi=0;bi<8;bi=bi+1) data_reg[bi]<=0;
        end else begin
            frame_start_pulse<=0; sequence_start_pulse<=0; sequence_end_pulse<=0;
            desc_wr_en<=0; layer_param_wr_en<=0; init_wr_en<=0;
            conv_weight_wr_en<=0; quant_wr_en<=0; fc_weight_wr_en<=0; fc_bias_wr_en<=0;
            core_error_d<=core_error;

            if(core_frame_done) frame_done_sticky<=1;
            if(core_error && !core_error_d) error_sticky<=1;
            if(core_sequence_done) sequence_done_sticky<=1;
            if(core_result_valid) result_valid_sticky<=1;

            if(wr_fire) begin
                case(wr_word)
                    A_CONTROL: begin
                        // bit0: 启动当前帧；bit1: 清状态；bit2/3: 首帧/末帧。
                        if(wdata_hold[0] && !core_busy) begin
                            frame_start_pulse<=1;
                            sequence_start_pulse<=wdata_hold[2];
                            sequence_end_pulse<=wdata_hold[3];
                            frame_done_sticky<=0;
                        end
                        if(wdata_hold[1]) begin
                            frame_done_sticky<=0; error_sticky<=0;
                            sequence_done_sticky<=0; result_valid_sticky<=0;
                            load_reject_sticky<=0;
                        end
                    end
                    A_FRAME_INDEX: frame_index_reg<=wdata_hold[3:0];
                    A_COUNT_INDEX: count_index_reg<=wdata_hold[3:0];
                    A_LOAD_TARGET: load_target_reg<=wdata_hold[7:0];
                    A_LOAD_ADDR: load_addr_reg<=wdata_hold;
                    A_DATA0,A_DATA1,A_DATA2,A_DATA3,A_DATA4,A_DATA5,A_DATA6,A_DATA7:
                        data_reg[wr_word-A_DATA0] <=
                            merge_wstrb(data_reg[wr_word-A_DATA0],wdata_hold,wstrb_hold);
                    A_COMMIT: begin
                        if(core_busy) begin
                            load_reject_sticky<=1;
                        end else begin
                            case(load_target_reg)
                                T_FEATURE: begin
                                    init_wr_en<=1; init_wr_bank<=1'b0;
                                    init_wr_addr<=load_addr_reg[FEATURE_ADDR_WIDTH-1:0];
                                    init_wr_data<={data_reg[3],data_reg[2],data_reg[1],data_reg[0]};
                                    init_wr_strb<=16'hffff;
                                end
                                T_CONV_WEIGHT: begin
                                    conv_weight_wr_en<=1;
                                    conv_weight_wr_addr<=load_addr_reg[WEIGHT_ADDR_WIDTH-1:0];
                                    conv_weight_wr_data<={data_reg[3],data_reg[2],data_reg[1],data_reg[0]};
                                end
                                T_QUANT: begin
                                    quant_wr_en<=1; quant_wr_addr<=load_addr_reg[QUANT_ADDR_WIDTH-1:0];
                                    quant_wr_bias<=data_reg[0]; quant_wr_multiplier<=data_reg[1][15:0];
                                    quant_wr_shift<=data_reg[1][21:16];
                                end
                                T_DESC: begin
                                    desc_wr_en<=1; desc_wr_index<=load_addr_reg[2:0];
                                    desc_wr_data<={data_reg[7],data_reg[6],data_reg[5],data_reg[4],
                                                  data_reg[3],data_reg[2],data_reg[1],data_reg[0]};
                                end
                                T_LAYER_PARAM: begin
                                    layer_param_wr_en<=1; layer_param_wr_index<=load_addr_reg[2:0];
                                    layer_param_wr_data<={data_reg[2],data_reg[1],data_reg[0]};
                                end
                                T_FC_WEIGHT: begin
                                    fc_weight_wr_en<=1;
                                    fc_weight_wr_class<=load_addr_reg[FC_CLASS_ADDR_WIDTH-1:0];
                                    fc_weight_wr_word_addr<=load_addr_reg[16 +: FC_INPUT_ADDR_WIDTH];
                                    fc_weight_wr_data<={data_reg[1],data_reg[0]};
                                end
                                T_FC_BIAS: begin
                                    fc_bias_wr_en<=1;
                                    fc_bias_wr_class<=load_addr_reg[FC_CLASS_ADDR_WIDTH-1:0];
                                    fc_bias_wr_data<=data_reg[0];
                                end
                                default: load_reject_sticky<=1;
                            endcase
                        end
                    end
                    default: ;
                endcase
            end
        end
    end

    always_ff @(posedge s_axi_aclk) begin
        if(!s_axi_aresetn) begin
            s_axi_rvalid<=0; s_axi_rdata<=0;
        end else begin
            if(s_axi_rvalid && s_axi_rready) s_axi_rvalid<=0;
            if(s_axi_arvalid && s_axi_arready) begin
                s_axi_rvalid<=1;
                case(s_axi_araddr[11:2])
                    A_CONTROL: s_axi_rdata<=0;
                    A_STATUS: s_axi_rdata<={20'd0,active_layer_index,load_reject_sticky,
                        result_valid_sticky,sequence_done_sticky,error_sticky,
                        frame_done_sticky,core_busy,core_result_valid,core_sequence_done};
                    A_RESULT: s_axi_rdata<={28'd0,core_result_class};
                    A_FRAME_INDEX: s_axi_rdata<={28'd0,frame_index_reg};
                    A_COUNT_INDEX: s_axi_rdata<={28'd0,count_index_reg};
                    A_COUNT_DATA: begin
                        if(count_index_reg < 11)
                            s_axi_rdata<={16'd0,core_spike_counts[count_index_reg*16 +: 16]};
                        else
                            s_axi_rdata<=0;
                    end
                    A_LOAD_TARGET: s_axi_rdata<={24'd0,load_target_reg};
                    A_LOAD_ADDR: s_axi_rdata<=load_addr_reg;
                    A_DATA0,A_DATA1,A_DATA2,A_DATA3,A_DATA4,A_DATA5,A_DATA6,A_DATA7:
                        s_axi_rdata<=data_reg[s_axi_araddr[11:2]-A_DATA0];
                    A_VERSION: s_axi_rdata<=32'h0004_0001;
                    default: s_axi_rdata<=0;
                endcase
            end
        end
    end

    gesture_cnn_lif_local_top #(
        .FEATURE_DEPTH_WORDS(FEATURE_DEPTH_WORDS),
        .FEATURE_ADDR_WIDTH(FEATURE_ADDR_WIDTH),
        .WEIGHT_ADDR_WIDTH(WEIGHT_ADDR_WIDTH),
        .WEIGHT_DEPTH_WORDS(WEIGHT_DEPTH_WORDS),
        .QUANT_ADDR_WIDTH(QUANT_ADDR_WIDTH),
        .FC_INPUT_ADDR_WIDTH(FC_INPUT_ADDR_WIDTH),
        .FC_CLASS_ADDR_WIDTH(FC_CLASS_ADDR_WIDTH),
        .FC_ACC_WIDTH(FC_ACC_WIDTH)
    ) u_gesture (
        .clk(s_axi_aclk), .rst_n(s_axi_aresetn),
        .frame_start(frame_start_pulse), .sequence_start(sequence_start_pulse),
        .sequence_end(sequence_end_pulse),
        .desc_wr_en(desc_wr_en), .desc_wr_index(desc_wr_index), .desc_wr_data(desc_wr_data),
        .layer_param_wr_en(layer_param_wr_en), .layer_param_wr_index(layer_param_wr_index),
        .layer_param_wr_data(layer_param_wr_data),
        .init_wr_en(init_wr_en), .init_wr_bank(init_wr_bank), .init_wr_addr(init_wr_addr),
        .init_wr_data(init_wr_data), .init_wr_strb(init_wr_strb),
        .conv_weight_wr_en(conv_weight_wr_en), .conv_weight_wr_addr(conv_weight_wr_addr),
        .conv_weight_wr_data(conv_weight_wr_data),
        .quant_wr_en(quant_wr_en), .quant_wr_addr(quant_wr_addr),
        .quant_wr_bias(quant_wr_bias), .quant_wr_multiplier(quant_wr_multiplier),
        .quant_wr_shift(quant_wr_shift),
        .fc_weight_wr_en(fc_weight_wr_en), .fc_weight_wr_class(fc_weight_wr_class),
        .fc_weight_wr_word_addr(fc_weight_wr_word_addr), .fc_weight_wr_data(fc_weight_wr_data),
        .fc_bias_wr_en(fc_bias_wr_en), .fc_bias_wr_class(fc_bias_wr_class),
        .fc_bias_wr_data(fc_bias_wr_data),
        .busy(core_busy), .frame_done(core_frame_done), .error(core_error),
        .sequence_done(core_sequence_done), .result_valid(core_result_valid),
        .result_class(core_result_class), .spike_counts(core_spike_counts),
        .active_layer_index(active_layer_index)
    );
endmodule
