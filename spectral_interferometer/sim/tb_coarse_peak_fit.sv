`timescale 1ns/1ps
module tb_coarse_peak_fit;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,s_valid=0,m_ready=0;
    wire s_ready,m_valid,m_invalid;
    reg [9:0] s_peak=0;
    reg [64:0] s_left=0,s_center=0,s_right=0;
    wire [9:0] m_peak;wire signed [20:0] m_delta;
    coarse_peak_fit dut(.*);
    integer input_file,read_count,count=0,latency,i;
    reg [20:0] expected_delta;reg expected_invalid;
    reg [31:0] held;
    initial begin
        input_file=$fopen("coarse_vectors.mem","r");
        if(!input_file) $fatal(1,"Missing vectors");
        repeat(6) @(negedge clk);rst_n=1;
        while(!$feof(input_file)) begin
            read_count=$fscanf(input_file,"%h %h %h %h %h %h\n",s_peak,s_left,s_center,s_right,expected_delta,expected_invalid);
            if(read_count==6) begin
                @(negedge clk);s_valid=1;
                @(posedge clk);if(!s_ready) $fatal(1,"Not ready");
                @(negedge clk);s_valid=0;latency=0;
                while(!m_valid) begin @(negedge clk);latency=latency+1;if(latency>22) $fatal(1,"Unbounded latency");end
                if(m_peak!==s_peak || m_delta!==expected_delta || m_invalid!==expected_invalid)
                    $fatal(1,"Vector %0d delta=%0d expected=%0d invalid=%0d/%0d",count,m_delta,$signed(expected_delta),m_invalid,expected_invalid);
                held={m_peak,m_delta,m_invalid};
                for(i=0;i<count%5+1;i=i+1) begin
                    @(negedge clk);
                    if(!m_valid || s_ready || held!=={m_peak,m_delta,m_invalid}) $fatal(1,"Backpressure corruption");
                end
                m_ready=1;@(negedge clk);m_ready=0;count=count+1;
            end
        end
        if(count!=313) $fatal(1,"Vector count");
        $display("PASS: 313 exact coarse peak fits, boundary/flat/rejected maxima, full 65-bit powers, signed rounding and backpressure");
        $finish;
    end
    initial begin #1000000;$fatal(1,"Timeout");end
endmodule
