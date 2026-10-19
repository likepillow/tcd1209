`timescale 1ns/1ps
// 1024 samples/frame. Reciprocal gain = round(2^30 / S), S >= 1 ADC count.
// S1 unsigned Q12 in 24 bits; S2 signed Q12 in 25 bits (sign extended for FFT).
// Mean is floor(sum(S1)/1024). Per-pixel rounding: nearest, ties upward.
// Coefficients upload sequentially to an inactive bank; commit is atomic between
// COMPLETE frames, including output backpressure. No startup unity calibration.
module normalize_frame (
    input wire clk, input wire rst_n,
    input wire cfg_begin, input wire cfg_we,
    input wire [9:0] cfg_addr, input wire [30:0] cfg_gain,
    input wire cfg_commit,
    output reg cfg_ack, output reg cfg_error,
    output reg configured, output reg [31:0] calibration_version,
    input wire s_valid, output wire s_ready,
    input wire [11:0] s_data,
    input wire s_first, input wire s_last,
    input wire [31:0] s_frame_id,
    output reg m_valid, input wire m_ready,
    output wire [11:0] m_s0,
    output wire [23:0] m_s1,
    output wire signed [24:0] m_s2,
    output reg [4:0] m_fft_shift,
    output wire m_first, output wire m_last,
    output reg [31:0] m_frame_id,
    output reg [31:0] m_calibration_version,
    output reg frame_error, output reg frame_overflow,
    output reg frame_clipped
);
    localparam ACCEPT=0, MULTIPLY=1, STORE=2, READ=3, OUTPUT=4, RANGE=5, SCALE=6;
    reg [2:0] state;
    reg [9:0] index;
    reg [33:0] sum;
    reg [23:0] mean;
    reg [23:0] minimum,maximum,max_deviation;
    wire [23:0] positive_deviation=maximum-mean;
    wire [23:0] negative_deviation=mean-minimum;
    function [4:0] fft_shift(input [23:0] magnitude);
        integer bit_index;
        begin
            fft_shift=0;
            for(bit_index=0;bit_index<24;bit_index=bit_index+1)
                if(magnitude[bit_index]) fft_shift=29-bit_index;
        end
    endfunction
    reg [11:0] raw;
    reg [42:0] product;
    wire [43:0] rounded = {1'b0,product} + 44'd131072;
    wire overflow = |rounded[43:42];
    wire [23:0] normalized = overflow ? 24'hffffff : rounded[41:18];
    reg active_bank, pending, uploading, upload_bad;
    reg [10:0] upload_count;
    reg [30:0] gain0_q, gain1_q;
    wire [30:0] gain = active_bank ? gain1_q : gain0_q;
    (* ram_style="block" *) reg [30:0] gain0 [0:1023];
    (* ram_style="block" *) reg [30:0] gain1 [0:1023];
    (* ram_style="block" *) reg [35:0] samples [0:1023];
    reg [35:0] sample_q;
    wire boundary = state==ACCEPT && index==0;
    assign s_ready = rst_n && configured && state==ACCEPT && !(boundary && (pending || cfg_commit));
    wire take = s_valid && s_ready;
    wire cfg_write = rst_n && uploading && !pending && !cfg_begin && !cfg_commit && cfg_we &&
        upload_count<1024 && cfg_addr==upload_count && cfg_gain!=0 && cfg_gain<=31'h40000000;
    assign m_s0=sample_q[35:24];
    assign m_s1=sample_q[23:0];
    assign m_s2=$signed({1'b0,sample_q[23:0]})-$signed({1'b0,mean});
    assign m_first=(index==0);
    assign m_last=(index==1023);

    always @(posedge clk) begin
        if (cfg_write) begin
            if (active_bank) gain0[cfg_addr]<=cfg_gain;
            else gain1[cfg_addr]<=cfg_gain;
        end
        if (take) begin
            gain0_q<=gain0[index];
            gain1_q<=gain1[index];
        end
        if (rst_n && state==STORE) samples[index]<={raw,normalized};
        if (state==READ) sample_q<=samples[index];
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            active_bank<=0; pending<=0; uploading<=0; upload_bad<=0;
            upload_count<=0; configured<=0; calibration_version<=0;
            cfg_ack<=0; cfg_error<=0;
        end else begin
            cfg_ack<=0; cfg_error<=0;
            if (pending && boundary) begin
                active_bank<=~active_bank;
                calibration_version<=calibration_version+1;
                configured<=1;
                pending<=0;
                cfg_ack<=1;
            end
            if (cfg_begin) begin
                if (pending) cfg_error<=1;
                else begin uploading<=1; upload_count<=0; upload_bad<=0; end
            end else if (cfg_we) begin
                if (cfg_write) upload_count<=upload_count+1;
                else begin cfg_error<=1; upload_bad<=1; end
            end
            if (cfg_commit) begin
                if (uploading && !upload_bad && upload_count==1024 && !cfg_we && !cfg_begin && !pending) begin
                    pending<=1;
                    uploading<=0;
                end else cfg_error<=1;
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            state<=ACCEPT; index<=0; sum<=0; mean<=0; raw<=0; product<=0;
            minimum<=0;maximum<=0;max_deviation<=0;m_fft_shift<=0;
            m_valid<=0; m_frame_id<=0; m_calibration_version<=0;
            frame_error<=0; frame_overflow<=0; frame_clipped<=0;
        end else begin
            frame_error<=0;
            case (state)
                ACCEPT: if (take) begin
                    if (s_first!=(index==0) || s_last!=(index==1023) ||
                        (index!=0 && s_frame_id!=m_frame_id)) begin
                        index<=0; sum<=0; frame_error<=1;
                    end else begin
                        raw<=s_data;
                        if (index==0) begin
                            m_frame_id<=s_frame_id;
                            m_calibration_version<=calibration_version;
                            frame_overflow<=0;
                            frame_clipped<=0;
                        end
                        state<=MULTIPLY;
                    end
                end
                MULTIPLY: begin product<=raw*gain; state<=STORE; end
                STORE: begin
                    if (overflow) frame_overflow<=1;
                    if (raw==12'd0 || raw==12'd4095) frame_clipped<=1;
                    if(index==0) begin minimum<=normalized;maximum<=normalized;end
                    else begin
                        if(normalized<minimum) minimum<=normalized;
                        if(normalized>maximum) maximum<=normalized;
                    end
                    if (index==1023) begin
                        mean<=(sum+{10'b0,normalized})>>10;
                        index<=0;
                        state<=RANGE;
                    end else begin
                        sum<=sum+{10'b0,normalized};
                        index<=index+1;
                        state<=ACCEPT;
                    end
                end
                RANGE: begin
                    max_deviation<=positive_deviation>negative_deviation ? positive_deviation : negative_deviation;
                    state<=SCALE;
                end
                SCALE: begin m_fft_shift<=fft_shift(max_deviation);state<=READ;end
                READ: begin m_valid<=1; state<=OUTPUT; end
                OUTPUT: if (m_valid && m_ready) begin
                    m_valid<=0;
                    if (index==1023) begin index<=0; sum<=0; state<=ACCEPT; end
                    else begin index<=index+1; state<=READ; end
                end
                default: begin state<=ACCEPT; index<=0; sum<=0; m_valid<=0; end
            endcase
        end
    end
endmodule
