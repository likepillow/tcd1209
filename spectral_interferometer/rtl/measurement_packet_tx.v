`timescale 1ns/1ps
// System-clock RAW/RESULT packet arbitration. Input streams must hold their
// payload and metadata while stalled. RAW comes from a validated frame buffer.
// Reset this module together with its sources and downstream transport session.
module measurement_packet_tx(
    input wire clk,input wire rst_n,
    output wire idle,
    // calibration_control reserves this sequence on control_grant, then emits
    // its complete ACK byte stream. Tie request/valid/last/data low if unused.
    input wire control_request,output wire control_grant,
    output wire [31:0] control_sequence,
    input wire control_valid,output wire control_ready,
    input wire [7:0] control_data,input wire control_last,
    input wire raw_valid,output wire raw_ready,input wire [11:0] raw_data,
    input wire raw_first,input wire [31:0] raw_frame_id,
    input wire raw_timestamp_valid,input wire [63:0] raw_timestamp,
    input wire spectrum_valid,output wire spectrum_ready,input wire spectrum_first,
    input wire [11:0] spectrum_s0,input wire [23:0] spectrum_s1,input wire signed [24:0] spectrum_s2,
    input wire [31:0] spectrum_frame_id,input wire [31:0] spectrum_source_version,
    input wire spectrum_timestamp_valid,input wire [63:0] spectrum_timestamp,
    input wire result_valid,output wire result_ready,
    input wire signed [83:0] result_accumulator,input wire signed [15:0] result_exponent,
    input wire [9:0] result_peak,input wire [9:0] result_left,input wire [9:0] result_right,
    input wire result_invalid,input wire [31:0] result_frame_id,
    input wire [31:0] result_source_version,input wire [31:0] result_k_version,
    input wire result_timestamp_valid,input wire [63:0] result_timestamp,
    input wire [31:0] dropped_frames,input wire [31:0] malformed_frames,
    output wire m_valid,input wire m_ready,output wire [7:0] m_data,output wire m_last
);
    wire [3:0] request,grant,valid,ready,last;
    wire [31:0] data;
    wire [31:0] sequence_number;
    wire result_available;
    assign request[2]=control_request;
    assign control_grant=grant[2];
    assign control_sequence=sequence_number;
    assign valid[2]=control_valid;
    assign data[23:16]=control_data;
    assign last[2]=control_last;
    assign control_ready=ready[2];
    reg have_result;
    reg [31:0] previous_result_frame;
    wire result_gap=have_result && result_frame_id!=previous_result_frame+32'd1;
    assign request[1]=result_valid && result_available;
    assign result_ready=grant[1] && result_available;
    always @(posedge clk) begin
        if(!rst_n) begin have_result<=0;previous_result_frame<=0;end
        else if(result_valid && result_ready) begin
            have_result<=1;previous_result_frame<=result_frame_id;
        end
    end
    raw_stream_packet_tx raw_packet(.clk(clk),.rst_n(rst_n),
        .s_valid(raw_valid),.s_ready(raw_ready),.s_data(raw_data),.s_first(raw_first),.s_frame_id(raw_frame_id),
        .timestamp_valid(raw_timestamp_valid),.timestamp(raw_timestamp),
        .request(request[0]),.grant(grant[0]),.packet_sequence(sequence_number),
        .m_valid(valid[0]),.m_ready(ready[0]),.m_data(data[7:0]),.m_last(last[0]));
    result_packet_tx result_packet(.clk(clk),.rst_n(rst_n),
        .s_valid(result_valid && grant[1]),.s_ready(result_available),
        .accumulator(result_accumulator),.exponent(result_exponent),
        .peak(result_peak),.left_bin(result_left),.right_bin(result_right),
        .dropped_frames(dropped_frames),.malformed_frames(malformed_frames),
        .invalid(result_invalid),.discontinuity(result_gap),
        .timestamp_valid(result_timestamp_valid),.timestamp(result_timestamp),
        .frame_id(result_frame_id),.packet_sequence(sequence_number),
        .source_version(result_source_version),.k_version(result_k_version),
        .m_valid(valid[1]),.m_ready(ready[1]),.m_data(data[15:8]),.m_last(last[1]));
    spectrum_stream_packet_tx spectrum_packet(.clk(clk),.rst_n(rst_n),
        .s_valid(spectrum_valid),.s_ready(spectrum_ready),.s_first(spectrum_first),
        .s0(spectrum_s0),.s1(spectrum_s1),.s2(spectrum_s2),
        .frame_id(spectrum_frame_id),.source_version(spectrum_source_version),
        .timestamp_valid(spectrum_timestamp_valid),.timestamp(spectrum_timestamp),
        .request(request[3]),.grant(grant[3]),.packet_sequence(sequence_number),
        .m_valid(valid[3]),.m_ready(ready[3]),.m_data(data[31:24]),.m_last(last[3]));
    packet_scheduler #(.CHANNELS(4)) scheduler(.clk(clk),.rst_n(rst_n),
        .idle(idle),
        .request(request),.grant(grant),.packet_sequence(sequence_number),
        .s_valid(valid),.s_ready(ready),.s_data(data),.s_last(last),
        .m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_last(m_last));
endmodule
