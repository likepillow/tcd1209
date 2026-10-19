`timescale 1ns/1ps
module tb_raw_stream_packet_tx;
    reg clk=0,rst_n=0,s_valid=0,m_ready=0,grant=0;
    always #5 clk=~clk;
    reg [11:0] s_data=0;
    reg s_first=1;
    reg [31:0] s_frame_id=32'hfffffffe,packet_sequence=0;
    wire s_ready,request,m_valid,m_last;
    wire [7:0] m_data;
    integer sent=0,packets=0,cycle=0,trace,grants=0,waited=0;
    reg accepted=0,stalled=0;
    reg [8:0] held;
    raw_stream_packet_tx dut(.*,.timestamp_valid(1'b0),.timestamp(64'd987));
    function [31:0] frame_number(input integer n);
        case(n)
            0: frame_number=32'hfffffffe;
            1: frame_number=32'hffffffff;
            2: frame_number=0;
            3: frame_number=2;
            default: frame_number=3;
        endcase
    endfunction
    always @(posedge clk) if(rst_n) begin
        accepted=s_valid && s_ready;
        if(accepted) begin
            if(grants!=sent/1024+1) $fatal(1,"pixel consumed without frame grant");
            sent=sent+1;
        end
        if(grant && request) grants=grants+1;
        if(stalled && (!m_valid || {m_last,m_data}!==held)) $fatal(1,"unstable output");
        stalled=m_valid && !m_ready;held={m_last,m_data};
        if(m_valid && m_ready) begin
            $fwrite(trace,"%02x\n",m_data);
            if(m_last) packets=packets+1;
        end
    end
    always @(negedge clk) if(rst_n) begin
        cycle=cycle+1;m_ready=cycle%31>15;
        packet_sequence=packets;
        grant=0;
        if(request) begin
            waited=waited+1;
            if(waited==40) begin grant=1;waited=0;end
        end else waited=0;
        if(!s_valid || accepted) begin
            s_valid=sent<5120 && cycle%7!=0;
            s_data=(sent*73+19)%4096;
            s_first=sent%1024==0;
            s_frame_id=frame_number(sent/1024);
        end
    end
    initial begin
        trace=$fopen("raw_stream_packets.hex","w");
        repeat(4) @(negedge clk);rst_n=1;
        wait(packets==5);repeat(5) @(negedge clk);$fclose(trace);
        if(sent!=5120 || grants!=5 || request) $fatal(1,"coverage mismatch");
        $display("PASS: RAW stream multiframe grants wrap gaps stalls");$finish;
    end
    initial begin #1000000;$fatal(1,"timeout");end
endmodule
