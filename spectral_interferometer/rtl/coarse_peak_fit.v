`timescale 1ns/1ps
// Three-point POWER parabola, independent of complex H1/IFFT phase processing.
// delta = (right-left)/(2*(2*center-left-right)), Q1.20, nearest-even rounding.
// Iterative fractional division: bounded latency, no combinational wide divider.
// Boundary/flat/nonmaximum peaks are invalid AUXILIARY results, not fine flags.
module coarse_peak_fit(
    input wire clk,input wire rst_n,
    input wire s_valid,output wire s_ready,
    input wire [9:0] s_peak,
    input wire [64:0] s_left,s_center,s_right,
    output reg m_valid,input wire m_ready,
    output reg [9:0] m_peak,
    output reg signed [20:0] m_delta,
    output reg m_invalid
);
    localparam IDLE=0,DIVIDE=1,ROUND=2,OUTPUT=3;
    reg [1:0] state;
    reg negative;
    reg [4:0] iteration;
    reg [67:0] denominator;
    reg [68:0] remainder;
    reg [20:0] quotient;
    wire [66:0] twice_center={1'b0,s_center,1'b0};
    wire [66:0] neighbor_sum={2'b0,s_left}+{2'b0,s_right};
    wire [66:0] curvature=twice_center-neighbor_sum;
    wire [68:0] shifted=remainder<<1;
    wire subtract=shifted>={1'b0,denominator};
    wire round_up=(remainder<<1)>{1'b0,denominator} ||
        ((remainder<<1)=={1'b0,denominator} && quotient[0]);
    wire [21:0] rounded={1'b0,quotient}+round_up;
    wire [20:0] bounded=rounded>22'd524288 ? 21'd524288 : rounded[20:0];
    assign s_ready=rst_n && state==IDLE;
    always @(posedge clk) begin
        if(!rst_n) begin
            state<=IDLE;negative<=0;iteration<=0;denominator<=0;
            remainder<=0;quotient<=0;m_valid<=0;m_peak<=0;m_delta<=0;m_invalid<=0;
        end else case(state)
            IDLE: if(s_valid && s_ready) begin
                m_peak<=s_peak;m_delta<=0;quotient<=0;iteration<=0;
                m_invalid<=s_peak<=1 || s_peak>=511 || s_center==0 ||
                    s_left>s_center || s_right>s_center || twice_center==neighbor_sum;
                if(s_peak<=1 || s_peak>=511 || s_center==0 ||
                    s_left>s_center || s_right>s_center || twice_center==neighbor_sum) begin
                    m_valid<=1;state<=OUTPUT;
                end else begin
                    denominator<={curvature,1'b0};
                    negative<=s_right<s_left;
                    remainder<=s_right>=s_left ? s_right-s_left : s_left-s_right;
                    state<=DIVIDE;
                end
            end
            DIVIDE: begin
                remainder<=subtract ? shifted-{1'b0,denominator} : shifted;
                quotient<={quotient[19:0],subtract};
                if(iteration==19) state<=ROUND;
                else iteration<=iteration+1'b1;
            end
            ROUND: begin
                m_delta<=negative ? -$signed(bounded) : $signed(bounded);
                m_valid<=1;state<=OUTPUT;
            end
            OUTPUT: if(m_valid && m_ready) begin m_valid<=0;state<=IDLE;end
        endcase
    end
endmodule
