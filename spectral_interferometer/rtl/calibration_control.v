`timescale 1ns/1ps
// System-clock control plane. Connect rx bytes from usb_rx_bridge, tx bytes to
// a packet-aware outbound scheduler. Reset must include the calibration cores.
// packet_sequence must be reserved for this packet when sequence_take pulses;
// this module does not allocate a global sequence or arbitrate measurement data.
module calibration_control #(parameter FAST_PROFILE=0)(
    input wire clk,input wire rst_n,
    input wire rx_valid,output wire rx_ready,input wire [7:0] rx_data,
    output wire tx_valid,input wire tx_ready,output wire [7:0] tx_data,output wire tx_last,
    output wire tx_request,input wire tx_grant,
    input wire [31:0] packet_sequence,output wire sequence_take,output wire receive_error,
    input wire [31:0] source_version,input wire [31:0] k_version,
    output wire source_begin,output wire source_we,output wire source_commit,
    output wire [9:0] source_addr,output wire [30:0] source_gain,
    input wire source_ack,input wire source_error,
    output wire k_begin,output wire k_we,output wire k_commit,
    output wire [8:0] k_addr,output wire signed [31:0] k_weight,
    output wire signed [15:0] k_exponent,input wire k_ack,input wire k_error,
    output wire [31:0] export_period_frames,
    output wire acquisition_request,input wire acquisition_ack,
    output wire [10:0] requested_window,
    output wire [63:0] requested_period,
    output wire [31:0] requested_result_stride,
    output wire run_request,input wire run_ack,output wire requested_run
);
    wire cmd_valid,cmd_ready,payload_valid,payload_ready,payload_last;
    wire [7:0] cmd_kind,payload_data;
    wire [31:0] cmd_sequence;
    wire ack_valid,ack_ready;
    wire response_ready;
    wire [31:0] ack_sequence;
    wire [15:0] ack_status;
    assign sequence_take=ack_valid && ack_ready;
    assign tx_request=ack_valid && response_ready;
    assign ack_ready=response_ready && tx_grant;
    config_packet_rx receiver(.clk(clk),.rst_n(rst_n),.abort(1'b0),
        .s_valid(rx_valid),.s_ready(rx_ready),.s_data(rx_data),
        .cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_kind(cmd_kind),.cmd_sequence(cmd_sequence),.cmd_length(),
        .m_valid(payload_valid),.m_ready(payload_ready),.m_data(payload_data),.m_last(payload_last),.error(receive_error));
    calibration_loader #(.FAST_PROFILE(FAST_PROFILE)) loader(.clk(clk),.rst_n(rst_n),
        .acquisition_request(acquisition_request),.acquisition_ack(acquisition_ack),
        .requested_window(requested_window),.requested_period(requested_period),
        .requested_result_stride(requested_result_stride),
        .run_request(run_request),.run_ack(run_ack),.requested_run(requested_run),
        .export_period_frames(export_period_frames),
        .cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_kind(cmd_kind),.cmd_sequence(cmd_sequence),
        .s_valid(payload_valid),.s_ready(payload_ready),.s_data(payload_data),.s_last(payload_last),
        .source_begin(source_begin),.source_we(source_we),.source_commit(source_commit),
        .source_addr(source_addr),.source_gain(source_gain),.source_ack(source_ack),.source_error(source_error),
        .k_begin(k_begin),.k_we(k_we),.k_commit(k_commit),.k_addr(k_addr),.k_weight(k_weight),
        .k_exponent(k_exponent),.k_ack(k_ack),.k_error(k_error),
        .ack_valid(ack_valid),.ack_ready(ack_ready),.ack_sequence(ack_sequence),.ack_status(ack_status));
    ack_packet_tx response(.clk(clk),.rst_n(rst_n),
        .s_valid(ack_valid && tx_grant),.s_ready(response_ready),.command_sequence(ack_sequence),.status(ack_status),
        .packet_sequence(packet_sequence),.source_version(source_version),.k_version(k_version),
        .m_valid(tx_valid),.m_ready(tx_ready),.m_data(tx_data),.m_last(tx_last));
endmodule
