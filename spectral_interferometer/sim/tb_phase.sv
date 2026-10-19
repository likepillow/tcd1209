`timescale 1ns/1ps
module tb_phase;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,s_valid=0,s_last=0,m_ready=0;
    reg signed [42:0] s_re=0,s_im=0;
    reg [9:0] s_index=0;
    wire s_ready,p_valid,p_ready,p_last,p_zero,m_valid,m_last,m_invalid,fault;
    wire signed [31:0] p_phase;
    wire signed [42:0] m_phase;
    wire [9:0] p_index,m_index;
    reg [42:0] real_mem[0:6143],imag_mem[0:6143];
    integer i,cycles=0,outputs=0,p_outputs=0,pcsv,ucsv;
    reg p_stalled=0,m_stalled=0;
    reg [43:0] p_held;
    reg [54:0] m_held;
    phase_cordic cordic(.clk(clk),.rst_n(rst_n),.s_valid(s_valid),.s_ready(s_ready),
        .s_re(s_re),.s_im(s_im),.s_index(s_index),.s_last(s_last),
        .m_valid(p_valid),.m_ready(p_ready),.m_phase(p_phase),.m_index(p_index),.m_last(p_last),.m_zero(p_zero));
    phase_unwrap unwrap(.clk(clk),.rst_n(rst_n),.s_valid(p_valid),.s_ready(p_ready),
        .s_phase(p_phase),.s_index(p_index),.s_last(p_last),.s_zero(p_zero),
        .m_valid(m_valid),.m_ready(m_ready),.m_phase(m_phase),.m_index(m_index),.m_last(m_last),.m_invalid(m_invalid),.fault(fault));
    always @(posedge clk) if(rst_n) begin
        cycles<=cycles+1;
        if(fault) $fatal(1,"Unexpected index/frame fault");
        if(p_stalled && (!p_valid || {p_phase,p_index,p_last,p_zero}!==p_held)) $fatal(1,"CORDIC stall corruption");
        if(m_stalled && (!m_valid || {m_phase,m_index,m_last,m_invalid}!==m_held)) $fatal(1,"Unwrap stall corruption");
        p_stalled<=p_valid && !p_ready;p_held<={p_phase,p_index,p_last,p_zero};
        m_stalled<=m_valid && !m_ready;m_held<={m_phase,m_index,m_last,m_invalid};
        if(p_valid && p_ready) begin
            $fdisplay(pcsv,"%0d,%0d,%0d,%0d",p_index,p_phase,p_last,p_zero);p_outputs=p_outputs+1;
        end
        if(m_valid && m_ready) begin
            $fdisplay(ucsv,"%0d,%0d,%0d,%0d",m_index,m_phase,m_last,m_invalid);outputs=outputs+1;
        end
    end
    always @(negedge clk) if(rst_n) m_ready=cycles%29<19;
    initial begin
        $readmemh("phase_re.mem",real_mem);$readmemh("phase_im.mem",imag_mem);
        pcsv=$fopen("cordic_output.csv","w");ucsv=$fopen("unwrap_output.csv","w");
        if(!pcsv || !ucsv) $fatal(1,"Cannot create output");
        repeat(5) @(negedge clk);rst_n=1;
        for(i=0;i<6144;i=i+1) begin
            @(negedge clk);
            if(i%37==0) begin s_valid=0;repeat(3) @(negedge clk);end
            s_valid=1;s_re=real_mem[i];s_im=imag_mem[i];s_index=i%1024;s_last=i%1024==1023;
            @(posedge clk);while(!s_ready) @(posedge clk);
        end
        @(negedge clk);s_valid=0;
        wait(outputs==6144);repeat(5) @(negedge clk);
        if(p_outputs!=6144) $fatal(1,"Lost/duplicated CORDIC samples");
        $fclose(pcsv);$fclose(ucsv);
        $display("PASS: phase pipeline protocol; numerical check required");$finish;
    end
    initial begin #1000000;$fatal(1,"Timeout");end
endmodule
