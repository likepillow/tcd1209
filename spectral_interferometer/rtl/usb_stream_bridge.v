`timescale 1ns/1ps
// rst is synchronous to wr_clk; both clocks run during reset/recovery.
// Bridges flush their local adapters together with the crossing FIFO.
module usb_tx_bridge #(parameter integer DEPTH=1024)(
    input wire wr_clk,input wire rd_clk,input wire rst,
    input wire s_valid,output wire s_ready,input wire [7:0] s_data,input wire s_last,
    output wire m_valid,input wire m_ready,output wire [15:0] m_data,output wire m_last,
    output wire fault
);
    wire p_valid,p_ready,p_last,byte_ready;
    wire [15:0] p_data;
    assign s_ready=!rst && byte_ready;
    usb_byte_to_word packer(.clk(wr_clk),.rst_n(!rst),
        .s_valid(s_valid && !rst),.s_ready(byte_ready),.s_data(s_data),.s_last(s_last),
        .m_valid(p_valid),.m_ready(p_ready),.m_data(p_data),.m_last(p_last),.fault(fault));
    usb_async_fifo #(.DEPTH(DEPTH)) crossing(.wr_clk(wr_clk),.rd_clk(rd_clk),.rst(rst),
        .s_valid(p_valid),.s_ready(p_ready),.s_data(p_data),.s_last(p_last),
        .m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_last(m_last),.wr_busy(),.rd_busy());
endmodule

module usb_rx_bridge #(parameter integer DEPTH=1024)(
    input wire wr_clk,input wire rd_clk,input wire rst,
    input wire s_valid,output wire s_ready,input wire [15:0] s_data,input wire s_last,
    output wire m_valid,input wire m_ready,output wire [7:0] m_data,output wire m_last
);
    wire f_valid,f_ready,f_last,byte_valid;
    wire [15:0] f_data;
    (* ASYNC_REG="TRUE" *) reg [1:0] rd_reset=2'b11;
    always @(posedge rd_clk or posedge rst)
        if(rst) rd_reset<=2'b11;
        else rd_reset<={rd_reset[0],1'b0};
    assign m_valid=byte_valid && !rd_reset[1];
    usb_async_fifo #(.DEPTH(DEPTH)) crossing(.wr_clk(wr_clk),.rd_clk(rd_clk),.rst(rst),
        .s_valid(s_valid),.s_ready(s_ready),.s_data(s_data),.s_last(s_last),
        .m_valid(f_valid),.m_ready(f_ready),.m_data(f_data),.m_last(f_last),.wr_busy(),.rd_busy());
    usb_word_to_byte unpacker(.clk(rd_clk),.rst_n(!rd_reset[1]),
        .s_valid(f_valid && !rd_reset[1]),.s_ready(f_ready),.s_data(f_data),.s_last(f_last),
        .m_valid(byte_valid),.m_ready(m_ready && !rd_reset[1]),.m_data(m_data),.m_last(m_last));
endmodule
