`timescale 1ns/1ps
// Complete 1024-pixel numerical core, separate from CCD pins and transport.
// Spectrum/phase outputs are lossless: tie ready high when not recording them.
// A protocol fault requires reset. Calibration errors reject only that upload.
module spectral_processor(
    input wire clk,input wire rst_n,
    input wire source_begin,input wire source_we,input wire source_commit,
    input wire [9:0] source_addr,input wire [30:0] source_gain,
    output wire source_ack,output wire source_error,
    input wire k_begin,input wire k_we,input wire k_commit,
    input wire [8:0] k_addr,input wire signed [31:0] k_weight,
    input wire signed [15:0] k_exponent,
    output wire k_ack,output wire k_error,
    output wire configured,output wire fault,
    // Active calibration versions for control ACKs, not per-frame snapshots.
    output wire [31:0] active_source_version,output wire [31:0] active_k_version,
    input wire s_valid,output wire s_ready,
    input wire [11:0] s_data,input wire s_first,input wire s_last,
    input wire [31:0] s_frame_id,input wire [63:0] s_timestamp,
    output wire spectrum_valid,input wire spectrum_ready,
    output wire [11:0] spectrum_s0,output wire [23:0] spectrum_s1,
    output wire signed [24:0] spectrum_s2,
    output wire spectrum_first,output wire spectrum_last,
    output wire [31:0] spectrum_frame_id,output wire [31:0] spectrum_source_version,
    output wire phase_valid,input wire phase_ready,
    output wire signed [42:0] phase_data,output wire [9:0] phase_index,
    output wire phase_last,output wire phase_invalid,
    output wire [31:0] phase_frame_id,
    output wire result_valid,input wire result_ready,
    output wire signed [83:0] result_accumulator,
    output wire signed [15:0] result_exponent,
    output wire [31:0] result_frame_id,output wire [31:0] result_k_version,
    output reg [31:0] result_source_version,output reg [63:0] result_timestamp,
    output wire result_invalid,
    output wire [9:0] result_peak,result_left,result_right
);
    reg input_open,n_fault,normalization_invalid;
    reg [31:0] processing_frame_id;
    wire n_configured,k_configured,n_ready,n_valid,n_output_ready,n_error,n_overflow,n_clipped;
    wire [31:0] source_version,k_version;
    assign active_source_version=source_version;
    assign active_k_version=k_version;
    wire [4:0] n_fft_shift;
    wire transform_valid,transform_ready,p_valid,p_ready,p_invalid,p_fault,fit_fault;
    wire fit_valid,fit_ready;
    wire input_enable=input_open && k_configured && !fault;
    assign configured=n_configured && k_configured;
    assign fault=n_fault || p_fault || fit_fault;
    assign s_ready=input_enable && n_ready;
    assign phase_invalid=p_invalid || normalization_invalid;
    assign phase_frame_id=processing_frame_id;
    // Common per-frame shift maximizes FFT precision below magnitude 2^30.
    // This changes only a positive amplitude factor, leaving phase unchanged.
    wire signed [31:0] fft_data=$signed({{7{spectrum_s2[24]}},spectrum_s2}) <<< n_fft_shift;
    always @(posedge clk) begin
        if(!rst_n) begin
            input_open<=1;n_fault<=0;normalization_invalid<=0;
            processing_frame_id<=0;result_source_version<=0;result_timestamp<=0;
        end else begin
            if(n_error) n_fault<=1;
            if(s_valid && s_ready && s_first) result_timestamp<=s_timestamp;
            if(s_valid && s_ready && s_last) input_open<=0;
            if(result_valid && result_ready) input_open<=1;
            if(transform_valid && transform_ready && spectrum_first) begin
                processing_frame_id<=spectrum_frame_id;
                result_source_version<=spectrum_source_version;
                normalization_invalid<=n_overflow || n_clipped;
            end
        end
    end
    normalize_frame normalize(.clk(clk),.rst_n(rst_n),
        .cfg_begin(source_begin),.cfg_we(source_we),.cfg_commit(source_commit),.cfg_addr(source_addr),.cfg_gain(source_gain),
        .cfg_ack(source_ack),.cfg_error(source_error),.configured(n_configured),.calibration_version(source_version),
        .s_valid(s_valid && input_enable),.s_ready(n_ready),.s_data(s_data),.s_first(s_first),.s_last(s_last),.s_frame_id(s_frame_id),
        .m_valid(n_valid),.m_ready(n_output_ready),.m_s0(spectrum_s0),.m_s1(spectrum_s1),.m_s2(spectrum_s2),.m_fft_shift(n_fft_shift),
        .m_first(spectrum_first),.m_last(spectrum_last),.m_frame_id(spectrum_frame_id),.m_calibration_version(spectrum_source_version),
        .frame_error(n_error),.frame_overflow(n_overflow),.frame_clipped(n_clipped));
    stream_fork_control spectrum_fork(.clk(clk),.rst_n(rst_n),.s_valid(n_valid),.s_ready(n_output_ready),
        .a_valid(transform_valid),.a_ready(transform_ready),.b_valid(spectrum_valid),.b_ready(spectrum_ready));
    spectral_phase phase(.clk(clk),.rst_n(rst_n),.s_valid(transform_valid),.s_ready(transform_ready),.s_data(fft_data),.s_last(spectrum_last),
        .m_valid(p_valid),.m_ready(p_ready),.m_phase(phase_data),.m_index(phase_index),.m_last(phase_last),.m_invalid(p_invalid),
        .peak_bin(result_peak),.band_left(result_left),.band_right(result_right),.fault(p_fault));
    stream_fork_control phase_fork(.clk(clk),.rst_n(rst_n),.s_valid(p_valid),.s_ready(p_ready),
        .a_valid(fit_valid),.a_ready(fit_ready),.b_valid(phase_valid),.b_ready(phase_ready));
    distance_fit fit(.clk(clk),.rst_n(rst_n),
        .cfg_begin(k_begin),.cfg_we(k_we),.cfg_commit(k_commit),.cfg_addr(k_addr),.cfg_weight(k_weight),.cfg_exponent(k_exponent),
        .cfg_ack(k_ack),.cfg_error(k_error),.configured(k_configured),.calibration_version(k_version),
        .s_valid(fit_valid),.s_ready(fit_ready),.s_phase(phase_data),.s_index(phase_index),.s_last(phase_last),.s_invalid(phase_invalid),
        .s_frame_id(processing_frame_id),.m_valid(result_valid),.m_ready(result_ready),.m_accumulator(result_accumulator),
        .m_exponent(result_exponent),.m_frame_id(result_frame_id),.m_calibration_version(result_k_version),.m_invalid(result_invalid),.fault(fit_fault));
endmodule
