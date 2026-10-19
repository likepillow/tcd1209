`timescale 1ns/1ps
module tb_packet_scheduler;
    reg clk=0,rst_n=0,m_ready=0;
    always #5 clk=~clk;
    reg [4:0] request=0,s_valid=0,s_last=0;
    reg [39:0] s_data=0;
    wire [4:0] grant,s_ready;
    wire [31:0] packet_sequence;
    wire m_valid,m_last;wire [7:0] m_data;
    integer rounds[0:4],index[0:4];
    reg [4:0] active=0;
    integer i,cycle=0,grants=0,packets=0,out_index=0;
    reg stalled=0;reg [8:0] held;
    packet_scheduler #(.INITIAL_SEQUENCE(32'hfffffffe)) dut(.*,.idle());
    always @(posedge clk) if(rst_n) begin
        if(stalled && (!m_valid || {m_last,m_data}!==held)) $fatal(1,"scheduler changed stalled output");
        stalled=m_valid && !m_ready;held={m_last,m_data};
        for(i=0;i<5;i=i+1) begin
            if(grant[i]) begin
                if(i!=grants%5 || packet_sequence!=(32'hfffffffe+grants)) $fatal(1,"fairness/sequence mismatch");
                if(active!=0) $fatal(1,"overlapping packet grants");
                active[i]=1;index[i]=0;grants=grants+1;
            end
            if(s_valid[i] && s_ready[i]) begin
                if(s_last[i]) begin active[i]=0;rounds[i]=rounds[i]+1;end
                else index[i]=index[i]+1;
            end
        end
        if(m_valid && m_ready) begin
            if(m_data!=(packets%5)*16+out_index || m_last!==(out_index==(packets%5)+2)) $fatal(1,"interleaved packet");
            if(m_last) begin packets=packets+1;out_index=0;end
            else out_index=out_index+1;
        end
    end
    always @(negedge clk) if(rst_n) begin
        cycle=cycle+1;m_ready=cycle%13>5;
        for(i=0;i<5;i=i+1) begin
            request[i]=rounds[i]<4 && !active[i];
            // A source may pause inside its packet, but never withdraw a beat.
            if(!s_valid[i] || s_ready[i]) s_valid[i]=active[i] && cycle%7!=0;
            s_data[i*8+:8]=i*16+index[i];s_last[i]=(index[i]==i+2);
        end
    end
    initial begin
        for(i=0;i<5;i=i+1) begin rounds[i]=0;index[i]=0;end
        repeat(4) @(negedge clk);rst_n=1;
        wait(packets==20);repeat(5) @(posedge clk);
        if(grants!=20 || packet_sequence!=18) $fatal(1,"final sequence mismatch");
        $display("PASS: packet scheduler, 5 sources, 20 packets, stalls, non-interleaving and sequence wrap");$finish;
    end
    initial begin #100000;$fatal(1,"timeout");end
endmodule
