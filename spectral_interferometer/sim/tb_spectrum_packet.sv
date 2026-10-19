`timescale 1ns/1ps
module tb_spectrum_packet;
    reg clk=0,rst_n=0,grant=0,s_valid=0,m_ready=0;
    always #5 clk=~clk;
    wire request,s_ready,m_valid,m_last;
    wire [7:0] m_data;
    reg [11:0] s0=0;reg [23:0] s1=0;reg signed [24:0] s2=0;
    integer sent=0,cycles=0,trace,packets=0;
    reg accepted=0,stalled=0;reg [8:0] held;
    spectrum_stream_packet_tx dut(.*,.s_first(sent==0),.packet_sequence(32'd5),.frame_id(32'd123),.source_version(32'd7),
        .timestamp_valid(1'b1),.timestamp(64'd987654));
    always @(posedge clk) if(rst_n) begin
        accepted=s_valid && s_ready;if(accepted) sent=sent+1;
        if(stalled && (!m_valid || {m_last,m_data}!==held)) $fatal(1,"spectrum output changed while stalled");
        stalled=m_valid && !m_ready;held={m_last,m_data};
        if(m_valid && m_ready) begin
            $fwrite(trace,"%02x\n",m_data);if(m_last) packets=packets+1;
        end
    end
    always @(negedge clk) if(rst_n) begin
        cycles=cycles+1;m_ready=cycles%17>5;
        if(!s_valid || accepted) begin
            s_valid=sent<1024 && cycles%7!=0;s0=sent*17;s1=24'hffffff-sent*123;
            s2=sent%2 ? 25'sh0ffffff-sent : -25'sd16777216+sent;
        end
    end
    initial begin
        trace=$fopen("spectrum_packets.hex","w");
        repeat(4) @(negedge clk);rst_n=1;
        wait(request);
        repeat(40) begin @(negedge clk);if(sent!=0 || m_valid || s_ready) $fatal(1,"consumed before grant");end
        grant=1;@(negedge clk);grant=0;
        wait(packets==1);repeat(4) @(negedge clk);$fclose(trace);
        if(sent!=1024) $fatal(1,"tuple count mismatch");
        $display("PASS: spectrum tuple serialization");$finish;
    end
    initial begin #1000000;$fatal(1,"timeout");end
endmodule
