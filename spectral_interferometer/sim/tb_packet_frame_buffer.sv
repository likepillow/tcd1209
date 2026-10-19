`timescale 1ns/1ps
module tb_packet_frame_buffer;
    reg clk=0,rst_n=0,s_valid=0,s_first=0,s_last=0,m_ready=0;
    always #5 clk=~clk;
    reg [11:0] s_data=0;reg [31:0] s_meta=0;
    wire s_ready,m_valid,m_first,m_last,fault;wire [11:0] m_data;wire [31:0] m_meta;
    integer n,f,received=0,cycle=0;
    reg stalled=0;reg [45:0] held;
    packet_frame_buffer #(.DEPTH(16)) dut(.*);
    always @(negedge clk) if(rst_n) begin cycle=cycle+1;m_ready=cycle%13>6;end
    always @(posedge clk) if(rst_n) begin
        if(stalled && (!m_valid || {m_data,m_meta,m_first,m_last}!==held)) $fatal(1,"unstable buffered frame");
        stalled=m_valid && !m_ready;held={m_data,m_meta,m_first,m_last};
        if(m_valid && m_ready) begin
            if(m_meta!=received/16 || m_data!=received || m_first!=(received%16==0) || m_last!=(received%16==15)) $fatal(1,"frame mismatch");
            received=received+1;
        end
    end
    task send(input integer value,input integer frame,input bit first,input bit last);
        begin
            @(negedge clk);s_valid=1;s_data=value;s_meta=frame;s_first=first;s_last=last;
            @(posedge clk);while(!s_ready) @(posedge clk);
            @(negedge clk);s_valid=0;
        end
    endtask
    initial begin
        repeat(4) @(negedge clk);rst_n=1;
        for(f=0;f<3;f=f+1) begin
            for(n=0;n<16;n=n+1) begin
                send(f*16+n,f,n==0,n==15);
                if(n<15 && m_valid) $fatal(1,"published incomplete frame");
            end
            wait(received==(f+1)*16);
        end
        send(0,3,1,0);send(1,4,0,0);
        if(!fault || s_ready || m_valid) $fatal(1,"metadata corruption not isolated");
        @(negedge clk);rst_n=0;repeat(3) @(negedge clk);rst_n=1;
        @(negedge clk);if(fault || !s_ready || m_valid) $fatal(1,"reset recovery failed");
        $display("PASS: complete frame publication, stalls, metadata fault and reset");$finish;
    end
    initial begin #100000;$fatal(1,"timeout");end
endmodule
