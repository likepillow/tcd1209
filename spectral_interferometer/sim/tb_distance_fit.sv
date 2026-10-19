`timescale 1ns/1ps
module tb_distance_fit;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,cfg_begin=0,cfg_we=0,cfg_commit=0;
    reg [8:0] cfg_addr=0;
    reg signed [31:0] cfg_weight=0;
    reg signed [15:0] cfg_exponent=0;
    wire cfg_ack,cfg_error,configured;
    wire [31:0] calibration_version;
    reg s_valid=0,s_last=0,s_invalid=0;
    wire s_ready;
    reg signed [42:0] s_phase=0;
    reg [9:0] s_index=0;
    reg [31:0] s_frame_id=0;
    wire m_valid,m_invalid,fault;
    reg m_ready=0;
    wire signed [83:0] m_accumulator;
    wire signed [15:0] m_exponent;
    wire [31:0] m_frame_id,m_calibration_version;
    distance_fit dut(.*);
    reg [31:0] weights[0:1535];reg [42:0] phases[0:6143];
    reg [83:0] results[0:5];reg [15:0] exponents[0:5];
    integer frame_number,i,cycles=0,outputs=0,acks=0,errors=0,before_errors;
    reg release_frame4=0,stalled=0;
    reg [164:0] held;
    wire [164:0] bundle={m_accumulator,m_exponent,m_frame_id,m_calibration_version,m_invalid};
    task begin_upload(input integer bank);
        begin
            @(negedge clk);cfg_begin=1;cfg_exponent=bank==0 ? exponents[0] : bank==1 ? exponents[1] : exponents[5];
            @(negedge clk);cfg_begin=0;
        end
    endtask
    task write_weights(input integer bank,input integer count,input integer damage);
        integer j;
        begin
            for(j=0;j<count;j=j+1) begin
                cfg_we=1;cfg_addr=j;cfg_weight=weights[bank*512+j]+((damage!=0 && j==511) ? 1 : 0);
                @(negedge clk);
            end
            cfg_we=0;
        end
    endtask
    task commit_upload;
        begin cfg_commit=1;@(negedge clk);cfg_commit=0;@(negedge clk);end
    endtask
    always @(negedge clk) if(rst_n) begin
        m_ready=(cycles%17<11) && !(m_valid && m_frame_id==104 && !release_frame4);
    end
    always @(posedge clk) if(rst_n) begin
        cycles<=cycles+1;
        if(cfg_ack) acks=acks+1;
        if(cfg_error) errors=errors+1;
        if(cfg_ack && m_valid) $fatal(1,"Calibration switched while result pending");
        if(stalled && (!m_valid || bundle!==held)) $fatal(1,"Result changed under backpressure");
        stalled<=m_valid && !m_ready;held<=bundle;
        if(m_valid && m_ready) begin
            if(m_accumulator!==results[outputs]) $fatal(1,"MAC mismatch frame %0d: %h expected %h",outputs,m_accumulator,results[outputs]);
            if(m_exponent!==exponents[outputs] || m_frame_id!=100+outputs ||
                m_calibration_version!=(outputs==0 ? 1 : outputs==5 ? 3 : 2)) $fatal(1,"Metadata/version mismatch");
            if(m_invalid!=(outputs==3 || outputs==4)) $fatal(1,"Invalid frame flag");
            if(fault!=(outputs>=4)) $fatal(1,"Protocol fault not sticky or triggered too early");
            outputs=outputs+1;
        end
    end
    initial begin
        $readmemh("fit_weights.mem",weights);$readmemh("fit_phases.mem",phases);
        $readmemh("fit_results.mem",results);$readmemh("fit_exponents.mem",exponents);
        repeat(5) @(negedge clk);rst_n=1;
        if(s_ready) $fatal(1,"Input accepted without K calibration");
        begin_upload(0);write_weights(0,64,0);before_errors=errors;commit_upload();
        if(errors!=before_errors+1 || configured) $fatal(1,"Partial upload accepted");
        begin_upload(0);write_weights(0,512,1);before_errors=errors;commit_upload();
        if(errors!=before_errors+1 || configured) $fatal(1,"Nonzero weight sum accepted");
        begin_upload(0);write_weights(0,1,0);
        cfg_we=1;cfg_addr=0;cfg_weight=weights[0];@(negedge clk);cfg_we=0;@(negedge clk);
        before_errors=errors;commit_upload();
        if(errors!=before_errors+1 || configured) $fatal(1,"Duplicate address accepted");
        begin_upload(0);write_weights(0,512,0);commit_upload();
        wait(acks==1);
        fork
            begin
                for(frame_number=0;frame_number<6;frame_number=frame_number+1) begin
                    for(i=0;i<1024;i=i+1) begin
                        @(negedge clk);
                        s_valid=1;s_phase=phases[frame_number*1024+i];
                        s_index=(frame_number==4 && i==42) ? 43 : i;
                        s_last=i==1023;s_invalid=frame_number==3 && i==900;s_frame_id=100+frame_number;
                        @(posedge clk);while(!s_ready) @(posedge clk);
                    end
                end
                @(negedge clk);s_valid=0;
            end
            begin
                wait(dut.index==128 && m_frame_id==100);
                begin_upload(1);write_weights(1,512,0);commit_upload();
                if(calibration_version!=1) $fatal(1,"K switched during first frame");
                wait(m_valid && m_frame_id==104);
                begin_upload(2);write_weights(2,512,0);commit_upload();
                repeat(20) @(negedge clk);
                if(calibration_version!=2 || !m_valid) $fatal(1,"K switched before held result released");
                release_frame4=1;
            end
        join
        wait(outputs==6);repeat(5) @(negedge clk);
        if(acks!=3) $fatal(1,"Wrong calibration ack count");
        $display("PASS: six exact 84-bit fits, middle crop, calibration atomicity, invalid frames and result stalls");$finish;
    end
    initial begin #1000000;$fatal(1,"Timeout");end
endmodule
