`timescale 1ns/1ps
// Snapshot a complete distance result before streaming its SPIF packet.
module result_packet_tx(
    input wire clk,input wire rst_n,input wire s_valid,output wire s_ready,
    input wire signed [83:0] accumulator,input wire signed [15:0] exponent,
    input wire [9:0] peak,input wire [9:0] left_bin,input wire [9:0] right_bin,
    input wire [31:0] dropped_frames,input wire [31:0] malformed_frames,
    input wire invalid,input wire discontinuity,input wire timestamp_valid,
    input wire [63:0] timestamp,input wire [31:0] frame_id,input wire [31:0] packet_sequence,
    input wire [31:0] source_version,input wire [31:0] k_version,
    output wire m_valid,input wire m_ready,output wire [7:0] m_data,output wire m_last
);
    localparam IDLE=0,COMMAND=1,PAYLOAD=2,DRAIN=3;
    reg [1:0] state;
    reg [223:0] payload;
    reg [31:0] seq,frame,sv,kv;
    reg [63:0] stamp;
    reg [15:0] flags;
    reg [4:0] index;
    wire command_ready,payload_ready;
    assign s_ready=rst_n && state==IDLE;
    packet_tx tx(.clk(clk),.rst_n(rst_n),.cmd_valid(state==COMMAND),.cmd_ready(command_ready),
        .cmd_kind(8'h13),.cmd_flags(flags),.cmd_length(32'd28),.cmd_sequence(seq),
        .cmd_frame_id(frame),.cmd_timestamp(stamp),.cmd_source_version(sv),.cmd_k_version(kv),.cmd_error(),
        .s_valid(state==PAYLOAD),.s_ready(payload_ready),.s_data(payload[7:0]),
        .m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_last(m_last));
    always @(posedge clk) begin
        if(!rst_n) begin
            state<=IDLE;payload<=0;seq<=0;frame<=0;sv<=0;kv<=0;stamp<=0;flags<=0;index<=0;
        end else case(state)
            IDLE:if(s_valid) begin
                payload<={malformed_frames,dropped_frames,{6'b0,right_bin},{6'b0,left_bin},{6'b0,peak},
                          exponent,{{12{accumulator[83]}},accumulator}};
                seq<=packet_sequence;frame<=frame_id;sv<=source_version;kv<=k_version;
                stamp<=timestamp_valid ? timestamp : 64'b0;
                flags<={13'b0,timestamp_valid,discontinuity,invalid};index<=0;state<=COMMAND;
            end
            COMMAND:if(command_ready) state<=PAYLOAD;
            PAYLOAD:if(payload_ready) begin
                payload<=payload>>8;
                if(index==27) state<=DRAIN;else index<=index+1'b1;
            end
            DRAIN:if(m_valid && m_ready && m_last) state<=IDLE;
        endcase
    end
endmodule
