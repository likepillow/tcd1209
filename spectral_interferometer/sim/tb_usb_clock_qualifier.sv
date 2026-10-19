`timescale 1ns/1ps
module tb_usb_clock_qualifier;
    reg clk=0, reset_n=0, ifclk=0;
    real half_period=10.416667;
    reg enabled=1;
    wire qualified;
    always #5 clk=~clk;
    always begin #(half_period); if (enabled) ifclk=~ifclk; else ifclk=0; end
    usb_clock_qualifier dut(.*);
    initial begin
        #100;reset_n=1;
        #300000;if(qualified) $fatal(1,"48 MHz must not qualify");
        half_period=16.666667;
        #300000;if(!qualified) $fatal(1,"30 MHz must qualify");
        enabled=0;
        #90000;if(qualified) $fatal(1,"Stopped IFCLK must revoke qualification");
        enabled=1;
        #300000;if(!qualified) $fatal(1,"30 MHz restart must recover");
        reset_n=0;#100;if(qualified) $fatal(1,"Reset must revoke qualification");
        reset_n=1;half_period=10.416667;
        #300000;if(qualified) $fatal(1,"48 MHz restart must remain blocked");
        $display("PASS: standalone IFCLK 48/30 MHz, clock loss, restart, reset");
        $finish;
    end
endmodule
