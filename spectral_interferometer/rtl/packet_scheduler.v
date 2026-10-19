`timescale 1ns/1ps
// Request reserves a complete packet source, which must remain available until
// its one-cycle grant. Latch packet_sequence on grant, then supply bytes/last.
// Never withdraw a granted packet. Recovery from a broken source resets session.
module packet_scheduler #(
    parameter integer CHANNELS=5,
    parameter [31:0] INITIAL_SEQUENCE=0
)(
    input wire clk,input wire rst_n,input wire [CHANNELS-1:0] request,
    output wire idle,
    output reg [CHANNELS-1:0] grant,output reg [31:0] packet_sequence,
    input wire [CHANNELS-1:0] s_valid,output reg [CHANNELS-1:0] s_ready,
    input wire [CHANNELS*8-1:0] s_data,input wire [CHANNELS-1:0] s_last,
    output reg m_valid,input wire m_ready,output reg [7:0] m_data,output reg m_last
);
    localparam IDLE=0,GRANT=1,STREAM=2;
    localparam CW=CHANNELS>1 ? $clog2(CHANNELS):1;
    reg [1:0] state;
    assign idle=state==IDLE && request==0;
    reg [CW-1:0] selected,cursor;
    integer offset,candidate;
    reg found;
    reg [CW-1:0] next_channel;
    always @* begin
        found=0;next_channel=0;candidate=0;
        for(offset=0;offset<CHANNELS;offset=offset+1) begin
            candidate=cursor+offset;
            if(candidate>=CHANNELS) candidate=candidate-CHANNELS;
            if(!found && request[candidate]) begin found=1;next_channel=candidate;end
        end
        grant=0;s_ready=0;m_valid=0;m_data=0;m_last=0;
        if(rst_n && state==GRANT) grant[selected]=1;
        if(rst_n && state==STREAM) begin
            m_valid=s_valid[selected];m_data=s_data[selected*8+:8];m_last=s_last[selected];
            s_ready[selected]=m_ready;
        end
    end
    always @(posedge clk) begin
        if(!rst_n) begin state<=IDLE;selected<=0;cursor<=0;packet_sequence<=INITIAL_SEQUENCE;end
        else case(state)
            IDLE:if(found) begin selected<=next_channel;state<=GRANT;end
            GRANT:state<=STREAM;
            STREAM:if(m_valid && m_ready && m_last) begin
                state<=IDLE;packet_sequence<=packet_sequence+1'b1;
                cursor<=(selected==CHANNELS-1) ? 0 : selected+1'b1;
            end
        endcase
    end
endmodule
