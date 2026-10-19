`timescale 1ns/1ps
// Non-backpressurable 2048-effective-pixel stream -> two cropped banks -> DSP.
// s_valid is a system-clock enable, not an asynchronous ADC clock.
module acquisition_core #(parameter DYNAMIC_WINDOW=0)(
    input wire clk,input wire rst_n,
    input wire [10:0] capture_first,
    output wire idle,
    input wire source_begin,input wire source_we,input wire source_commit,
    input wire [9:0] source_addr,input wire [30:0] source_gain,
    output wire source_ack,output wire source_error,
    input wire k_begin,input wire k_we,input wire k_commit,
    input wire [8:0] k_addr,input wire signed [31:0] k_weight,
    input wire signed [15:0] k_exponent,
    output wire k_ack,output wire k_error,
    output wire configured,output wire fault,
    output wire [31:0] active_source_version,output wire [31:0] active_k_version,
    input wire s_valid,input wire [11:0] s_data,input wire s_first,input wire s_last,
    input wire [31:0] s_frame_id,input wire [63:0] s_timestamp,
    output wire [31:0] dropped_frames,output wire [31:0] malformed_frames,
    output wire raw_valid,input wire raw_ready,output wire [11:0] raw_data,
    output wire raw_first,output wire raw_last,output wire [31:0] raw_frame_id,output wire [63:0] raw_timestamp,
    output wire spectrum_valid,input wire spectrum_ready,
    output wire [11:0] spectrum_s0,output wire [23:0] spectrum_s1,
    output wire signed [24:0] spectrum_s2,
    output wire spectrum_first,output wire spectrum_last,
    output wire [31:0] spectrum_frame_id,output wire [31:0] spectrum_source_version,
    output wire phase_valid,input wire phase_ready,
    output wire signed [42:0] phase_data,output wire [9:0] phase_index,
    output wire phase_last,output wire phase_invalid,output wire [31:0] phase_frame_id,
    output wire result_valid,input wire result_ready,
    output wire signed [83:0] result_accumulator,
    output wire signed [15:0] result_exponent,
    output wire [31:0] result_frame_id,output wire [31:0] result_k_version,
    output wire [31:0] result_source_version,output wire result_invalid,output wire [63:0] result_timestamp,
    output wire [9:0] result_peak,output wire [9:0] result_left,output wire [9:0] result_right
);
    wire b_valid,b_ready,b_first,b_last;
    wire [11:0] b_data;
    wire [31:0] b_frame_id;wire [63:0] b_timestamp;
    wire fork_ready,process_valid,process_ready;
    reg routing,process_frame;
    wire capture_idle;
    reg [3:0] processing_frames;
    wire processing_start=process_valid && process_ready && process_frame && b_first;
    wire processing_end=result_valid && result_ready;
    always @(posedge clk) begin
        if(!rst_n) processing_frames<=0;
        else case({processing_start,processing_end})
            2'b10:processing_frames<=processing_frames+1'b1;
            2'b01:processing_frames<=processing_frames-1'b1;
        endcase
    end
    assign idle=capture_idle && !routing && processing_frames==0 && !result_valid;
    assign b_ready=routing && fork_ready;
    assign raw_data=b_data;assign raw_first=b_first;assign raw_last=b_last;assign raw_frame_id=b_frame_id;assign raw_timestamp=b_timestamp;
    // Decide once before exposing the first beat to either consumer. A K/S
    // upload while the raw consumer stalls cannot enable only half a frame.
    always @(posedge clk) begin
        if(!rst_n) begin routing<=0;process_frame<=0;end
        else if(!routing && b_valid) begin routing<=1;process_frame<=configured && !fault;end
        else if(b_valid && b_ready && b_last) routing<=0;
    end
    stream_fork_control raw_fork(.clk(clk),.rst_n(rst_n),.s_valid(b_valid && routing),.s_ready(fork_ready),
        .a_valid(process_valid),.a_ready(!process_frame || process_ready),.b_valid(raw_valid),.b_ready(raw_ready));
    frame_ping_pong #(.WIDTH(12),.CAPTURE_DEPTH(2048),.CAPTURE_FIRST(512),.DYNAMIC_WINDOW(DYNAMIC_WINDOW)) capture(
        .capture_first(capture_first),
        .idle(capture_idle),
        .clk(clk),.rst_n(rst_n),.s_valid(s_valid),.s_first(s_first),.s_last(s_last),.s_data(s_data),.s_frame_id(s_frame_id),.s_timestamp(s_timestamp),
        .m_valid(b_valid),.m_ready(b_ready),.m_data(b_data),.m_first(b_first),.m_last(b_last),.m_frame_id(b_frame_id),.m_timestamp(b_timestamp),
        .dropped_frames(dropped_frames),.malformed_frames(malformed_frames));
    spectral_processor processor(.clk(clk),.rst_n(rst_n),
        .source_begin(source_begin),.source_we(source_we),.source_commit(source_commit),.source_addr(source_addr),.source_gain(source_gain),
        .source_ack(source_ack),.source_error(source_error),
        .k_begin(k_begin),.k_we(k_we),.k_commit(k_commit),.k_addr(k_addr),.k_weight(k_weight),.k_exponent(k_exponent),.k_ack(k_ack),.k_error(k_error),
        .configured(configured),.fault(fault),
        .active_source_version(active_source_version),.active_k_version(active_k_version),
        .s_valid(process_valid && process_frame),.s_ready(process_ready),.s_data(b_data),.s_first(b_first),.s_last(b_last),.s_frame_id(b_frame_id),.s_timestamp(b_timestamp),
        .spectrum_valid(spectrum_valid),.spectrum_ready(spectrum_ready),.spectrum_s0(spectrum_s0),.spectrum_s1(spectrum_s1),.spectrum_s2(spectrum_s2),
        .spectrum_first(spectrum_first),.spectrum_last(spectrum_last),.spectrum_frame_id(spectrum_frame_id),.spectrum_source_version(spectrum_source_version),
        .phase_valid(phase_valid),.phase_ready(phase_ready),.phase_data(phase_data),.phase_index(phase_index),.phase_last(phase_last),.phase_invalid(phase_invalid),.phase_frame_id(phase_frame_id),
        .result_valid(result_valid),.result_ready(result_ready),.result_accumulator(result_accumulator),.result_exponent(result_exponent),
        .result_frame_id(result_frame_id),.result_k_version(result_k_version),.result_source_version(result_source_version),.result_invalid(result_invalid),.result_timestamp(result_timestamp),
        .result_peak(result_peak),.result_left(result_left),.result_right(result_right));
endmodule
