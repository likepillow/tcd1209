`timescale 1ns/1ps
// Connect the held, validated frame_ping_pong output to packet arbitration.
// Metadata must describe the first pixel and remain stable until grant.
// No pixel is consumed before the scheduler grants this complete frame.
module raw_stream_packet_tx(
    input wire clk,input wire rst_n,
    input wire s_valid,output wire s_ready,input wire [11:0] s_data,
    input wire s_first,input wire [31:0] s_frame_id,
    input wire timestamp_valid,input wire [63:0] timestamp,
    output wire request,input wire grant,input wire [31:0] packet_sequence,
    output wire m_valid,input wire m_ready,output wire [7:0] m_data,output wire m_last
);
    reg busy,have_previous;
    reg [31:0] previous_frame;
    wire cmd_ready,pixel_ready;
    wire start=request && grant;
    wire discontinuity=have_previous && s_frame_id!=(previous_frame+32'd1);
    assign request=!busy && cmd_ready && s_valid && s_first;
    assign s_ready=busy && pixel_ready;
    always @(posedge clk) begin
        if(!rst_n) begin busy<=0;have_previous<=0;previous_frame<=0;end
        else begin
            if(start) begin busy<=1;have_previous<=1;previous_frame<=s_frame_id;end
            if(m_valid && m_ready && m_last) busy<=0;
        end
    end
    raw_packet_tx packet(.clk(clk),.rst_n(rst_n),.cmd_valid(start),.cmd_ready(cmd_ready),
        .packet_sequence(packet_sequence),.frame_id(s_frame_id),
        .timestamp_valid(timestamp_valid),.timestamp(timestamp),.discontinuity(discontinuity),
        .s_valid(s_valid && busy),.s_ready(pixel_ready),.s_data(s_data),
        .m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_last(m_last));
endmodule
