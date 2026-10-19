`timescale 1ns/1ps
module tb_spectral_phase;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,s_valid=0,s_last=0,m_ready=0;
    reg signed [31:0] s_data=0;
    wire s_ready,m_valid,m_last,m_invalid,fault;
    wire signed [42:0] m_phase;
    wire [9:0] m_index,peak_bin,band_left,band_right;
    spectral_phase dut(.*);
    integer i,fr,outputs=0,frames=0,cycles=0,fp;
    integer frame_start=0;
    real phase,signal_value;
    reg stalled=0;
    reg [84:0] held;
    wire [84:0] bundle={peak_bin,band_left,band_right,m_index,m_last,m_invalid,m_phase};
    function integer frequency(input integer f);
        case(f) 0:frequency=43;1:frequency=97;2:frequency=0;3:frequency=211;endcase
    endfunction
    always @(posedge clk) if(rst_n) begin
        cycles<=cycles+1;
        if(fault) $fatal(1,"Unexpected transform/phase fault");
        if(stalled && (!m_valid || bundle!==held)) $fatal(1,"Stall/metadata corruption");
        held<=bundle;stalled<=m_valid && !m_ready;
        if(s_valid && s_ready && dut.input_index==0) frame_start=cycles;
        if(m_valid && m_ready) begin
            if(m_index!=outputs || m_last!=(outputs==1023)) $fatal(1,"Frame index");
            if(peak_bin!=frequency(frames) || m_invalid!=(frames==2)) $fatal(1,"Peak/validity mismatch");
            $fdisplay(fp,"%0d,%0d,%0d,%0d,%0d,%0d",frames,outputs,m_phase,m_invalid,band_left,band_right);
            if(outputs==1023) begin
                $display("Frame %0d input-to-last-output: %0d clocks",frames,cycles-frame_start);
                outputs=0;frames=frames+1;
            end else outputs=outputs+1;
        end
    end
    always @(negedge clk) if(rst_n) m_ready=cycles%17<11;
    initial begin
        fp=$fopen("spectral_phase_output.csv","w");
        if(!fp) $fatal(1,"Output file unavailable");
        repeat(8) @(negedge clk);rst_n=1;
        for(fr=0;fr<4;fr=fr+1) begin
            for(i=0;i<1024;i=i+1) begin
                @(negedge clk);
                phase=2.0*3.141592653589793*frequency(fr)*i/1024.0+0.7;
                signal_value=fr==2 ? 0.0 : 1048576.0*$cos(phase)+131072.0*$cos(2.0*3.141592653589793*173.0*i/1024.0);
                s_data=$rtoi(signal_value);s_valid=1;s_last=i==1023;
                @(posedge clk);while(!s_ready) @(posedge clk);
            end
        end
        @(negedge clk);s_valid=0;
        wait(frames==4);repeat(5) @(negedge clk);$fclose(fp);
        $display("PASS: spectral phase protocol; numerical check required");$finish;
    end
    initial begin #2000000;$fatal(1,"Timeout");end
endmodule
