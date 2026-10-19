`timescale 1ns/1ps
// Frame-aware adapter for the normalized spectrum stream. All three samples
// and frame metadata must remain stable while the stream is backpressured.
module spectrum_stream_packet_tx(
    input wire clk,input wire rst_n,
    input wire s_valid,output wire s_ready,input wire s_first,
    input wire [11:0] s0,input wire [23:0] s1,input wire signed [24:0] s2,
    input wire [31:0] frame_id,input wire [31:0] source_version,
    input wire timestamp_valid,input wire [63:0] timestamp,
    output wire request,input wire grant,input wire [31:0] packet_sequence,
    output wire m_valid,input wire m_ready,output wire [7:0] m_data,output wire m_last
);
    reg busy,have_previous;
    reg [31:0] previous_frame;
    wire cmd_ready,tuple_ready;
    wire start=request && grant;
    wire discontinuity=have_previous && frame_id!=previous_frame+32'd1;
    assign request=!busy && cmd_ready && s_valid && s_first;
    assign s_ready=busy && tuple_ready;
    always @(posedge clk) begin
        if(!rst_n) begin busy<=0;have_previous<=0;previous_frame<=0;end
        else begin
            if(start) begin busy<=1;have_previous<=1;previous_frame<=frame_id;end
            if(m_valid && m_ready && m_last) busy<=0;
        end
    end
    spectrum_packet_tx packet(.clk(clk),.rst_n(rst_n),.cmd_valid(start),.cmd_ready(cmd_ready),
        .packet_sequence(packet_sequence),.frame_id(frame_id),.source_version(source_version),
        .timestamp_valid(timestamp_valid),.timestamp(timestamp),.discontinuity(discontinuity),
        .s_valid(s_valid && busy),.s_ready(tuple_ready),.s0(s0),.s1(s1),.s2(s2),
        .m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_last(m_last));
endmodule
