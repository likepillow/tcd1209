`timescale 1ns/1ps
module tb_processor #(parameter CAPTURE=0, parameter PACKET=0);
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,source_begin=0,source_we=0,source_commit=0,k_begin=0,k_we=0,k_commit=0;
    reg [9:0] source_addr=0;reg [30:0] source_gain=31'd1048576;
    reg [8:0] k_addr=0;reg signed [31:0] k_weight=0;reg signed [15:0] k_exponent=0;
    wire source_ack,source_error,k_ack,k_error,configured,fault;
    wire [31:0] active_source_version,active_k_version;
    wire c_source_begin,c_source_we,c_source_commit,c_k_begin,c_k_we,c_k_commit;
    wire [9:0] c_source_addr;wire [30:0] c_source_gain;
    wire [8:0] c_k_addr;wire signed [31:0] c_k_weight;wire signed [15:0] c_k_exponent;
    reg rx_valid=0;reg [7:0] rx_data=0;wire rx_ready;
    reg [7:0] config_bytes[0:6271];
    reg s_valid=0,s_first=0,s_last=0;wire s_ready;
    reg [11:0] s_data=0;reg [31:0] s_frame_id=0;reg [63:0] s_timestamp=0;
    wire spectrum_valid,spectrum_ready;
    wire [11:0] spectrum_s0;wire [23:0] spectrum_s1;wire signed [24:0] spectrum_s2;
    wire spectrum_first,spectrum_last;wire [31:0] spectrum_frame_id,spectrum_source_version;
    wire phase_valid;reg phase_ready=0;wire signed [42:0] phase_data;wire [9:0] phase_index;
    wire phase_last,phase_invalid;wire [31:0] phase_frame_id;
    wire result_valid,result_ready;wire signed [83:0] result_accumulator;
    wire signed [15:0] result_exponent;wire [31:0] result_frame_id,result_k_version,result_source_version;
    wire result_invalid;wire [9:0] result_peak,result_left,result_right;wire [63:0] result_timestamp;
    wire [31:0] dropped_frames,malformed_frames;
    wire raw_valid,raw_first,raw_last;wire [11:0] raw_data;wire [31:0] raw_frame_id;wire [63:0] raw_timestamp;
    wire raw_ready;
    reg raw_enable=0;
    wire packet_valid,packet_last;
    wire [7:0] packet_data;
    reg packet_ready=0;
    integer packet_file,packet_count=0,cycles=0;
    wire [31:0] export_period_frames_test,rate_skipped_frames_test;
    generate if(PACKET) begin: packet_test
        wire export_ready,export_fault;
        wire [31:0] export_period_frames,busy_skipped_frames,rate_skipped_frames;
        assign export_period_frames_test=export_period_frames;
        assign rate_skipped_frames_test=rate_skipped_frames;
        wire control_request,control_grant,control_valid,control_ready,control_last,receive_error;
        wire [31:0] control_sequence;
        wire [7:0] control_data;
        calibration_control control(.clk(clk),.rst_n(rst_n),.rx_valid(rx_valid),.rx_ready(rx_ready),.rx_data(rx_data),
            .export_period_frames(export_period_frames),
            .tx_request(control_request),.tx_grant(control_grant),.packet_sequence(control_sequence),.sequence_take(),.receive_error(receive_error),
            .source_version(active_source_version),.k_version(active_k_version),
            .source_begin(c_source_begin),.source_we(c_source_we),.source_commit(c_source_commit),.source_addr(c_source_addr),.source_gain(c_source_gain),
            .source_ack(source_ack),.source_error(source_error),
            .k_begin(c_k_begin),.k_we(c_k_we),.k_commit(c_k_commit),.k_addr(c_k_addr),.k_weight(c_k_weight),.k_exponent(c_k_exponent),
            .k_ack(k_ack),.k_error(k_error),
            .tx_valid(control_valid),.tx_ready(control_ready),.tx_data(control_data),.tx_last(control_last));
        always @(posedge clk) if(rst_n && receive_error) $fatal(1,"Configuration packet rejected");
        assign raw_ready=raw_enable && export_ready;
        // Keep internal S1/S2 checks, but never serialize them in S0-only mode.
        assign spectrum_ready=1'b1;
        always @(posedge clk) if(rst_n && (export_fault || busy_skipped_frames!=0))
            $fatal(1,"Unexpected S0 export fault/skip at qualified simulation bandwidth");
        s0_measurement_packet_tx packetizer(.*,.idle(),
            .period_frames(export_period_frames),
            .raw_valid(raw_valid && raw_enable),.raw_ready(export_ready),
            .raw_timestamp_valid(1'b1),.result_timestamp_valid(1'b1),
            .m_valid(packet_valid),.m_ready(packet_ready),.m_data(packet_data),.m_last(packet_last));
    end else begin
        assign export_period_frames_test=0;
        assign rate_skipped_frames_test=0;
        assign spectrum_ready=cycles%19<11;
        assign raw_ready=raw_enable && cycles%11<8;
        assign result_ready=cycles%137<71;
        assign packet_valid=0;assign packet_data=0;assign packet_last=0;
    end endgenerate
    generate if(CAPTURE) begin: capture_test
        acquisition_core dut(.*,.capture_first(11'd512),.idle(),
            .source_begin(PACKET ? c_source_begin : source_begin),.source_we(PACKET ? c_source_we : source_we),
            .source_commit(PACKET ? c_source_commit : source_commit),.source_addr(PACKET ? c_source_addr : source_addr),
            .source_gain(PACKET ? c_source_gain : source_gain),
            .k_begin(PACKET ? c_k_begin : k_begin),.k_we(PACKET ? c_k_we : k_we),.k_commit(PACKET ? c_k_commit : k_commit),
            .k_addr(PACKET ? c_k_addr : k_addr),.k_weight(PACKET ? c_k_weight : k_weight),.k_exponent(PACKET ? c_k_exponent : k_exponent));
        assign s_ready=1'b1;
    end else begin: processor_test
        spectral_processor dut(.*);
        assign dropped_frames=0;assign malformed_frames=0;
        assign raw_valid=0;assign raw_data=0;assign raw_first=0;assign raw_last=0;assign raw_frame_id=0;
    end endgenerate
    reg [11:0] raw[0:4095];reg [31:0] weights[0:511];reg [15:0] exponent_mem[0:0];
    integer i,f,s_count=0,p_count=0,r_count=0,sfile,pfile,rfile,overlap_count=0;
    integer frame_start[0:3];
    integer raw_count=0,raw_position,raw_id;
    reg s_stalled=0,p_stalled=0,r_stalled=0;
    reg [255:0] shold,phold,rhold;
    reg raw_stalled=0;reg [109:0] raw_hold;
    wire [109:0] raw_bundle={raw_data,raw_first,raw_last,raw_frame_id,raw_timestamp};
    wire [255:0] sbundle={spectrum_s0,spectrum_s1,spectrum_s2,spectrum_first,spectrum_last,spectrum_frame_id,spectrum_source_version};
    wire [255:0] pbundle={phase_data,phase_index,phase_last,phase_invalid,phase_frame_id};
    wire [255:0] rbundle={result_accumulator,result_exponent,result_frame_id,result_source_version,result_k_version,result_invalid,result_peak,result_left,result_right};
    always @(negedge clk) if(rst_n) begin
        phase_ready=cycles%23<13;
        packet_ready=cycles%17>5;
    end
    always @(posedge clk) if(rst_n) begin
        cycles<=cycles+1;
        if(PACKET && packet_valid && packet_ready) begin
            $fwrite(packet_file,"%02x\n",packet_data);
            if(packet_last) packet_count=packet_count+1;
        end
        if(raw_stalled && (!raw_valid || raw_bundle!==raw_hold)) $fatal(1,"Raw calibration stream stall corruption");
        raw_stalled<=raw_valid && !raw_ready;raw_hold<=raw_bundle;
        if(raw_valid && raw_ready) begin
            raw_position=raw_count%1024;
            raw_id=raw_count<1024 ? 198 : 199+raw_count/1024;
            if(raw_frame_id!=raw_id || raw_timestamp!=64'd100000+raw_id*64'd17002 || raw_first!=(raw_position==0) || raw_last!=(raw_position==1023)) $fatal(1,"Raw stream frame metadata");
            if(raw_data!==(raw_count<1024 ? 12'd777 : raw[(raw_count/1024-1)*1024+raw_position])) $fatal(1,"Raw source-capture data");
            raw_count=raw_count+1;
        end
        if(fault || source_error || k_error) $fatal(1,"Unexpected configuration/protocol fault");
        if(s_stalled && (!spectrum_valid || sbundle!==shold)) $fatal(1,"Spectrum stall corruption");
        if(p_stalled && (!phase_valid || pbundle!==phold)) $fatal(1,"Phase stall corruption");
        if(r_stalled && (!result_valid || rbundle!==rhold)) $fatal(1,"Result stall corruption");
        s_stalled<=spectrum_valid && !spectrum_ready;shold<=sbundle;
        p_stalled<=phase_valid && !phase_ready;phold<=pbundle;
        r_stalled<=result_valid && !result_ready;rhold<=rbundle;
        if(s_valid && s_ready && s_first && s_frame_id>=200) begin
            frame_start[s_frame_id-200]=cycles;
            if(CAPTURE && s_frame_id>200 && cycles-frame_start[s_frame_id-201]!=17002) $fatal(1,"Input frame period changed");
        end
        if(CAPTURE && s_valid && (spectrum_valid || phase_valid || result_valid)) overlap_count=overlap_count+1;
        if(spectrum_valid && spectrum_ready) begin
            if(spectrum_first!=(s_count%1024==0) || spectrum_last!=(s_count%1024==1023) ||
                spectrum_frame_id!=200+s_count/1024 || spectrum_source_version!=1) $fatal(1,"Spectrum metadata");
            $fdisplay(sfile,"%0d,%0d,%0d,%0d,%0d",spectrum_frame_id,s_count%1024,spectrum_s0,spectrum_s1,spectrum_s2);
            s_count=s_count+1;
        end
        if(phase_valid && phase_ready) begin
            if(phase_index!=p_count%1024 || phase_last!=(p_count%1024==1023) || phase_frame_id!=200+p_count/1024) $fatal(1,"Phase metadata");
            $fdisplay(pfile,"%0d,%0d,%0d,%0d",phase_frame_id,phase_index,phase_data,phase_invalid);
            p_count=p_count+1;
        end
        if(result_valid && result_ready) begin
            if(result_frame_id!=200+r_count) $fatal(1,"Result frame ID");
            $fdisplay(rfile,"%0d,%h,%0d,%0d,%0d,%0d,%0d,%0d,%0d",result_frame_id,result_accumulator,result_exponent,result_invalid,result_peak,result_left,result_right,result_source_version,result_k_version);
            $display("Raw frame %0d -> distance: %0d clocks",r_count,cycles-frame_start[r_count]);
            r_count=r_count+1;
        end
    end
    initial begin
        if(PACKET) packet_file=$fopen("processor_raw_packets.hex","w");
        $readmemh("processor_raw.mem",raw);$readmemh("processor_weights.mem",weights);$readmemh("processor_exponent.mem",exponent_mem);
        sfile=$fopen("processor_spectrum.csv","w");pfile=$fopen("processor_phase.csv","w");rfile=$fopen("processor_results.csv","w");
        if(!sfile || !pfile || !rfile) $fatal(1,"Output files unavailable");
        repeat(8) @(negedge clk);rst_n=1;
        if(CAPTURE) begin
            // No S or K yet: raw light-source capture must still be available.
            for(i=0;i<2048;i=i+1) begin
                @(negedge clk);s_valid=1;s_data=777;s_frame_id=198;s_timestamp=64'd100000+198*64'd17002;s_first=i==0;s_last=i==2047;
                @(negedge clk);s_valid=0;repeat(6) @(negedge clk);
            end
            wait(raw_valid);
            if(configured || spectrum_valid || phase_valid || result_valid) $fatal(1,"Uncalibrated frame entered DSP");
        end
        if(PACKET) begin
            $readmemh("processor_config.mem",config_bytes);
            for(i=0;i<6272;i=i+1) begin
                @(negedge clk);rx_valid=1;rx_data=config_bytes[i];
                @(posedge clk);while(!rx_ready) @(posedge clk);
                @(negedge clk);rx_valid=0;
            end
            wait(export_period_frames_test==2);
        end else begin
        @(negedge clk);source_begin=1;k_begin=1;k_exponent=exponent_mem[0];
        @(negedge clk);source_begin=0;k_begin=0;
        for(i=0;i<1024;i=i+1) begin
            source_we=1;source_addr=i;
            k_we=i<512;k_addr=i;k_weight=weights[i%512];
            @(negedge clk);
        end
        source_we=0;k_we=0;source_commit=1;k_commit=1;
        @(negedge clk);source_commit=0;k_commit=0;
        end
        wait(configured);
        if(active_source_version!=1 || active_k_version!=1) $fatal(1,"Active calibration versions not exported");
        raw_enable=1;
        for(f=0;f<4;f=f+1) begin
            for(i=0;i<(CAPTURE ? 2048 : 1024);i=i+1) begin
                @(negedge clk);s_valid=1;
                s_data=CAPTURE ? (i>=512 && i<1536 ? raw[f*1024+i-512] : (i<512 ? 12'd0 : 12'd4095)) : raw[f*1024+i];
                s_first=i==0;s_last=i==(CAPTURE ? 2047 : 1023);s_frame_id=200+f;s_timestamp=64'd100000+(200+f)*64'd17002;
                @(posedge clk);while(!s_ready) @(posedge clk);
                if(CAPTURE) begin
                    @(negedge clk);s_valid=0;
                    repeat(6) @(negedge clk);
                end
            end
            if(CAPTURE) repeat(618) @(negedge clk); // 17002 clocks/frame at 100 MHz.
        end
        @(negedge clk);s_valid=0;
        wait(r_count==4 && p_count==4096 && s_count==4096);repeat(5) @(negedge clk);
        if(PACKET) begin
            wait(packet_count==10);$fclose(packet_file);
            if(rate_skipped_frames_test!=2) $fatal(1,"Configured S0 selection did not skip two frames");
        end
        if(CAPTURE && raw_count!=5120) $fatal(1,"Missing uncalibrated/calibrated raw frames");
        if(dropped_frames!=0 || malformed_frames!=0) $fatal(1,"Continuous acquisition lost frames");
        if(CAPTURE && overlap_count==0) $fatal(1,"No acquisition/processing overlap observed");
        if(CAPTURE) $display("PASS: four continuous 2048-pixel frames, 12.5 MHz sample rate, 170.02 us frame period, zero drops");
        $fclose(sfile);$fclose(pfile);$fclose(rfile);
        $display("PASS: processor protocol; numerical check required");$finish;
    end
    initial begin #3000000;$fatal(1,"Timeout");end
endmodule
