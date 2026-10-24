`timescale 1ns/1ps
// Integration boundary for board clock/reset and verified flag polarity.
// Uses the currently qualified 5-MHz frontend for initial hardware bring-up;
// this is not a claim that the final high-speed CCD profile is qualified.
module instrument_frontend_usb #(
    parameter integer ADC_CAPTURE_DELAY=2,
    parameter integer FAST_PROFILE=0
)(
    input wire clk,input wire ifclk,input wire rst_n,input wire if_rst,
    input wire run,input wire [11:0] ad_data,
    output wire ccd_phi1,ccd_phi2,ccd_sh,ccd_rs,ccd_cp,
    output wire ad_shp,ad_shd,ad_dataclk,ad_clpob,ad_pblk,
    output wire ad_sck,ad_sdata,ad_sl,
    input wire ep2_has_data,input wire ep6_has_space,
    inout wire [15:0] fd,output wire [1:0] fifo_addr,
    output wire slrd_n,slwr_n,sloe_n,pktend_n,slcs_n,
    output wire configured,output wire afe_configured,output wire fault,output wire receive_error,
    output wire [31:0] dropped_frames,malformed_frames,
    output wire [31:0] busy_skipped_frames,rate_skipped_frames
);
    wire s_valid,s_first,s_last;
    wire [11:0] s_data;wire [31:0] s_frame_id;wire [63:0] s_timestamp;
    wire frontend_fault,core_fault,transport_fault;
    wire tx_valid,tx_ready,tx_last,rx_valid,rx_ready;
    wire [7:0] tx_data,rx_data;
    wire [12:0] pins;
    wire acquisition_stop,frontend_busy;
    wire [63:0] active_period;
    assign fault=frontend_fault || core_fault || transport_fault;
    ccd_frontend #(.DYNAMIC_PERIOD(1),.ADC_CAPTURE_DELAY(ADC_CAPTURE_DELAY),.FAST_PROFILE(FAST_PROFILE)) frontend(.clk(clk),.rst_n(rst_n),.run(run && !fault && !acquisition_stop),.adc_data(ad_data),
        .period_pixels(active_period),
        .ccd_phi1(pins[12]),.ccd_phi2(pins[11]),.ccd_sh(pins[10]),.ccd_rs(pins[9]),.ccd_cp(pins[8]),
        .ad_shp(pins[7]),.ad_shd(pins[6]),.ad_dataclk(pins[5]),.ad_clpob(pins[4]),.ad_pblk(pins[3]),
        .ad_sck(pins[2]),.ad_sdata(pins[1]),.ad_sl(pins[0]),
        .configure_done(afe_configured),.busy(frontend_busy),.fault(frontend_fault),.frame_start(),.frame_timestamp(s_timestamp),
        .m_valid(s_valid),.m_data(s_data),.m_first(s_first),.m_last(s_last),.m_index(),.m_frame_id(s_frame_id));
    assign {ccd_phi1,ccd_phi2,ccd_sh,ccd_rs,ccd_cp,ad_shp,ad_shd,ad_dataclk,
            ad_clpob,ad_pblk,ad_sck,ad_sdata,ad_sl}=rst_n ? pins : 13'b1000011011001;
    instrument_core #(.RUNTIME_ACQUISITION(1),.FAST_PROFILE(FAST_PROFILE)) core(.*,.fault(core_fault));
    // About 64 KiB of encoded traffic absorb bounded host scheduling/disk pauses.
    fx2_transport #(.TX_DEPTH(FAST_PROFILE ? 32768 : 1024)) transport(.sys_clk(clk),.ifclk(ifclk),.sys_rst(!rst_n),.if_rst(if_rst),
        .tx_valid(tx_valid),.tx_ready(tx_ready),.tx_data(tx_data),.tx_last(tx_last),
        .rx_valid(rx_valid),.rx_ready(rx_ready),.rx_data(rx_data),.fault(transport_fault),
        .ep2_has_data(ep2_has_data),.ep6_has_space(ep6_has_space),
        .fd(fd),.fifo_addr(fifo_addr),.slrd_n(slrd_n),.slwr_n(slwr_n),
        .sloe_n(sloe_n),.pktend_n(pktend_n),.slcs_n(slcs_n));
endmodule
