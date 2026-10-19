`timescale 1ns/1ps
// S2 -> FFT -> complex principal band -> IFFT -> atan2 -> unwrap.
// End-to-end frame gating protects peak metadata while phase output stalls.
module spectral_phase(
    input wire clk,input wire rst_n,
    input wire s_valid,output wire s_ready,
    input wire signed [31:0] s_data,input wire s_last,
    output wire m_valid,input wire m_ready,
    output wire signed [42:0] m_phase,
    output wire [9:0] m_index,output wire m_last,output wire m_invalid,
    output reg [9:0] peak_bin,output reg [9:0] band_left,output reg [9:0] band_right,
    output wire fault
);
    reg accepting;
    reg [9:0] input_index;
    reg empty_frame;
    wire a_input_ready,a_valid,a_ready,a_last,a_empty,a_fault;
    wire signed [42:0] a_re,a_im;
    wire [9:0] a_index,a_peak,a_left,a_right;
    wire p_valid,p_ready,p_last,p_zero,u_invalid,u_fault;
    wire signed [31:0] p_phase;
    wire [9:0] p_index;
    assign s_ready=accepting && a_input_ready;
    assign fault=a_fault || u_fault;
    assign m_invalid=u_invalid || empty_frame || fault;
    always @(posedge clk) begin
        if(!rst_n) begin
            accepting<=1;input_index<=0;empty_frame<=0;
            peak_bin<=0;band_left<=0;band_right<=0;
        end else begin
            if(s_valid && s_ready) begin
                input_index<=input_index+1'b1;
                if(input_index==1023) accepting<=0;
            end
            if(m_valid && m_ready && m_last) accepting<=1;
            if(a_valid && a_ready && a_index==0) begin
                peak_bin<=a_peak;band_left<=a_left;band_right<=a_right;empty_frame<=a_empty;
            end
        end
    end
    analytic_spectrum analytic(.clk(clk),.rst_n(rst_n),.s_valid(s_valid && accepting),.s_ready(a_input_ready),
        .s_data(s_data),.s_last(s_last),.m_valid(a_valid),.m_ready(a_ready),.m_re(a_re),.m_im(a_im),
        .m_index(a_index),.m_last(a_last),.peak_bin(a_peak),.band_left(a_left),.band_right(a_right),.no_peak(a_empty),.fault(a_fault));
    phase_cordic cordic(.clk(clk),.rst_n(rst_n),.s_valid(a_valid),.s_ready(a_ready),
        .s_re(a_re),.s_im(a_im),.s_index(a_index),.s_last(a_last),
        .m_valid(p_valid),.m_ready(p_ready),.m_phase(p_phase),.m_index(p_index),.m_last(p_last),.m_zero(p_zero));
    phase_unwrap unwrap(.clk(clk),.rst_n(rst_n),.s_valid(p_valid),.s_ready(p_ready),
        .s_phase(p_phase),.s_index(p_index),.s_last(p_last),.s_zero(p_zero),
        .m_valid(m_valid),.m_ready(m_ready),.m_phase(m_phase),.m_index(m_index),.m_last(m_last),.m_invalid(u_invalid),.fault(u_fault));
endmodule
