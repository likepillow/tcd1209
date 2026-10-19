`timescale 1ns/1ps
// 100 MHz synchronous frontend, initial 5 MHz CCD profile. Board clock/reset,
// pin constraints, ILA and USB are outside this module.
module ccd_frontend #(
    parameter integer POWERUP_CYCLES=200000,
    // 100 ms at 100 MHz; observed working on replacement hardware, not a
    // characterized minimum. Zero is for diagnostic observation of startup.
    parameter integer SETTLE_CYCLES=10000000,
    parameter integer DYNAMIC_PERIOD=0,
    // Compile-time diagnostic option; retain the deployed 20 ns default.
    parameter integer ADC_CAPTURE_DELAY=2
)(
    input wire clk,input wire rst_n,input wire run,
    input wire [12:0] period_pixels,
    input wire [11:0] adc_data,
    output wire ccd_phi1,output wire ccd_phi2,output wire ccd_sh,
    output wire ccd_rs,output wire ccd_cp,
    output wire ad_shp,output wire ad_shd,output wire ad_dataclk,
    output wire ad_clpob,output wire ad_pblk,
    output wire ad_sck,output wire ad_sdata,output wire ad_sl,
    output wire configure_done,output wire busy,output wire fault,
    output wire frame_start,output wire [63:0] frame_timestamp,
    output wire m_valid,output wire [11:0] m_data,
    output wire m_first,output wire m_last,
    output wire [10:0] m_index,output wire [31:0] m_frame_id
);
    wire launch_ce,tag_valid;
    wire [10:0] tag_index;
    wire [31:0] tag_frame_id;
    wire aligned_valid;
    ccd_startup_guard #(.SETTLE_CYCLES(SETTLE_CYCLES)) settling(
        .clk(clk),.rst_n(rst_n),.busy(busy),.frame_start(frame_start),
        .s_valid(aligned_valid),.m_valid(m_valid));
    ad9945_init #(.POWERUP_CYCLES(POWERUP_CYCLES)) startup(
        .clk(clk),.rst_n(rst_n),.ad_sck(ad_sck),.ad_sdata(ad_sdata),
        .ad_sl(ad_sl),.configure_done(configure_done));
    ccd_afe_timing #(.DYNAMIC_PERIOD(DYNAMIC_PERIOD)) timing(.clk(clk),.rst_n(rst_n),.run(run && configure_done && !fault),
        .period_pixels(period_pixels),
        .ccd_phi1(ccd_phi1),.ccd_phi2(ccd_phi2),.ccd_sh(ccd_sh),.ccd_rs(ccd_rs),.ccd_cp(ccd_cp),
        .ad_shp(ad_shp),.ad_shd(ad_shd),.ad_dataclk(ad_dataclk),.ad_clpob(ad_clpob),.ad_pblk(ad_pblk),
        .launch_ce(launch_ce),.tag_valid(tag_valid),.tag_index(tag_index),.tag_frame_id(tag_frame_id),
        .busy(busy),.frame_start(frame_start),.frame_timestamp(frame_timestamp));
    adc_pixel_align #(.CAPTURE_DELAY(ADC_CAPTURE_DELAY)) alignment(.clk(clk),.rst_n(rst_n && configure_done),
        .launch_ce(launch_ce),.tag_valid(tag_valid),.tag_index(tag_index),.tag_frame_id(tag_frame_id),
        .adc_data(adc_data),.m_valid(aligned_valid),.m_data(m_data),.m_first(m_first),.m_last(m_last),
        .m_index(m_index),.m_frame_id(m_frame_id),.fault(fault));
endmodule

// Continue physical CCD/AFE clocking while suppressing whole startup frames.
// busy stays high through a frame even after run falls. Re-arm on actual idle,
// not on run, so stopping never truncates a published frame.
module ccd_startup_guard #(parameter integer SETTLE_CYCLES=10000000)(
    input wire clk,input wire rst_n,input wire busy,input wire frame_start,
    input wire s_valid,output wire m_valid
);
    generate if (SETTLE_CYCLES == 0) begin : diagnostic_bypass
        assign m_valid=s_valid;
    end else begin : enabled
        localparam integer CW=$clog2(SETTLE_CYCLES+1);
        reg [CW-1:0] elapsed;
        reg publish_frame;
        assign m_valid=s_valid && publish_frame;
        always @(posedge clk) begin
            if (!rst_n || !busy) begin elapsed<=0;publish_frame<=0;end
            else begin
                if (elapsed < SETTLE_CYCLES) elapsed<=elapsed+1'b1;
                if (frame_start) publish_frame<=(elapsed >= SETTLE_CYCLES);
            end
        end
    end endgenerate
endmodule
