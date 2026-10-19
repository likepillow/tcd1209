`timescale 1ns/1ps
`include "packet_count.vh"
module tb_packet_tx;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,cmd_valid=0;
    wire cmd_ready,cmd_error;
    reg [7:0] cmd_kind=0;
    reg [15:0] cmd_flags=0;
    reg [31:0] cmd_length=0,cmd_sequence=0,cmd_frame_id=0,cmd_source_version=0,cmd_k_version=0;
    reg [63:0] cmd_timestamp=0;
    reg s_valid=0;wire s_ready;reg [7:0] s_data=0;
    wire m_valid,m_last;reg m_ready=0;wire [7:0] m_data;
    packet_tx dut(.*);
    reg [7:0] bytes[0:`BYTE_COUNT-1];
    integer cycles=0,received=0,packets=0,base=0,length,j;
    integer expected_end=0,errors=0;
    reg check_output=0,stalled=0;
    reg [8:0] held;
    function [31:0] u32(input integer addr);
        u32={bytes[addr+3],bytes[addr+2],bytes[addr+1],bytes[addr]};
    endfunction
    always @(negedge clk) begin cycles=cycles+1;m_ready=(cycles%13<9);end
    always @(posedge clk) begin
        if(rst_n) begin
            if(cmd_error) errors=errors+1;
            if(check_output) begin
                if(stalled && (!m_valid || {m_last,m_data}!==held)) $fatal(1,"Output changed on stall");
                stalled=m_valid && !m_ready;held={m_last,m_data};
                if(m_valid && m_ready) begin
                    if(received>=`BYTE_COUNT || m_data!==bytes[received]) $fatal(1,"Byte mismatch at %0d",received);
                    if(received==base) expected_end=base+36+u32(base+8)+4-1;
                    if(m_last!==(received==expected_end)) $fatal(1,"Incorrect packet last at %0d",received);
                    if(m_last) packets=packets+1;
                    received=received+1;
                end
            end
        end else stalled=0;
    end
    task command_from_vector(input integer offset);
        begin
            @(negedge clk);while(!cmd_ready) @(negedge clk);
            cmd_kind=bytes[offset+5];cmd_flags={bytes[offset+7],bytes[offset+6]};
            cmd_length=u32(offset+8);cmd_sequence=u32(offset+12);cmd_frame_id=u32(offset+16);
            cmd_timestamp={u32(offset+24),u32(offset+20)};
            cmd_source_version=u32(offset+28);cmd_k_version=u32(offset+32);
            cmd_valid=1;
            @(posedge clk);@(negedge clk);cmd_valid=0;
        end
    endtask
    initial begin
        $readmemh("packet_bytes.mem",bytes);
        repeat(3) @(negedge clk);rst_n=1;
        // Invalid kind/length, flags, and nonzero timestamp without its valid bit.
        @(negedge clk);cmd_kind=8'h10;cmd_length=1;cmd_valid=1;
        @(negedge clk);cmd_length=2048;cmd_flags=8;
        @(negedge clk);cmd_flags=0;cmd_timestamp=1;
        @(negedge clk);cmd_valid=0;cmd_timestamp=0;
        repeat(3) @(negedge clk);
        if(errors!=3 || m_valid) $fatal(1,"Illegal command rejection failed");
        // Abort a partially transmitted header. Reset discards the transaction.
        command_from_vector(0);
        repeat(10) @(negedge clk);
        rst_n=0;repeat(3) @(negedge clk);rst_n=1;
        check_output=1;
        while(base<`BYTE_COUNT) begin
            command_from_vector(base);
            length=u32(base+8);
            for(j=0;j<length;j=j+1) begin
                @(negedge clk);
                if(j%7==3) begin s_valid=0;repeat(2) @(negedge clk);end
                s_valid=1;s_data=bytes[base+36+j];
                @(posedge clk);while(!s_ready) @(posedge clk);
            end
            @(negedge clk);s_valid=0;
            wait(cmd_ready);@(negedge clk);
            if(received!=base+length+40) $fatal(1,"Packet boundary mismatch");
            base=base+length+40;
        end
        if(packets!=`PACKET_COUNT || received!=`BYTE_COUNT) $fatal(1,"Missing output packets");
        $display("PASS: SPIF transmitter, %0d packets, %0d exact bytes, independent CRC, bubbles/stalls/reset/errors",packets,received);
        $finish;
    end
    initial begin #5000000;$fatal(1,"Timeout");end
endmodule
