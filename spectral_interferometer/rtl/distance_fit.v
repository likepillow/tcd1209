`timescale 1ns/1ps
// Fit P1[256..767] using uploaded signed weights. Result is A * 2^(-e).
// 43-bit phase * 32-bit weight -> 75-bit product -> 84-bit sum.
// Coefficients and exponent switch together only between complete results.
module distance_fit(
    input wire clk,input wire rst_n,
    input wire cfg_begin,input wire cfg_we,input wire cfg_commit,
    input wire [8:0] cfg_addr,input wire signed [31:0] cfg_weight,
    input wire signed [15:0] cfg_exponent,
    output reg cfg_ack,output reg cfg_error,output reg configured,
    output reg [31:0] calibration_version,
    input wire s_valid,output wire s_ready,
    input wire signed [42:0] s_phase,
    input wire [9:0] s_index,input wire s_last,input wire s_invalid,
    input wire [31:0] s_frame_id,
    output reg m_valid,input wire m_ready,
    output reg signed [83:0] m_accumulator,
    output reg signed [15:0] m_exponent,
    output reg [31:0] m_frame_id,output reg [31:0] m_calibration_version,
    output reg m_invalid,output reg fault
);
    (* ram_style="block" *) reg signed [31:0] weights0[0:511];
    (* ram_style="block" *) reg signed [31:0] weights1[0:511];
    reg signed [31:0] weight0_q,weight1_q;
    reg signed [42:0] phase_q;
    reg signed [74:0] product;
    reg signed [83:0] accumulator;
    reg product_valid,read_valid;
    reg [9:0] index;
    reg frame_invalid;
    reg active_bank,pending,uploading,upload_bad;
    reg [9:0] upload_count;
    reg signed [41:0] weight_sum;
    reg signed [15:0] upload_exponent,active_exponent;
    wire boundary=index==0 && !m_valid;
    wire command_collision=(cfg_begin && cfg_we) || (cfg_begin && cfg_commit) || (cfg_we && cfg_commit);
    wire cfg_write=rst_n && uploading && !pending && !command_collision && cfg_we &&
        upload_count<512 && cfg_addr==upload_count;
    assign s_ready=rst_n && configured && !m_valid && !(index==0 && (pending || cfg_commit));
    wire take=s_valid && s_ready;
    wire fit_take=take && index>=256 && index<768;
    wire signed [31:0] weight=active_bank ? weight1_q : weight0_q;
    wire malformed=s_index!=index || s_last!=(index==1023) || (index!=0 && s_frame_id!=m_frame_id);
    wire invalid_now=s_invalid || malformed || (index!=0 && frame_invalid);

    always @(posedge clk) begin
        if(cfg_write) begin
            if(active_bank) weights0[cfg_addr]<=cfg_weight;
            else weights1[cfg_addr]<=cfg_weight;
        end
        if(fit_take) begin
            // Low nine bits of (index-256) are the 512-point fit address.
            weight0_q<=weights0[(index-10'd256)&10'd511];
            weight1_q<=weights1[(index-10'd256)&10'd511];
            phase_q<=s_phase;
        end
    end
    always @(posedge clk) begin
        if(!rst_n) begin
            active_bank<=0;pending<=0;uploading<=0;upload_bad<=0;
            upload_count<=0;weight_sum<=0;upload_exponent<=0;active_exponent<=0;
            configured<=0;calibration_version<=0;cfg_ack<=0;cfg_error<=0;
        end else begin
            cfg_ack<=0;cfg_error<=0;
            if(pending && boundary) begin
                active_bank<=~active_bank;active_exponent<=upload_exponent;
                calibration_version<=calibration_version+1;configured<=1;
                pending<=0;cfg_ack<=1;
            end
            if(command_collision) begin cfg_error<=1;upload_bad<=1;end
            else if(cfg_begin) begin
                if(pending) cfg_error<=1;
                else begin
                    uploading<=1;upload_bad<=0;upload_count<=0;weight_sum<=0;
                    upload_exponent<=cfg_exponent;
                end
            end else if(cfg_we) begin
                if(cfg_write) begin
                    upload_count<=upload_count+1;
                    weight_sum<=weight_sum+{{10{cfg_weight[31]}},cfg_weight};
                end else begin cfg_error<=1;upload_bad<=1;end
            end else if(cfg_commit) begin
                if(uploading && !upload_bad && upload_count==512 && weight_sum==0 && !pending) begin
                    pending<=1;uploading<=0;
                end else cfg_error<=1;
            end
        end
    end
    always @(posedge clk) begin
        if(!rst_n) begin
            read_valid<=0;product_valid<=0;product<=0;accumulator<=0;
            index<=0;frame_invalid<=0;fault<=0;
            m_valid<=0;m_accumulator<=0;m_exponent<=0;
            m_frame_id<=0;m_calibration_version<=0;m_invalid<=0;
        end else begin
            read_valid<=fit_take;product_valid<=read_valid;
            if(read_valid) product<=phase_q*weight;
            if(product_valid) accumulator<=accumulator+{{9{product[74]}},product};
            if(m_valid && m_ready) m_valid<=0;
            if(take) begin
                if(malformed) fault<=1;
                frame_invalid<=invalid_now;
                if(index==0) begin
                    accumulator<=0;m_frame_id<=s_frame_id;
                    m_calibration_version<=calibration_version;m_exponent<=active_exponent;
                end
                if(index==1023) begin
                    // Last fit product was accepted at 767; it has drained
                    // long before frame-end, even for full-rate input.
                    m_accumulator<=accumulator;m_invalid<=invalid_now;m_valid<=1;
                    index<=0;
                end else index<=index+1'b1;
            end
        end
    end
endmodule
