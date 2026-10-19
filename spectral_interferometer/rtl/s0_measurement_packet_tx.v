`timescale 1ns/1ps
// S0-only production export boundary. RAW input never stalls for USB; complete
// selected frames are buffered before packet arbitration. RESULT remains
// lossless/backpressurable: downstream must sustain its per-frame rate.
// S1/S2 and phase monitor outputs of acquisition_core must be consumed separately.
module s0_measurement_packet_tx(
    output wire idle,
    input wire clk,input wire rst_n,input wire [31:0] period_frames,
    input wire control_request,output wire control_grant,
    output wire [31:0] control_sequence,
    input wire control_valid,output wire control_ready,
    input wire [7:0] control_data,input wire control_last,
    input wire raw_valid,output wire raw_ready,input wire [11:0] raw_data,
    input wire raw_first,input wire raw_last,input wire [31:0] raw_frame_id,
    input wire raw_timestamp_valid,input wire [63:0] raw_timestamp,
    input wire result_valid,output wire result_ready,
    input wire signed [83:0] result_accumulator,input wire signed [15:0] result_exponent,
    input wire [9:0] result_peak,input wire [9:0] result_left,input wire [9:0] result_right,
    input wire result_invalid,input wire [31:0] result_frame_id,
    input wire [31:0] result_source_version,input wire [31:0] result_k_version,
    input wire result_timestamp_valid,input wire [63:0] result_timestamp,
    input wire [31:0] dropped_frames,input wire [31:0] malformed_frames,
    output wire export_fault,output wire [31:0] busy_skipped_frames,
    output wire [31:0] rate_skipped_frames,
    output wire m_valid,input wire m_ready,output wire [7:0] m_data,output wire m_last
);
    wire buffered_valid,buffered_ready,buffered_first;
    wire buffer_idle,packet_idle;
    assign idle=buffer_idle && packet_idle;
    wire [11:0] buffered_data;
    wire [31:0] buffered_frame_id;wire [63:0] buffered_timestamp;
    s0_export_buffer export_buffer(.clk(clk),.rst_n(rst_n),.period_frames(period_frames),
        .idle(buffer_idle),
        .s_valid(raw_valid),.s_ready(raw_ready),.s_data(raw_data),
        .s_first(raw_first),.s_last(raw_last),.s_frame_id(raw_frame_id),.s_timestamp(raw_timestamp),
        .m_valid(buffered_valid),.m_ready(buffered_ready),.m_data(buffered_data),
        .m_first(buffered_first),.m_last(),.m_frame_id(buffered_frame_id),.m_timestamp(buffered_timestamp),
        .fault(export_fault),.busy_skipped_frames(busy_skipped_frames),.rate_skipped_frames(rate_skipped_frames));
    measurement_packet_tx packetizer(.clk(clk),.rst_n(rst_n),
        .idle(packet_idle),
        .control_request(control_request),.control_grant(control_grant),.control_sequence(control_sequence),
        .control_valid(control_valid),.control_ready(control_ready),.control_data(control_data),.control_last(control_last),
        .raw_valid(buffered_valid),.raw_ready(buffered_ready),.raw_data(buffered_data),
        .raw_first(buffered_first),.raw_frame_id(buffered_frame_id),
        .raw_timestamp_valid(raw_timestamp_valid),.raw_timestamp(buffered_timestamp),
        .spectrum_valid(1'b0),.spectrum_ready(),.spectrum_first(1'b0),
        .spectrum_s0(12'b0),.spectrum_s1(24'b0),.spectrum_s2(25'b0),
        .spectrum_frame_id(32'b0),.spectrum_source_version(32'b0),
        .spectrum_timestamp_valid(1'b0),.spectrum_timestamp(64'b0),
        .result_valid(result_valid),.result_ready(result_ready),
        .result_accumulator(result_accumulator),.result_exponent(result_exponent),
        .result_peak(result_peak),.result_left(result_left),.result_right(result_right),
        .result_invalid(result_invalid),.result_frame_id(result_frame_id),
        .result_source_version(result_source_version),.result_k_version(result_k_version),
        .result_timestamp_valid(result_timestamp_valid),.result_timestamp(result_timestamp),
        .dropped_frames(dropped_frames),.malformed_frames(malformed_frames),
        .m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_last(m_last));
endmodule
