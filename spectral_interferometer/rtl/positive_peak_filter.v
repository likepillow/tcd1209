`timescale 1ns/1ps
// Natural-order 1024-bin FFT -> complex positive main lobe -> IFFT input.
// Peak search excludes DC/Nyquist/negative bins. First maximum wins ties.
// Descend toward each first nonzero valley; stop before a rise or zero.
// Accepts one bin/clock during capture. Output obeys ready/valid.
module positive_peak_filter(
    input wire clk, input wire rst_n,
    input wire s_valid, output wire s_ready,
    input wire signed [31:0] s_re, input wire signed [31:0] s_im,
    input wire [9:0] s_index, input wire s_last,
    output reg m_valid, input wire m_ready,
    output wire signed [31:0] m_re, output wire signed [31:0] m_im,
    output wire [9:0] m_index, output wire m_last,
    output reg [9:0] peak_bin, output reg [9:0] band_left, output reg [9:0] band_right,
    output reg no_peak, output reg fault
);
    localparam LOAD=0,DRAIN=1,FINISH=2,PREAD=3,PEVAL=4,RSTART=5,OREAD=6,SEND=7;
    reg [2:0] state;
    reg [9:0] wr_index,rd_index,scan;
    reg scan_right,frame_bad;
    reg [64:0] maximum,previous,power_q;
    reg v1,v2;
    reg [9:0] idx1,idx2;
    reg [63:0] square_re,square_im;
    reg [64:0] power2;
    (* ram_style="block" *) reg [63:0] spectrum[0:1023];
    (* ram_style="block" *) reg [64:0] powers[0:1023];
    reg [63:0] complex_q;
    wire take=s_valid && s_ready;
    assign s_ready=rst_n && state==LOAD;
    assign m_index=rd_index;
    assign m_last=rd_index==1023;
    wire keep_bin=!no_peak && rd_index>=band_left && rd_index<=band_right;
    assign m_re=keep_bin ? complex_q[31:0] : 32'd0;
    assign m_im=keep_bin ? complex_q[63:32] : 32'd0;

    always @(posedge clk) begin
        if(take) spectrum[wr_index]<={s_im,s_re};
        if(rst_n && v2) powers[idx2]<=power2;
        if(state==PREAD) power_q<=powers[scan];
        if(state==OREAD) complex_q<=spectrum[rd_index];
    end
    always @(posedge clk) begin
        if(!rst_n) begin
            v1<=0;v2<=0;idx1<=0;idx2<=0;square_re<=0;square_im<=0;power2<=0;
        end else begin
            v1<=take;v2<=v1;
            if(take) begin square_re<=s_re*s_re;square_im<=s_im*s_im;idx1<=wr_index;end
            if(v1) begin power2<={1'b0,square_re}+{1'b0,square_im};idx2<=idx1;end
        end
    end
    always @(posedge clk) begin
        if(!rst_n) begin
            state<=LOAD;wr_index<=0;rd_index<=0;scan<=0;scan_right<=0;
            frame_bad<=0;maximum<=0;previous<=0;peak_bin<=0;
            band_left<=0;band_right<=0;no_peak<=1;fault<=0;m_valid<=0;
        end else begin
            if(v2 && idx2>=1 && idx2<=511 && power2>maximum) begin
                maximum<=power2;peak_bin<=idx2;
            end
            case(state)
                LOAD: if(take) begin
                    if(wr_index==0) begin maximum<=0;peak_bin<=0;frame_bad<=0;end
                    if(s_index!=wr_index || s_last!=(wr_index==1023)) begin frame_bad<=1;fault<=1;end
                    if(wr_index==1023) begin state<=DRAIN;wr_index<=0;end
                    else wr_index<=wr_index+1;
                end
                DRAIN: if(v2 && idx2==1023) state<=FINISH;
                FINISH: begin
                    band_left<=peak_bin;band_right<=peak_bin;rd_index<=0;
                    no_peak<=maximum==0 || frame_bad;
                    previous<=maximum;scan_right<=0;
                    if(maximum==0 || frame_bad) state<=OREAD;
                    else if(peak_bin==1) state<=RSTART;
                    else begin scan<=peak_bin-1;state<=PREAD;end
                end
                PREAD: state<=PEVAL;
                PEVAL: begin
                    if(power_q!=0 && power_q<=previous) begin
                        previous<=power_q;
                        if(scan_right) begin
                            band_right<=scan;
                            if(scan==511) state<=OREAD;
                            else begin scan<=scan+1;state<=PREAD;end
                        end else begin
                            band_left<=scan;
                            if(scan==1) state<=RSTART;
                            else begin scan<=scan-1;state<=PREAD;end
                        end
                    end else state<=scan_right ? OREAD : RSTART;
                end
                RSTART: begin
                    scan_right<=1;previous<=maximum;
                    if(peak_bin==511) state<=OREAD;
                    else begin scan<=peak_bin+1;state<=PREAD;end
                end
                OREAD: begin m_valid<=1;state<=SEND;end
                SEND: if(m_valid && m_ready) begin
                    m_valid<=0;
                    if(rd_index==1023) begin rd_index<=0;state<=LOAD;end
                    else begin rd_index<=rd_index+1;state<=OREAD;end
                end
            endcase
        end
    end
endmodule
