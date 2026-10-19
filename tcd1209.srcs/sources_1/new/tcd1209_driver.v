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
reg [1:0] pixel_cnt;
reg pixel_clk;
reg clk_r;
always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		g_cnt<=0;
	else if(g_cnt==14'd8500)
		g_cnt<=0;//g_cnt在8500时重置
	else if(configure_done)
		g_cnt<=g_cnt+1'b1;//g_cnt在configure_done有效时自增
	else 
		g_cnt<=g_cnt;//g_cnt在configure_done无效时保持不变
end

//sh
always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		sh_r<=0;
	else if(g_cnt>=14'd25 && g_cnt<14'd75)
		sh_r<=1;//sh_r在g_cnt在25~75之间时有效
	else
		sh_r<=0;//sh_r在g_cnt在25~75之外时无效
end


always@(posedge clk or negedge rst_n) 
begin
	if(!rst_n)
		pixel_cnt<=0;
	else if(g_cnt>=14'd125 && g_cnt<=14'd8500)
		pixel_cnt<=pixel_cnt+1'b1;//g_cnt在125~8500之间时，pixel_cnt自增
	else
		pixel_cnt<=0;
end


always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		pixel_clk<=1'b1;
	else if(pixel_cnt[0]==1'b1)
		pixel_clk<=~pixel_clk;//pixel_cnt开始计数后，每隔两个时钟周期，pixel_clk翻转，其周期为clk的4倍
	else
		pixel_clk<=pixel_clk;
end


//clk1 clk2
always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		clk_r<=1'b0;
	else if(g_cnt<125)
		clk_r<=1'b1;//g_cnt在0~125之间时，clk_r有效
	else
		clk_r<=pixel_clk;
end	

always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		rs_r<=0;
	else if(pixel_cnt==2)
		rs_r<=1;//rs_r在pixel_cnt为2时有效
	else
		rs_r<=0;
end

always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		cp_r<=0;
	else if(pixel_cnt==3)
		cp_r<=1;//cp_r在pixel_cnt为3时有效
	else
		cp_r<=0;
end

always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		en_r<=0;
	else if(g_cnt>=14'd253 && g_cnt<14'd8455)
		en_r<=1;//g_cnt在253~8455之间时，en_r有效
	else
		en_r<=0;
end

always@(posedge clk or negedge rst_n) 
begin
	if(!rst_n)
		led_con_r<=1;
	else if(g_cnt>=10 && g_cnt<=14'd4000)
		led_con_r<=0;//led_con_r在g_cnt在10~4000之间时为0
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
