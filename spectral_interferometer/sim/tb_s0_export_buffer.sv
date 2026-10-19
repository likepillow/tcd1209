`timescale 1ns/1ps
module tb_s0_export_buffer;
    reg clk=0,rst_n=0,s_valid=0,s_first=0,s_last=0,m_ready=0;
    always #5 clk=~clk;
    reg [31:0] period_frames=2,s_frame_id=0;reg [63:0] s_timestamp=0;
    reg [11:0] s_data=0;
    wire s_ready,m_valid,m_first,m_last,fault;
    wire [11:0] m_data;wire [31:0] m_frame_id,busy_skipped_frames,rate_skipped_frames;wire [63:0] m_timestamp;
    integer received=0;
    s0_export_buffer #(.DEPTH(16)) dut(.*,.idle());
    always @(posedge clk) if(rst_n) begin
        if(!s_ready || fault) $fatal(1,"export blocked producer or faulted");
        if(m_valid && m_ready) begin
            if(m_frame_id!=0 || m_timestamp!=64'h123456789abcdef0 || m_data!=received || m_first!=(received==0) || m_last!=(received==15)) $fatal(1,"data/metadata mismatch");
            received=received+1;
        end
    end
    task send_frame(input integer frame);
        integer n;
        begin
            for(n=0;n<16;n=n+1) begin
                @(negedge clk);s_valid=1;s_first=n==0;s_last=n==15;s_data=n;s_frame_id=frame;s_timestamp=64'h123456789abcdef0+frame;
            end
            @(negedge clk);s_valid=0;
        end
    endtask
    initial begin
        repeat(4) @(negedge clk);rst_n=1;
        send_frame(0);send_frame(1);send_frame(2);send_frame(3);
        if(busy_skipped_frames!=1 || rate_skipped_frames!=2) $fatal(1,"selection counters wrong");
        m_ready=1;wait(received==16);@(negedge clk);
        period_frames=0;send_frame(4);
        if(m_valid || rate_skipped_frames!=3) $fatal(1,"disable failed");
        $display("PASS: S0 nonblocking export, rate selection, busy whole-frame skip, disable");$finish;
    end
    initial begin #100000;$fatal(1,"timeout");end
endmodule
