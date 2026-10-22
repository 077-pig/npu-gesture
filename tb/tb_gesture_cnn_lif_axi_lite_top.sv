`timescale 1ns/1ps
module tb_gesture_cnn_lif_axi_lite_top;
    bit tb_passed = 1'b0;
    logic s_axi_aclk=0,s_axi_aresetn=0;
    logic [11:0] s_axi_awaddr=0,s_axi_araddr=0; logic s_axi_awvalid=0,s_axi_wvalid=0;
    logic s_axi_awready,s_axi_wready; logic [31:0] s_axi_wdata=0; logic [3:0] s_axi_wstrb=4'hf;
    logic [1:0] s_axi_bresp,s_axi_rresp; logic s_axi_bvalid,s_axi_bready=1;
    logic s_axi_arvalid=0,s_axi_arready; logic [31:0] s_axi_rdata; logic s_axi_rvalid,s_axi_rready=1,irq;
    logic [31:0] rd;
    always #5 s_axi_aclk=~s_axi_aclk;
    gesture_cnn_lif_axi_lite_top #(.FEATURE_DEPTH_WORDS(64),.FEATURE_ADDR_WIDTH(6),
        .WEIGHT_ADDR_WIDTH(6),.WEIGHT_DEPTH_WORDS(64),.QUANT_ADDR_WIDTH(6)) dut(.*);
    task axi_write(input [11:0] addr,input [31:0] data);
        begin
            @(negedge s_axi_aclk); s_axi_awaddr=addr; s_axi_awvalid=1; s_axi_wdata=data; s_axi_wvalid=1;
            while(!(s_axi_awready&&s_axi_wready)) @(negedge s_axi_aclk);
            @(negedge s_axi_aclk); s_axi_awvalid=0; s_axi_wvalid=0;
            wait(s_axi_bvalid); @(negedge s_axi_aclk);
            if(s_axi_bresp!==0) $fatal(1,"AXI write response error");
        end
    endtask
    task axi_read(input [11:0] addr,output [31:0] data);
        begin
            @(negedge s_axi_aclk); s_axi_araddr=addr; s_axi_arvalid=1;
            while(!s_axi_arready) @(negedge s_axi_aclk);
            @(negedge s_axi_aclk); s_axi_arvalid=0;
            wait(s_axi_rvalid); data=s_axi_rdata;
            @(negedge s_axi_aclk);
            if(s_axi_rresp!==0) $fatal(1,"AXI read response error");
        end
    endtask
    initial begin
        repeat(3) @(negedge s_axi_aclk); s_axi_aresetn=1;
        axi_read(12'h04c,rd); if(rd!==32'h0004_0001) $fatal(1,"version mismatch %h",rd);
        axi_write(12'h00c,32'h0000_000a); axi_read(12'h00c,rd);
        if(rd!==10) $fatal(1,"frame index readback mismatch");
        axi_write(12'h020,32'h0000_00ff); axi_write(12'h048,1);
        axi_read(12'h004,rd);
        if(!rd[7] || !irq) $fatal(1,"invalid target did not set sticky status/irq");
        axi_write(12'h000,32'h2); axi_read(12'h004,rd);
        if(rd[7] || irq) $fatal(1,"status clear failed");
        tb_passed = 1'b1;
        $display("TEST PASS: gesture_cnn_lif_axi_lite_top"); $finish;
    end
    initial begin #20000; $fatal(1,"TEST TIMEOUT: gesture_cnn_lif_axi_lite_top"); end
endmodule
