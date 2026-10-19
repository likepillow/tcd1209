`timescale 1ns/1ps
module tb_shared_packets;
    reg clk=0,rst_n=0,m_ready=0;
    always #5 clk=~clk;
    reg [2:0] pending=3'b111;
    wire [2:0] request,grant,sv,sr,sl,available;
    wire [23:0] sd;
    wire [31:0] packet_sequence;
    wire m_valid,m_last;wire [7:0] m_data;
    integer sent=0,cycle=0,packets=0,trace,i;
    reg pixel_valid=0;reg [11:0] pixel_data=0;
    wire pixel_ready;
    reg pixel_accepted=0,stalled=0;reg [8:0] held;
    assign request[0]=pending[0] & available[0];
    assign request[2]=pending[2] & available[2];
`ifdef USB_BRIDGE
    reg usb_clk=0;
    always #10.417 usb_clk=~usb_clk;
    reg [1:0] usb_reset=3;
    always @(posedge usb_clk or negedge rst_n)
        if(!rst_n) usb_reset<=3;else usb_reset<={usb_reset[0],1'b0};
    wire scheduled_valid,scheduled_ready,scheduled_last;
    wire [7:0] scheduled_data;
    wire word_valid,word_ready,word_last,bridge_fault;
    wire [15:0] word_data;
    usb_tx_bridge #(.DEPTH(32)) outbound(.wr_clk(clk),.rd_clk(usb_clk),.rst(!rst_n),
        .s_valid(scheduled_valid),.s_ready(scheduled_ready),.s_data(scheduled_data),.s_last(scheduled_last),
        .m_valid(word_valid),.m_ready(word_ready),.m_data(word_data),.m_last(word_last),.fault(bridge_fault));
    usb_rx_bridge #(.DEPTH(32)) loopback(.wr_clk(usb_clk),.rd_clk(clk),.rst(usb_reset[1]),
        .s_valid(word_valid),.s_ready(word_ready),.s_data(word_data),.s_last(word_last),
        .m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_last(m_last));
    always @(posedge clk) if(rst_n && bridge_fault) $fatal(1,"bridge rejected packet length");
    packet_scheduler #(.CHANNELS(3)) scheduler(.clk(clk),.rst_n(rst_n),.request(request),.grant(grant),
        .packet_sequence(packet_sequence),.s_valid(sv),.s_ready(sr),.s_data(sd),.s_last(sl),
        .m_valid(scheduled_valid),.m_ready(scheduled_ready),.m_data(scheduled_data),.m_last(scheduled_last));
`else
    packet_scheduler #(.CHANNELS(3)) scheduler(.*,.idle(),
        .s_valid(sv),.s_ready(sr),.s_data(sd),.s_last(sl));
`endif
    ack_packet_tx ack(.clk(clk),.rst_n(rst_n),.s_valid(grant[0]),.s_ready(available[0]),
        .command_sequence(32'd44),.status(16'b0),.packet_sequence(packet_sequence),
        .source_version(32'd1),.k_version(32'd1),
        .m_valid(sv[0]),.m_ready(sr[0]),.m_data(sd[7:0]),.m_last(sl[0]));
    raw_stream_packet_tx raw(.clk(clk),.rst_n(rst_n),.grant(grant[1]),.request(request[1]),
        .packet_sequence(packet_sequence),.s_frame_id(32'd55),.s_first(sent==0),.timestamp_valid(1'b1),.timestamp(64'd777),
        .s_valid(pixel_valid),.s_ready(pixel_ready),.s_data(pixel_data),
        .m_valid(sv[1]),.m_ready(sr[1]),.m_data(sd[15:8]),.m_last(sl[1]));
    result_packet_tx result_tx(.clk(clk),.rst_n(rst_n),.s_valid(grant[2]),.s_ready(available[2]),
        .accumulator(-84'sd123456789),.exponent(16'sd24),.peak(10'd97),.left_bin(10'd95),.right_bin(10'd99),
        .dropped_frames(32'b0),.malformed_frames(32'b0),.invalid(1'b0),.discontinuity(1'b0),
        .timestamp_valid(1'b1),.timestamp(64'd777),.frame_id(32'd55),.packet_sequence(packet_sequence),
        .source_version(32'd1),.k_version(32'd1),
        .m_valid(sv[2]),.m_ready(sr[2]),.m_data(sd[23:16]),.m_last(sl[2]));
    always @(posedge clk) if(rst_n) begin
        for(i=0;i<3;i=i+1) if(grant[i]) pending[i]<=0;
        pixel_accepted=pixel_valid && pixel_ready;
        if(pixel_accepted) sent=sent+1;
        if(stalled && (!m_valid || {m_last,m_data}!==held)) $fatal(1,"shared output changed while stalled");
        stalled=m_valid && !m_ready;held={m_last,m_data};
        if(m_valid && m_ready) begin
            $fwrite(trace,"%02x\n",m_data);if(m_last) packets=packets+1;
        end
    end
    always @(negedge clk) if(rst_n) begin
        cycle=cycle+1;m_ready=cycle%17>6;
        if(!pixel_valid || pixel_accepted) begin
            pixel_valid=sent<1024 && cycle%7!=0;pixel_data=(sent*73+19)%4096;
        end
    end
    initial begin
        trace=$fopen("shared_packets.hex","w");
        repeat(30) @(negedge clk);rst_n=1;
        wait(packets==3);repeat(5) @(posedge clk);$fclose(trace);
        if(sent!=1024 || packet_sequence!=3 || pending!=0) $fatal(1,"coverage incomplete");
        $display("PASS: shared ACK RAW RESULT packets, common sequence and stalled output");$finish;
    end
    initial begin #200000;$fatal(1,"timeout");end
endmodule
