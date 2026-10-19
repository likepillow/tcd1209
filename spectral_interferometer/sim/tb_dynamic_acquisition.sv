`timescale 1ns/1ps
module tb_dynamic_acquisition;
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0,run=1;
    reg [12:0] period_pixels=2114;
    wire frame_start,ccd_sh;
    wire [63:0] frame_timestamp;
    ccd_afe_timing #(.DYNAMIC_PERIOD(1)) timing(
        .clk(clk),.rst_n(rst_n),.run(run),.period_pixels(period_pixels),
        .ccd_sh(ccd_sh),.frame_start(frame_start),.frame_timestamp(frame_timestamp));
    reg s_valid=0,s_first=0,s_last=0;
    reg [11:0] s_data=0;
    reg [10:0] capture_first=0;
    reg [31:0] s_frame_id=0;
    wire m_valid,m_first,m_last;
    wire [11:0] m_data;
    wire [31:0] m_frame_id,dropped_frames,malformed_frames;
    frame_ping_pong #(.WIDTH(12),.CAPTURE_DEPTH(2048),.DYNAMIC_WINDOW(1)) banks(
        .clk(clk),.rst_n(rst_n),.capture_first(capture_first),
        .s_valid(s_valid),.s_first(s_first),.s_last(s_last),.s_data(s_data),
        .s_frame_id(s_frame_id),.s_timestamp(64'd0),.m_valid(m_valid),.m_ready(1'b1),
        .m_data(m_data),.m_first(m_first),.m_last(m_last),.m_frame_id(m_frame_id),
        .dropped_frames(dropped_frames),.malformed_frames(malformed_frames));
    integer outputs=0,offsets[0:2];
    always @(posedge clk) if(rst_n && m_valid) begin
        if(m_data !== offsets[m_frame_id]+outputs%1024) $fatal(1,"Dynamic crop data mismatch");
        if(m_first!=(outputs%1024==0) || m_last!=(outputs%1024==1023)) $fatal(1,"Crop bounds");
        outputs=outputs+1;
    end
    task send_frame(input integer id,input integer start);
        integer i;
        begin
            for(i=0;i<2048;i=i+1) begin
                @(negedge clk);
                s_valid=1;s_first=(i==0);s_last=(i==2047);s_data=i;s_frame_id=id;
                // A mid-frame change must not affect this frame's crop.
                capture_first=i<100 ? start : 321;
            end
            @(negedge clk);s_valid=0;s_first=0;s_last=0;
            wait(outputs==(id+1)*1024);
            repeat(3) @(negedge clk);
        end
    endtask
    integer frames=0;
    reg [63:0] previous_time;
    always @(negedge clk) if(frame_start) begin
        if(frames==1 && frame_timestamp-previous_time!=42280) $fatal(1,"Default interval");
        if(frames==2 && frame_timestamp-previous_time!=99980) $fatal(1,"Maximum interval");
        if(frames==3 && frame_timestamp-previous_time!=50000) $fatal(1,"500 us interval");
        previous_time=frame_timestamp;
        frames=frames+1;
    end
    initial begin
        offsets[0]=0;offsets[1]=512;offsets[2]=1024;
        repeat(5) @(negedge clk);rst_n=1;
        fork
            begin send_frame(0,0);send_frame(1,512);send_frame(2,1024);end
            begin
                wait(frames==1);repeat(100) @(negedge clk);period_pixels=4999;
                wait(frames==2);repeat(100) @(negedge clk);period_pixels=2500;
                wait(frames==4);
            end
        join
        if(outputs!=3072 || dropped_frames || malformed_frames) $fatal(1,"Capture totals");
        $display("PASS: dynamic W endpoints and frame latch; T 422.8/999.8/500 us intervals");
        $finish;
    end
    initial begin #4000000;$fatal(1,"Timeout");end
endmodule
