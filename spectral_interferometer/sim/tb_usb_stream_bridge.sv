`timescale 1ns/1ps
module tb_usb_stream_bridge;
    reg sys_clk=0,usb_clk=0,rst=1;
    always #5 sys_clk=~sys_clk;
    always #10.417 usb_clk=~usb_clk;
    reg [1:0] usb_reset=3;
    always @(posedge usb_clk or posedge rst)
        if(rst) usb_reset<=3;else usb_reset<={usb_reset[0],1'b0};
    reg s_valid=0,m_ready=0;
    reg [7:0] s_data=0;
    reg s_last=0;
    wire s_ready,m_valid,m_last,fault,w_valid,w_ready,w_last;
    wire [7:0] m_data;
    wire [15:0] w_data;
    integer sent=0,received=0,cycles=0;
    reg stalled=0;
    reg [8:0] held;
    usb_tx_bridge #(.DEPTH(32)) tx(.wr_clk(sys_clk),.rd_clk(usb_clk),.rst(rst),
        .s_valid(s_valid),.s_ready(s_ready),.s_data(s_data),.s_last(s_last),
        .m_valid(w_valid),.m_ready(w_ready),.m_data(w_data),.m_last(w_last),.fault(fault));
    usb_rx_bridge #(.DEPTH(32)) rx(.wr_clk(usb_clk),.rd_clk(sys_clk),.rst(usb_reset[1]),
        .s_valid(w_valid),.s_ready(w_ready),.s_data(w_data),.s_last(w_last),
        .m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_last(m_last));
    function [7:0] value(input integer n);value=n*73+19;endfunction
    always @(posedge sys_clk) if(!rst) begin
        if(s_valid && s_ready) sent=sent+1;
        if(stalled && (!m_valid || {m_last,m_data} !== held)) $fatal(1,"unstable output");
        stalled=m_valid && !m_ready;held={m_last,m_data};
        if(m_valid && m_ready) begin
            if(m_data !== value(received) || m_last !== (received%68==67))
                $fatal(1,"bridge mismatch byte %0d",received);
            received=received+1;
        end
        if(fault) $fatal(1,"packer fault");
    end
    always @(negedge sys_clk) if(!rst) begin
        cycles=cycles+1;
        s_valid=(sent<6800);s_data=value(sent);s_last=(sent%68==67);
        m_ready=(cycles>500 && cycles%23>12);
    end
    initial begin
        repeat(30) @(posedge sys_clk);#1;rst=0;
        wait(received==6800);
        repeat(100) @(posedge sys_clk);
        if(m_valid || sent!=6800) $fatal(1,"bridge did not drain");
        $display("PASS: USB bridges 6800 bytes across two real XPM crossings with backpressure");
        $finish;
    end
    initial begin #1000000;$fatal(1,"bridge timeout");end
endmodule
