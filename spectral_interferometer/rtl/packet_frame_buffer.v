`timescale 1ns/1ps
// Backpressurable store-and-forward frame buffer. Never connect directly to a
// non-backpressurable ADC. Only a complete validated frame is published.
// A malformed boundary/metadata change stops the session until coordinated reset.
module packet_frame_buffer #(
    parameter WIDTH=12,parameter META_WIDTH=32,parameter DEPTH=1024
)(
    input wire clk,input wire rst_n,
    input wire s_valid,output wire s_ready,input wire [WIDTH-1:0] s_data,
    input wire s_first,input wire s_last,input wire [META_WIDTH-1:0] s_meta,
    output wire m_valid,input wire m_ready,output reg [WIDTH-1:0] m_data,
    output wire m_first,output wire m_last,output reg [META_WIDTH-1:0] m_meta,
    output reg fault
);
    localparam AW=DEPTH>1 ? $clog2(DEPTH):1;
    localparam RECEIVE=0,READ=1,OUTPUT=2;
    reg [1:0] state;
    reg [AW-1:0] address;
    (* ram_style="block" *) reg [WIDTH-1:0] memory[0:DEPTH-1];
    wire good=s_first==(address==0) && s_last==(address==DEPTH-1)
              && (address==0 || s_meta==m_meta);
    assign s_ready=rst_n && !fault && state==RECEIVE;
    assign m_valid=rst_n && !fault && state==OUTPUT;
    assign m_first=address==0;
    assign m_last=address==DEPTH-1;
    always @(posedge clk) begin
        if(s_valid && s_ready && good) memory[address]<=s_data;
        if(rst_n && !fault && state==READ) m_data<=memory[address];
    end
    always @(posedge clk) begin
        if(!rst_n) begin state<=RECEIVE;address<=0;m_meta<=0;fault<=0;end
        else if(!fault) case(state)
            RECEIVE:if(s_valid && s_ready) begin
                if(!good) fault<=1;
                else begin
                    if(address==0) m_meta<=s_meta;
                    if(address==DEPTH-1) begin address<=0;state<=READ;end
                    else address<=address+1'b1;
                end
            end
            READ:state<=OUTPUT;
            OUTPUT:if(m_ready) begin
                if(address==DEPTH-1) begin address<=0;state<=RECEIVE;end
                else begin address<=address+1'b1;state<=READ;end
            end
            default:fault<=1;
        endcase
    end
endmodule
