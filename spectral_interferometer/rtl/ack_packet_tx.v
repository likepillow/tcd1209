`timescale 1ns/1ps
// Snapshot an applied/error response and versions; emit a complete SPIF ACK.
// packet_sequence is allocated by the future shared outbound scheduler.
module ack_packet_tx(
    input wire clk,input wire rst_n,
    input wire s_valid,output wire s_ready,input wire [31:0] command_sequence,
    input wire [15:0] status,input wire [31:0] packet_sequence,
    input wire [31:0] source_version,input wire [31:0] k_version,
    output wire m_valid,input wire m_ready,output wire [7:0] m_data,output wire m_last
);
    localparam IDLE=0,COMMAND=1,PAYLOAD=2,DRAIN=3;
    reg [1:0] state;
    reg [63:0] payload;
    reg [31:0] seq,sv,kv;
    reg [2:0] index;
    wire command_ready,payload_ready;
    assign s_ready=rst_n && state==IDLE;
    packet_tx tx(.clk(clk),.rst_n(rst_n),.cmd_valid(state==COMMAND),.cmd_ready(command_ready),
        .cmd_kind(8'h22),.cmd_flags(16'b0),.cmd_length(32'd8),.cmd_sequence(seq),
        .cmd_frame_id(32'hffffffff),.cmd_timestamp(64'b0),.cmd_source_version(sv),.cmd_k_version(kv),.cmd_error(),
        .s_valid(state==PAYLOAD),.s_ready(payload_ready),.s_data(payload[7:0]),
        .m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_last(m_last));
    always @(posedge clk) begin
        if(!rst_n) begin state<=IDLE;payload<=0;seq<=0;sv<=0;kv<=0;index<=0;end
        else case(state)
            IDLE:if(s_valid) begin
                payload<={16'b0,status,command_sequence};seq<=packet_sequence;
                sv<=source_version;kv<=k_version;index<=0;state<=COMMAND;
            end
            COMMAND:if(command_ready) state<=PAYLOAD;
            PAYLOAD:if(payload_ready) begin
                payload<=payload>>8;
                if(index==7) state<=DRAIN;else index<=index+1'b1;
            end
            DRAIN:if(m_valid && m_ready && m_last) state<=IDLE;
        endcase
    end
endmodule
