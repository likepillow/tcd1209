`timescale 1ns/1ps
module tb_ad9945_init;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0;
    wire ad_sck,ad_sdata,ad_sl,configure_done;
    ad9945_init #(.CLAMP_LEVEL(8'h9b),.VGA_GAIN(10'h2a5)) dut(.*);
    integer bit_count=0,word_count=0,successful_runs=0;
    reg [15:0] received=0;
    time release_time=0,last_fall=0,last_data_change=0,last_sl_fall=0,last_rise=0;
    reg active=0;
    function [15:0] expected(input integer n);
        case(n) 0:expected=16'h838d;1:expected=16'h0000;2:expected=16'h0001;
            3:expected=16'h09b2;4:expected=16'h2a53;default:expected=0;endcase
    endfunction
    always @(negedge rst_n) begin active=0;bit_count=0;word_count=0;end
    always @(posedge rst_n) release_time=$time;
    always @(negedge ad_sl) if(rst_n) begin
        if($time-release_time<2000000) $fatal(1,"Startup wait shorter than 2 ms");
        if(ad_sck) $fatal(1,"SCK not idle when SL asserts");
        last_sl_fall=$time;bit_count=0;received=0;active=1;
    end
    always @(ad_sdata) begin
        if(rst_n && active && last_fall>last_sl_fall && $time-last_fall<10) $fatal(1,"SDATA changed too early after SCK falling edge");
        last_data_change=$time;
    end
    always @(posedge ad_sck) if(rst_n) begin
        if(!active || ad_sl || bit_count>=16) $fatal(1,"Unexpected SCK rising edge");
        if($time-last_sl_fall<10 || $time-last_data_change<10) $fatal(1,"Serial setup violation");
        if(bit_count>0 && $time-last_rise!=1000) $fatal(1,"SCK frequency differs from 1 MHz");
        last_rise=$time;received[bit_count]=ad_sdata;bit_count=bit_count+1;
    end
    always @(negedge ad_sck) if(rst_n) begin
        if(active && $time-last_rise!=500) $fatal(1,"SCK high width");
        last_fall=$time;
    end
    always @(posedge ad_sl) if(rst_n && active) begin
        if(bit_count!=16 || received!==expected(word_count)) $fatal(1,"Serial word %0d: %h, %0d bits",word_count,received,bit_count);
        if($time-last_fall<10) $fatal(1,"SL hold violation");
        word_count=word_count+1;active=0;
    end
    always @(posedge configure_done) if(rst_n) begin
        if(word_count!=5 || !ad_sl || ad_sck) $fatal(1,"Premature configuration completion");
        successful_runs=successful_runs+1;
    end
    initial begin
        repeat(5) @(negedge clk);rst_n=1;
        wait(active && bit_count==7);
        @(negedge clk);rst_n=0;
        repeat(5) @(negedge clk);
        if(configure_done || ad_sck || !ad_sl) $fatal(1,"Reset did not abort transaction");
        rst_n=1;
        wait(configure_done);repeat(250) @(negedge clk);
        if(successful_runs!=1 || word_count!=5 || !configure_done || !ad_sl || ad_sck) $fatal(1,"Done not stable");
        $display("PASS: AD9945 startup delay, five LSB-first writes, serial timing and reset recovery");$finish;
    end
    initial begin #6000000;$fatal(1,"Timeout");end
endmodule
