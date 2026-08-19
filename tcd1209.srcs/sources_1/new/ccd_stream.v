`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/19 12:02:21
// Design Name: 
// Module Name: ccd_stream
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



module ccd_stream(
input clk,
input rst_n,

input en,
input ad_dataclk,

input [11:0] ad_data,

output INT0,
input re_sample,
output wrclock,
output wren,
output [12:0] wraddress,
input sh,
output [15:0] fifo_data,
input [2:0] yuzhi
);

reg line_valid;
reg rec_en_r1;
reg rec_en_r2;
reg [11:0] pixel_cnt;


reg [11:0] kuandu;
reg [11:0] kuandu_r;

reg INT0_r;
reg [12:0] wraddress_r;
reg wren_r;
reg Ctrl_state;
parameter
ready=1'b0,
sampling=1'b1;
assign INT0=INT0_r;
assign wraddress=wraddress_r;

assign wren=wren_r;
assign wrclock=rec_en;

always@(posedge sh or  posedge rec_en)//negedge
	if(sh)
		begin
		if(!re_sample)					   	//??????????????0
			Ctrl_state<=sampling;			//???????????
		else
			Ctrl_state<=ready;				//??????
		end
	else
	case(Ctrl_state)
		ready:
			begin
				wraddress_r[12:0]<=13'd0;	//???¦Ë????
				wren_r<=1'b0;					//????§Õ
				INT0_r<=1'b1;					//??CPU????
				kuandu[11:0]<=12'd0;
				kuandu_r[11:0]<=12'd0;
			end
		sampling:
			begin
				if(wraddress_r[12:0]==13'd2053) 

					begin
						Ctrl_state<=ready;
						INT0_r<=1'b0;
					
					end
				else
					begin
						wraddress_r[12:0]<=wraddress_r[12:0]+1'b1;
						wren_r<=1'b1;			//§Õ??

					   if((wraddress_r[12:0]>13'd12)&&(usb_data_r<(yuzhi*100+1600)))
						begin 
							kuandu[11:0]<=kuandu[11:0]+1'b1;
						end
						else
						begin 
						   kuandu_r[11:0]<=kuandu[11:0];
						end
					end
			end
	endcase
reg [11:0] usb_data_r;

assign fifo_data=(wraddress_r[12:0]>13'd2051)?{1'b0,1'b0,1'b0,1'b0,kuandu_r}:{1'b0,1'b0,1'b0,1'b0,usb_data_r};

always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		pixel_cnt<=12'd0;
	else if(en && rec_en)
		pixel_cnt<=pixel_cnt+1'b1;
	else if(~en)
		pixel_cnt<=12'd0;
	else
		pixel_cnt<=pixel_cnt;
end
always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		begin
			rec_en_r1<=1'b0;
			rec_en_r2<=1'b0;
		end
	else if(en)
		begin
			rec_en_r1<=ad_dataclk;
			rec_en_r2<=rec_en_r1;
		end
	else
		begin
			rec_en_r1<=1'b0;
			rec_en_r2<=1'b0;
		end
end

wire rec_en=~rec_en_r2 && rec_en_r1;



always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		line_valid<=1'b0;

	else if(pixel_cnt>=0 && pixel_cnt<=2100)
		line_valid<=1'b1;
	else
		line_valid<=1'b0;
end

reg line_r1;
reg line_r2;
always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		begin
			line_r1<=0;
			line_r2<=0;
		end
	else
		begin
			line_r1<=en;
			line_r2<=line_r1;
		end
end

wire line_edge=~line_r2 & line_r1;
reg [9:0] line_cnt;
always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		line_cnt<=10'd0;
	else if(line_edge)
		line_cnt<=line_cnt+1'b1;
	else if(line_cnt==10'd500)
		line_cnt<=10'd0;
	else 
		line_cnt<=line_cnt;
end

reg frame_valid;
always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		frame_valid<=1'b0;
	else if((line_cnt>=10'd10) && (line_cnt<10'd500)) 
		frame_valid<=1'b1;
	else
		frame_valid<=1'b0;
end

reg line_flag;
always@(posedge clk or negedge rst_n)
begin	
	if(!rst_n)
		line_flag<=1'b0;
	else if(line_cnt>=10'd15 && line_cnt<495) 
		line_flag<=1'b1;
	else	
		line_flag<=1'b0;
end

always@(posedge clk or negedge rst_n)
begin	
	if(!rst_n)
	begin
		usb_data_r<=0;
	end

	else if(line_valid && rec_en)
	begin
      usb_data_r<=ad_data;

	end
	else if(~line_valid)
	begin
		usb_data_r<=0;
	end
	else 
	begin
		usb_data_r<=usb_data_r;
	end
end


endmodule




















