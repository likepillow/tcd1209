`timescale 1ns/1ps
// First point equals its wrapped phase; subsequent differences use (-pi,pi),
// retaining the sign for an exactly pi difference. Such samples are flagged
// ambiguous because sampled data cannot establish a unique unwrap direction.
module phase_unwrap(
    input wire clk,input wire rst_n,
    input wire s_valid,output wire s_ready,
    input wire signed [31:0] s_phase,
    input wire [9:0] s_index,input wire s_last,input wire s_zero,
    output reg m_valid,input wire m_ready,
    output reg signed [42:0] m_phase,
    output reg [9:0] m_index,output reg m_last,
    output reg m_invalid,output reg fault
);
    reg signed [31:0] previous;
    reg signed [42:0] accumulated;
    reg [9:0] expected;
    reg frame_invalid;
    wire signed [32:0] delta = $signed({s_phase[31],s_phase})-$signed({previous[31],previous});
    wire signed [33:0] delta_wide = {delta[32],delta};
    wire signed [33:0] corrected = delta_wide>34'sd2147483648 ? delta_wide-34'sd4294967296 :
        delta_wide < -34'sd2147483648 ? delta_wide+34'sd4294967296 : delta_wide;
    wire ambiguous = expected!=0 && (delta_wide==34'sd2147483648 || delta_wide == -34'sd2147483648);
    wire malformed = s_index!=expected || s_last!=(expected==1023);
    wire invalid_now = s_zero || ambiguous || malformed || (expected!=0 && frame_invalid);
    wire signed [42:0] next_phase = expected==0 ? {{11{s_phase[31]}},s_phase} :
        accumulated+{{9{corrected[33]}},corrected};
    assign s_ready = rst_n && (!m_valid || m_ready);
    always @(posedge clk) begin
        if(!rst_n) begin
            m_valid<=0;m_phase<=0;m_index<=0;m_last<=0;m_invalid<=0;
            previous<=0;accumulated<=0;expected<=0;frame_invalid<=0;fault<=0;
        end else if(s_ready) begin
            m_valid<=s_valid;
            if(s_valid) begin
                m_phase<=next_phase;m_index<=expected;m_last<=expected==1023;
                m_invalid<=invalid_now;frame_invalid<=invalid_now;
                previous<=s_phase;accumulated<=next_phase;
                expected<=expected+1'b1;
                if(malformed) fault<=1;
            end
        end
    end
endmodule
