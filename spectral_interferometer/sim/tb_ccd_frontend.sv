`timescale 1ns/1ps
module tb_ccd_frontend #(
    parameter integer ADC_CAPTURE_DELAY=2,
    parameter integer BUS_ARRIVAL_PS=9500,
    parameter integer FAST_PROFILE=0
);
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0,run=1;
    reg [11:0] adc_data=0;
    wire ccd_phi1,ccd_phi2,ccd_sh,ccd_rs,ccd_cp;
    wire ad_shp,ad_shd,ad_dataclk,ad_clpob,ad_pblk,ad_sck,ad_sdata,ad_sl;
    wire configure_done,busy,fault,frame_start,m_valid,m_first,m_last;
    wire [63:0] frame_timestamp;
    wire [11:0] m_data;
    wire [10:0] m_index;
    wire [31:0] m_frame_id;
    ccd_frontend #(.SETTLE_CYCLES(0),.DYNAMIC_PERIOD(FAST_PROFILE),.ADC_CAPTURE_DELAY(ADC_CAPTURE_DELAY),.FAST_PROFILE(FAST_PROFILE)) dut(.*,.period_pixels(FAST_PROFILE ? 64'd2500 : 64'd2114));

    wire raw_valid,raw_first,raw_last;
    wire [11:0] raw_data;
    wire [31:0] raw_frame,dropped,malformed;
    reg raw_ready=0;
    integer ticks=0,read_index=0,read_frame=0,raw_index=0,raw_next_frame=0;
    integer pixel_total=0,complete_total=0,crop_total=0,crop_frames=0;
    frame_ping_pong #(.WIDTH(12),.CAPTURE_DEPTH(2048),.CAPTURE_FIRST(512)) banks(
        .clk(clk),.rst_n(rst_n),.s_valid(m_valid),.s_data(m_data),
        .s_first(m_first),.s_last(m_last),.s_frame_id(m_frame_id),
        .m_valid(raw_valid),.m_ready(raw_ready),.m_data(raw_data),
        .m_first(raw_first),.m_last(raw_last),.m_frame_id(raw_frame),
        .dropped_frames(dropped),.malformed_frames(malformed));
    always @(negedge clk) raw_ready=(ticks%11 > 3);

    function automatic [11:0] sample_value(input integer frame,input integer pixel);
        sample_value=((pixel*137 + frame*911) ^ (pixel>>2) ^ (frame<<5)) & 4095;
    endfunction

    // Independent pin-driven model, deliberately not driven by DUT tag_valid,
    // tag_index, phase or state. After SH falls there are 3 post-guard ADC
    // conversions, followed by D0..D39/S1..S2048 in the 2088-slot CCD line.
    integer model_frame=-1,line_cursor=-100000,conversions=0;
    reg [11:0] history[0:99999];
    reg [11:0] delayed_value;
    realtime sh_rise_time=0,sh_fall_time=0,last_adc=0,adc_fall=0;
    realtime rs_rise=0,rs_fall=0,cp_rise=0,cp_fall=0,phi2_rise=0;
    realtime shp_fall=0,shp_rise=0,shd_fall=0,shd_rise=0,ob_fall=0;
    realtime reset_release=0,previous_sh=0;
    integer rs_count=0,cp_count=0,phi2_count=0,ob_count=0,serial_bits=0;
    integer sh_total=0,launch_before_config=0;
    reg check_line=0;

    always @(negedge rst_n) begin
        model_frame=-1;line_cursor=-100000;check_line=0;
        last_adc=0;adc_fall=0;rs_count=0;cp_count=0;phi2_count=0;ob_count=0;
        serial_bits=0;previous_sh=0;
        // Do NOT clear converter history on an FPGA-only reset.
    end
    always @(posedge rst_n) reset_release=$realtime;
    always @(posedge ad_sck) if(rst_n) serial_bits=serial_bits+1;
    always @(posedge configure_done) begin
        if($realtime-reset_release<2000000 || serial_bits!=80)
            $fatal(1,"startup did not wait 2 ms and send 80 serial bits");
    end
    always @(posedge ccd_sh) if(rst_n) begin
        if(!configure_done || !ccd_phi1 || ccd_phi2 || ccd_rs || ccd_cp)
            $fatal(1,"unsafe SH entry");
        if(check_line && (rs_count!=2088 || cp_count!=2088 || phi2_count!=2087 || ob_count!=16))
            $fatal(1,"line edge count mismatch: RS=%0d CP=%0d phi2=%0d OB=%0d",rs_count,cp_count,phi2_count,ob_count);
        if(cp_fall>0 && $realtime-cp_fall<200) $fatal(1,"SH pre-guard too short");
        if(sh_total==1 || sh_total==2)
            if($realtime-previous_sh!=(FAST_PROFILE ? 200000 : 422800)) $fatal(1,"continuous frame period mismatch");
        previous_sh=$realtime;sh_rise_time=$realtime;
        model_frame=model_frame+1;sh_total=sh_total+1;
        rs_count=0;cp_count=0;phi2_count=0;ob_count=0;check_line=1;
    end
    always @(negedge ccd_sh) if(rst_n && check_line) begin
        if($realtime-sh_rise_time!=1600) $fatal(1,"SH width mismatch");
        sh_fall_time=$realtime;line_cursor=FAST_PROFILE ? -8 : -3;
    end
    always @(posedge ccd_rs) if(rst_n) begin
        if(ccd_sh || $realtime-sh_fall_time<200) $fatal(1,"RS violates SH guard");
        rs_rise=$realtime;rs_count=rs_count+1;
    end
    always @(negedge ccd_rs) if(rst_n && rs_rise>0) begin
        if($realtime-rs_rise!=(FAST_PROFILE ? 10 : 30)) $fatal(1,"RS width mismatch");
        rs_fall=$realtime;
    end
    always @(posedge ccd_cp) if(rst_n) begin
        if(ccd_sh || $realtime-rs_fall<10) $fatal(1,"CP/RS ordering error");
        cp_rise=$realtime;cp_count=cp_count+1;
    end
    always @(negedge ccd_cp) if(rst_n && cp_rise>0) begin
        if($realtime-cp_rise!=(FAST_PROFILE ? 10 : 30)) $fatal(1,"CP width mismatch");
        cp_fall=$realtime;
    end
    always @(posedge ccd_phi2) if(rst_n) begin
        if(ccd_sh || $realtime-sh_fall_time<600) $fatal(1,"phi2 violates SH guard");
        phi2_rise=$realtime;phi2_count=phi2_count+1;
    end
    always @(negedge ccd_phi2) if(rst_n && phi2_rise>0) begin
        if($realtime-phi2_rise!=(FAST_PROFILE ? 40 : 120) || $realtime-cp_fall!=(FAST_PROFILE ? 10 : 20))
            $fatal(1,"phi2 pulse/CP edge mismatch");
    end
    always @(negedge ad_shp) if(rst_n) shp_fall=$realtime;
    always @(posedge ad_shp) if(rst_n && shp_fall>0) begin
        if($realtime-shp_fall!=(FAST_PROFILE ? 10 : 30)) $fatal(1,"SHP width mismatch");
        shp_rise=$realtime;
    end
    always @(negedge ad_shd) if(rst_n) begin
        if($realtime-shp_rise<6.25) $fatal(1,"SHP/SHD gap too short");
        shd_fall=$realtime;
    end
    always @(posedge ad_shd) if(rst_n && shd_fall>0) begin
        if($realtime-shd_fall!=(FAST_PROFILE ? 10 : 20) || $realtime-shp_rise<11.25)
            $fatal(1,"SHD pulse/phase mismatch");
        shd_rise=$realtime;
    end
    always @(negedge ad_clpob) if(rst_n) ob_fall=$realtime;
    always @(posedge ad_clpob) if(rst_n && ob_fall>0) begin
        if($realtime-ob_fall!=(FAST_PROFILE ? 1280 : 3200)) $fatal(1,"OB width mismatch");
    end
    always @(negedge ad_dataclk) if(rst_n && last_adc>0) begin
        if($realtime-last_adc!=(FAST_PROFILE ? 40 : 100)) $fatal(1,"DATACLK high width mismatch");
        adc_fall=$realtime;
    end
    always @(posedge ad_dataclk) if(rst_n) begin
        if(last_adc>0 && ($realtime-last_adc!=(FAST_PROFILE ? 80 : 200) || $realtime-adc_fall!=(FAST_PROFILE ? 40 : 100)))
            $fatal(1,"DATACLK period/low width mismatch");
        if($realtime-shd_rise!=10) $fatal(1,"DATACLK not after SHD");
        last_adc=$realtime;
        if(!configure_done) launch_before_config=launch_before_config+1;
        if(line_cursor>=0 && line_cursor<2088) begin
            history[conversions]=sample_value(model_frame,line_cursor);
            if((!ad_clpob)!=(line_cursor>=13 && line_cursor<=28))
                $fatal(1,"OB pulse outside shielded source samples");
            if(!ad_clpob) ob_count=ob_count+1;
        end else history[conversions]=12'hbad;
        if(line_cursor>-100000) line_cursor=line_cursor+1;
        delayed_value=conversions>=10 ? history[conversions-10] : 12'hbad;
        adc_data<=#(BUS_ARRIVAL_PS/1000.0) delayed_value;
        conversions=conversions+1;
    end

    integer trace;
    initial begin
        $timeformat(-9,0,"",0);
        trace=$fopen("frontend_waveform.csv","w");
        $fwrite(trace,"time_ns,phi1,phi2,sh,rs,cp,shp,shd,dataclk,clpob,valid,index,data\n");
    end
    // Raw bank output consumes the previous cycle's registered m_* signals.
    always @(posedge clk) begin
        if(!rst_n) begin
            ticks=0;read_index=0;read_frame=0;raw_index=0;raw_next_frame=0;
        end else begin
            ticks=ticks+1;
            if(raw_valid && raw_ready) begin
                if(raw_frame!=raw_next_frame || raw_data!==sample_value(raw_frame,raw_index+544)
                    || raw_first!==(raw_index==0) || raw_last!==(raw_index==1023))
                    $fatal(1,"cropped bank data mismatch at frame %0d index %0d",raw_frame,raw_index);
                crop_total=crop_total+1;
                if(raw_index==1023) begin raw_index=0;raw_next_frame=raw_next_frame+1;crop_frames=crop_frames+1;end
                else raw_index=raw_index+1;
            end
        end
        #1;
        if(ccd_phi1===ccd_phi2 || (ccd_sh && (ccd_rs || ccd_cp || ccd_phi2)))
            $fatal(1,"CCD safe-level violation");
        if(!ad_pblk || fault) $fatal(1,"unexpected blanking/alignment fault");
        if(frame_start && (frame_timestamp!=ticks-1 || !ccd_sh)) $fatal(1,"frame timestamp mismatch");
        if(!configure_done && (m_valid || busy || ccd_sh)) $fatal(1,"acquisition before startup completed");
        if(m_valid) begin
            if($realtime-last_adc!=10*ADC_CAPTURE_DELAY+1 || m_index!=read_index || m_frame_id!=read_frame
                || m_data!==sample_value(read_frame,read_index+32)
                || m_first!==(read_index==0) || m_last!==(read_index==2047))
                $fatal(1,"pin-driven ADC/data alignment mismatch frame=%0d index=%0d data=%0h expected=%0h",
                    m_frame_id,m_index,m_data,sample_value(read_frame,read_index+32));
            pixel_total=pixel_total+1;
            if(read_index==2047) begin read_index=0;read_frame=read_frame+1;complete_total=complete_total+1;end
            else read_index=read_index+1;
        end
        if(model_frame==0 && $realtime-sh_rise_time<11000 && rst_n)
            $fwrite(trace,"%0t,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                $realtime,ccd_phi1,ccd_phi2,ccd_sh,ccd_rs,ccd_cp,ad_shp,ad_shd,ad_dataclk,ad_clpob,m_valid,m_index,m_data);
    end

    task automatic stop_and_drain(input integer expected_frames);
        wait(!busy); repeat(4000) @(negedge clk);
        if(complete_total!=expected_frames || crop_frames!=expected_frames || dropped || malformed)
            $fatal(1,"stop/drain accounting failed: complete=%0d crop=%0d drop=%0d malformed=%0d",complete_total,crop_frames,dropped,malformed);
        if(rs_count!=2088 || cp_count!=2088 || phi2_count!=2087 || ob_count!=16)
            $fatal(1,"final line pin counts failed");
    endtask
    integer idle_conversions,idle_pixels;
    initial begin
        repeat(4) @(negedge clk);rst_n=1;
        wait(m_valid && m_frame_id==2 && m_index==700);
        @(negedge clk);run=0;
        stop_and_drain(3);
        idle_conversions=conversions;idle_pixels=pixel_total;
        repeat(FAST_PROFILE ? 504 : 500) @(negedge clk);
        if(conversions-idle_conversions!=(FAST_PROFILE ? 63 : 25) || pixel_total!=idle_pixels || busy)
            $fatal(1,"idle clocks or acquisition gating failed");
        run=1;
        wait(m_valid && m_frame_id==3 && m_index==700);
        @(negedge clk);run=0;
        stop_and_drain(4);

        // Abort a partial fifth frame; after a full hardware reset reinitialize
        // AD9945 and start a fresh frame-id epoch, suppressing old ADC history.
        run=1;wait(m_valid && m_frame_id==4 && m_index==50);
        @(negedge clk);rst_n=0;run=0;
        repeat(4) @(negedge clk);rst_n=1;run=1;
        wait(m_valid && m_frame_id==0 && m_index==700);
        @(negedge clk);run=0;
        stop_and_drain(5);
        if(crop_total!=5120 || launch_before_config<20000) $fatal(1,"test coverage incomplete");
        $fclose(trace);
        $display("PASS: frontend pin-driven model, %0d complete frames / %0d cropped pixels, fast=%0d, frame_ns=%0d",complete_total,crop_total,FAST_PROFILE,FAST_PROFILE ? 200000 : 422800);
        $display("PASS: startup gating, CCD/AFE edge widths, shielded-only clamp, graceful stop/restart, partial-frame reset");
        $finish;
    end
    initial begin #10000000; $fatal(1,"frontend timeout"); end
endmodule
