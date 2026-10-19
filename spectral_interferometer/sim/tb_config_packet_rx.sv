`timescale 1ns/1ps
module tb_config_packet_rx;
    `include "rx_sizes.vh"
    reg clk=0,rst_n=0,abort=0,s_valid=0,cmd_ready=0,m_ready=0;
    always #5 clk=~clk;
    reg [7:0] s_data=0;
    wire s_ready,cmd_valid,m_valid,m_last,error;
    wire [7:0] cmd_kind,m_data;
    wire [31:0] cmd_sequence;
    wire [12:0] cmd_length;
    reg [7:0] input_bytes[0:INPUT_SIZE-1],expected[0:OUTPUT_SIZE-1];
    reg [7:0] good[0:GOOD_SIZE-1];
    reg main_phase=0,cmd_stalled=0;
    reg [52:0] held_cmd;
    integer sent=0,received=0,commands=0,errors=0,cycle=0;
    reg stalled=0;
    reg [8:0] held;
    config_packet_rx dut(.*);
    always @(posedge clk) if(rst_n && main_phase) begin
        if(s_valid && s_ready) sent=sent+1;
        if(error) errors=errors+1;
        if(cmd_valid && cmd_ready) begin
            if(errors!=EXPECTED_ERRORS || cmd_sequence!=(commands<2 ? 11+commands:15) ||
                cmd_kind!=(commands==0 ? 8'h20:commands==1 ? 8'h21:8'h25) ||
                cmd_length!=(commands==0 ? 4096:commands==1 ? 2052:4)) $fatal(1,"bad descriptor or CRC leak");
            commands=commands+1;
        end
        if(cmd_stalled && (!cmd_valid || {cmd_kind,cmd_sequence,cmd_length} !== held_cmd))
            $fatal(1,"unstable command");
        cmd_stalled=cmd_valid && !cmd_ready;held_cmd={cmd_kind,cmd_sequence,cmd_length};
        if(stalled && (!m_valid || {m_last,m_data} !== held)) $fatal(1,"unstable payload");
        stalled=m_valid && !m_ready;held={m_last,m_data};
        if(m_valid && m_ready) begin
            if(m_data !== expected[received] || m_last !== (received==4095 || received==6147 || received==OUTPUT_SIZE-1))
                $fatal(1,"payload mismatch %0d",received);
            received=received+1;
        end
    end
    always @(negedge clk) if(rst_n && main_phase) begin
        cycle=cycle+1;
        s_valid=sent<INPUT_SIZE;s_data=input_bytes[sent];
        cmd_ready=cycle%11>3;m_ready=cycle%7>2;
    end
    task send_prefix(input integer length);
        integer i;
        begin
            for(i=0;i<length;i=i+1) begin
                @(negedge clk);s_valid=1;s_data=good[i];
                @(posedge clk);while(!s_ready) @(posedge clk);
                #1;
                if(m_valid) $fatal(1,"payload leaked before descriptor acceptance");
            end
            @(negedge clk);s_valid=0;
        end
    endtask
    task cancel;
        begin
            @(negedge clk);abort=1;
            #1;if(cmd_valid || m_valid || s_ready) $fatal(1,"abort did not mask interface");
            @(negedge clk);abort=0;
            repeat(4) @(posedge clk);
            #1;if(cmd_valid || m_valid || !s_ready) $fatal(1,"abort did not clear parser");
        end
    endtask
    initial begin
        $readmemh("rx_input.hex",input_bytes);$readmemh("rx_expected.hex",expected);
        $readmemh("rx_good.hex",good);
        repeat(4) @(negedge clk);rst_n=1;
        send_prefix(19);cancel(); // Truncated header.
        send_prefix(99);cancel(); // Truncated payload.
        send_prefix(GOOD_SIZE);
        repeat(10) @(posedge clk);
        #1;if(!cmd_valid || m_valid) $fatal(1,"pending descriptor test failed");
        cancel(); // Good CRC, but consumer has not accepted the command.
        @(posedge clk);#1;main_phase=1;
        wait(received==OUTPUT_SIZE);
        repeat(20) @(posedge clk);
        if(errors!=EXPECTED_ERRORS || commands!=3 || sent!=INPUT_SIZE) $fatal(1,"coverage incomplete");
        $display("PASS: config receiver bad headers, CRC, RUN semantics, varied S/K and backpressure");$finish;
    end
    initial begin #1000000;$fatal(1,"timeout");end
endmodule
