`timescale 1ns/1ps
// Broadcast a stable upstream beat exactly once to each independent consumer.
// Payload remains at the source until both consumers accept it.
module stream_fork_control(
    input wire clk,input wire rst_n,
    input wire s_valid,output wire s_ready,
    output wire a_valid,input wire a_ready,
    output wire b_valid,input wire b_ready
);
    reg a_sent,b_sent;
    assign a_valid=rst_n && s_valid && !a_sent;
    assign b_valid=rst_n && s_valid && !b_sent;
    assign s_ready=rst_n && (a_sent || a_ready) && (b_sent || b_ready);
    always @(posedge clk) begin
        if(!rst_n) begin a_sent<=0;b_sent<=0;end
        else if(s_valid && s_ready) begin a_sent<=0;b_sent<=0;end
        else begin
            if(a_valid && a_ready) a_sent<=1;
            if(b_valid && b_ready) b_sent<=1;
        end
    end
endmodule
