`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/19 12:02:21
// Design Name: 
// Module Name: ad9945_driver
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



module ad9945_driver(
	input clk,	
	input rst_n,
	input en,

	output ad_sck,
	output ad_sdata,
	output ad_sl,
	

	output ad_shp,
	output ad_shd,
	output ad_clpob,
	output ad_pbclk,
	output ad_dataclk,
	output configure_done
);

wire TCD_Valid=en;
reg ad_sck_r;
reg ad_sdata_r;
reg ad_sl_r;
reg ad_shd_r;
reg ad_shp_r;
reg ad_clpob_r;
reg ad_pbclk_r;
reg ad_dataclk_r;

localparam POWERUP_ADDRESS = 4'b1101;
localparam POWERUP_DATA = 12'b1000_0011_1000;

localparam ADDRESS = 4'b0000;
localparam AD_REG_DATA1 = 12'b0000_0000_0000_0000;
localparam AD_REG_DATA2 = 12'b0000_0000_0000_0000;
localparam AD_REG_DATA3 = 12'b0000_0000_0000_0000;
localparam AD_REG_DATA4 = 12'b0000_0001_0111_0000;

reg [15:0] delay_cnt;
reg delay_done;
always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		begin
			delay_cnt<=0;
			delay_done<=0;
		end
	else if(delay_cnt < 16'd10)  
			delay_cnt<=delay_cnt+1'b1;
	else
		begin
			delay_cnt<=delay_cnt;
			delay_done<=1'b1;
		end
end

reg configure_done_r;
always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		ad_sl_r<=1;
	else if(delay_done==1'b1 && (~configure_done_r))
		ad_sl_r<=0;
	else
		ad_sl_r<=1'b1;
end

reg [3:0] sck_cnt;
always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		sck_cnt<=0;	
	else if(sck_cnt==9)	
		sck_cnt<=0;
	else if(ad_sl_r==0)
		sck_cnt<=sck_cnt+1'b1;
	else
		sck_cnt<=0;
end
	

always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		ad_sck_r<=0;
	else if(sck_cnt==5 || sck_cnt==9)
		ad_sck_r<=~ad_sck_r;
	else
		ad_sck_r<=ad_sck_r;
end

reg send_en;
always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		send_en<=0;
	else if(sck_cnt==7)
		send_en<=1;
	else
		send_en<=0;
end


reg [5:0] reg_cnt;
always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		reg_cnt<=0;
	else if(send_en)
		reg_cnt<=reg_cnt+1'b1;
	else
		reg_cnt<=reg_cnt;
end

reg [2:0] state;
reg [51:0] sdata_r;
always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		sdata_r<=0;
	else if(ad_sl_r==0)
		sdata_r<={AD_REG_DATA4,AD_REG_DATA3,AD_REG_DATA2,AD_REG_DATA1,ADDRESS};
	else
		sdata_r<=0;
end

always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		begin
			configure_done_r<=0;
			ad_sdata_r<=0;
		end
	else if(reg_cnt<52)
		ad_sdata_r<=sdata_r[reg_cnt];
	else
		begin
			ad_sdata_r<=0;
			configure_done_r<=1;
		end
end

reg [1:0] cnt_25m; 
always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		cnt_25m<=0;
	else if(TCD_Valid)
		cnt_25m<=cnt_25m+1'b1;
	else
		cnt_25m<=0;
end


always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		ad_shp_r<=0;
	else if(TCD_Valid)
		ad_shp_r<=~(~cnt_25m[0] && cnt_25m[1]);
	else
		ad_shp_r<=0;
end


always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		ad_shd_r<=0;
	else if(TCD_Valid)
		ad_shd_r<=~(cnt_25m[1] && cnt_25m[0]);
	else
		ad_shd_r<=0;
end

always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		ad_dataclk_r<=0;
	else if(TCD_Valid)
		ad_dataclk_r<=~(cnt_25m==2'b11 || cnt_25m==2'b00);
	else
		ad_dataclk_r<=0;
end

reg clpob_r1;
reg clpob_r2;
always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		begin
			clpob_r1<=0;
			clpob_r2<=0;
		end
	else 
		begin
			clpob_r1<=TCD_Valid;
			clpob_r2<=clpob_r1;
		end
end

wire clpob_flag = ~clpob_r1 && clpob_r2;

reg [5:0] clpob_cnt;
always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		ad_clpob_r<=1;
	else if(clpob_flag)
		ad_clpob_r<=0;
	else if(clpob_cnt==40)
		ad_clpob_r<=1;
	else
		ad_clpob_r<=ad_clpob_r;
end
//ad_clpob_r
always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		clpob_cnt<=0;
	else if(~ad_clpob_r)
		clpob_cnt<=clpob_cnt+1'b1;
	else if(clpob_cnt==40)
		clpob_cnt<=0;
	else
		clpob_cnt<=clpob_cnt;
end


reg pbclk_r1;
reg pbclk_r2;

always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		begin
			pbclk_r1<=0;
			pbclk_r2<=0;
		end
	else
		begin
			pbclk_r1<=ad_clpob_r;
			pbclk_r2<=pbclk_r1;
		end
end

wire pbclk_flag = ~pbclk_r2 && pbclk_r1;

reg [6:0] pbclk_cnt;
always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		ad_pbclk_r<=1;
	else if(pbclk_flag)
		ad_pbclk_r<=0;
	else if(pbclk_cnt==7'd100)
		ad_pbclk_r<=1;
	else
		ad_pbclk_r<=ad_pbclk_r;
end

always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		pbclk_cnt<=0;
	else if(~ad_pbclk_r)
		pbclk_cnt<=pbclk_cnt+1'b1;
	else if(pbclk_cnt==7'd100)
		pbclk_cnt<=0;
	else
		pbclk_cnt<=pbclk_cnt;
end
		
assign ad_sdata=ad_sdata_r;
assign ad_sck=ad_sck_r;
assign ad_sl=ad_sl_r;

assign ad_shd=ad_shd_r;
assign ad_shp=ad_shp_r;
assign ad_dataclk=ad_dataclk_r;
assign ad_clpob=ad_clpob_r;
assign ad_pbclk=ad_pbclk_r;
assign configure_done=configure_done_r;
endmodule


