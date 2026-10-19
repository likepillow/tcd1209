`timescale 1ns/1ps
// AD9945 metadata pipeline and delayed, synchronous parallel-bus capture.
// launch_ce marks the system edge that launches a RISING DATACLK at the pin.
// It must occur for EVERY conversion, including dummy and blanking samples.
// tag_valid identifies effective CCD pixels, indexed 0..2047 (before cropping).
// ADC output at launch N represents sample N-PIPELINE_CYCLES. Capture happens
// CAPTURE_DELAY system clocks later, not on the DATACLK launch edge itself.
// Defaults: 100 MHz system clock, 20 ns capture offset, 10 conversion latency.
// This module does not prove analog settling or board I/O timing closure.
module adc_pixel_align #(
    parameter integer PIPELINE_CYCLES = 10,
    parameter integer CAPTURE_DELAY = 2
)(
    input wire clk, input wire rst_n,
    input wire launch_ce,
    input wire tag_valid,
    input wire [10:0] tag_index,
    input wire [31:0] tag_frame_id,
    input wire [11:0] adc_data,
    output reg m_valid,
    output reg [11:0] m_data,
    output reg m_first, output reg m_last,
    output reg [10:0] m_index,
    output reg [31:0] m_frame_id,
    output reg fault
);
    localparam integer COUNT_WIDTH = (CAPTURE_DELAY < 2) ? 1 : $clog2(CAPTURE_DELAY+1);
    reg [PIPELINE_CYCLES-1:0] valid_pipe;
    reg [10:0] index_pipe [0:PIPELINE_CYCLES-1];
    reg [31:0] frame_pipe [0:PIPELINE_CYCLES-1];
    reg pending, pending_valid;
    reg [10:0] pending_index;
    reg [31:0] pending_frame;
    reg [COUNT_WIDTH-1:0] remaining;
    integer i;

    // Fail closed on overlapping conversions. Even invalid/dummy conversions
    // own a capture slot; missing/too-close DATACLK strobes must not silently
    // change which physical ADC sample a pixel marker refers to.
    always @(posedge clk) begin
        if (!rst_n) begin
            valid_pipe <= 0;
            for (i=0; i<PIPELINE_CYCLES; i=i+1) begin
                index_pipe[i] <= 0; frame_pipe[i] <= 0;
            end
            pending <= 0; pending_valid <= 0; pending_index <= 0;
            pending_frame <= 0; remaining <= 0;
            m_valid <= 0; m_data <= 0; m_first <= 0; m_last <= 0;
            m_index <= 0; m_frame_id <= 0; fault <= 0;
        end else begin
            m_valid <= 0; m_first <= 0; m_last <= 0;
            if (!fault) begin
                if (launch_ce && pending) begin
                    fault <= 1; pending <= 0; pending_valid <= 0;
                    valid_pipe <= 0;
                end else begin
                    if (pending) begin
                        if (remaining == 1) begin
                            pending <= 0;
                            m_valid <= pending_valid;
                            if (pending_valid) begin
                                m_data <= adc_data;
                                m_index <= pending_index;
                                m_frame_id <= pending_frame;
                                m_first <= (pending_index == 0);
                                m_last <= (pending_index == 2047);
                            end
                        end else remaining <= remaining - 1'b1;
                    end
                    if (launch_ce) begin
                        pending <= 1;
                        remaining <= CAPTURE_DELAY;
                        pending_valid <= valid_pipe[PIPELINE_CYCLES-1];
                        pending_index <= index_pipe[PIPELINE_CYCLES-1];
                        pending_frame <= frame_pipe[PIPELINE_CYCLES-1];
                        for (i=PIPELINE_CYCLES-1; i>0; i=i-1) begin
                            valid_pipe[i] <= valid_pipe[i-1];
                            index_pipe[i] <= index_pipe[i-1];
                            frame_pipe[i] <= frame_pipe[i-1];
                        end
                        valid_pipe[0] <= tag_valid;
                        index_pipe[0] <= tag_index;
                        frame_pipe[0] <= tag_frame_id;
                    end
                end
            end
        end
    end
`ifndef SYNTHESIS
    initial begin
        if (PIPELINE_CYCLES < 1 || CAPTURE_DELAY < 1)
            $fatal(1, "adc_pixel_align requires positive pipeline and capture delay");
    end
`endif
endmodule
