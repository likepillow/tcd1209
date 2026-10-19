`timescale 1ns/1ps
// Serialize one already validated/cropped 1024-pixel frame per command.
// The source holds each pixel until s_ready: low and high bytes are consumed
// on separate cycles. No partial-frame validation or buffering is implied.
module raw_packet_tx(
    input wire clk,input wire rst_n,
    input wire cmd_valid,output wire cmd_ready,
    input wire [31:0] packet_sequence,input wire [31:0] frame_id,
    input wire timestamp_valid,input wire [63:0] timestamp,input wire discontinuity,
    input wire s_valid,output wire s_ready,input wire [11:0] s_data,
    output wire m_valid,input wire m_ready,output wire [7:0] m_data,output wire m_last
);
    reg high_byte;
    wire byte_ready;
    assign s_ready=byte_ready && high_byte;
    always @(posedge clk) begin
        if(!rst_n) high_byte<=0;
        else if(cmd_valid && cmd_ready) high_byte<=0;
        else if(s_valid && byte_ready) high_byte<=!high_byte;
    end
    packet_tx tx(.clk(clk),.rst_n(rst_n),.cmd_valid(cmd_valid),.cmd_ready(cmd_ready),
        .cmd_kind(8'h10),.cmd_flags({13'b0,timestamp_valid,discontinuity,1'b0}),
        .cmd_length(32'd2048),.cmd_sequence(packet_sequence),.cmd_frame_id(frame_id),
        .cmd_timestamp(timestamp_valid ? timestamp : 64'b0),.cmd_source_version(32'b0),.cmd_k_version(32'b0),.cmd_error(),
        .s_valid(s_valid),.s_ready(byte_ready),.s_data(high_byte ? {4'b0,s_data[11:8]} : s_data[7:0]),
        .m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_last(m_last));
endmodule
