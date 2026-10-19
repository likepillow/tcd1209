`timescale 1ns/1ps
module tb_adc_pixel_align;
    reg clk=0; always #5 clk=~clk;
    integer tick=0;
    reg rst_n=0, launch_ce=0, tag_valid=0;
    reg [10:0] tag_index=0;
    reg [31:0] tag_frame_id=0;
    reg [11:0] adc_data=12'hbad;
    wire m_valid,m_first,m_last,fault;
    wire [11:0] m_data;
    wire [10:0] m_index;
    wire [31:0] m_frame_id;
    adc_pixel_align dut(.*);

    // Exercise the actual downstream crop/bank interface as well as the
    // individual 2048-pixel capture stream. Nonbackpressurable ADC input.
    wire cropped_valid,cropped_first,cropped_last;
    wire [11:0] cropped_data;
    wire [31:0] cropped_frame,dropped,malformed;
    reg cropped_ready=0;
    integer crop_index=0,crop_total=0,crop_frames=0,crop_expected;
    frame_ping_pong #(.WIDTH(12),.CAPTURE_DEPTH(2048),.CAPTURE_FIRST(512)) banks(
        .clk(clk),.rst_n(rst_n),.s_valid(m_valid),.s_data(m_data),
        .s_first(m_first),.s_last(m_last),.s_frame_id(m_frame_id),
        .m_valid(cropped_valid),.m_ready(cropped_ready),.m_data(cropped_data),
        .m_first(cropped_first),.m_last(cropped_last),.m_frame_id(cropped_frame),
        .dropped_frames(dropped),.malformed_frames(malformed));
    always @(negedge clk) cropped_ready = (tick%7 != 0 && tick%7 != 1);
    always @(posedge clk) begin
        if (!rst_n) crop_index=0;
        else if (cropped_valid && cropped_ready) begin
            if (cropped_frame>=100 && cropped_frame<=102)
                crop_expected=(((crop_index+544)*73) ^ ((cropped_frame-100)*811)
                               ^ ((crop_index+544)>>3)) & 4095;
            else if (cropped_frame==501) crop_expected=((crop_index+512)*29+41)&4095;
            else $fatal(1,"unexpected cropped frame %0d",cropped_frame);
            if (cropped_data !== crop_expected[11:0]
                || cropped_first !== (crop_index==0) || cropped_last !== (crop_index==1023))
                $fatal(1,"crop mismatch frame %0d index %0d",cropped_frame,crop_index);
            crop_total=crop_total+1;
            if (crop_index==1023) begin crop_index=0;crop_frames=crop_frames+1;end
            else crop_index=crop_index+1;
        end
    end

    // Independent converter model: history addressed by absolute conversion
    // number, DOUT changes 9.5 ns AFTER each launch (not a zero-delay RTL ADC).
    reg [11:0] history [0:19999];
    reg [11:0] expected_data [0:9999];
    reg [10:0] expected_index [0:9999];
    reg [31:0] expected_frame [0:9999];
    integer conversions=0, written=0, read_count=0, total_checked=0;
    integer first_count=0, last_count=0;
    integer capture_due=-1, last_valid_tick=-1;
    reg checking=1;
    reg [11:0] model_sample=0, next_output;

    always @(posedge clk) begin
        tick=tick+1;
        if (launch_ce && rst_n) begin
            history[conversions]=model_sample;
            next_output=(conversions>=10) ? history[conversions-10] : 12'hbad;
            adc_data <= #9.5 next_output;
            conversions=conversions+1;
            capture_due=tick+2;
            if (tag_valid && checking) begin
                expected_data[written]=model_sample;
                expected_index[written]=tag_index;
                expected_frame[written]=tag_frame_id;
                written=written+1;
            end
        end
        #1;
        if (!rst_n && m_valid) $fatal(1,"valid during reset");
        if (m_valid && checking) begin
            if (tick!=capture_due || tick==last_valid_tick+1)
                $fatal(1,"wrong capture offset or non-pulsed valid");
            if (read_count>=written) $fatal(1,"unexpected valid after reset/blank");
            if (m_data!==expected_data[read_count] || m_index!==expected_index[read_count]
                || m_frame_id!==expected_frame[read_count])
                $fatal(1,"data/tag mismatch at %0d: got %h index %0d frame %0d expected %h index %0d frame %0d",
                    read_count,m_data,m_index,m_frame_id,expected_data[read_count],expected_index[read_count],expected_frame[read_count]);
            if (m_first !== (m_index==0) || m_last !== (m_index==2047))
                $fatal(1,"incorrect first/last");
            if (m_first) first_count=first_count+1;
            if (m_last) last_count=last_count+1;
            read_count=read_count+1; total_checked=total_checked+1;
            last_valid_tick=tick;
        end
        if (!m_valid && (m_first || m_last)) $fatal(1,"markers without valid");
    end

    task automatic convert(input integer spacing,input bit valid_pixel,
                           input integer pixel,input integer frame,input integer sample);
        @(negedge clk);
        launch_ce=1;tag_valid=valid_pixel;tag_index=pixel;
        tag_frame_id=frame;model_sample=sample;
        @(negedge clk);launch_ce=0;tag_valid=0;
        repeat(spacing-1) @(negedge clk);
    endtask
    task automatic flush(input integer spacing);
        integer j;
        for(j=0;j<12;j=j+1) convert(spacing,0,0,0,12'habc);
    endtask
    task automatic reset_logic;
        @(negedge clk); rst_n=0;launch_ce=0;tag_valid=0;
        repeat(3) @(negedge clk);
        // Model history intentionally NOT reset: physical ADC contents may
        // survive an FPGA-only reset; metadata must suppress the stale data.
        written=0;read_count=0;rst_n=1;
    endtask
    integer frame,pixel,spacing;
    initial begin
        reset_logic();
        for(frame=0;frame<3;frame=frame+1) begin
            spacing=(frame==0) ? 19 : ((frame==1) ? 7 : 3);
            // Task includes an additional separating edge: intervals are
            // 20, 8 and 4 system clocks, i.e. 5, 12.5 and 25 MHz.
            for(pixel=0;pixel<2088;pixel=pixel+1)
                convert(spacing,pixel>=32 && pixel<2080,pixel-32,100+frame,
                        ((pixel*73) ^ (frame*811) ^ (pixel>>3)) & 4095);
            flush(spacing);
        end
        repeat(3200) @(negedge clk);
        if (read_count!=6144 || first_count!=3 || last_count!=3 || fault)
            $fatal(1,"continuous frame accounting failed");
        if (crop_frames!=3 || crop_total!=3072 || dropped || malformed)
            $fatal(1,"three-frame crop accounting failed: frames=%0d pixels=%0d drop=%0d malformed=%0d",crop_frames,crop_total,dropped,malformed);

        // Reset while valid tags are still inside the ADC pipeline.
        for(pixel=0;pixel<7;pixel=pixel+1) convert(7,1,pixel,500,pixel+123);
        reset_logic(); flush(7);
        if (read_count!=0) $fatal(1,"stale pipeline escaped reset");
        for(pixel=0;pixel<2048;pixel=pixel+1)
            convert(7,1,pixel,501,(pixel*29+41)&4095);
        flush(7);
        repeat(3200) @(negedge clk);
        if (read_count!=2048 || first_count!=4 || last_count!=4 || fault)
            $fatal(1,"reset recovery failed");
        if (crop_frames!=4 || crop_total!=4096 || dropped || malformed)
            $fatal(1,"reset-recovered crop accounting failed");

        // A new DATACLK launch while capture is pending is an integration
        // error, even with invalid tags. Stop output until explicit reset.
        checking=0;
        @(negedge clk);launch_ce=1;tag_valid=0;
        repeat(2) @(negedge clk);
        launch_ce=0;
        @(negedge clk);
        if (!fault || m_valid) $fatal(1,"overlap did not fail closed");
        for(pixel=0;pixel<15;pixel=pixel+1) begin
            convert(7,1,pixel,600,pixel);
            if (!fault || m_valid) $fatal(1,"fault was not sticky");
        end
        reset_logic();checking=1;
        convert(7,1,0,700,12'h321);flush(7);
        if (fault || read_count!=1) $fatal(1,"fault reset recovery failed");

        // Abort an already pending VALID bus capture before its capture edge.
        reset_logic();
        convert(7,1,0,800,12'h456);
        for(pixel=0;pixel<9;pixel=pixel+1) convert(7,0,0,0,0);
        @(negedge clk);launch_ce=1;tag_valid=0;
        @(posedge clk);#1;
        if (!dut.pending || !dut.pending_valid) $fatal(1,"test did not reach valid pending capture");
        reset_logic();flush(7);
        if (read_count!=0 || fault) $fatal(1,"pending capture survived reset");
        $display("PASS: ADC alignment %0d checked pixels, 10 conversions + 20 ns, frame boundaries, reset and fail-closed overlap",total_checked);
        $display("PASS: ADC to ping-pong crop %0d frames / %0d pixels, randomized-pattern data and output stalls",crop_frames,crop_total);
        $finish;
    end
    initial begin #5000000; $fatal(1,"timeout"); end
endmodule
