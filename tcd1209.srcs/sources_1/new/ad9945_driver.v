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

localparam ADDRESS = 4'b0000;//寄存器地址
localparam AD_REG_DATA1 = 12'b0000_0000_0000_0000;
localparam AD_REG_DATA2 = 12'b0000_0000_0000_0000;
localparam AD_REG_DATA3 = 12'b0000_0000_0000_0000;
localparam AD_REG_DATA4 = 12'b0000_0001_0111_0000;

reg [15:0] delay_cnt;
reg delay_done;

reg configure_done_r;
reg [3:0] sck_cnt;
reg send_en;
reg [5:0] reg_cnt;
reg [2:0] state;
reg [51:0] sdata_r;
reg [1:0] cnt_25m; 
reg clpob_r1;
reg clpob_r2;
wire clpob_flag = ~clpob_r1 && clpob_r2;

reg [5:0] clpob_cnt;
reg pbclk_r1;
reg pbclk_r2;
wire pbclk_flag = ~pbclk_r2 && pbclk_r1;

reg [6:0] pbclk_cnt;
always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		begin
			delay_cnt<=0;
			delay_done<=0;
		end
	else if(delay_cnt < 16'd10)  
			delay_cnt<=delay_cnt+1'b1;//delay_cnt小于10时自增
	else
		begin
			delay_cnt<=delay_cnt;
		end
end


always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		ad_sl_r<=1;
	else if(delay_done==1'b1 && (~configure_done_r))
		ad_sl_r<=0;//delay_done有效，且configure_done_r无效时，ad_sl_r有效
	else
		ad_sl_r<=1'b1;//delay_done无效，或configure_done_r有效时，ad_sl_r无效
end


always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		sck_cnt<=0;	
	else if(sck_cnt==9)	
		sck_cnt<=0;//sck_cnt在9时重置
	else if(ad_sl_r==0)
		sck_cnt<=sck_cnt+1'b1;//ad_sl_r有效时，sck_cnt自增
	else
		sck_cnt<=0;
end
	

always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		ad_sck_r<=0;
	else if(sck_cnt==5 || sck_cnt==9)
		ad_sck_r<=~ad_sck_r;//sck_cnt在5或9时，ad_sck_r翻转
	else
		ad_sck_r<=ad_sck_r;
end


always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		send_en<=0;
	else if(sck_cnt==7)
		send_en<=1;//sck_cnt在7时，send_en有效
	else
		send_en<=0;
end



always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		reg_cnt<=0;
	else if(send_en)
		reg_cnt<=reg_cnt+1'b1;//send_en有效时，reg_cnt自增
	else
		reg_cnt<=reg_cnt;
end


always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		sdata_r<=0;
	else if(ad_sl_r==0)
		sdata_r<={AD_REG_DATA4,AD_REG_DATA3,AD_REG_DATA2,AD_REG_DATA1,ADDRESS};//ad_sl_r有效时，sdata_r寄存器更新为AD_REG_DATA4~AD_REG_DATA1和ADDRESS的值
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
		ad_sdata_r<=sdata_r[reg_cnt];//reg_cnt小于52时，ad_sdata_r寄存器每周期更新为sdata_r[reg_cnt]的值
	else
		begin
			ad_sdata_r<=0;
			configure_done_r<=1;//reg_cnt大于等于52时，ad_sdata_r寄存器清零，configure_done_r有效
		end
end


always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		cnt_25m<=0;
	else if(TCD_Valid)
		cnt_25m<=cnt_25m+1'b1;//TCD_Valid有效时，cnt_25m自增
	else
		cnt_25m<=0;
end


always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		ad_shp_r<=0;
	else if(TCD_Valid)
		ad_shp_r<=~(~cnt_25m[0] && cnt_25m[1]);//TCD_Valid有效时，ad_shp_r仅在cnt_25m为2'b10时为0，其周期为clk的4倍，占空比25%
	else
		ad_shp_r<=0;
end


always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		ad_shd_r<=0;
	else if(TCD_Valid)
		ad_shd_r<=~(cnt_25m[1] && cnt_25m[0]);//TCD_Valid有效时，ad_shd_r仅在cnt_25m为2'b11时为0，其周期为clk的4倍，占空比25%
	else
		ad_shd_r<=0;
end

always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		ad_dataclk_r<=0;
	else if(TCD_Valid)
		ad_dataclk_r<=~(cnt_25m==2'b11 || cnt_25m==2'b00);//TCD_Valid有效时，ad_dataclk_r仅在cnt_25m为2'b11或2'b00时为0，其周期为clk的4倍，占空比50%
	else
		ad_dataclk_r<=0;
end


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
			clpob_r2<=clpob_r1;//clpob_flag仅在TCD_Valid下降沿周期内有效
		end
end


always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		ad_clpob_r<=1;
	else if(clpob_flag)
		ad_clpob_r<=0;//clpob_flag有效时，ad_clpob_r有效
	else if(clpob_cnt==40)
		ad_clpob_r<=1;//clpob_cnt为40时，ad_clpob_r无效
	else
		ad_clpob_r<=ad_clpob_r;
end
//ad_clpob_r
always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		clpob_cnt<=0;
	else if(~ad_clpob_r)
		clpob_cnt<=clpob_cnt+1'b1;//clpob_flag有效时，clpob_cnt自增
	else if(clpob_cnt==40)
		clpob_cnt<=0;//clpob_cnt为40时，clpob_cnt重置
	else
		clpob_cnt<=clpob_cnt;
end




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
			pbclk_r2<=pbclk_r1;//pbclk_flag仅在ad_clpob_r上升沿周期内有效
		end
end



always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		ad_pbclk_r<=1;
	else if(pbclk_flag)
		ad_pbclk_r<=0;//pbclk_flag有效时，ad_pbclk_r有效
	else if(pbclk_cnt==7'd100)
		ad_pbclk_r<=1;//pbclk_cnt为100时，ad_pbclk_r无效
	else
		ad_pbclk_r<=ad_pbclk_r;
end

always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		pbclk_cnt<=0;
	else if(~ad_pbclk_r)
		pbclk_cnt<=pbclk_cnt+1'b1;//pbclk_flag有效时，pbclk_cnt自增
	else if(pbclk_cnt==7'd100)
		pbclk_cnt<=0;//pbclk_cnt为100时，pbclk_cnt重置
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


