`timescale 1ns/1ps
module tb_fx2_packets;
    reg ifclk=0,rst_n=0;
    always #16.666667 ifclk=~ifclk; // Candidate 30 MHz interface.
    reg ep2_has_data=0,ep6_has_space=1,rx_ready=1;
    wire tx_ready,rx_valid,fd_drive,slrd_n,slwr_n,sloe_n,pktend_n,slcs_n;
    wire [15:0] rx_data,fd_out;
    wire [1:0] fifo_addr;
    wire [15:0] fd_in=0;
    integer sent=0,writes=0,words=0,full_packets=0,short_packets=0;
    wire tx_valid=sent<1558;
    wire [15:0] tx_data=sent;
    // 256 words; 1 word; 257 words; 1044 words (one S0 SPIF packet).
    wire tx_last=sent==255 || sent==256 || sent==513 || sent==1557;
    fx2_slave_fifo dut(.*);
    always @(posedge ifclk) if(rst_n) begin
        if(tx_valid && tx_ready) sent<=sent+1;
        if(!slwr_n) begin
            if(!ep6_has_space || !fd_drive || !sloe_n || fifo_addr!=2)
                $fatal(1,"invalid bus write");
            if(fd_out!==writes[15:0]) $fatal(1,"lost/duplicated word");
            writes=writes+1;words=words+1;
            if(words==256) begin words=0;full_packets=full_packets+1;end
        end
        if(!pktend_n) begin
            if(!slwr_n || words==0) $fatal(1,"empty or overlapping short commit");
            short_packets=short_packets+1;words=0;
        end
    end
    initial begin
        repeat(4)@(negedge ifclk);rst_n=1;
        wait(writes==100);@(negedge ifclk);ep6_has_space=0;
        repeat(30)@(negedge ifclk);ep6_has_space=1;
        wait(short_packets==3);repeat(15)@(negedge ifclk);
        if(sent!=1558 || writes!=1558 || full_packets!=6 || words!=0)
            $fatal(1,"packet accounting");
        $display("PASS: FX2 long packets, exact full boundary, short commit, backpressure; 1558 words");
        $finish;
    end
    initial begin #1000000;$fatal(1,"timeout");end
endmodule
