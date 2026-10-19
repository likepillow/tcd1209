`timescale 1ns/1ps
// atan2 for the full signed 43-bit IFFT range. One sample per enabled clock.
// Phase is signed binary turns: pi = 2^31, a full turn = 2^32.
// 28 fractional guard bits preserve precision for even one-count vectors.
module phase_cordic(
    input wire clk,input wire rst_n,
    input wire s_valid,output wire s_ready,
    input wire signed [42:0] s_re,input wire signed [42:0] s_im,
    input wire [9:0] s_index,input wire s_last,
    output wire m_valid,input wire m_ready,
    output wire signed [31:0] m_phase,
    output wire [9:0] m_index,output wire m_last,output wire m_zero
);
    reg signed [73:0] x[0:31],y[0:31];
    reg signed [31:0] z[0:31];
    reg [31:0] valid_pipe,last_pipe,zero_pipe;
    reg [9:0] index_pipe[0:31];
    wire advance = !valid_pipe[31] || m_ready;
    wire signed [73:0] input_x = {{3{s_re[42]}},s_re,28'b0};
    wire signed [73:0] input_y = {{3{s_im[42]}},s_im,28'b0};
    assign s_ready = rst_n && advance;
    assign m_valid = valid_pipe[31];
    assign m_phase = z[31];
    assign m_index = index_pipe[31];
    assign m_last = last_pipe[31];
    assign m_zero = zero_pipe[31];
    function signed [31:0] atan_step(input integer n);
        case(n)
            0: atan_step=32'sd536870912; 1: atan_step=32'sd316933406;
            2: atan_step=32'sd167458907; 3: atan_step=32'sd85004756;
            4: atan_step=32'sd42667331; 5: atan_step=32'sd21354465;
            6: atan_step=32'sd10679838; 7: atan_step=32'sd5340245;
            8: atan_step=32'sd2670163; 9: atan_step=32'sd1335087;
            10: atan_step=32'sd667544; 11: atan_step=32'sd333772;
            12: atan_step=32'sd166886; 13: atan_step=32'sd83443;
            14: atan_step=32'sd41722; 15: atan_step=32'sd20861;
            16: atan_step=32'sd10430; 17: atan_step=32'sd5215;
            18: atan_step=32'sd2608; 19: atan_step=32'sd1304;
            20: atan_step=32'sd652; 21: atan_step=32'sd326;
            22: atan_step=32'sd163; 23: atan_step=32'sd81;
            24: atan_step=32'sd41; 25: atan_step=32'sd20;
            26: atan_step=32'sd10; 27: atan_step=32'sd5;
            28: atan_step=32'sd3; 29: atan_step=32'sd1;
            30: atan_step=32'sd1; default: atan_step=0;
        endcase
    endfunction
    always @(posedge clk) begin
        if(!rst_n) begin
            valid_pipe[0]<=0;last_pipe[0]<=0;zero_pipe[0]<=0;
        end else if(advance) begin
            valid_pipe[0]<=s_valid;last_pipe[0]<=s_last;
            index_pipe[0]<=s_index;zero_pipe[0]<=s_re==0 && s_im==0;
            // Rotate left half-plane by pi before vectoring. Modular phase
            // arithmetic represents both +pi and -pi as 0x80000000.
            x[0]<=s_re[42] ? -input_x : input_x;
            y[0]<=s_re[42] ? -input_y : input_y;
            z[0]<=s_re[42] ? 32'sh80000000 : 32'sd0;
        end
    end
    genvar j;
    generate for(j=0;j<31;j=j+1) begin: stage
        always @(posedge clk) begin
            if(!rst_n) begin
                valid_pipe[j+1]<=0;last_pipe[j+1]<=0;zero_pipe[j+1]<=0;
            end else if(advance) begin
                valid_pipe[j+1]<=valid_pipe[j];last_pipe[j+1]<=last_pipe[j];
                zero_pipe[j+1]<=zero_pipe[j];index_pipe[j+1]<=index_pipe[j];
                if(y[j]>0) begin
                    x[j+1]<=x[j]+(y[j]>>>j);y[j+1]<=y[j]-(x[j]>>>j);
                    z[j+1]<=z[j]+atan_step(j);
                end else if(y[j]<0) begin
                    x[j+1]<=x[j]-(y[j]>>>j);y[j+1]<=y[j]+(x[j]>>>j);
                    z[j+1]<=z[j]-atan_step(j);
                end else begin x[j+1]<=x[j];y[j+1]<=y[j];z[j+1]<=z[j];end
            end
        end
    end endgenerate
endmodule
