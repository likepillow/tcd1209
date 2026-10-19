`timescale 1ns/1ps
module tb_board_clock_reset;
    reg clk_50mhz=0;always #10 clk_50mhz=~clk_50mhz;
    reg reset_button_n=0;
    wire clk_100mhz,locked,system_reset_n;
    board_clock_reset dut(.*);
    integer released_edges=0,checked_periods=0,release_count=0;
    realtime previous_edge=0;
    always @(negedge reset_button_n or negedge locked) begin
        released_edges=0;previous_edge=0;
        #0.001;
        if(system_reset_n!==0) $fatal(1,"reset did not assert without a running clock");
    end
    always @(posedge clk_100mhz) begin
        if(reset_button_n && locked) begin
            released_edges=released_edges+1;
            if(previous_edge>0) begin
                if($realtime-previous_edge<9.999 || $realtime-previous_edge>10.001)
                    $fatal(1,"MMCM output is not 100 MHz");
                checked_periods=checked_periods+1;
            end
            previous_edge=$realtime;
            #0.001;
            if(system_reset_n !== (released_edges>=16))
                $fatal(1,"reset release offset mismatch at edge %0d",released_edges);
        end
    end
    always @(posedge system_reset_n) begin
        if(!locked || !reset_button_n) $fatal(1,"release without lock");
        release_count=release_count+1;
    end
    initial begin
        #200;reset_button_n=1;
        wait(system_reset_n);repeat(200) @(posedge clk_100mhz);
        #2;reset_button_n=0;
        #70;reset_button_n=1;
        // Deliberate button bounce while the MMCM is relocking.
        #35;reset_button_n=0;
        #110;reset_button_n=1;
        wait(system_reset_n);repeat(200) @(posedge clk_100mhz);
        if(release_count!=2 || checked_periods<400) $fatal(1,"incomplete clock/reset coverage");
        $display("PASS: actual MMCME2_BASE 50-to-100 MHz, %0d periods, 16-edge reset release, reset/bounce/relock",checked_periods);
        $finish;
    end
    initial begin #100000; $fatal(1,"MMCM/reset timeout"); end
endmodule
