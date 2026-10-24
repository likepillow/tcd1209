`timescale 1ns/1ps
// Initial 5 MHz bring-up waveform at 100 MHz clk. Not board-qualified.
// AFE clocks run continuously after reset, including startup/idle/SH guards.
// run is synchronous; deassertion stops CCD drive only after the frame tail.
// See docs/frontend_timing.md for the exact pin-edge schedule and assumptions.
module ccd_afe_timing #(
    parameter integer PRE_PIXELS=3,
    parameter integer SH_PIXELS=8,
    parameter integer POST_PIXELS=3,
    parameter integer TAIL_PIXELS=12,
    parameter integer DYNAMIC_PERIOD=0,
    parameter integer FAST_PROFILE=0
)(
    input wire clk,input wire rst_n,input wire run,
    input wire [63:0] period_pixels,
    output reg ccd_phi1,output reg ccd_phi2,output reg ccd_sh,
    output reg ccd_rs,output reg ccd_cp,
    output reg ad_shp,output reg ad_shd,output reg ad_dataclk,
    output reg ad_clpob,output wire ad_pblk,
    output wire launch_ce,output wire tag_valid,
    output wire [10:0] tag_index,output wire [31:0] tag_frame_id,
    output wire busy,output reg frame_start,
    output reg [63:0] frame_timestamp
);
    localparam STOP=0,PRE=1,SHIFT=2,POST=3,READOUT=4,TAIL=5;
    reg [2:0] state;
    reg [4:0] phase;
    reg [63:0] pixel_count;
    reg [31:0] frame_id;
    reg [63:0] ticks;
    reg [63:0] active_tail_pixels;
    localparam integer LAST_PHASE=FAST_PROFILE ? 7 : 19;
    localparam integer PRE_COUNT=FAST_PROFILE ? 8 : PRE_PIXELS;
    localparam integer SH_COUNT=FAST_PROFILE ? 20 : SH_PIXELS;
    localparam integer POST_COUNT=FAST_PROFILE ? 8 : POST_PIXELS;
    wire reading = (state==READOUT);
    // The source tag is sampled on exactly the edge that registers DATACLK
    // high. Do not register this CE again before adc_pixel_align.
    assign launch_ce = rst_n && phase==LAST_PHASE;
    assign tag_valid = reading && pixel_count>=32 && pixel_count<2080;
    assign tag_index = pixel_count-32;
    assign tag_frame_id = frame_id;
    assign busy = state!=STOP;
    // Optional PBLK is unused: its 9-cycle blanking latency must not truncate
    // the separately aligned 10-cycle effective-pixel data pipeline.
    assign ad_pblk = 1'b1;

    always @(posedge clk) begin
        if (!rst_n) begin
            state<=STOP;phase<=0;pixel_count<=0;frame_id<=0;ticks<=0;
            frame_start<=0;frame_timestamp<=0;
            active_tail_pixels<=TAIL_PIXELS;
            ccd_phi1<=1;ccd_phi2<=0;ccd_sh<=0;ccd_rs<=0;ccd_cp<=0;
            ad_shp<=1;ad_shd<=1;ad_dataclk<=0;ad_clpob<=1;
        end else begin
            ticks<=ticks+1'b1;
            frame_start<=0;
            // All external timing outputs are registers, not decoded counter
            // pins. No generated signal is used as an internal logic clock.
            ccd_phi2<=reading && pixel_count!=0 && phase<(FAST_PROFILE ? 4 : 12);
            ccd_phi1<=!(reading && pixel_count!=0 && phase<(FAST_PROFILE ? 4 : 12));
            ccd_sh<=state==SHIFT;
            ccd_rs<=reading && (FAST_PROFILE ? phase==0 : (phase>=2 && phase<5));
            ccd_cp<=reading && (FAST_PROFILE ? phase==2 : (phase>=7 && phase<10));
            ad_shp<=!(FAST_PROFILE ? phase==3 : (phase>=8 && phase<11));
            ad_shd<=!(FAST_PROFILE ? phase==5 : (phase>=16 && phase<18));
            if(phase==LAST_PHASE) ad_dataclk<=1;
            else if(phase==(FAST_PROFILE ? 3 : 9)) ad_dataclk<=0;
            // D13..D28: sixteen genuinely shielded CCD samples, not the
            // adjacent dummy/unspecified pixels. Active-low default polarity.
            ad_clpob<=!(reading && pixel_count>=13 && pixel_count<=28);
            if(state==SHIFT && pixel_count==0 && phase==0) begin
                frame_start<=1;frame_timestamp<=ticks;
                // Latch once per SH interval; no in-flight shortening of tail.
                if(DYNAMIC_PERIOD)
                    active_tail_pixels<=period_pixels-(PRE_COUNT+SH_COUNT+POST_COUNT+2088);
            end

            if (phase==LAST_PHASE) begin
                phase<=0;
                case(state)
                    STOP: begin
                        pixel_count<=0;
                        if(run) state<=PRE;
                    end
                    PRE: begin
                        if(pixel_count==PRE_COUNT-1) begin state<=SHIFT;pixel_count<=0;end
                        else pixel_count<=pixel_count+1'b1;
                    end
                    SHIFT: begin
                        if(pixel_count==SH_COUNT-1) begin state<=POST;pixel_count<=0;end
                        else pixel_count<=pixel_count+1'b1;
                    end
                    POST: begin
                        if(pixel_count==POST_COUNT-1) begin state<=READOUT;pixel_count<=0;end
                        else pixel_count<=pixel_count+1'b1;
                    end
                    READOUT: begin
                        if(pixel_count==2087) begin state<=TAIL;pixel_count<=0;end
                        else pixel_count<=pixel_count+1'b1;
                    end
                    TAIL: begin
                        // Once the complete readout and ADC tail are drained,
                        // a stop need not wait out a potentially hours-long idle tail.
                        if(pixel_count==active_tail_pixels-1 ||
                           (FAST_PROFILE && !run && pixel_count>=TAIL_PIXELS-1)) begin
                            state<=run ? PRE : STOP;pixel_count<=0;frame_id<=frame_id+1'b1;
                        end else pixel_count<=pixel_count+1'b1;
                    end
                    default: begin state<=STOP;pixel_count<=0;end
                endcase
            end else phase<=phase+1'b1;
        end
    end
`ifndef SYNTHESIS
    initial begin
        if(PRE_PIXELS<3 || POST_PIXELS<3 || SH_PIXELS<8 || TAIL_PIXELS<12)
            $fatal(1,"5 MHz profile requires >=600 ns guards, >=1600 ns SH and >=12 tail conversions");
    end
`endif
endmodule
