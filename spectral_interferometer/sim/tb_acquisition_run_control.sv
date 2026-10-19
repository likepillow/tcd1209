`timescale 1ns/1ps
module tb_acquisition_run_control;
    reg clk=0,rst_n=0,request=0,requested_run=0;
    reg frontend_busy=0,acquisition_idle=1,output_idle=1;
    wire ack,enabled;
    always #5 clk=~clk;
    acquisition_run_control dut(.*);

    task command(input run_value);
        begin
            @(negedge clk);requested_run=run_value;request=1;
            wait(ack);@(negedge clk);request=0;wait(!ack);
        end
    endtask

    initial begin
        repeat(4) @(negedge clk);rst_n=1;
        if(enabled || ack) $fatal(1,"power-up must be stopped");
        command(1);
        if(!enabled) $fatal(1,"start failed");
        // Idempotent start must acknowledge and retain state.
        command(1);
        frontend_busy=1;acquisition_idle=0;output_idle=0;
        fork
            begin command(0);end
            begin
                repeat(8) @(posedge clk);
                if(enabled || ack) $fatal(1,"stop did not gate new frame or ACKed before drain");
                frontend_busy=0;
                repeat(8) @(posedge clk);
                if(ack) $fatal(1,"ACKed while acquisition/output still active");
                acquisition_idle=1;output_idle=1;
            end
        join
        if(enabled) $fatal(1,"stop failed");
        command(0);
        if(enabled) $fatal(1,"idempotent stop changed state");
        $display("PASS: run control defaults stopped, is idempotent, and ACKs only after drain");
        $finish;
    end
    initial begin #10000;$fatal(1,"timeout");end
endmodule
