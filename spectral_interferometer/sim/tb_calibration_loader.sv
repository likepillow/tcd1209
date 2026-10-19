`timescale 1ns/1ps
module tb_calibration_loader;
    `include "rx_sizes.vh"
    reg clk=0,rst_n=0;
    always #5 clk=~clk;
    reg [7:0] bytes[0:LOADER_INPUT_SIZE-1];
    reg pixel_valid=0,pixel_first=0,pixel_last=0;
    wire pixel_ready,norm_valid,norm_last;
    wire [31:0] norm_version;
    integer norm_count=0,pixel;
    reg boundary_checked=0;
    reg phase_valid=0,phase_last=0,result_ready=0,k_boundary_checked=0;
    reg [9:0] phase_index=0;
    reg signed [42:0] phase_value=0;
    wire phase_ready,result_valid;
    wire [31:0] result_version;
    wire signed [15:0] result_exponent;
    wire signed [83:0] result_value;
    integer phase_pixel;
    reg signed [83:0] expected_fit=0;
    integer sent=0,replies=0,errors=0,cycle=0,swrites=0,kwrites=0;
    wire in_ready,cv,cr,pv,pr,pl,err;
    wire [7:0] kind,pdata;
    wire [31:0] seq;
    wire [12:0] len;
    wire sb,sw,sc,sa,se,kb,kw,kc,ka,ke,av;
    wire [9:0] saddr;wire [8:0] kaddr;
    wire [30:0] gain;wire signed [31:0] weight;wire signed [15:0] exponent;
    wire [31:0] ackseq,sv,kv;wire [15:0] status;wire sconfigured,kconfigured;
    wire ar,wire_valid,wire_last;wire [7:0] wire_data;
    reg wire_ready=0;
    wire [31:0] packet_sequence;
    wire control_valid,control_ready,control_last,control_request;
    wire [7:0] control_data;
    wire [4:0] grants,ready_bus;
    reg allow_grants=0;
    wire sequence_take;
    packet_scheduler scheduler(.clk(clk),.rst_n(rst_n),.request({4'b0,control_request && allow_grants}),
        .grant(grants),.packet_sequence(packet_sequence),.s_valid({4'b0,control_valid}),
        .s_ready(ready_bus),.s_data({32'b0,control_data}),.s_last({4'b0,control_last}),
        .m_valid(wire_valid),.m_ready(wire_ready),.m_data(wire_data),.m_last(wire_last));
    assign control_ready=ready_bus[0];
    integer trace,wire_packets=0;
    assign av=control.ack_valid;assign ar=control.ack_ready;
    assign ackseq=control.ack_sequence;assign status=control.ack_status;
    calibration_control control(.clk(clk),.rst_n(rst_n),
        .rx_valid(sent<LOADER_INPUT_SIZE),.rx_ready(in_ready),.rx_data(bytes[sent]),
        .tx_valid(control_valid),.tx_ready(control_ready),.tx_data(control_data),.tx_last(control_last),
        .tx_request(control_request),.tx_grant(grants[0]),
        .packet_sequence(packet_sequence),.sequence_take(sequence_take),.receive_error(err),.source_version(sv),.k_version(kv),
        .source_begin(sb),.source_we(sw),.source_commit(sc),.source_addr(saddr),.source_gain(gain),.source_ack(sa),.source_error(se),
        .k_begin(kb),.k_we(kw),.k_commit(kc),.k_addr(kaddr),.k_weight(weight),.k_exponent(exponent),.k_ack(ka),.k_error(ke));
    normalize_frame source_core(.clk(clk),.rst_n(rst_n),.cfg_begin(sb),.cfg_we(sw),.cfg_commit(sc),
        .cfg_addr(saddr),.cfg_gain(gain),.cfg_ack(sa),.cfg_error(se),.configured(sconfigured),.calibration_version(sv),
        .s_valid(pixel_valid),.s_ready(pixel_ready),.s_data(12'd100),.s_first(pixel_first),.s_last(pixel_last),
        .s_frame_id(32'd123),.m_ready(1'b1),.m_valid(norm_valid),.m_last(norm_last),.m_calibration_version(norm_version));
    distance_fit k_core(.clk(clk),.rst_n(rst_n),.cfg_begin(kb),.cfg_we(kw),.cfg_commit(kc),
        .cfg_addr(kaddr),.cfg_weight(weight),.cfg_exponent(exponent),.cfg_ack(ka),.cfg_error(ke),
        .configured(kconfigured),.calibration_version(kv),.s_valid(phase_valid),.s_ready(phase_ready),.s_phase(phase_value),.s_index(phase_index),
        .s_last(phase_last),.s_invalid(1'b0),.s_frame_id(32'd123),.m_ready(result_ready),.m_valid(result_valid),
        .m_calibration_version(result_version),.m_exponent(result_exponent),.m_accumulator(result_value));
    // Drive byte address on the falling edge to avoid races with the receiver.
    reg accepted=0;
    always @(posedge clk) if(rst_n) begin
        if(sequence_take && !grants[0]) $fatal(1,"ACK accepted without scheduler grant");
        if(wire_valid && wire_ready) begin
            $fwrite(trace,"%02x\n",wire_data);
            if(wire_last) wire_packets=wire_packets+1;
        end
        accepted=(sent<LOADER_INPUT_SIZE && in_ready);
        if(norm_valid) begin
            if(norm_version!=1 || norm_last!=(norm_count==1023)) $fatal(1,"mixed frame calibration");
            norm_count=norm_count+1;
        end
        if(err) errors=errors+1;
        if(sw) begin
            if(saddr!=swrites%1024 || gain!=1+swrites/1024+(swrites%1024)*1024) $fatal(1,"source write mismatch");
            swrites=swrites+1;
        end
        if(kw) begin
            if(kaddr!=kwrites%512 || weight!=((kwrites%512<256 ? kwrites%512-256:kwrites%512-255)*(kwrites<512 ? 1:-1))) $fatal(1,"K write mismatch");
            kwrites=kwrites+1;
        end
        if(kb && exponent!=(kwrites==0 ? 16:17)) $fatal(1,"exponent not ready at begin");
        if(av && ar) begin
            if(status!=0 || ackseq!=11+replies || (replies==0 ? sv!=1 : kv!=(replies==3 ? 2:1))) $fatal(1,"early/invalid ACK");
            if(replies==2 && (sv!=2 || norm_count!=1024 || !boundary_checked)) $fatal(1,"ACK before frame boundary");
            if(replies==3 && (!k_boundary_checked || result_valid)) $fatal(1,"K ACK before result consumption");
            replies=replies+1;
        end
        if(se || ke) $fatal(1,"core rejected configuration");
    end
    always @(negedge clk) if(rst_n) begin
        if(accepted) sent=sent+1;
        cycle=cycle+1;wire_ready=(cycle%19>10);
    end
    initial begin
        $readmemh("loader_input.hex",bytes);
        trace=$fopen("loader_ack.hex","w");
        repeat(4) @(negedge clk);rst_n=1;
        wait(wire_packets==4);repeat(10) @(posedge clk);
        $fclose(trace);
        if(swrites!=2048 || kwrites!=1024 || errors!=EXPECTED_ERRORS || !sconfigured || !kconfigured)
            $fatal(1,"coverage incomplete");
        $display("PASS: calibration loader, validated host packets, actual S/K cores, applied ACKs");$finish;
    end
    initial begin
        wait(control_request);
        repeat(40) begin
            @(negedge clk);
            if(control_valid || sequence_take || replies!=0) $fatal(1,"ACK started without authorization");
        end
        allow_grants=1;
    end
    initial begin
        wait(kconfigured);
        for(phase_pixel=0;phase_pixel<1024;phase_pixel=phase_pixel+1) begin
            if(phase_pixel==16) begin
                wait(kc && kwrites==1024);
                repeat(50) begin
                    @(negedge clk);
                    if(kv!=1 || replies!=3 || ka || av) $fatal(1,"early K switch");
                end
            end
            if(phase_pixel>=256 && phase_pixel<768)
                expected_fit=expected_fit+phase_pixel*(phase_pixel<512 ? phase_pixel-512:phase_pixel-511);
            @(negedge clk);phase_valid=1;phase_index=phase_pixel;phase_value=phase_pixel;phase_last=(phase_pixel==1023);
            @(posedge clk);while(!phase_ready) @(posedge clk);
            @(negedge clk);phase_valid=0;
        end
        wait(result_valid);
        repeat(50) begin
            @(negedge clk);
            if(!result_valid || result_version!=1 || result_exponent!=16 || result_value!==expected_fit || kv!=1 || replies!=3 || ka || av)
                $fatal(1,"K changed while old result stalled");
        end
        k_boundary_checked=1;result_ready=1;
    end
    initial begin
        wait(sconfigured);
        for(pixel=0;pixel<1024;pixel=pixel+1) begin
            if(pixel==16) begin
                // Keep a real frame open while the second SOURCE uploads.
                wait(sc && swrites==2048);
                repeat(50) begin
                    @(negedge clk);
                    if(sv!=1 || replies!=2 || sa || av) $fatal(1,"early source switch/ACK");
                end
                boundary_checked=1;
            end
            @(negedge clk);pixel_valid=1;pixel_first=(pixel==0);pixel_last=(pixel==1023);
            @(posedge clk);while(!pixel_ready) @(posedge clk);
            @(negedge clk);pixel_valid=0;
        end
    end
    initial begin #2000000;$fatal(1,"timeout");end
endmodule
