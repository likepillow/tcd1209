`timescale 1ns/1ps
// AD9945 Rev.C p4, p8, p9, p13. Automatic startup after stable reset release.
// Each transaction: A0..A3, D0..D11; rising SCK samples, rising SL commits.
// Quarter-period data hold after falling SCK is deliberately explicit.
module ad9945_init #(
    parameter CLK_HZ=100000000,
    parameter SCK_HZ=1000000,
    parameter POWERUP_CYCLES=CLK_HZ/500,
    parameter [7:0] CLAMP_LEVEL=8'd128,
    parameter [9:0] VGA_GAIN=10'd0
)(
    input wire clk,input wire rst_n,
    output reg ad_sck,output reg ad_sdata,output reg ad_sl,
    output reg configure_done
);
    localparam QUARTER_CYCLES=CLK_HZ/(4*SCK_HZ);
    localparam WAIT_POWER=0,SETUP=1,HIGH_FIRST=2,HIGH_SECOND=3,HOLD=4,GAP=5,DONE=6;
    reg [2:0] state,word_index;
    reg [3:0] bit_index;
    reg [31:0] power_count,quarter_count;
    reg [15:0] word_data;
    function [15:0] command(input [2:0] n);
        case(n)
            0: command={12'h838,4'hd};
            1: command={12'h000,4'h0}; // normal power, OB clamp enabled
            2: command={12'h000,4'h1}; // active-low clocks, binary latched data
            3: command={4'b0,CLAMP_LEVEL,4'h2};
            4: command={2'b0,VGA_GAIN,4'h3};
            default: command=0;
        endcase
    endfunction
    wire [15:0] next_word=command(word_index+1'b1);
    always @(posedge clk) begin
        if(!rst_n) begin
            state<=WAIT_POWER;word_index<=0;bit_index<=0;word_data<=0;
            power_count<=0;quarter_count<=0;
            ad_sck<=0;ad_sdata<=0;ad_sl<=1;configure_done<=0;
        end else if(state==WAIT_POWER) begin
            if(power_count==POWERUP_CYCLES) begin
                word_data<=command(0);ad_sdata<=1'b1;ad_sl<=0;
                state<=SETUP;quarter_count<=0;
            end else power_count<=power_count+1;
        end else if(state!=DONE) begin
            if(quarter_count==QUARTER_CYCLES-1) begin
                quarter_count<=0;
                case(state)
                    SETUP: begin ad_sck<=1;state<=HIGH_FIRST;end
                    HIGH_FIRST: state<=HIGH_SECOND;
                    HIGH_SECOND: begin ad_sck<=0;state<=HOLD;end
                    HOLD: begin
                        if(bit_index==15) begin ad_sl<=1;state<=GAP;end
                        else begin
                            bit_index<=bit_index+1'b1;
                            ad_sdata<=word_data[bit_index+1'b1];state<=SETUP;
                        end
                    end
                    GAP: begin
                        if(word_index==4) begin configure_done<=1;state<=DONE;end
                        else begin
                            word_index<=word_index+1'b1;word_data<=next_word;
                            bit_index<=0;ad_sdata<=next_word[0];ad_sl<=0;state<=SETUP;
                        end
                    end
                    default: begin state<=WAIT_POWER;power_count<=0;ad_sl<=1;ad_sck<=0;end
                endcase
            end else quarter_count<=quarter_count+1;
        end
    end
endmodule
