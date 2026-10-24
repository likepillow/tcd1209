`timescale 1ns/1ps
module tb_usb_large_fifo;
    reg wr_clk=0,rd_clk=0,rst=1,drain=0;
    always #5 wr_clk=~wr_clk;
    always #16.667 rd_clk=~rd_clk;
    reg s_valid=0,s_last=0,m_ready=0;reg [15:0] s_data=0;
    wire s_ready,m_valid,m_last,wr_busy,rd_busy;wire [15:0] m_data;
    integer sent=0,received=0,cycles=0;
    usb_async_fifo #(.DEPTH(32768)) dut(.*);
    always @(posedge wr_clk) if(!rst && s_valid && s_ready) sent=sent+1;
    always @(negedge wr_clk) if(!rst) begin
        s_valid=sent<33000;s_data=sent;s_last=sent%34==33;
    end
    always @(negedge rd_clk) begin cycles=cycles+1;m_ready=drain && cycles%17>6;end
    always @(posedge rd_clk) if(!rst && m_valid && m_ready) begin
        if(m_data!==received[15:0] || m_last!==(received%34==33)) $fatal(1,"large FIFO order/packet-end corruption");
        received=received+1;
    end
    initial begin
        repeat(8)@(negedge wr_clk);rst=0;
        wait(sent>=32760);wait(!s_ready);repeat(30)@(negedge wr_clk);
        // XPM FWFT may prefetch a few words into output registers in addition to RAM depth.
        if(sent<32768 || sent>32772 || received!=0) $fatal(1,"large FIFO capacity unexpected: %0d",sent);
        drain=1;wait(received==33000);repeat(50)@(negedge rd_clk);
        if(sent!=received || m_valid) $fatal(1,"large FIFO did not drain");
        $display("PASS: 32768-word XPM FIFO fills, stalls and drains 33000 ordered words across 100/30 MHz");$finish;
    end
    initial begin #10000000;$fatal(1,"large FIFO timeout");end
endmodule
