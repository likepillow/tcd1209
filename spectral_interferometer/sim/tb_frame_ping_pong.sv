`timescale 1ns/1ps
module tb_frame_ping_pong;
    parameter N=1024;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, s_valid=0, s_first=0, s_last=0, m_ready=0;
    reg [15:0] s_data=0;
    reg [31:0] s_frame_id=0;
    wire [63:0] s_timestamp=64'h1234000000000000+s_frame_id;
    wire [63:0] m_timestamp;
    wire m_valid, m_first, m_last;
    wire [15:0] m_data;
    wire [31:0] m_frame_id, dropped_frames, malformed_frames;
    frame_ping_pong #(.DEPTH(N), .ADDR_BITS($clog2(N))) dut(.*,.capture_first(11'd0),.idle());
    integer read_index=0, read_frames=0, expected_id=1;
    reg stalled=0;
    reg [49:0] held;
    always @(posedge clk) if (rst_n) begin
        if (stalled && (!m_valid || {m_frame_id,m_first,m_last,m_data} !== held))
            $fatal(1,"Output changed under backpressure");
        stalled <= m_valid && !m_ready;
        held <= {m_frame_id,m_first,m_last,m_data};
        if (m_valid && m_ready) begin
            if(m_timestamp !== 64'h1234000000000000+expected_id) $fatal(1,"Timestamp mismatch");
            if (m_frame_id !== expected_id || m_data !== expected_id*100+read_index)
                $fatal(1,"Mixed/corrupt frame: id=%d data=%d index=%d expected=%d",m_frame_id,m_data,read_index,expected_id);
            if (m_first !== (read_index==0) || m_last !== (read_index==N-1))
                $fatal(1,"Invalid output boundaries");
            if (read_index==N-1) begin
                read_index=0;
                read_frames=read_frames+1;
                expected_id=(expected_id==2) ? 4 : expected_id+1;
            end else read_index=read_index+1;
        end
    end
    task send_frame(input integer id, input integer count);
        integer i;
        begin
            for(i=0;i<count;i=i+1) begin
                @(negedge clk);
                s_valid=1; s_first=(i==0); s_last=(i==count-1);
                s_data=id*100+i; s_frame_id=id;
            end
            @(negedge clk); s_valid=0; s_first=0; s_last=0;
        end
    endtask
    initial begin
        repeat(4) @(negedge clk);
        rst_n=1;
        send_frame(1,N);
        send_frame(2,N);
        send_frame(3,N); // Both banks owned: must drop the WHOLE frame.
        if(dropped_frames!=1) $fatal(1,"Expected one overrun");
        repeat(5) @(negedge clk);
        m_ready=1;
        wait(read_frames==2);
        repeat(3) @(negedge clk);
        send_frame(4,N);
        wait(read_frames==3);
        repeat(3) @(negedge clk);
        send_frame(9,3); // Short frame must never publish.
        repeat(10) @(negedge clk);
        if(malformed_frames!=1 || read_frames!=3 || m_valid) $fatal(1,"Malformed frame published");
        fork
            send_frame(5,N);
            begin
                repeat(30) begin @(negedge clk); m_ready=~m_ready; end
                m_ready=1;
            end
        join
        wait(read_frames==4);
        repeat(4) @(negedge clk);
        $display("PASS: ownership, whole-frame drop, malformed frame, stalls, metadata");
        $finish;
    end
    initial begin #1000000; $fatal(1,"Timeout"); end
endmodule
