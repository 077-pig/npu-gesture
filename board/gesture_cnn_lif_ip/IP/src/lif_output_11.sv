`timescale 1ns / 1ps

// 11类输出层：FC整数累加结果 -> current量化 -> LIF膜电位更新。
// 复用一套乘法/舍入/膜电位单元，每类四拍完成流水计算。
// 序列末帧再逐类扫描脉冲计数，避免把膜电位更新和最大值比较串成一条长路径。
module lif_output_11 #(
    parameter integer CLASS_COUNT=11, SCORE_WIDTH=40, MEMBRANE_WIDTH=32,
    parameter integer MULTIPLIER=11759, SHIFT=20, THRESHOLD_Q=40
) (
    input logic clk, rst_n, sequence_start, current_valid, sequence_end,
    input logic signed [CLASS_COUNT*SCORE_WIDTH-1:0] in_score,
    output logic processing_busy, spike_valid,
    output logic [CLASS_COUNT-1:0] spikes,
    output logic sequence_done, result_valid,
    output logic [$clog2(CLASS_COUNT)-1:0] result_class,
    output logic [CLASS_COUNT*16-1:0] spike_counts
);
    localparam integer PRODUCT_WIDTH=SCORE_WIDTH+16;
    localparam integer CLASS_INDEX_WIDTH=(CLASS_COUNT<=1)?1:$clog2(CLASS_COUNT);
    logic signed [MEMBRANE_WIDTH-1:0] membrane [0:CLASS_COUNT-1];
    logic [15:0] count_reg [0:CLASS_COUNT-1];
    logic signed [CLASS_COUNT*SCORE_WIDTH-1:0] score_latched;
    logic sequence_start_latched, sequence_end_latched;
    logic [CLASS_INDEX_WIDTH-1:0] class_index, scan_index, best_class;
    logic [15:0] best_count;
    logic scan_active;
    logic [1:0] update_phase;
    logic [CLASS_COUNT-1:0] spikes_work;
    logic signed [SCORE_WIDTH-1:0] selected_score;
    logic signed [PRODUCT_WIDTH-1:0] score_product;
    logic signed [PRODUCT_WIDTH-1:0] product_reg, current_q_wide;
    logic signed [MEMBRANE_WIDTH-1:0] current_q_reg, base_membrane_reg;
    logic signed [MEMBRANE_WIDTH-1:0] updated_membrane_reg, stored_membrane;
    logic [15:0] base_count_reg, stored_count;
    logic stored_spike;
    integer reset_i;

    function automatic logic signed [PRODUCT_WIDTH-1:0] round_shift_even(
        input logic signed [PRODUCT_WIDTH-1:0] value);
        logic signed [PRODUCT_WIDTH-1:0] magnitude, rounded;
        logic [PRODUCT_WIDTH-1:0] remainder;
        logic sign_bit;
        begin
            sign_bit=value[PRODUCT_WIDTH-1]; magnitude=sign_bit?-value:value;
            rounded=magnitude>>>SHIFT;
            remainder=magnitude&(({{(PRODUCT_WIDTH-1){1'b0}},1'b1}<<SHIFT)-1'b1);
            if((remainder>({{(PRODUCT_WIDTH-1){1'b0}},1'b1}<<(SHIFT-1)))||
               ((remainder==({{(PRODUCT_WIDTH-1){1'b0}},1'b1}<<(SHIFT-1)))&&rounded[0]))
                rounded=rounded+1'b1;
            round_shift_even=sign_bit?-rounded:rounded;
        end
    endfunction

    function automatic logic signed [MEMBRANE_WIDTH-1:0] half_even(
        input logic signed [MEMBRANE_WIDTH-1:0] value);
        logic signed [MEMBRANE_WIDTH-1:0] q;
        begin q=value>>>1; if(value[0]&&q[0]) q=q+1'b1; half_even=q; end
    endfunction

    always_comb begin
        selected_score=$signed(score_latched[class_index*SCORE_WIDTH+:SCORE_WIDTH]);
        score_product=selected_score*MULTIPLIER;
        current_q_wide=round_shift_even(product_reg);
        stored_spike=(updated_membrane_reg>=THRESHOLD_Q);
        if(stored_spike) begin
            stored_membrane=updated_membrane_reg-THRESHOLD_Q;
            stored_count=base_count_reg+16'd1;
        end else begin
            stored_membrane=updated_membrane_reg; stored_count=base_count_reg;
        end
    end

    always_ff @(posedge clk) begin
        if(!rst_n) begin
            processing_busy<=0; spike_valid<=0; spikes<='0; sequence_done<=0;
            result_valid<=0; result_class<='0; spike_counts<='0; score_latched<='0;
            sequence_start_latched<=0; sequence_end_latched<=0; class_index<='0;
            scan_index<='0; best_count<='0; best_class<='0; scan_active<=0;
            update_phase<='0; product_reg<='0; current_q_reg<='0;
            base_membrane_reg<='0; base_count_reg<='0;
            updated_membrane_reg<='0; spikes_work<='0;
            for(reset_i=0;reset_i<CLASS_COUNT;reset_i=reset_i+1) begin
                membrane[reset_i]<='0; count_reg[reset_i]<='0;
            end
        end else begin
            spike_valid<=0; sequence_done<=0; result_valid<=0;
            if(scan_active) begin
                if(scan_index==0) begin
                    best_count<=count_reg[0];
                    best_class<='0;
                    scan_index<=scan_index+1'b1;
                end else begin
                    if(count_reg[scan_index]>best_count) begin
                        best_count<=count_reg[scan_index];
                        best_class<=scan_index;
                    end
                    if(scan_index==CLASS_COUNT-1) begin
                        scan_active<=0;
                        processing_busy<=0;
                        spike_valid<=1;
                        spikes<=spikes_work;
                        sequence_done<=1;
                        result_valid<=1;
                        result_class<=(count_reg[scan_index]>best_count)?scan_index:best_class;
                    end else scan_index<=scan_index+1'b1;
                end
            end else if(!processing_busy) begin
                if(current_valid) begin
                    score_latched<=in_score; sequence_start_latched<=sequence_start;
                    sequence_end_latched<=sequence_end; class_index<='0;
                    scan_index<='0; best_count<='0; best_class<='0;
                    update_phase<='0; spikes_work<='0; processing_busy<=1;
                end else if(sequence_start) begin
                    spike_counts<='0;
                    for(reset_i=0;reset_i<CLASS_COUNT;reset_i=reset_i+1) begin
                        membrane[reset_i]<='0; count_reg[reset_i]<='0;
                    end
                end
            end else begin
                case(update_phase)
                    2'd0: begin
                        product_reg<=score_product;
                        update_phase<=2'd1;
                    end
                    2'd1: begin
                        current_q_reg<=current_q_wide[MEMBRANE_WIDTH-1:0];
                        base_membrane_reg<=sequence_start_latched?'0:membrane[class_index];
                        base_count_reg<=sequence_start_latched?16'd0:count_reg[class_index];
                        update_phase<=2'd2;
                    end
                    2'd2: begin
                        updated_membrane_reg<=half_even(base_membrane_reg)+current_q_reg;
                        update_phase<=2'd3;
                    end
                    default: begin
                        membrane[class_index]<=stored_membrane;
                        count_reg[class_index]<=stored_count;
                        spike_counts[class_index*16+:16]<=stored_count;
                        spikes_work[class_index]<=stored_spike;
                        update_phase<='0;
                        if(class_index==CLASS_COUNT-1) begin
                            if(sequence_end_latched) begin
                                scan_active<=1;
                                scan_index<='0;
                            end else begin
                                processing_busy<=0;
                                spike_valid<=1;
                                spikes<=spikes_work|({{(CLASS_COUNT-1){1'b0}},stored_spike}<<class_index);
                            end
                        end else class_index<=class_index+1'b1;
                    end
                endcase
            end
        end
    end
endmodule
