`timescale 1ns/1ps
module tb_peak_filter;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,s_valid=0,s_last=0,m_ready=0;
    reg signed [31:0] s_re=0,s_im=0;
    reg [9:0] s_index=0;
    wire s_ready,m_valid,m_last,no_peak,fault;
    wire signed [31:0] m_re,m_im;
    wire [9:0] m_index,peak_bin,band_left,band_right;
    positive_peak_filter dut(.*);
    integer i,fr,cycles=0,outputs=0,frames=0;
    reg stalled=0;reg [74:0] held;
    function automatic signed [31:0] re_value(input integer f,input integer n);
        begin
            re_value=0;
            if(n==0 || n==512 || n==1000) re_value=2147483647; // Excluded even when dominant.
            if(f==0) case(n)
                8:re_value=-1;9:re_value=-4;10:re_value=-8;
                11:re_value=6;12:re_value=1;13:re_value=3;14:re_value=5;
            endcase
            if(f==1 && n==1) re_value=32'sh80000000;
            if(f==2 && n==511) re_value=100;
            if(f==4 && (n==23 || n==24)) re_value=50;
        end
    endfunction
    function automatic signed [31:0] im_value(input integer f,input integer n);
        begin
            im_value=0;
            if(f==0 && n>=8 && n<=12) im_value=re_value(f,n)/2;
            if(f==1 && n==1) im_value=32'sh80000000;
            if(f==2 && n==511) im_value=-200;
        end
    endfunction
    function automatic integer left_bound(input integer f);
        case(f) 0:left_bound=8;1:left_bound=1;2:left_bound=511;3:left_bound=0;4:left_bound=23;endcase
    endfunction
    function automatic integer right_bound(input integer f);
        case(f) 0:right_bound=12;1:right_bound=1;2:right_bound=511;3:right_bound=0;4:right_bound=24;endcase
    endfunction
    always @(posedge clk) if(rst_n) begin
        cycles<=cycles+1;
        if(fault) $fatal(1,"Unexpected protocol fault");
        if(stalled && (!m_valid || {m_index,m_last,m_re,m_im}!==held)) $fatal(1,"Stall corruption");
        held<={m_index,m_last,m_re,m_im};stalled<=m_valid && !m_ready;
        if(m_valid && m_ready) begin
            if(m_index!=outputs || m_last!=(outputs==1023)) $fatal(1,"Index/TLAST");
            if(band_left!=left_bound(frames) || band_right!=right_bound(frames) || no_peak!=(frames==3)) $fatal(1,"Band bounds frame %d: %d..%d",frames,band_left,band_right);
            if(peak_bin!=(frames==0 ? 10 : left_bound(frames))) $fatal(1,"Peak tie/order");
            if(frames!=3 && outputs>=left_bound(frames) && outputs<=right_bound(frames)) begin
                if(m_re!==re_value(frames,outputs) || m_im!==im_value(frames,outputs)) $fatal(1,"Complex coefficient changed");
            end else if(m_re!=0 || m_im!=0) $fatal(1,"Rejected bin not zeroed");
            if(outputs==1023) begin outputs=0;frames=frames+1;end
            else outputs=outputs+1;
        end
    end
    always @(negedge clk) if(rst_n) m_ready=cycles%17<11;
    initial begin
        repeat(5) @(negedge clk);rst_n=1;
        for(fr=0;fr<5;fr=fr+1) begin
            for(i=0;i<1024;i=i+1) begin
                @(negedge clk);s_valid=1;s_index=i;s_last=i==1023;
                s_re=re_value(fr,i);s_im=im_value(fr,i);
                @(posedge clk);while(!s_ready) @(posedge clk);
            end
        end
        @(negedge clk);s_valid=0;
        wait(frames==5);repeat(5) @(negedge clk);
        $display("PASS: 5120 complex bins, valley bounds, DC/Nyquist rejection, integer extremes, ties, empty band, stalls");
        $finish;
    end
    initial begin #1000000;$fatal(1,"Timeout");end
endmodule
