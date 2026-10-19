`timescale 1ns/1ps
module tb_export_control;
    reg clk=0,rst_n=0,rx_valid=0,tx_ready=0,tx_grant=0;
    always #5 clk=~clk;
    reg [7:0] rx_data=0;
    wire rx_ready,tx_valid,tx_last,tx_request,sequence_take,receive_error;
    wire [7:0] tx_data;
    wire [31:0] export_period_frames;
    wire acquisition_request;
    reg acquisition_ack=0;
    wire [10:0] requested_window;
    wire [12:0] requested_period;
    wire sb,sw,sc,kb,kw,kc;
    integer errors=0,packets=0,cycle=0,acks=0;
    reg [31:0] expected_period=1;
    calibration_control dut(.clk(clk),.rst_n(rst_n),
        .acquisition_request(acquisition_request),.acquisition_ack(acquisition_ack),
        .requested_window(requested_window),.requested_period(requested_period),
        .rx_valid(rx_valid),.rx_ready(rx_ready),.rx_data(rx_data),
        .tx_valid(tx_valid),.tx_ready(tx_ready),.tx_data(tx_data),.tx_last(tx_last),
        .tx_request(tx_request),.tx_grant(tx_grant),.packet_sequence(32'd0),
        .sequence_take(sequence_take),.receive_error(receive_error),
        .source_version(32'd7),.k_version(32'd8),
        .source_begin(sb),.source_we(sw),.source_commit(sc),.source_ack(1'b0),.source_error(1'b0),
        .k_begin(kb),.k_we(kw),.k_commit(kc),.k_ack(1'b0),.k_error(1'b0),
        .export_period_frames(export_period_frames));
    always @(negedge clk) begin cycle=cycle+1;tx_ready=cycle%7>2;end
    always @(posedge clk) if(rst_n) begin
        if(sb || sw || sc || kb || kw || kc) $fatal(1,"EXPORT changed calibration");
        if(receive_error) errors=errors+1;
        if(sequence_take) begin
            if(export_period_frames!==expected_period || dut.ack_status!=0) $fatal(1,"early or failed ACK");
            acks=acks+1;
        end
        if(tx_valid && tx_ready && tx_last) packets=packets+1;
    end
    function [31:0] crc_byte(input [31:0] c0,input [7:0] d);
        reg [31:0] c;integer j;
        begin c=c0^d;for(j=0;j<8;j=j+1)c=c[0]?(c>>1)^32'hedb88320:c>>1;crc_byte=c;end
    endfunction
    task send_byte(input [7:0] value);
        begin
            @(negedge clk);rx_valid=1;rx_data=value;
            @(posedge clk);while(!rx_ready) @(posedge clk);
            @(negedge clk);rx_valid=0;
        end
    endtask
    task command(input [31:0] period,input bit corrupt);
        reg [319:0] body;reg [31:0] crc;integer i;
        begin
            body=0;body[31:0]=32'h46495053;body[39:32]=1;body[47:40]=8'h23;
            body[95:64]=4;body[127:96]=73;body[159:128]=32'hffffffff;body[319:288]=period;
            crc=32'hffffffff;
            for(i=0;i<40;i=i+1) begin crc=crc_byte(crc,body[i*8+:8]);send_byte(body[i*8+:8]);end
            // No effects may occur before all CRC bytes have arrived.
            if(export_period_frames!==expected_period || tx_request) $fatal(1,"unvalidated command leaked");
            crc=~crc;if(corrupt)crc=crc^1;
            for(i=0;i<4;i=i+1)send_byte(crc[i*8+:8]);
            if(!corrupt)expected_period=period;
        end
    endtask
    task accept_reply;
        begin
            wait(tx_request);repeat(12)@(negedge clk);
            if(export_period_frames!==expected_period) $fatal(1,"configuration not stored before reply");
            tx_grant=1;@(negedge clk);tx_grant=0;
            wait(packets==acks);repeat(3)@(negedge clk);
        end
    endtask
    task acquisition_command(input [31:0] w,input [31:0] t,input bit corrupt);
        reg [351:0] body;reg [31:0] crc;integer i;
        begin
            body=0;body[31:0]=32'h46495053;body[39:32]=1;body[47:40]=8'h24;
            body[95:64]=8;body[127:96]=74;body[159:128]=32'hffffffff;
            body[319:288]=w;body[351:320]=t;crc=32'hffffffff;
            for(i=0;i<44;i=i+1) begin crc=crc_byte(crc,body[i*8+:8]);send_byte(body[i*8+:8]);end
            if(acquisition_request || tx_request) $fatal(1,"W/T acted before CRC");
            crc=~crc;if(corrupt)crc=crc^1;
            for(i=0;i<4;i=i+1)send_byte(crc[i*8+:8]);
        end
    endtask
    initial begin
        repeat(4)@(negedge clk);rst_n=1;
        command(99,1);repeat(20)@(negedge clk);
        if(errors!=1 || export_period_frames!=1 || tx_request) $fatal(1,"bad CRC applied");
        command(0,0);accept_reply();command(5,0);accept_reply();command(32'hffffffff,0);accept_reply();
        if(acks!=3 || packets!=3 || errors!=1) $fatal(1,"missing responses");
        acquisition_command(1025,2114,0);repeat(30)@(negedge clk);
        acquisition_command(0,5000,0);repeat(30)@(negedge clk);
        acquisition_command(0,2113,0);repeat(30)@(negedge clk);
        acquisition_command(0,2114,1);repeat(30)@(negedge clk);
        if(errors!=5 || acquisition_request || tx_request) $fatal(1,"invalid W/T accepted");
        acquisition_command(1024,4999,0);wait(acquisition_request);
        repeat(30)@(negedge clk);
        if(requested_window!=1024 || requested_period!=4999 || tx_request) $fatal(1,"W/T latch or early ACK");
        acquisition_ack=1;@(negedge clk);acquisition_ack=0;accept_reply();
        if(acks!=4 || packets!=4) $fatal(1,"W/T response missing");
        $display("PASS: EXPORT CRC isolation, register update before ACK, held grant, three periods");$finish;
    end
    initial begin #100000;$fatal(1,"timeout");end
endmodule
