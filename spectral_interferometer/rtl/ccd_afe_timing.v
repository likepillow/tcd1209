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
    parameter integer DYNAMIC_PERIOD=0
)(
    input wire clk,input wire rst_n,input wire run,
    input wire [12:0] period_pixels,
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
    reg [31:0] pixel_count,frame_id;
    reg [63:0] ticks;
    reg [12:0] active_tail_pixels;
    wire reading = (state==READOUT);
    // The source tag is sampled on exactly the edge that registers DATACLK
    // high. Do not register this CE again before adc_pixel_align.
    assign launch_ce = rst_n && phase==19;
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
            ccd_phi2<=reading && pixel_count!=0 && phase<12;
            ccd_phi1<=!(reading && pixel_count!=0 && phase<12);
            ccd_sh<=state==SHIFT;
            ccd_rs<=reading && phase>=2 && phase<5;
            ccd_cp<=reading && phase>=7 && phase<10;
            ad_shp<=!(phase>=8 && phase<11);
            ad_shd<=!(phase>=16 && phase<18);
            if(phase==19) ad_dataclk<=1;
            else if(phase==9) ad_dataclk<=0;
            // D13..D28: sixteen genuinely shielded CCD samples, not the
            // adjacent dummy/unspecified pixels. Active-low default polarity.
            ad_clpob<=!(reading && pixel_count>=13 && pixel_count<=28);
            if(state==SHIFT && pixel_count==0 && phase==0) begin
                frame_start<=1;frame_timestamp<=ticks;
                // Latch once per SH interval; no in-flight shortening of tail.
                if(DYNAMIC_PERIOD)
                    active_tail_pixels<=period_pixels-(PRE_PIXELS+SH_PIXELS+POST_PIXELS+2088);
            end

            if (phase==19) begin
                phase<=0;
                case(state)
                    STOP: begin
                        pixel_count<=0;
                        if(run) state<=PRE;
                    end
                    PRE: begin
                        if(pixel_count==PRE_PIXELS-1) begin state<=SHIFT;pixel_count<=0;end
                        else pixel_count<=pixel_count+1'b1;
                    end
                    SHIFT: begin
                        if(pixel_count==SH_PIXELS-1) begin state<=POST;pixel_count<=0;end
                        else pixel_count<=pixel_count+1'b1;
                    end
                    POST: begin
                        if(pixel_count==POST_PIXELS-1) begin state<=READOUT;pixel_count<=0;end
                        else pixel_count<=pixel_count+1'b1;
                    end
                    READOUT: begin
                        if(pixel_count==2087) begin state<=TAIL;pixel_count<=0;end
                        else pixel_count<=pixel_count+1'b1;
                    end
                    TAIL: begin
                        if(pixel_count==active_tail_pixels-1) begin
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
