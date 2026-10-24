`timescale 1ns/1ps
// Board bring-up top. Reuses diagnostic_vio: power-up run=0, hold_reset=1.
// IFCLK firmware must match USB_IFCLK_MHZ: E3=48 MHz or A3=30 MHz.
// Default flag polarity assumes active-low EP2 empty and EP6 full indications;
// verify FIFOPINPOLAR against the installed image before enabling transfers.
module instrument_board_top #(
    parameter FLAGB_EMPTY_ACTIVE_LOW=1,parameter FLAGC_FULL_ACTIVE_LOW=1,
    parameter integer USB_IFCLK_MHZ=48,
    parameter integer AUTO_START=0,
    parameter integer ADC_CAPTURE_DELAY=2,
    parameter integer FAST_PROFILE=0
)(
    input wire clk_50mhz,input wire reset_button_n,input wire [11:0] ad_data,
    output wire ccd_phi1,ccd_phi2,ccd_sh,ccd_rs,ccd_cp,
    output wire ad_shp,ad_shd,ad_dataclk,ad_clpob,ad_pblk,ad_sck,ad_sdata,ad_sl,
    input wire usb_ifclk,input wire usb_flaga,input wire usb_flagb,input wire usb_flagc,
    inout wire [15:0] usb_fd,output wire [1:0] usb_fifo_addr,
    output wire usb_slrd_n,usb_slwr_n,usb_sloe_n,usb_pktend_n,usb_slcs_n,
    output wire [7:0] user_led
);
    wire clk,locked,board_reset_n,ifclk_raw,ifclk;
    wire usb_clock_raw,usb_feedback_raw,usb_feedback,usb_locked;
    board_clock_reset board_clocks(.clk_50mhz(clk_50mhz),.reset_button_n(reset_button_n),
        .clk_100mhz(clk),.locked(locked),.system_reset_n(board_reset_n));
    IBUF usb_clock_input(.I(usb_ifclk),.O(ifclk_raw));
    // Firmware must match: E3=48 MHz, A3=30 MHz. Both use 960 MHz VCO.
    localparam real USB_MULT = USB_IFCLK_MHZ==30 ? 32.0 : 20.0;
    MMCME2_BASE #(.CLKIN1_PERIOD(1000.0/USB_IFCLK_MHZ),.CLKFBOUT_MULT_F(USB_MULT),
        .DIVCLK_DIVIDE(1),.CLKOUT0_DIVIDE_F(USB_MULT),.CLKOUT0_PHASE(0.0),
        .BANDWIDTH("OPTIMIZED"),.STARTUP_WAIT("FALSE")) usb_clock_manager(
        .CLKIN1(ifclk_raw),.CLKFBIN(usb_feedback),.CLKFBOUT(usb_feedback_raw),
        .CLKOUT0(usb_clock_raw),.LOCKED(usb_locked),
        .RST(!reset_button_n),.PWRDWN(1'b0));
    BUFG usb_feedback_buffer(.I(usb_feedback_raw),.O(usb_feedback));
    BUFG usb_clock_buffer(.I(usb_clock_raw),.O(ifclk));
    wire run,hold_reset,clock_qualified;
    generate if (AUTO_START) begin : autonomous
        usb_clock_qualifier clock_guard(.clk(clk),.reset_n(board_reset_n),
            .ifclk(ifclk_raw),.qualified(clock_qualified));
        assign run=1'b1;
        assign hold_reset=1'b0;
    end else begin : manual
        assign clock_qualified=1'b1;
    end endgenerate
    wire release_allowed=board_reset_n && usb_locked && clock_qualified && !hold_reset;
    (* ASYNC_REG="TRUE", SHREG_EXTRACT="NO" *) reg [15:0] sys_release,usb_release;
    always @(posedge clk or negedge release_allowed)
        if(!release_allowed) sys_release<=0;
        else sys_release<={sys_release[14:0],1'b1};
    always @(posedge ifclk or negedge release_allowed)
        if(!release_allowed) usb_release<=0;
        else usb_release<={usb_release[14:0],1'b1};
    wire rst_n=sys_release[15];
    wire if_rst=!usb_release[15];
    wire configured,afe_configured,fault,receive_error;
    wire [31:0] dropped_frames,malformed_frames,busy_skipped_frames,rate_skipped_frames;
    wire ep2_has_data=FLAGB_EMPTY_ACTIVE_LOW ? usb_flagb : !usb_flagb;
    wire ep6_has_space=FLAGC_FULL_ACTIVE_LOW ? usb_flagc : !usb_flagc;
    // D0..D7 are active-high. No heartbeat/PWM light during optical measurements.
    assign user_led=8'b0;
    instrument_frontend_usb #(.ADC_CAPTURE_DELAY(ADC_CAPTURE_DELAY),.FAST_PROFILE(FAST_PROFILE)) instrument(.*,
        .fd(usb_fd),.fifo_addr(usb_fifo_addr),.slrd_n(usb_slrd_n),.slwr_n(usb_slwr_n),
        .sloe_n(usb_sloe_n),.pktend_n(usb_pktend_n),.slcs_n(usb_slcs_n));
    // Only synchronized IFCLK-domain indicators enter the system-domain VIO.
    (* ASYNC_REG="TRUE" *) reg [3:0] usb_status_meta,usb_status_sync;
    always @(posedge clk) begin
        usb_status_meta<={usb_release[15],usb_flaga,usb_flagb,usb_flagc};
        usb_status_sync<=usb_status_meta;
    end
    wire [15:0] status={usb_status_sync,hold_reset,run,board_reset_n,locked,
        rst_n,configured,fault,receive_error,|dropped_frames,|malformed_frames,
        |busy_skipped_frames,afe_configured};
    generate if (!AUTO_START) begin : debug_control
        diagnostic_vio control(.clk(clk),.probe_in0(status),.probe_out0(run),.probe_out1(hold_reset));
    end endgenerate
endmodule
