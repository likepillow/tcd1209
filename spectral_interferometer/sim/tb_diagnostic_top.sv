`timescale 1ns/1ps
// VIO/ILA functional substitutes test top-level control, not debug-core internals.
// Actual vendor debug cores are separately synthesized/routed by Vivado.
module diagnostic_vio(input wire clk,input wire [15:0] probe_in0,
    output reg probe_out0=0,output reg probe_out1=1);
endmodule
module diagnostic_ila(input wire clk,input wire [11:0] probe0,
    input wire [10:0] probe1,input wire [31:0] probe2,input wire [15:0] probe3,
    input wire [12:0] probe4,input wire [11:0] probe5,input wire [63:0] probe6);
endmodule
module tb_diagnostic_top;
    reg clk_50mhz=0; always #10 clk_50mhz=~clk_50mhz;
    reg reset_button_n=0;
    reg [11:0] ad_data=12'h5a3;
    wire ccd_phi1,ccd_phi2,ccd_sh,ccd_rs,ccd_cp;
    wire ad_shp,ad_shd,ad_dataclk,ad_clpob,ad_pblk,ad_sck,ad_sdata,ad_sl;
    diagnostic_top dut(.*);
    wire [12:0] pins={ccd_phi1,ccd_phi2,ccd_sh,ccd_rs,ccd_cp,
        ad_shp,ad_shd,ad_dataclk,ad_clpob,ad_pblk,ad_sck,ad_sdata,ad_sl};
    task check_idle;
        begin
            if(pins!==13'b1000011011001) $fatal(1,"reset output pin levels wrong: %b",pins);
            if(dut.frontend_reset_n!==0) $fatal(1,"frontend escaped reset");
        end
    endtask
    integer pixel_count=0;
    always @(posedge dut.clk) if(dut.frontend_reset_n && dut.valid) begin
        if(dut.data!==12'h5a3) $fatal(1,"ADC data misconnected");
        pixel_count=pixel_count+1;
    end
    initial begin
        #200; check_idle(); reset_button_n=1;
        wait(dut.board_reset_n);
        repeat(500) @(posedge dut.clk);
        #1; check_idle();
        // Release hold, but no run request: AFE config/clock may run; CCD may not.
        @(negedge dut.clk);dut.control.probe_out1=0;
        wait(dut.configured);
        repeat(1000) @(posedge dut.clk);
        if(dut.busy!==0 || pixel_count!=0) $fatal(1,"capture started without run");
        @(negedge dut.clk);dut.control.probe_out0=1;
        wait(pixel_count>=8);
        // Abort explicitly, including immediate pin clamps between clock edges.
        @(negedge dut.clk);dut.control.probe_out1=1;
        #0.01;check_idle();
        repeat(10) @(posedge dut.clk);
        @(negedge dut.clk);dut.control.probe_out0=0;dut.control.probe_out1=0;
        wait(dut.frontend_reset_n);
        #2;reset_button_n=0;
        #0.01;check_idle();
        #200;check_idle();reset_button_n=1;
        wait(dut.frontend_reset_n);
        if(!dut.locked || !dut.board_reset_n) $fatal(1,"unsafe reset release");
        $display("PASS: diagnostic top held startup, gated run, ADC wiring, VIO abort, button clock-loss clamp/relock; debug cores modeled");
        $finish;
    end
    initial begin #4000000; $fatal(1,"diagnostic top timeout"); end
endmodule
