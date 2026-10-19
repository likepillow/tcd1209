`timescale 1ns/1ps
module tb_transform;
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0,s_valid=0,s_last=0;
    reg signed [31:0] s_re=0,s_im=0;
    wire s_ready,f_valid,f_ready,f_last,m_valid,m_last,f_fault,i_fault;
    reg m_ready=0;
    wire signed [42:0] f_re,f_im,m_re,m_im;
    wire [9:0] f_index,m_index;
    spectral_transform forward(clk,rst_n,s_valid,s_ready,s_re,s_im,s_last,
        f_valid,f_ready,f_re,f_im,f_index,f_last,f_fault);
    spectral_transform #(.INVERSE(1)) inverse(clk,rst_n,f_valid,f_ready,f_re[31:0],f_im[31:0],f_last,
        m_valid,m_ready,m_re,m_im,m_index,m_last,i_fault);
    integer outputs=0,frames=0,forward_count=0,cycles=0,i,fr;
    reg stalled=0;
    reg [96:0] held;
    always @(posedge clk) if(rst_n) begin
        cycles<=cycles+1;
        if(f_fault || i_fault) $fatal(1,"Transform fault");
        if(f_valid && f_ready) begin
            if(f_index!==forward_count%1024 || f_last!==(forward_count%1024==1023)) $fatal(1,"Forward index");
            // An impulse of 2^20, after FFT/1024, is constant 1024.
            if(forward_count<1024) begin
                if(f_re!=1024 || f_im!=0) $fatal(1,"Forward scale/order");
            end else if(f_re!=0 || f_im!=-1024) $fatal(1,"Imaginary forward scale/order");
            forward_count=forward_count+1;
        end
        if(stalled && (!m_valid || {m_index,m_last,m_re,m_im}!==held)) $fatal(1,"Stall corruption");
        stalled<=m_valid && !m_ready;
        held<={m_index,m_last,m_re,m_im};
        if(m_valid && m_ready) begin
            if(m_index!==outputs || m_last!==(outputs==1023)) $fatal(1,"Inverse index");
            if(frames==0) begin
                if(m_re!=(outputs==0 ? 1048576 : 0) || m_im!=0) $fatal(1,"Real roundtrip");
            end else if(m_re!=0 || m_im!=(outputs==0 ? -1048576 : 0)) $fatal(1,"Imaginary roundtrip");
            if(outputs==1023) begin outputs=0; frames=frames+1; end
            else outputs=outputs+1;
        end
    end
    always @(negedge clk) if(rst_n) m_ready=(cycles%19<13);
    initial begin
        repeat(8) @(negedge clk); rst_n=1;
        for(fr=0;fr<2;fr=fr+1) begin
            for(i=0;i<1024;i=i+1) begin
                @(negedge clk); s_valid=1; s_last=i==1023;
                s_re=(fr==0 && i==0) ? 1048576 : 0;
                s_im=(fr==1 && i==0) ? -1048576 : 0;
                @(posedge clk); while(!s_ready) @(posedge clk);
            end
        end
        @(negedge clk); s_valid=0;
        wait(frames==2); repeat(10) @(negedge clk);
        $display("PASS: generated XFFT FFT/IFFT, scales, real/imaginary fields, indices, output stalls");
        $finish;
    end
    initial begin #2000000; $fatal(1,"Timeout"); end
endmodule
