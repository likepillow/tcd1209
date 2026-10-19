`timescale 1ns/1ps
// SPIF v1 byte-stream framing. The caller must hold the payload stable on stall
// and supply exactly cmd_length bytes. No USB timing or payload RAM is implied.
module packet_tx(
    input wire clk,input wire rst_n,
    input wire cmd_valid,output wire cmd_ready,
    input wire [7:0] cmd_kind,input wire [15:0] cmd_flags,
    input wire [31:0] cmd_length,input wire [31:0] cmd_sequence,
    input wire [31:0] cmd_frame_id,input wire [63:0] cmd_timestamp,
    input wire [31:0] cmd_source_version,input wire [31:0] cmd_k_version,
    output reg cmd_error,
    input wire s_valid,output wire s_ready,input wire [7:0] s_data,
    output wire m_valid,input wire m_ready,output wire [7:0] m_data,
    output wire m_last
);
    localparam IDLE=0,HEADER=1,PAYLOAD=2,CHECKSUM=3;
    reg [1:0] state;
    reg [287:0] header;
    reg [31:0] crc;
    reg [13:0] remaining;
    reg [5:0] count;
    reg legal;
    always @* begin
        legal=0;
        case(cmd_kind)
            8'h10:legal=(cmd_length==2048);
            8'h11:legal=(cmd_length==10240);
            8'h12:legal=(cmd_length==8192);
            8'h13:legal=(cmd_length==28);
            8'h20:legal=(cmd_length==4096);
            8'h21:legal=(cmd_length==2052);
            8'h22:legal=(cmd_length==8);
        endcase
        if((cmd_flags & 16'hfff8)!=0 || (!cmd_flags[2] && cmd_timestamp!=0)) legal=0;
    end
    function [31:0] crc_byte;
        input [31:0] current;
        input [7:0] value;
        reg [31:0] c;
        integer i;
        begin
            c=current^{24'b0,value};
            for(i=0;i<8;i=i+1) c=c[0] ? (c>>1)^32'hedb88320 : c>>1;
            crc_byte=c;
        end
    endfunction
    assign cmd_ready=(state==IDLE);
    assign s_ready=(state==PAYLOAD) && m_ready;
    assign m_valid=(state==HEADER || state==CHECKSUM || (state==PAYLOAD && s_valid));
    assign m_data=(state==HEADER) ? header[7:0] : (state==PAYLOAD) ? s_data : crc[7:0];
    assign m_last=(state==CHECKSUM && count==3);
    always @(posedge clk) begin
        if(!rst_n) begin
            state<=IDLE;header<=0;crc<=32'hffffffff;remaining<=0;count<=0;cmd_error<=0;
        end else begin
            cmd_error<=0;
            case(state)
                IDLE:if(cmd_valid) begin
                    if(!legal) cmd_error<=1;
                    else begin
                        header<={cmd_k_version,cmd_source_version,cmd_timestamp,cmd_frame_id,
                                 cmd_sequence,cmd_length,cmd_flags,cmd_kind,8'h01,32'h46495053};
                        crc<=32'hffffffff;remaining<=cmd_length[13:0];count<=0;state<=HEADER;
                    end
                end
                HEADER:if(m_ready) begin
                    crc<=crc_byte(crc,header[7:0]);header<=header>>8;
                    if(count==35) begin count<=0;state<=PAYLOAD;end
                    else count<=count+1'b1;
                end
                PAYLOAD:if(s_valid && m_ready) begin
                    if(remaining==1) begin
                        crc<=~crc_byte(crc,s_data);count<=0;state<=CHECKSUM;
                    end else begin remaining<=remaining-1'b1;crc<=crc_byte(crc,s_data);end
                end
                CHECKSUM:if(m_ready) begin
                    crc<=crc>>8;
                    if(count==3) begin state<=IDLE;count<=0;end
                    else count<=count+1'b1;
                end
            endcase
        end
    end
endmodule
