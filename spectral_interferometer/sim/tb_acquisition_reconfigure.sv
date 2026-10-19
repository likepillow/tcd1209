`timescale 1ns/1ps
module tb_acquisition_reconfigure;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,request=0,frontend_busy=1,acquisition_idle=0,output_idle=0;
    reg [10:0] requested_window=1024;
    reg [12:0] requested_period=4999;
    wire ack,stop,pipeline_reset_n;
    wire [10:0] active_window;
    wire [12:0] active_period;
    acquisition_reconfigure dut(.*);
    integer reset_cycles=0;
    always @(posedge clk) if(rst_n && !pipeline_reset_n) reset_cycles=reset_cycles+1;
    task verify_wait;
        begin
            repeat(40) @(negedge clk);
            if(!stop || ack || !pipeline_reset_n || active_window!=512 || active_period!=2114)
                $fatal(1,"Changed configuration before drain");
        end
    endtask
    initial begin
        repeat(4) @(negedge clk);rst_n=1;request=1;
        verify_wait();frontend_busy=0;
        verify_wait();acquisition_idle=1;
        verify_wait();output_idle=1;
        repeat(10) @(negedge clk);output_idle=0;
        verify_wait();output_idle=1;
        wait(ack);@(negedge clk);
        if(reset_cycles!=16 || active_window!=1024 || active_period!=4999 || !stop || !pipeline_reset_n)
            $fatal(1,"Reset width or applied values");
        repeat(20) @(negedge clk);
        if(!ack || !stop) $fatal(1,"ACK not held");
        request=0;repeat(2) @(negedge clk);
        if(stop || ack) $fatal(1,"Did not resume");
        rst_n=0;@(negedge clk);rst_n=1;@(negedge clk);
        if(active_window!=512 || active_period!=2114) $fatal(1,"Boot defaults");
        $display("PASS: W/T waits for CCD, pipeline and packet drain; reset 16 cycles; ACK hold and boot defaults");
        $finish;
    end
    initial begin #100000;$fatal(1,"Timeout");end
endmodule
