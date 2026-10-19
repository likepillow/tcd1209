`timescale 1ns/1ps
// Nonblocking tap of an accepted, framed S0 stream. period_frames=0 disables
// export; N>=1 selects one in N input frames. Changes apply at the next first
// pixel. Busy selections are counted, never queued as partial frames.
module s0_export_buffer #(parameter DEPTH=1024)(
    input wire clk,input wire rst_n,
    output wire idle,
    input wire [31:0] period_frames,
    input wire s_valid,output wire s_ready,input wire [11:0] s_data,
    input wire s_first,input wire s_last,input wire [31:0] s_frame_id,
    input wire [63:0] s_timestamp,
    output wire m_valid,input wire m_ready,output wire [11:0] m_data,
    output wire m_first,output wire m_last,output wire [31:0] m_frame_id,
    output wire [63:0] m_timestamp,
    output wire fault,output reg [31:0] busy_skipped_frames,
    output reg [31:0] rate_skipped_frames
);
    reg selected;
    reg [31:0] countdown,previous_period;
    wire buffer_ready;
    assign idle=buffer_ready && !selected;
    wire due=period_frames!=0 && (period_frames!=previous_period || countdown==0);
    wire take=s_first ? (due && buffer_ready && !fault) : selected;
    assign s_ready=rst_n;
    wire [95:0] m_meta;
    assign {m_timestamp,m_frame_id}=m_meta;
    packet_frame_buffer #(.WIDTH(12),.META_WIDTH(96),.DEPTH(DEPTH)) buffer_i(
        .clk(clk),.rst_n(rst_n),.s_valid(s_valid && s_ready && take),
        .s_ready(buffer_ready),.s_data(s_data),.s_first(s_first),.s_last(s_last),.s_meta({s_timestamp,s_frame_id}),
        .m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_first(m_first),
        .m_last(m_last),.m_meta(m_meta),.fault(fault));
    always @(posedge clk) begin
        if(!rst_n) begin
            selected<=0;countdown<=0;previous_period<=0;
            busy_skipped_frames<=0;rate_skipped_frames<=0;
        end else if(s_valid && s_ready) begin
            if(s_first) begin
                previous_period<=period_frames;
                selected<=take && !s_last;
                if(period_frames==0) countdown<=0;
                else if(due) countdown<=period_frames-1'b1;
                else countdown<=countdown-1'b1;
                if(!due) rate_skipped_frames<=rate_skipped_frames+1'b1;
                else if(!buffer_ready || fault) busy_skipped_frames<=busy_skipped_frames+1'b1;
            end else if(s_last) selected<=0;
        end
    end
endmodule
