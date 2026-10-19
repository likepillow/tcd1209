`timescale 1ns/1ps
module tb_raw_packet_tx;
    reg clk=0,rst_n=0,cmd_valid=0,m_ready=0,s_valid=0;
    always #5 clk=~clk;
    reg [31:0] packet_sequence=0,frame_id=123;
    reg timestamp_valid=1,discontinuity=0;
    reg [63:0] timestamp=999;
    reg [11:0] s_data=0;
    wire cmd_ready,s_ready,m_valid,m_last;wire [7:0] m_data;
    integer sent=0,packets=0,cycle=0,trace;
    reg accepted=0,stalled=0;
    reg [8:0] held;
    raw_packet_tx dut(.*);
    always @(posedge clk) if(rst_n) begin
        accepted=s_valid && s_ready;
        if(accepted) sent=sent+1;
        if(stalled && (!m_valid || {m_last,m_data} !== held)) $fatal(1,"unstable RAW output");
        stalled=m_valid && !m_ready;held={m_last,m_data};
        if(m_valid && m_ready) begin
            $fwrite(trace,"%02x\n",m_data);
            if(m_last) packets=packets+1;
        end
    end
    always @(negedge clk) if(rst_n) begin
        cycle=cycle+1;m_ready=cycle%17>5;
        if(!s_valid || accepted) begin
            s_valid=sent<2048 && cycle%7!=0;
            s_data=(sent*73+19)%4096;
        end
    end
    task command;
        begin
            @(negedge clk);cmd_valid=1;
            @(posedge clk);while(!cmd_ready) @(posedge clk);
            @(negedge clk);cmd_valid=0;
        end
    endtask
    initial begin
        trace=$fopen("raw_packets.hex","w");
        repeat(4) @(negedge clk);rst_n=1;
        command();wait(packets==1);
        @(negedge clk);packet_sequence=1;frame_id=125;timestamp_valid=0;timestamp=123456;discontinuity=1;
        command();wait(packets==2);
        repeat(4) @(posedge clk);$fclose(trace);
        if(sent!=2048) $fatal(1,"pixel count mismatch");
        $display("PASS: RAW packets, 2048 pixels, input gaps and output stalls");$finish;
    end
    initial begin #1000000;$fatal(1,"timeout");end
endmodule
