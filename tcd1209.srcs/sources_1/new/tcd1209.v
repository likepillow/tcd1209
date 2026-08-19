`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/19 12:02:21
// Design Name: 
// Module Name: tcd1209
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////



module tcd1209(
	input clk,
	input rst_n,
	
	output sh,
	output rs,
	output cp,
	output clk1,
	output clk2,

	output ad_sck,
	output ad_sdata,
	output ad_sl,

	output ad_shp,
	output ad_shd,
	output ad_clpob,
	output ad_pbclk,
	output ad_dataclk,

	input [11:0] ad_data,
	output PULSE,

	input rdclock, 
	input [12:0] rdaddress,	
   output INT0,
   input re_sample,
	output [15:0] q,
	input [2:0] yuzhi
);
wire en;
wire configure_done;
wire led_con;

assign PULSE = led_con;

wire wrclock; 
wire wren;
wire [12:0]wraddress;
wire [15:0] fifo_data;
tcd1209_driver TCD1209_Driver_u(
	.clk(clk),		
	.rst_n(rst_n),
	
	.sh(sh),
	.rs(rs),
	.cp(cp),
	.clk1(clk1),
	.clk2(clk2),
	.en(en),
	.configure_done(configure_done),
	.led_con(led_con)
);

ad9945_driver AD9945_driver_u(
	.clk(clk),	
	.rst_n(rst_n),
	.en(en),

	.ad_sck(ad_sck),
	.ad_sdata(ad_sdata),
	.ad_sl(ad_sl),

	.ad_shp(ad_shp),
	.ad_shd(ad_shd),
	.ad_clpob(ad_clpob),
	.ad_pbclk(ad_pbclk),
	.ad_dataclk(ad_dataclk),
	.configure_done(configure_done)
);

ccd_stream CCD_Stream_u(
	.clk(clk),
	.rst_n(rst_n),	
	.en(en),
	.ad_dataclk(ad_dataclk),
	.ad_data(ad_data),
	.INT0(INT0),
	.re_sample(re_sample),
	.wrclock(wrclock),
	.wren(wren),
	.wraddress(wraddress),
	.sh(sh),
	.fifo_data(fifo_data),
	.yuzhi(yuzhi)
);
ad_ram U1  
(
	.data(fifo_data),  
	.rdaddress(rdaddress),//
	.rdclock(rdclock),
	.wraddress(wraddress), //
	.wrclock(wrclock),//
	.wren(wren),//   
	.q(q)   
);
endmodule


































