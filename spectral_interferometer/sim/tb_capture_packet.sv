`timescale 1ns/1ps
module tb_capture_packet;
    reg clk=0,rst_n=0;
    always #5 clk=~clk;
    reg adc_valid=0,adc_first=0,adc_last=0;
    reg [11:0] adc_data=0;
    reg [31:0] adc_frame=0;
    wire valid,ready,first,last,request,grant,m_valid,m_last;
    wire [11:0] data;
    wire [31:0] frame_id,dropped,malformed,sequence_number;
    wire [7:0] m_data;
    reg m_ready=0;
    integer trace,packets=0,cycle=0,f,p;
    reg long_stall=0;
    reg held_valid=0;
    reg [8:0] held;
    frame_ping_pong #(.WIDTH(12),.CAPTURE_DEPTH(2048),.CAPTURE_FIRST(512)) capture(
        .clk(clk),.rst_n(rst_n),.s_valid(adc_valid),.s_first(adc_first),.s_last(adc_last),
        .s_data(adc_data),.s_frame_id(adc_frame),.m_valid(valid),.m_ready(ready),
        .m_data(data),.m_first(first),.m_last(last),.m_frame_id(frame_id),
        .dropped_frames(dropped),.malformed_frames(malformed));
    wire byte_valid,byte_ready,byte_last;
    wire [7:0] byte_data;
    raw_stream_packet_tx raw(.clk(clk),.rst_n(rst_n),.s_valid(valid),.s_ready(ready),
        .s_data(data),.s_first(first),.s_frame_id(frame_id),.timestamp_valid(1'b0),.timestamp(64'b0),
        .request(request),.grant(grant),.packet_sequence(sequence_number),
        .m_valid(byte_valid),.m_ready(byte_ready),.m_data(byte_data),.m_last(byte_last));
    packet_scheduler #(.CHANNELS(1)) scheduler(.clk(clk),.rst_n(rst_n),.request(request),.grant(grant),
        .packet_sequence(sequence_number),.s_valid(byte_valid),.s_ready(byte_ready),
        .s_data(byte_data),.s_last(byte_last),.m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_last(m_last));
    always @(negedge clk) if(rst_n) begin
        cycle=cycle+1;m_ready=(cycle%17>5) && (!long_stall || cycle>50000);
    end
    always @(posedge clk) if(rst_n) begin
        if(held_valid && (!m_valid || {m_last,m_data}!==held)) $fatal(1,"stalled packet changed");
        held_valid=m_valid && !m_ready;held={m_last,m_data};
    end
    always @(posedge clk) if(rst_n && m_valid && m_ready) begin
        $fwrite(trace,"%02x\n",m_data);
        if(m_last) packets=packets+1;
    end
    initial begin
        long_stall=$test$plusargs("LONG_STALL");
        trace=$fopen("capture_packets.hex","w");
        repeat(4) @(negedge clk);rst_n=1;
        // ADC cannot be stopped by downstream ready; 12.5 MHz at 100 MHz system.
        for(f=0;f<6;f=f+1) begin
            for(p=0;p<2048;p=p+1) begin
                @(negedge clk);adc_valid=1;adc_first=p==0;adc_last=p==2047;
                adc_frame=f;adc_data=(f*211+p*13+7)%4096;
                @(negedge clk);adc_valid=0;adc_first=0;adc_last=0;
                repeat(6) @(negedge clk);
            end
        end
        wait(packets==(long_stall ? 4 : 6));repeat(8) @(negedge clk);$fclose(trace);
        if(dropped!=(long_stall ? 2 : 0) || malformed!=0 || sequence_number!=(long_stall ? 4 : 6)) $fatal(1,"capture counters mismatch");
        $display("PASS: capture packet crop continuous ADC and backpressure");$finish;
    end
    initial begin #2000000;$fatal(1,"timeout");end
endmodule
