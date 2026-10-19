`timescale 1ns/1ps
// One frame in flight ensures peak metadata stays associated with IFFT output.
// The acquisition ping-pong buffer continues capturing independently.
module analytic_spectrum(
    input wire clk,input wire rst_n,
    input wire s_valid,output wire s_ready,
    input wire signed [31:0] s_data,input wire s_last,
    output wire m_valid,input wire m_ready,
    output wire signed [42:0] m_re,output wire signed [42:0] m_im,
    output wire [9:0] m_index,output wire m_last,
    output wire [9:0] peak_bin,output wire [9:0] band_left,output wire [9:0] band_right,
    output wire no_peak,output wire fault
);
    reg accepting;
    reg [9:0] input_index;
    wire f_input_ready,f_valid,f_ready,f_last,f_fault,p_fault,i_fault;
    wire signed [42:0] f_re,f_im;
    wire [9:0] f_index;
    wire p_valid,p_ready,p_last;
    wire signed [31:0] p_re,p_im;
    wire [9:0] p_index;
    assign s_ready=accepting && f_input_ready;
    assign fault=f_fault || p_fault || i_fault;
    always @(posedge clk) begin
        if(!rst_n) begin accepting<=1;input_index<=0;end
        else begin
            if(s_valid && s_ready) begin
                if(input_index==1023) begin accepting<=0;input_index<=0;end
                else input_index<=input_index+1;
            end
            if(m_valid && m_ready && m_last) accepting<=1;
        end
    end
    spectral_transform forward(
        .clk(clk),.rst_n(rst_n),.s_valid(s_valid && accepting),.s_ready(f_input_ready),
        .s_re(s_data),.s_im(32'sd0),.s_last(s_last),
        .m_valid(f_valid),.m_ready(f_ready),.m_re(f_re),.m_im(f_im),.m_index(f_index),.m_last(f_last),.fault(f_fault));
    positive_peak_filter filter(
        .clk(clk),.rst_n(rst_n),.s_valid(f_valid),.s_ready(f_ready),
        .s_re(f_re[31:0]),.s_im(f_im[31:0]),.s_index(f_index),.s_last(f_last),
        .m_valid(p_valid),.m_ready(p_ready),.m_re(p_re),.m_im(p_im),.m_index(p_index),.m_last(p_last),
        .peak_bin(peak_bin),.band_left(band_left),.band_right(band_right),.no_peak(no_peak),.fault(p_fault));
    spectral_transform #(.INVERSE(1)) inverse(
        .clk(clk),.rst_n(rst_n),.s_valid(p_valid),.s_ready(p_ready),.s_re(p_re),.s_im(p_im),.s_last(p_last),
        .m_valid(m_valid),.m_ready(m_ready),.m_re(m_re),.m_im(m_im),.m_index(m_index),.m_last(m_last),.fault(i_fault));
endmodule
