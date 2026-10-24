`timescale 1ns/1ps
module tb_extended_exposure;
    reg clk=0,rst_n=0;always #5 clk=~clk;
    reg rx_valid=0;reg [7:0] rx_data=0;wire rx_ready;
    wire tx_request,tx_valid,tx_last,receive_error,acquisition_request,acquisition_ack;
    wire [7:0] tx_data;reg tx_grant=0;reg frontend_busy=1;
    wire [10:0] requested_window,active_window;
    wire [63:0] requested_period,active_period;wire [31:0] requested_result_stride;
    wire stop,pipeline_reset_n;integer errors=0,replies=0,byte_count=0,last_status=0;
    wire sb,sw,sc,kb,kw,kc;
    calibration_control #(.FAST_PROFILE(1)) control(
        .clk(clk),.rst_n(rst_n),.rx_valid(rx_valid),.rx_ready(rx_ready),.rx_data(rx_data),
        .tx_valid(tx_valid),.tx_ready(1'b1),.tx_data(tx_data),.tx_last(tx_last),
        .tx_request(tx_request),.tx_grant(tx_grant),.packet_sequence(32'd0),
        .source_version(32'd0),.k_version(32'd0),.receive_error(receive_error),
        .source_begin(sb),.source_we(sw),.source_commit(sc),.source_ack(1'b0),.source_error(1'b0),
        .k_begin(kb),.k_we(kw),.k_commit(kc),.k_ack(1'b0),.k_error(1'b0),
        .run_ack(1'b0),.acquisition_request(acquisition_request),.acquisition_ack(acquisition_ack),
        .requested_window(requested_window),.requested_period(requested_period),
        .requested_result_stride(requested_result_stride));
    acquisition_reconfigure #(.FAST_PROFILE(1)) config_apply(
        .clk(clk),.rst_n(rst_n),.request(acquisition_request),.ack(acquisition_ack),
        .requested_window(requested_window),.requested_period(requested_period),
        .frontend_busy(frontend_busy),.acquisition_idle(1'b1),.output_idle(1'b1),
        .stop(stop),.pipeline_reset_n(pipeline_reset_n),.active_window(active_window),.active_period(active_period));
    always @(posedge clk) begin
        if(receive_error) errors=errors+1;
        if(sb || sw || sc || kb || kw || kc) $fatal(1,"exposure wrote calibration memory");
        if(tx_valid) begin
            if(byte_count==40) last_status=tx_data;
            if(byte_count==41) last_status=last_status+(tx_data<<8);
            if(tx_last) begin replies=replies+1;byte_count=0;end
            else byte_count=byte_count+1;
        end
    end
    function [31:0] crc_byte(input [31:0] value,input [7:0] b);
        reg [31:0] c;integer j;
        begin c=value^b;for(j=0;j<8;j=j+1)c=c[0]?(c>>1)^32'hedb88320:c>>1;crc_byte=c;end
    endfunction
    task send_byte(input [7:0] b);
        @(negedge clk);rx_valid=1;rx_data=b;
        @(posedge clk);while(!rx_ready) @(posedge clk);
        @(negedge clk);rx_valid=0;
    endtask
    task command(input [7:0] kind,input [31:0] w,input [63:0] p,input [31:0] n,input bit corrupt);
        reg [415:0] body;reg [31:0] crc;integer i,length;
        begin
            length=kind==8'h27 ? 16 : 8;
            body=0;body[31:0]=32'h46495053;body[39:32]=1;body[47:40]=kind;
            body[95:64]=length;body[127:96]=32'd7;body[159:128]=32'hffffffff;
            body[319:288]=w;body[383:320]=p;body[415:384]=n;crc=32'hffffffff;
            for(i=0;i<36+length;i=i+1) begin crc=crc_byte(crc,body[i*8+:8]);send_byte(body[i*8+:8]);end
            if(acquisition_request || tx_request) $fatal(1,"configuration applied before CRC");
            crc=~crc;if(corrupt)crc=crc^1;
            for(i=0;i<4;i=i+1)send_byte(crc[i*8+:8]);
        end
    endtask
    task reply(input integer status);
        integer previous_replies;
        begin
            previous_replies=replies;wait(tx_request);@(negedge clk);tx_grant=1;
            @(negedge clk);tx_grant=0;wait(replies==previous_replies+1);repeat(4)@(negedge clk);
            if(last_status!=status) $fatal(1,"wrong ACK status");
        end
    endtask
    initial begin
        repeat(4)@(negedge clk);rst_n=1;
        if(active_period!=2500) $fatal(1,"fast boot period");
        command(8'h27,40,2500,4,1);repeat(20)@(negedge clk);
        command(8'h27,40,2499,4,0);repeat(20)@(negedge clk);
        command(8'h27,40,2500,0,0);repeat(20)@(negedge clk);
        command(8'h27,1025,2500,4,0);repeat(20)@(negedge clk);
        command(8'h27,40,64'h2000000000000000,4,0);repeat(20)@(negedge clk);
        if(errors!=5 || acquisition_request || active_period!=2500) $fatal(1,"invalid exposure isolation");
        command(8'h27,40,2500,4,0);wait(acquisition_request);repeat(30)@(negedge clk);
        if(!stop || tx_request || active_window!=512) $fatal(1,"early config/ACK while frame busy");
        frontend_busy=0;reply(0);
        if(active_window!=40 || active_period!=2500 || requested_result_stride!=4) $fatal(1,"200 us config");
        command(8'h27,1024,64'h0000000800000000,1,0);reply(0);
        if(active_period!=64'h0000000800000000) $fatal(1,"long period truncated");
        command(8'h24,40,3000,1,0);reply(1);
        if(active_period!=64'h0000000800000000) $fatal(1,"legacy command corrupted fast profile");
        $display("PASS: extended exposure CRC/range isolation, drain ACK, uint64 period and legacy rejection");$finish;
    end
    initial begin #1000000;$fatal(1,"extended control timeout");end
endmodule

module tb_long_exposure_stop;
    reg clk=0,rst_n=0,run=1;always #5 clk=~clk;
    reg [63:0] period_pixels=64'h0000000800000000;
    wire busy,frame_start,tag_valid;wire [10:0] tag_index;wire [63:0] frame_timestamp;
    wire ccd_sh;integer pixels=0;realtime stopped_at;
    ccd_afe_timing #(.DYNAMIC_PERIOD(1),.FAST_PROFILE(1)) dut(.clk(clk),.rst_n(rst_n),
        .run(run),.period_pixels(period_pixels),.busy(busy),.frame_start(frame_start),
        .frame_timestamp(frame_timestamp),.tag_valid(tag_valid),.tag_index(tag_index),.ccd_sh(ccd_sh));
    always @(posedge clk) if(tag_valid && dut.launch_ce) pixels=pixels+1;
    initial begin
        repeat(4)@(negedge clk);rst_n=1;wait(frame_start);repeat(4)@(negedge clk);
        if(dut.active_tail_pixels!=period_pixels-2124) $fatal(1,"64-bit tail latch");
        period_pixels=2500; // Must not shorten an in-flight integration interval.
        wait(dut.state==5);repeat(100)@(negedge clk);
        if(dut.active_tail_pixels==376) $fatal(1,"in-flight period changed");
        run=0;stopped_at=$realtime;wait(!busy);
        if(pixels!=2048 || $realtime-stopped_at>2000) $fatal(1,"long exposure stop truncated/waited idle tail");
        $display("PASS: uint64 integration tail latched; stop drains full line without waiting long idle");$finish;
    end
    initial begin #1000000;$fatal(1,"long stop timeout");end
endmodule

module tb_result_stride;
    reg clk=0,rst_n=0,s_valid=0,m_ready=0;always #5 clk=~clk;
    wire s_ready,m_valid;reg [31:0] stride=4;integer consumed=0,selected=0;
    result_export_control dut(.*);
    always @(posedge clk) if(rst_n) begin
        if(s_valid && s_ready) consumed=consumed+1;
        if(m_valid && m_ready) begin
            if((consumed-1)%4!=0) $fatal(1,"selection phase wrong");selected=selected+1;
        end
    end
    initial begin
        repeat(4)@(negedge clk);rst_n=1;s_valid=1;
        repeat(20)@(negedge clk);
        if(s_ready || consumed || !m_valid) $fatal(1,"backpressure bypassed selected result");
        m_ready=1;repeat(16)@(negedge clk);s_valid=0;
        if(consumed!=16 || selected!=4) $fatal(1,"stride count");
        $display("PASS: independent RESULT stride and selected-packet backpressure");$finish;
    end
endmodule
