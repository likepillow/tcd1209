`timescale 1ns/1ps
module tb_fx2_slave_fifo;
    reg ifclk=0,rst_n=0,ep2_has_data=1,ep6_has_space=0;
    always #10.416 ifclk=~ifclk;
    reg tx_valid=1,tx_last=1,rx_ready=1;
    reg [15:0] tx_data=16'h1234;
    wire tx_ready,rx_valid,fd_drive,slrd_n,slwr_n,sloe_n,pktend_n,slcs_n;
    wire [15:0] rx_data,fd_out;
    wire [1:0] fifo_addr;
    wire [15:0] fd_in=16'habcd;
    integer reads=0,writes=0,commits=0,received=0;
    fx2_slave_fifo dut(.*);
    always @(posedge ifclk) if(rst_n) begin
        if(fd_drive && !sloe_n) $fatal(1,"bus contention");
        if(!slrd_n) begin
            if(fifo_addr!=0 || sloe_n || !ep2_has_data || !slwr_n) $fatal(1,"invalid read");
            reads=reads+1;
        end
        if(rx_valid && rx_ready) begin
            if(rx_data!==16'habcd) $fatal(1,"read corruption");
            received=received+1;
        end
        if(!slwr_n) begin
            if(fifo_addr!=2 || !fd_drive || !ep6_has_space || fd_out!==16'h1234) $fatal(1,"invalid write");
            writes=writes+1;
        end
        if(!pktend_n) begin
            if(!slwr_n || fifo_addr!=2) $fatal(1,"invalid commit");
            commits=commits+1;
        end
    end
    initial begin
        repeat(4)@(negedge ifclk);rst_n=1;
        // After the first read the arbiter prefers TX, but EP6 remains full.
        // A second OUT word must still be serviced without host IN progress.
        wait(received==2);@(negedge ifclk);ep2_has_data=0;ep6_has_space=1;
        wait(tx_ready);@(posedge ifclk);@(negedge ifclk);tx_valid=0;
        wait(commits==1);repeat(10)@(negedge ifclk);
        if(reads!=2 || writes!=1 || commits!=1) $fatal(1,"transaction count");
        // Assert reset during an active output pulse, between IFCLK edges.
        tx_valid=1;
        wait(!slwr_n);#1;rst_n=0;#0.1;
        if(!slrd_n || !slwr_n || !sloe_n || !pktend_n || !slcs_n || fd_drive)
            $fatal(1,"asynchronous reset did not immediately release bus");
        $display("PASS: FX2 full-IN does not starve OUT; read/write data and short commit");$finish;
    end
    initial begin #20000;$fatal(1,"FIFO arbitration timeout");end
endmodule
