`timescale 1ns/1ps
// Same-clock adapters between SPIF bytes and the 16-bit FX2 FIFO stream.
// These modules do NOT implement clock-domain crossing or FX2 pin timing.
// All current SPIF packets have even byte length. First byte is FD[7:0].
module usb_byte_to_word(
    input wire clk,input wire rst_n,
    input wire s_valid,output wire s_ready,input wire [7:0] s_data,input wire s_last,
    output reg m_valid,input wire m_ready,output reg [15:0] m_data,
    output reg m_last,output reg fault
);
    reg half_full;
    reg [7:0] low_byte;
    assign s_ready=!fault && (!m_valid || m_ready);
    always @(posedge clk) begin
        if(!rst_n) begin
            half_full<=0;low_byte<=0;m_valid<=0;m_data<=0;m_last<=0;fault<=0;
        end else begin
            if(m_valid && m_ready) m_valid<=0;
            if(s_valid && s_ready) begin
                if(!half_full) begin
                    // Never add padding to a framed/CRC-protected SPIF packet.
                    // Odd lengths require a stream reset/resynchronization.
                    if(s_last) fault<=1;
                    else begin low_byte<=s_data;half_full<=1;end
                end else begin
                    m_data<={s_data,low_byte};m_last<=s_last;m_valid<=1;half_full<=0;
                end
            end
        end
    end
endmodule

module usb_word_to_byte(
    input wire clk,input wire rst_n,
    input wire s_valid,output wire s_ready,input wire [15:0] s_data,input wire s_last,
    output wire m_valid,input wire m_ready,output wire [7:0] m_data,output wire m_last
);
    reg full,high_byte;
    reg [15:0] data;
    reg last;
    assign s_ready=!full || (high_byte && m_ready);
    assign m_valid=full;
    assign m_data=high_byte ? data[15:8] : data[7:0];
    assign m_last=full && high_byte && last;
    always @(posedge clk) begin
        if(!rst_n) begin full<=0;high_byte<=0;data<=0;last<=0;end
        else begin
            if(m_valid && m_ready) begin
                if(high_byte) begin full<=0;high_byte<=0;end
                else high_byte<=1;
            end
            if(s_valid && s_ready) begin data<=s_data;last<=s_last;full<=1;high_byte<=0;end
        end
    end
endmodule
