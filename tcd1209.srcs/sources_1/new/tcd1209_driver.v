`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/19 12:07:28
// Design Name: 
// Module Name: tcd1209_driver
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


module tcd1209_driver(
	input clk,		
	input rst_n,
	input configure_done,
	output sh,
	output rs,
	output cp,
	output clk1,
	output clk2,
	output en,
	output led_con
);

reg sh_r;
reg rs_r;
reg cp_r;
reg en_r;
reg led_con_r;
reg [14:0] g_cnt;
always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		g_cnt<=0;
	else if(g_cnt==14'd8500)
		g_cnt<=0;
	else if(configure_done)
		g_cnt<=g_cnt+1'b1;
	else 
		g_cnt<=g_cnt;
end

//sh
always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		sh_r<=0;
	else if(g_cnt>=14'd25 && g_cnt<14'd75)
		sh_r<=1;
	else
		sh_r<=0;
end

reg [1:0] pixel_cnt;
always@(posedge clk or negedge rst_n) 
begin
	if(!rst_n)
		pixel_cnt<=0;
	else if(g_cnt>=125 && g_cnt<=14'd8500)
		pixel_cnt<=pixel_cnt+1'b1;
	else
		pixel_cnt<=0;
end

reg pixel_clk;
always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		pixel_clk<=1'b1;
	else if(pixel_cnt[0]==1'b1)
		pixel_clk<=~pixel_clk;
	else
		pixel_clk<=pixel_clk;
end

reg clk_r;
//clk1 clk2
always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		clk_r<=1'b0;
	else if(g_cnt<125)
		clk_r<=1'b1;
	else
		clk_r<=pixel_clk;
end	

always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		rs_r<=0;
	else if(pixel_cnt==2)
		rs_r<=1;
	else
		rs_r<=0;
end

always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		cp_r<=0;
	else if(pixel_cnt==3)
		cp_r<=1;
	else
		cp_r<=0;
end

always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		en_r<=0;
	else if(g_cnt>=14'd253 && g_cnt<14'd8455)
		en_r<=1;
	else
		en_r<=0;
end

always@(posedge clk or negedge rst_n) 
begin
	if(!rst_n)
		led_con_r<=1;
	else if(g_cnt>=10 && g_cnt<=14'd4000)
		led_con_r<=0;
	else
		led_con_r<=1;
end
assign en=en_r;
assign sh=sh_r;
assign cp=cp_r;
assign clk1=clk_r;
assign clk2=~clk_r;
assign rs=rs_r;
assign led_con=led_con_r;
endmodule
