`timescale 1ns/1ps
module tb_normalize_frame;
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0,cfg_begin=0,cfg_we=0,cfg_commit=0;
    reg [9:0] cfg_addr=0;
    reg [30:0] cfg_gain=0;
    wire cfg_ack,cfg_error,configured;
    wire [31:0] calibration_version;
    reg s_valid=0,s_first=0,s_last=0;
    wire s_ready;
    reg [11:0] s_data=0;
    reg [31:0] s_frame_id=0;
    wire m_valid,m_first,m_last,frame_error,frame_overflow,frame_clipped;
    reg m_ready=0;
    wire [11:0] m_s0;
    wire [23:0] m_s1;
    wire signed [24:0] m_s2;
    wire [4:0] m_fft_shift;
    wire [31:0] m_frame_id,m_calibration_version;
    normalize_frame dut(.*);
    reg [31:0] raw[0:1023],gain[0:1023],gain2[0:1023];
    reg [31:0] s1[0:1023],s2[0:1023],s12[0:1023],s22[0:1023];
    integer accepted=0,outputs=0,frames=0,cycles=0,config_errors=0;
    reg held_valid=0;
    reg [131:0] held;
    wire [131:0] output_bits={m_fft_shift,m_first,m_last,m_frame_id,m_calibration_version,m_s0,m_s1,m_s2};
    reg [31:0] shifts[0:1];
    always @(posedge clk) if(rst_n) begin
        cycles<=cycles+1;
        if(s_valid && s_ready) accepted<=accepted+1;
        if(cfg_error) config_errors<=config_errors+1;
        if(frame_error || frame_overflow) $fatal(1,"Unexpected frame error/overflow");
        if(held_valid && (!m_valid || output_bits!==held)) $fatal(1,"Backpressure corruption");
        held_valid<=m_valid && !m_ready;
        held<=output_bits;
        if(cfg_ack && calibration_version==2 && frames!=1) $fatal(1,"Calibration changed inside frame");
        if(m_valid && m_ready) begin
            if(!frame_clipped) $fatal(1,"Rail-containing fixture missing clipping flag");
            if(m_frame_id!=frames+1 || m_calibration_version!=frames+1) $fatal(1,"Frame/calibration metadata");
            if(m_first!=(outputs==0) || m_last!=(outputs==1023)) $fatal(1,"Frame bounds");
            if(m_s0!==raw[outputs][11:0]) $fatal(1,"Raw sample mismatch");
            if(m_fft_shift!=shifts[frames]) $fatal(1,"FFT common frame shift");
            if(frames==0) begin
                if(m_s1!==s1[outputs][23:0] || m_s2!==s2[outputs][24:0])
                    $fatal(1,"Q12 mismatch frame 1 index %d got %d expected %d",outputs,m_s2,$signed(s2[outputs][24:0]));
            end else if(m_s1!==s12[outputs][23:0] || m_s2!==s22[outputs][24:0])
                $fatal(1,"Q12 mismatch frame 2 index %d",outputs);
            if(outputs==1023) begin outputs=0; frames=frames+1; end
            else outputs=outputs+1;
        end
    end
    always @(negedge clk) if(rst_n) m_ready=(cycles%11<7);
    task upload(input integer version);
        integer i;
        begin
            @(negedge clk); cfg_begin=1;
            @(negedge clk); cfg_begin=0;
            for(i=0;i<1024;i=i+1) begin
                cfg_we=1; cfg_addr=i; cfg_gain=version==1 ? gain[i] : gain2[i];
                @(negedge clk);
            end
            cfg_we=0; cfg_commit=1;
            @(negedge clk); cfg_commit=0;
        end
    endtask
    task send_frame(input integer id);
        integer i;
        begin
            for(i=0;i<1024;i=i+1) begin
                @(negedge clk);
                s_valid=1; s_data=raw[i]; s_first=i==0; s_last=i==1023; s_frame_id=id;
                @(posedge clk);
                while(!s_ready) @(posedge clk);
            end
            @(negedge clk); s_valid=0; s_first=0; s_last=0;
        end
    endtask
    initial begin
        $readmemh("raw.mem",raw); $readmemh("gain.mem",gain); $readmemh("gain2.mem",gain2);
        $readmemh("s1.mem",s1); $readmemh("s2.mem",s2);
        $readmemh("s12.mem",s12); $readmemh("s22.mem",s22);
        $readmemh("shifts.mem",shifts);
        repeat(4) @(negedge clk); rst_n=1;
        // A partial upload cannot enable acquisition or commit calibration.
        @(negedge clk); cfg_begin=1;
        @(negedge clk); cfg_begin=0; cfg_we=1; cfg_addr=0; cfg_gain=31'h40000000;
        @(negedge clk); cfg_we=0; cfg_commit=1;
        @(negedge clk); cfg_commit=0;
        repeat(3) @(negedge clk);
        if(configured || s_ready || config_errors!=1) $fatal(1,"Partial calibration accepted");
        upload(1);
        wait(cfg_ack);
        fork
            begin send_frame(1); send_frame(2); end
            begin wait(accepted==128); upload(2); end
        join
        wait(frames==2);
        repeat(5) @(negedge clk);
        if(config_errors!=1) $fatal(1,"Unexpected calibration error");
        $display("PASS: 2048 bit-exact normalized samples; atomic calibration, backpressure, invalid upload");
        $finish;
    end
    initial begin #1000000; $fatal(1,"Timeout"); end
endmodule
