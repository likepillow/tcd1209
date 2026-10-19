`timescale 1ns/1ps
// Exactly 1024 spectrum tuples per command. Source holds the complete tuple
// until s_ready; each tuple is serialized as u16 S0, u32 S1, signed i32 S2.
module spectrum_packet_tx(
    input wire clk,input wire rst_n,input wire cmd_valid,output wire cmd_ready,
    input wire [31:0] packet_sequence,input wire [31:0] frame_id,
    input wire [31:0] source_version,
    input wire timestamp_valid,input wire [63:0] timestamp,input wire discontinuity,
    input wire s_valid,output wire s_ready,
    input wire [11:0] s0,input wire [23:0] s1,input wire signed [24:0] s2,
    output wire m_valid,input wire m_ready,output wire [7:0] m_data,output wire m_last
);
    reg [3:0] byte_index;
    wire byte_ready;
    wire [79:0] tuple={ {7{s2[24]}},s2,8'b0,s1,4'b0,s0 };
    assign s_ready=byte_ready && byte_index==9;
    always @(posedge clk) begin
        if(!rst_n) byte_index<=0;
        else if(cmd_valid && cmd_ready) byte_index<=0;
        else if(s_valid && byte_ready) byte_index<=byte_index==9 ? 0 : byte_index+1'b1;
    end
    packet_tx tx(.clk(clk),.rst_n(rst_n),.cmd_valid(cmd_valid),.cmd_ready(cmd_ready),
        .cmd_kind(8'h11),.cmd_flags({13'b0,timestamp_valid,discontinuity,1'b0}),
        .cmd_length(32'd10240),.cmd_sequence(packet_sequence),.cmd_frame_id(frame_id),
        .cmd_timestamp(timestamp_valid ? timestamp : 64'b0),.cmd_source_version(source_version),.cmd_k_version(32'b0),.cmd_error(),
        .s_valid(s_valid),.s_ready(byte_ready),.s_data(tuple[byte_index*8+:8]),
        .m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_last(m_last));
endmodule
