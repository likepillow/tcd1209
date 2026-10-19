`timescale 1ns/1ps
module tb_analytic;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,s_valid=0,s_last=0,m_ready=0;
    reg signed [31:0] s_data=0;
    wire s_ready,m_valid,m_last,no_peak,fault;
    wire signed [42:0] m_re,m_im;
    wire [9:0] m_index,peak_bin,band_left,band_right;
    analytic_spectrum dut(.*);
    integer i,fr,outputs=0,frames=0,cycles=0,fp;
    real phase,signal_value;
    reg stalled=0;
    reg [126:0] held;
    wire [126:0] bundle={peak_bin,band_left,band_right,m_index,m_last,m_re,m_im};
    always @(posedge clk) if(rst_n) begin
        cycles<=cycles+1;
        if(fault || (m_valid && no_peak)) $fatal(1,"Invalid analytic frame");
        if(stalled && (!m_valid || bundle!==held)) $fatal(1,"Stall/metadata corruption");
        held<=bundle;stalled<=m_valid && !m_ready;
        if(m_valid && m_ready) begin
            if(m_index!=outputs || m_last!=(outputs==1023)) $fatal(1,"Frame index");
            if(peak_bin!=(frames==0 ? 43 : 97)) $fatal(1,"Wrong principal peak");
            $fdisplay(fp,"%0d,%0d,%0d,%0d,%0d,%0d",frames,outputs,m_re,m_im,band_left,band_right);
            if(outputs==1023) begin outputs=0;frames=frames+1;end
            else outputs=outputs+1;
        end
    end
    always @(negedge clk) if(rst_n) m_ready=cycles%17<11;
    initial begin
        fp=$fopen("analytic_output.csv","w");
        if(!fp) $fatal(1,"Output file unavailable");
        repeat(8) @(negedge clk);rst_n=1;
        for(fr=0;fr<2;fr=fr+1) begin
            for(i=0;i<1024;i=i+1) begin
                @(negedge clk);
                phase=2.0*3.141592653589793*(fr==0 ? 43.0 : 97.0)*i/1024.0+0.7;
                signal_value=1048576.0*$cos(phase)+131072.0*$cos(2.0*3.141592653589793*173.0*i/1024.0);
                s_data=$rtoi(signal_value);s_valid=1;s_last=i==1023;
                @(posedge clk);while(!s_ready) @(posedge clk);
            end
        end
        @(negedge clk);s_valid=0;
        wait(frames==2);repeat(5) @(negedge clk);
        $fclose(fp);
        $display("PASS: analytic chain protocol; compare analytic_output.csv numerically");
        $finish;
    end
    initial begin #2000000;$fatal(1,"Timeout");end
endmodule
