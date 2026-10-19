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
output clka,
output wea,
output [12:0] addra,
input sh,//帧采样启动信号
output [15:0] fifo_data,
input [2:0] yuzhi
);

reg line_valid;
reg rec_en_r1;
reg rec_en_r2;
reg [11:0] pixel_cnt;
reg line_flag;
reg [9:0] line_cnt;
reg line_r1;
reg line_r2;
reg frame_valid;
wire rec_en=~rec_en_r2 && rec_en_r1;//像素采样信号，只在ad_dataclk的上升沿有效
wire line_edge=~line_r2 & line_r1;


reg [11:0] kuandu;
reg [11:0] kuandu_r;

reg INT0_r;
reg [12:0] wraddress_r;
reg wea_r;
reg Ctrl_state;
parameter
ready=1'b0,
sampling=1'b1;
reg [11:0] usb_data_r;
reg [11:0] pixel_index;
reg [10:0] ram_wr_addr;
reg        ram_wr_en;
reg [15:0] ram_wr_data;
assign INT0=INT0_r;
assign addra=wraddress_r;

assign clka = clk;

assign fifo_data=(wraddress_r[12:0]>13'd2051)?{1'b0,1'b0,1'b0,1'b0,kuandu_r}:{1'b0,1'b0,1'b0,1'b0,usb_data_r};

assign wea =
       rec_en &&
       (pixel_index <= 12'd2047);

always@(posedge sh or  posedge rec_en) //sh为上升沿时，表示CCD采样完成，进入下一帧采样，rec_en为上升沿时，表示CCD正在采样
	if(sh)
		begin
		if(!re_sample)					   	//是否需要重采样
			Ctrl_state<=sampling;			//正在采样
		else
			Ctrl_state<=ready;				//准备采样
		end
	else
	case(Ctrl_state)
		ready:
			begin
				wraddress_r[12:0]<=13'd0;	//写入地址重置
				wea_r<=1'b0;					//写使能重置
				INT0_r<=1'b1;					//中断信号置高
				kuandu[11:0]<=12'd0;
				kuandu_r[11:0]<=12'd0;
			end
		sampling:
			begin
				if(wraddress_r[12:0]==13'd2053) //地址到达2053时重置

					begin
						Ctrl_state<=ready;
						INT0_r<=1'b0;
					
					end
				else
					begin
						wraddress_r[12:0]<=wraddress_r[12:0]+1'b1;
						wea_r<=1'b1;			

					   if((wraddress_r[12:0]>13'd12)&&(usb_data_r<(yuzhi*100+1600)))//判断像素值是否小于阈值
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
	
	always @(posedge clk or negedge rst_n)
begin
    if(!rst_n)
    begin
        pixel_index <= 12'd0;
        ram_wr_addr <= 11'd0;
        ram_wr_en   <= 1'b0;
        ram_wr_data <= 16'd0;
    end
    else
    begin
        ram_wr_en <= 1'b0;

        if(!en)
        begin
            pixel_index <= 12'd0;
            ram_wr_addr <= 11'd0;
        end
        else if(rec_en)
        begin
            // 采样时，写入RAM，地址自增
            if(pixel_index <= 12'd2047)
            begin
                ram_wr_en   <= 1'b1;
                ram_wr_data <= {4'd0, ad_data};
                ram_wr_addr <= ram_wr_addr + 1'b1; // ram_wr_addr自增0~2047
            end

            // 采样时，像素索引自增
            if(pixel_index < 12'd2052)
                pixel_index <= pixel_index + 1'b1; // pixel_index自增0~2051
        end
    end
end



always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		pixel_cnt<=12'd0;
	else if(en && rec_en)
		pixel_cnt<=pixel_cnt+1'b1;//采集窗口内，采样触发时，pixel_cnt自增
	else if(~en)
		pixel_cnt<=12'd0;//采集窗口外，pixel_cnt重置
	else
		pixel_cnt<=pixel_cnt;//采集窗口内，采样未触发时，保持不变
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
			rec_en_r2<=rec_en_r1;//2步移位寄存器，仅在ad_dataclk上升沿周期内使rec_en有效
		end
	else
		begin
			rec_en_r1<=1'b0;
			rec_en_r2<=1'b0;
		end
end





always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		line_valid<=1'b0;

	else if(pixel_cnt>=0 && pixel_cnt<=2100)//pixel_cnt在0~2100之间时，line_valid有效
		line_valid<=1'b1;
	else
		line_valid<=1'b0;
end



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
			line_r2<=line_r1;//2步移位寄存器，仅在en的上升沿周期有效
		end
end


always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		line_cnt<=10'd0;
	else if(line_edge)
		line_cnt<=line_cnt+1'b1;//en的上升沿周期内，line_cnt自增
	else if(line_cnt==10'd500)
		line_cnt<=10'd0;//line_cnt在500时重置
	else 
		line_cnt<=line_cnt;//非en的上升沿周期，line_cnt保持不变
end


always@(posedge clk or negedge rst_n)
begin
	if(!rst_n)
		frame_valid<=1'b0;
	else if((line_cnt>=10'd10) && (line_cnt<10'd500)) 
		frame_valid<=1'b1;//line_cnt在10~500之间时，frame_valid有效
	else
		frame_valid<=1'b0;
end


always@(posedge clk or negedge rst_n)
begin	
	if(!rst_n)
		line_flag<=1'b0;
	else if(line_cnt>=10'd15 && line_cnt<495) 
		line_flag<=1'b1;//line_cnt在15~495之间时，line_flag有效
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
      usb_data_r<=ad_data;//line_valid有效，采样触发时，usb_data_r寄存器更新为ad_data的值

	end
	else if(~line_valid)
	begin
		usb_data_r<=0;//line_valid无效时，usb_data_r寄存器清零
	end
	else 
	begin
		usb_data_r<=usb_data_r;//line_valid有效，采样未触发时，usb_data_r寄存器保持不变
	end
end


endmodule




















