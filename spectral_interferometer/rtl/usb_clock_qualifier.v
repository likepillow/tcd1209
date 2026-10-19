`timescale 1ns/1ps
// Qualify the external 30 MHz IFCLK against the board's 100 MHz clock.
// A divided toggle crosses through 3 flops; it cannot alias at 30/48 MHz.
// 4096 system cycles contain ~307 toggles at 30 MHz, ~492 at 48 MHz.
module usb_clock_qualifier(
    input wire clk, input wire reset_n, input wire ifclk,
    output reg qualified=0
);
    reg [2:0] divider=0;
    always @(posedge ifclk) divider<=divider+1'b1;
    (* ASYNC_REG="TRUE", SHREG_EXTRACT="NO" *) reg [2:0] toggle_sync=0;
    reg previous=0;
    reg [11:0] window_count=0;
    reg [9:0] edge_count=0;
    reg [2:0] good_windows=0;
    always @(posedge clk) begin
        toggle_sync<={toggle_sync[1:0],divider[2]};
        previous<=toggle_sync[2];
        if (!reset_n) begin
            window_count<=0;edge_count<=0;good_windows<=0;qualified<=0;
        end else begin
            window_count<=window_count+1'b1;
            if (window_count==4095) begin
                edge_count<=0;
                if (edge_count>=300 && edge_count<=315) begin
                    if (good_windows<4) good_windows<=good_windows+1'b1;
                    if (good_windows>=3) qualified<=1;
                end else begin good_windows<=0;qualified<=0;end
            end else if (toggle_sync[2]!=previous) edge_count<=edge_count+1'b1;
        end
    end
endmodule
