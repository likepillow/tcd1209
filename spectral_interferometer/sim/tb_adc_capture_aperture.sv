`timescale 1ns/1ps
// Sensitivity experiment, NOT a worst-case AD9945 model or board signoff.
module tb_adc_capture_aperture;
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0, launch_ce=0, tag_valid=0;
    reg [10:0] tag_index=0;
    reg [31:0] tag_frame_id=0;
    reg [11:0] adc_data=12'hbad;
    wire valid20,valid40,fault20,fault40;
    wire [11:0] data20,data40;
    wire [10:0] index20,index40;
    wire [31:0] frame20,frame40;
    adc_pixel_align #(.CAPTURE_DELAY(2)) current_capture(
        .clk(clk),.rst_n(rst_n),.launch_ce(launch_ce),.tag_valid(tag_valid),
        .tag_index(tag_index),.tag_frame_id(tag_frame_id),.adc_data(adc_data),
        .m_valid(valid20),.m_data(data20),.m_index(index20),.m_frame_id(frame20),
        .m_first(),.m_last(),.fault(fault20));
    adc_pixel_align #(.CAPTURE_DELAY(4)) candidate_capture(
        .clk(clk),.rst_n(rst_n),.launch_ce(launch_ce),.tag_valid(tag_valid),
        .tag_index(tag_index),.tag_frame_id(tag_frame_id),.adc_data(adc_data),
        .m_valid(valid40),.m_data(data40),.m_index(index40),.m_frame_id(frame40),
        .m_first(),.m_last(),.fault(fault40));
    realtime arrival_ns;
    integer conversions=0,case_id=0,count20=0,count40=0,bad20=0,bad40=0;
    reg [11:0] next_data;
    function [11:0] sample(input integer pixel,input integer frame);
        sample=((pixel*37) ^ (frame*811) ^ (pixel>>2)) & 4095;
    endfunction
    always @(posedge clk) begin
        if(rst_n && launch_ce) begin
            next_data=conversions>=10 ? sample(conversions-10,case_id) : 12'hbad;
            adc_data <= #(arrival_ns) next_data;
            conversions=conversions+1;
        end
        #1;
        if(rst_n && valid20) begin
            if(index20!==count20[10:0] || frame20!==case_id)
                $fatal(1,"20 ns metadata mismatch");
            if(data20!==sample(count20,case_id)) bad20=bad20+1;
            count20=count20+1;
        end
        if(rst_n && valid40) begin
            if(index40!==count40[10:0] || frame40!==case_id)
                $fatal(1,"40 ns metadata mismatch");
            if(data40!==sample(count40,case_id)) bad40=bad40+1;
            count40=count40+1;
        end
    end
    task automatic exercise(input realtime delay_ns,input integer identity);
        integer n;
        @(negedge clk);rst_n=0;launch_ce=0;tag_valid=0;
        repeat(10) @(negedge clk);
        arrival_ns=delay_ns;case_id=identity;conversions=0;
        count20=0;count40=0;bad20=0;bad40=0;adc_data=12'hbad;rst_n=1;
        for(n=0;n<76;n=n+1) begin
            @(negedge clk);launch_ce=1;tag_valid=n<64;
            tag_index=n;tag_frame_id=case_id;
            @(negedge clk);launch_ce=0;tag_valid=0;
            repeat(18) @(negedge clk);
        end
        repeat(10) @(negedge clk);
        if(count20!=64 || count40!=64 || fault20 || fault40)
            $fatal(1,"accounting/overlap fault");
        if(delay_ns<20 && bad20!=0) $fatal(1,"early data unexpectedly failed 20 ns");
        if(delay_ns>20 && bad20==0) $fatal(1,"late data did not expose old capture");
        if(delay_ns<40 && bad40!=0) $fatal(1,"candidate failed within experimental 40 ns aperture");
        if(delay_ns>40 && bad40==0) $fatal(1,"candidate test failed to expose its own late-data limit");
        $display("APERTURE: arrival=%0.3f ns, 20 ns bad=%0d/64, 40 ns bad=%0d/64",delay_ns,bad20,bad40);
    endtask
    initial begin
        exercise(9.5,1);exercise(15.0,2);exercise(19.0,3);
        exercise(23.295,4);exercise(30.0,5);exercise(39.0,6);exercise(45.0,7);
        $display("PASS: ADC late-arrival sensitivity; no deployed RTL changed; not board signoff");
        $finish;
    end
    initial begin #1000000;$fatal(1,"timeout");end
endmodule
