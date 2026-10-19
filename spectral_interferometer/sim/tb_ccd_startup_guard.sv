`timescale 1ns/1ps
module tb_ccd_startup_guard;
    reg clk=0,rst_n=0,busy=0,frame_start=0,s_valid=0;
    wire m_valid,bypass_valid;
    always #5 clk=~clk;
    ccd_startup_guard #(.SETTLE_CYCLES(10)) dut(.*);
    ccd_startup_guard #(.SETTLE_CYCLES(0)) bypass(
        .clk(clk),.rst_n(rst_n),.busy(busy),.frame_start(frame_start),
        .s_valid(s_valid),.m_valid(bypass_valid));
    task tick(input bit b,input bit fs,input bit v,input bit expected);
        @(negedge clk);busy=b;frame_start=fs;s_valid=v;
        @(posedge clk);#1;
        if(m_valid !== expected || bypass_valid !== v) $fatal(1,"guard mismatch");
    endtask
    initial begin
        tick(0,0,0,0);rst_n=1;
        // Timeout occurs in the middle of this frame: never publish its tail.
        tick(1,1,0,0);
        repeat(14) tick(1,0,1,0);
        tick(1,1,0,0);
        repeat(20) tick(1,0,1,1);
        tick(1,1,0,0);tick(1,0,1,1);
        // Actual stop/restart must re-arm the settling interval.
        tick(0,0,0,0);tick(1,1,0,0);
        repeat(14) tick(1,0,1,0);
        tick(1,1,0,0);tick(1,0,1,1);
        // Reset while active must also re-arm, even without an idle cycle.
        @(negedge clk);rst_n=0;
        tick(1,0,1,0);rst_n=1;
        tick(1,1,0,0);repeat(14) tick(1,0,1,0);
        tick(1,1,0,0);tick(1,0,1,1);
        $display("PASS: startup whole-frame guard, re-arm, reset and diagnostic bypass");
        $finish;
    end
    initial begin #10000;$fatal(1,"timeout");end
endmodule
