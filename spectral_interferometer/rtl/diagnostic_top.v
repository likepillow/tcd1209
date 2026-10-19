`timescale 1ns/1ps
// Initial 5 MHz frontend diagnostic only. No USB pins, DSP or production stream.
// VIO power-up values MUST be run=0, hold_reset=1 (see build_diagnostic.tcl).
module diagnostic_top(
    input wire clk_50mhz,input wire reset_button_n,
    input wire [11:0] ad_data,
    output wire ccd_phi1,ccd_phi2,ccd_sh,ccd_rs,ccd_cp,
    output wire ad_shp,ad_shd,ad_dataclk,ad_clpob,ad_pblk,
    output wire ad_sck,ad_sdata,ad_sl
);
    wire clk,locked,board_reset_n;
    board_clock_reset clocking(.clk_50mhz(clk_50mhz),.reset_button_n(reset_button_n),
        .clk_100mhz(clk),.locked(locked),.system_reset_n(board_reset_n));
    wire run,hold_reset;
    wire release_allowed=board_reset_n && !hold_reset;
    (* ASYNC_REG="TRUE", SHREG_EXTRACT="NO" *) reg [3:0] release_pipe;
    always @(posedge clk or negedge release_allowed)
        if(!release_allowed) release_pipe<=0;
        else release_pipe<={release_pipe[2:0],1'b1};
    wire frontend_reset_n=release_pipe[3];
    wire configured,busy,fault,frame_start,valid,first,last;
    wire [63:0] timestamp;
    wire [11:0] data;
    wire [10:0] index;
    wire [31:0] frame_id;
    wire [12:0] pins;
    ccd_frontend #(.SETTLE_CYCLES(0)) frontend(.clk(clk),.rst_n(frontend_reset_n),.run(run),.adc_data(ad_data),
        .ccd_phi1(pins[12]),.ccd_phi2(pins[11]),.ccd_sh(pins[10]),.ccd_rs(pins[9]),.ccd_cp(pins[8]),
        .ad_shp(pins[7]),.ad_shd(pins[6]),.ad_dataclk(pins[5]),.ad_clpob(pins[4]),.ad_pblk(pins[3]),
        .ad_sck(pins[2]),.ad_sdata(pins[1]),.ad_sl(pins[0]),
        .configure_done(configured),.busy(busy),.fault(fault),.frame_start(frame_start),
        .frame_timestamp(timestamp),.m_valid(valid),.m_data(data),.m_first(first),.m_last(last),
        .m_index(index),.m_frame_id(frame_id));
    // Force defined idle levels even if the system clock stops in reset.
    // Reset intentionally aborts a frame and may truncate an output pulse;
    // it is not the normal graceful-stop command (use run=0 for that).
    wire [12:0] output_pins=frontend_reset_n ? pins : 13'b1000011011001;
    assign {ccd_phi1,ccd_phi2,ccd_sh,ccd_rs,ccd_cp,
            ad_shp,ad_shd,ad_dataclk,ad_clpob,ad_pblk,ad_sck,ad_sdata,ad_sl}=output_pins;
    wire [15:0] status={4'b0,hold_reset,run,board_reset_n,locked,
        frontend_reset_n,configured,busy,fault,frame_start,valid,first,last};
    diagnostic_vio control(.clk(clk),.probe_in0(status),.probe_out0(run),.probe_out1(hold_reset));
    // Storage qualification on probe3[2] (valid) fits four complete 2048-point
    // frames in 8192 samples. Disable qualification for short pin-level traces.
    diagnostic_ila capture(.clk(clk),.probe0(data),.probe1(index),.probe2(frame_id),
        .probe3(status),.probe4(output_pins),.probe5(ad_data),.probe6(timestamp));
endmodule
