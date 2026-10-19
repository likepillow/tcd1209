`timescale 1ns/1ps
module tb_usb_word_stream;
    reg clk=0,rst_n=0,s_valid=0,s_last=0,m_ready=0;
    reg [7:0] s_data=0;
    wire s_ready,m_valid,m_last,fault,w_valid,w_ready,w_last;
    wire [7:0] m_data;
    wire [15:0] w_data;
    integer sent=0,received=0,words=0,cycles=0;
    reg checking=1;
    reg accepted=0,word_stalled=0,byte_stalled=0;
    reg [16:0] held_word;
    reg [8:0] held_byte;
    always #5 clk=~clk;
    usb_byte_to_word packer(.clk(clk),.rst_n(rst_n),.s_valid(s_valid),.s_ready(s_ready),
        .s_data(s_data),.s_last(s_last),.m_valid(w_valid),.m_ready(w_ready),
        .m_data(w_data),.m_last(w_last),.fault(fault));
    usb_word_to_byte unpacker(.clk(clk),.rst_n(rst_n),.s_valid(w_valid),.s_ready(w_ready),
        .s_data(w_data),.s_last(w_last),.m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_last(m_last));
    function [7:0] value(input integer i);value=(i*73+19)%256;endfunction
    always @(posedge clk) if(rst_n && checking) begin
        accepted=s_valid && s_ready;
        if(word_stalled && (!w_valid || {w_last,w_data} !== held_word))
            $fatal(1,"word changed under backpressure");
        if(byte_stalled && (!m_valid || {m_last,m_data} !== held_byte))
            $fatal(1,"byte changed under backpressure");
        word_stalled=w_valid && !w_ready;held_word={w_last,w_data};
        byte_stalled=m_valid && !m_ready;held_byte={m_last,m_data};
        if(s_valid && s_ready) sent=sent+1;
        if(w_valid && w_ready) begin
            if(w_data !== {value(words*2+1),value(words*2)} || w_last !== (words%34==33))
                $fatal(1,"word byte order or packet boundary mismatch");
            words=words+1;
        end
        if(m_valid && m_ready) begin
            if(m_data !== value(received) || m_last !== (received%68==67))
                $fatal(1,"round trip mismatch at byte %0d",received);
            received=received+1;
        end
        if(fault) $fatal(1,"unexpected fault");
    end
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        while(received<6800) begin
            @(negedge clk);cycles=cycles+1;
            m_ready=(cycles%13>=5);
            if(!s_valid || accepted) begin
                s_valid=(sent<6800 && cycles%7!=0);
                s_data=value(sent);s_last=(sent%68==67);
            end
        end
        @(negedge clk);checking=0;s_valid=0;m_ready=1;
        repeat(5) @(negedge clk);
        // Reject an odd-length packet rather than silently inserting padding.
        s_valid=1;s_last=1;s_data=8'h55;
        @(negedge clk);s_valid=0;
        if(!fault || s_ready) $fatal(1,"odd packet not rejected");
        rst_n=0;@(negedge clk);rst_n=1;s_valid=1;s_last=0;
        @(negedge clk);s_valid=0;rst_n=0;
        @(negedge clk);rst_n=1;
        repeat(5) @(negedge clk);
        if(fault || m_valid || w_valid || !s_ready) $fatal(1,"partial word reset failed");
        $display("PASS: USB word stream 6800 bytes, byte order, boundaries, stalls, odd rejection and reset");
        $finish;
    end
    initial begin #1000000;$fatal(1,"timeout");end
endmodule
