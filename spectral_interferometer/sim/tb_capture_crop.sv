`timescale 1ns/1ps
module tb_capture_crop;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,s_valid=0,s_first=0,s_last=0,m_ready=0,read_enable=0;
    reg [11:0] s_data=0;reg [31:0] s_frame_id=0;
    wire [63:0] s_timestamp=64'h1234000000000000+s_frame_id;
    wire [63:0] m_timestamp;
    wire m_valid,m_first,m_last;wire [11:0] m_data;
    wire [31:0] m_frame_id,dropped_frames,malformed_frames;
    frame_ping_pong #(.WIDTH(12),.CAPTURE_DEPTH(2048),.CAPTURE_FIRST(512)) dut(.*,.capture_first(11'd512),.idle());
    integer outputs=0,cycles=0,expected_id;
    reg [8:0] complete_frames=0;
    reg stalled=0;reg [45:0] held;
    wire [45:0] bundle={m_data,m_first,m_last,m_frame_id};
    function [11:0] value(input integer id,input integer pixel);
        value=(id*17+pixel)&4095;
    endfunction
    task send(input integer f,input integer count,input integer last_flag,input integer corrupt_id);
        integer i;
        begin
            for(i=0;i<count;i=i+1) begin
                @(negedge clk);s_valid=1;s_first=i==0;s_last=last_flag && i==count-1;
                s_frame_id=100+f+((corrupt_id && i==999) ? 1 : 0);s_data=value(100+f,i);
                @(posedge clk);
            end
            if(count==2048 && last_flag && !corrupt_id) complete_frames[f]=1;
            @(negedge clk);s_valid=0;s_first=0;s_last=0;
        end
    endtask
    always @(negedge clk) if(rst_n) m_ready=read_enable && cycles%13<8;
    always @(posedge clk) if(rst_n) begin
        cycles<=cycles+1;
        if(stalled && (!m_valid || bundle!==held)) $fatal(1,"Stall corruption");
        held<=bundle;stalled<=m_valid && !m_ready;
        if(m_valid && !complete_frames[m_frame_id-100]) $fatal(1,"Published before full 2048 input pixels");
        if(m_valid && m_ready) begin
            expected_id=outputs<1024 ? 100 : outputs<2048 ? 101 : 108;
            if(m_timestamp !== 64'h1234000000000000+expected_id) $fatal(1,"Crop timestamp mismatch");
            if(m_frame_id!=expected_id || m_first!=(outputs%1024==0) || m_last!=(outputs%1024==1023)) $fatal(1,"Frame order/bounds");
            if(m_data!==value(expected_id,512+outputs%1024)) $fatal(1,"Crop offset or data mismatch");
            outputs=outputs+1;
        end
    end
    initial begin
        repeat(5) @(negedge clk);rst_n=1;
        send(0,2048,1,0);send(1,2048,1,0);send(2,2048,1,0);
        if(dropped_frames!=1 || malformed_frames!=0) $fatal(1,"Full-cache drop count");
        read_enable=1;wait(outputs==2048);repeat(5) @(negedge clk);
        send(3,1600,1,0); // Entire crop exists, but the original frame is short.
        send(4,2048,1,1); // Frame ID changes while capturing.
        send(5,2048,0,0); // Missing end marker at the required pixel.
        send(6,100,0,0);  // Aborted by the next first marker.
        send(7,1,1,0);    // Also malformed: count both simultaneous errors.
        repeat(5) @(negedge clk);
        if(malformed_frames!=5 || outputs!=2048 || m_valid) $fatal(1,"Malformed frame leaked or wrong count: %0d",malformed_frames);
        send(8,2048,1,0);
        wait(outputs==3072);repeat(5) @(negedge clk);
        if(dropped_frames!=1 || malformed_frames!=5) $fatal(1,"Recovery counts");
        $display("PASS: 2048-to-1024 crop, delayed publication, full drop, malformed tails/IDs, recovery and stalls");$finish;
    end
    initial begin #1000000;$fatal(1,"Timeout");end
endmodule
