`timescale 1ns/1ps
// Byte-stream to FX2 pins. sys_rst and if_rst must be coordinated and held
// through reset recovery, synchronous to their respective clocks. Both clocks
// must run. Board wrapper supplies normalized flag polarity and pin constraints.
// Session restart must also clear stale FX2 endpoint bytes; no silent reconnect.
module fx2_transport #(parameter integer TX_DEPTH=1024)(
    input wire sys_clk,input wire ifclk,input wire sys_rst,input wire if_rst,
    input wire tx_valid,output wire tx_ready,input wire [7:0] tx_data,input wire tx_last,
    output wire rx_valid,input wire rx_ready,output wire [7:0] rx_data,
    output wire fault,
    input wire ep2_has_data,input wire ep6_has_space,
    inout wire [15:0] fd,output wire [1:0] fifo_addr,
    output wire slrd_n,output wire slwr_n,output wire sloe_n,
    output wire pktend_n,output wire slcs_n
);
    wire word_tx_valid,word_tx_ready,word_tx_last;
    wire [15:0] word_tx_data;
    wire word_rx_valid,word_rx_ready;
    wire [15:0] word_rx_data;
    wire [15:0] fd_out;
    wire fd_drive,rd_i,wr_i,oe_i,end_i,cs_i;
    // Controller output registers assert reset asynchronously. Avoid extra LUT
    // gating between these registers and pads, permitting IOB placement.
    assign fd=fd_drive ? fd_out : 16'bz;
    assign slrd_n=rd_i;
    assign slwr_n=wr_i;
    assign sloe_n=oe_i;
    assign pktend_n=end_i;
    assign slcs_n=cs_i;
    usb_tx_bridge #(.DEPTH(TX_DEPTH)) tx_bridge(.wr_clk(sys_clk),.rd_clk(ifclk),.rst(sys_rst),
        .s_valid(tx_valid),.s_ready(tx_ready),.s_data(tx_data),.s_last(tx_last),
        .m_valid(word_tx_valid),.m_ready(word_tx_ready),.m_data(word_tx_data),.m_last(word_tx_last),.fault(fault));
    usb_rx_bridge rx_bridge(.wr_clk(ifclk),.rd_clk(sys_clk),.rst(if_rst),
        .s_valid(word_rx_valid),.s_ready(word_rx_ready),.s_data(word_rx_data),.s_last(1'b0),
        .m_valid(rx_valid),.m_ready(rx_ready),.m_data(rx_data),.m_last());
    fx2_slave_fifo controller(.ifclk(ifclk),.rst_n(!if_rst),
        .ep2_has_data(ep2_has_data),.ep6_has_space(ep6_has_space),
        .tx_valid(word_tx_valid),.tx_ready(word_tx_ready),.tx_data(word_tx_data),.tx_last(word_tx_last),
        .rx_valid(word_rx_valid),.rx_ready(word_rx_ready),.rx_data(word_rx_data),
        .fd_in(fd),.fd_out(fd_out),.fd_drive(fd_drive),.fifo_addr(fifo_addr),
        .slrd_n(rd_i),.slwr_n(wr_i),.sloe_n(oe_i),.pktend_n(end_i),.slcs_n(cs_i));
endmodule
