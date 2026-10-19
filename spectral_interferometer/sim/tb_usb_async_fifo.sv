`timescale 1ns/1ps
module usb_async_fifo_case #(
    parameter realtime WR_HALF=5.0,RD_HALF=10.417
)(output reg done=0);
    reg wr_clk=0,rd_clk=0,rst=1;
    always #(WR_HALF) wr_clk=~wr_clk;
    always #(RD_HALF) rd_clk=~rd_clk;
    reg s_valid=0,s_last=0,m_ready=0;
    reg [15:0] s_data=0;
    wire s_ready,m_valid,m_last,wr_busy,rd_busy;
    wire [15:0] m_data;
    integer sent=0,received=0,stall_count=0,cycles=0;
    integer epoch_base=0;
    reg force_stall=0;
    function [15:0] expected(input integer index);
        expected=epoch_base+index;
    endfunction
    reg stalled=0;
    reg [16:0] held;
    usb_async_fifo #(.DEPTH(32)) dut(.*);
    always @(posedge wr_clk) if(!rst) begin
        if(s_valid && s_ready) sent=sent+1;
        if(s_valid && !s_ready) stall_count=stall_count+1;
    end
    always @(negedge wr_clk) if(!rst) begin
        s_valid=(sent<2000);s_data=expected(sent);s_last=(sent%34==33);
    end
    always @(negedge rd_clk) begin
        cycles=cycles+1;
        m_ready=!rst && !force_stall && cycles>100 && cycles%17>6;
    end
    always @(posedge rd_clk) if(!rst) begin
        if(stalled && (!m_valid || {m_last,m_data} !== held)) $fatal(1,"stalled data changed");
        stalled=m_valid && !m_ready;held={m_last,m_data};
        if(m_valid && m_ready) begin
            if(m_data !== expected(received) || m_last !== (received%34==33))
                $fatal(1,"CDC ordering mismatch at %0d got %0d",received,m_data);
            received=received+1;
        end
    end else stalled=0;
    initial begin
        repeat(20) @(posedge wr_clk);#1;rst=0;
        wait(received==2000);
        repeat(20) @(posedge rd_clk);
        if(m_valid || stall_count==0) $fatal(1,"empty/full coverage failed");
        // Restart both ends as a fresh stream epoch after reset.
        @(posedge wr_clk);#1;rst=1;s_valid=0;
        repeat(20) @(posedge wr_clk);
        sent=0;received=0;#1;rst=0;
        wait(received==2000);
        // Queue an identifiable old epoch while the consumer is blocked.
        @(posedge wr_clk);#1;rst=1;s_valid=0;force_stall=1;
        repeat(20) @(posedge wr_clk);
        #1;sent=0;received=0;epoch_base=16'h4000;rst=0;
        wait(sent>=16);
        repeat(20) @(posedge rd_clk);
        if(!m_valid || received!=0 || sent<16) $fatal(1,"queued-reset coverage failed");
        @(posedge wr_clk);#1;rst=1;s_valid=0;
        repeat(20) @(posedge wr_clk);
        #1;sent=0;received=0;epoch_base=16'h8000;rst=0;force_stall=0;
        wait(received==2000);
        repeat(20) @(posedge rd_clk);
        if(m_valid) $fatal(1,"unexpected stale word after final epoch");
        $display("PASS: CDC case wr_half=%0f rd_half=%0f, 6000 received words and queued reset",WR_HALF,RD_HALF);
        done=1;
    end
    initial begin #1000000;$fatal(1,"timeout");end
endmodule

module tb_usb_async_fifo;
    wire tx_done,rx_done;
    usb_async_fifo_case tx(.done(tx_done));
    usb_async_fifo_case #(.WR_HALF(10.417),.RD_HALF(5.0)) rx(.done(rx_done));
    initial begin
        wait(tx_done && rx_done);
        $display("PASS: actual XPM async FIFO, both clock directions, 12000 words, queued-reset isolation");
        $finish;
    end
endmodule
