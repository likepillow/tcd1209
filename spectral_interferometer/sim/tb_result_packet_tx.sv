`timescale 1ns/1ps
module tb_result_packet_tx;
    reg clk=0,rst_n=0,s_valid=0,m_ready=0;
    always #5 clk=~clk;
    wire s_ready,m_valid,m_last;wire [7:0] m_data;
    reg signed [83:0] accumulator=0;reg signed [15:0] exponent=0;
    reg [9:0] peak=97,left_bin=95,right_bin=99;
    reg [31:0] dropped_frames=3,malformed_frames=4,frame_id=9,packet_sequence=0,source_version=32'h12345678,k_version=32'habcdef01;
    reg invalid=0,discontinuity=1,timestamp_valid=1;
    reg [63:0] timestamp=64'h123456789abcdef0;
    integer trace,i,packets=0,cycles=0;
    reg stalled=0;reg [8:0] held;
    result_packet_tx dut(.*);
    always @(negedge clk) begin cycles=cycles+1;m_ready=cycles%13>5;end
    always @(posedge clk) if(rst_n) begin
        if(stalled && (!m_valid || {m_last,m_data} !== held)) $fatal(1,"unstable result packet");
        stalled=m_valid && !m_ready;held={m_last,m_data};
        if(m_valid && m_ready) begin
            $fwrite(trace,"%02x\n",m_data);if(m_last) packets=packets+1;
        end
    end
    initial begin
        trace=$fopen("result_packets.hex","w");
        repeat(4) @(negedge clk);rst_n=1;
        for(i=0;i<3;i=i+1) begin
            wait(s_ready);@(negedge clk);
            accumulator=(i==0) ? (84'sd1<<82)+123 : (i==1) ? -(84'sd1<<83) : 0;
            exponent=(i==1) ? -3:32;packet_sequence=i;frame_id=9+i;invalid=(i==2);s_valid=1;
            @(posedge clk);@(negedge clk);s_valid=0;
            // Mutate all wide input data after acceptance to test snapshotting.
            accumulator=17;exponent=17;
            wait(packets==i+1);
        end
        $fclose(trace);$display("PASS: RESULT packet extremes, invalid flag, snapshots and stalls");$finish;
    end
    initial begin #100000;$fatal(1,"timeout");end
endmodule
