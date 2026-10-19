`timescale 1ns/1ps
// ACX720-V3 U2 50 MHz oscillator (Y18), active-low S4 reset button (B21).
// 50 MHz * 20 / 1 = 1000 MHz VCO, / 10 = 100 MHz system clock.
// Instantiate only once at board top. Uses the actual 7-series primitives.
module board_clock_reset(
    input wire clk_50mhz,input wire reset_button_n,
    output wire clk_100mhz,output wire locked,output wire system_reset_n
);
    wire clock_input,feedback_raw,feedback_buffered,clock_raw;
    IBUF input_buffer(.I(clk_50mhz),.O(clock_input));
    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"),.CLKIN1_PERIOD(20.000),
        .CLKFBOUT_MULT_F(20.000),.DIVCLK_DIVIDE(1),
        .CLKOUT0_DIVIDE_F(10.000),.CLKOUT0_PHASE(0.000),
        .CLKOUT0_DUTY_CYCLE(0.500),.STARTUP_WAIT("FALSE")
    ) clock_manager(
        .CLKIN1(clock_input),.CLKFBIN(feedback_buffered),
        .CLKFBOUT(feedback_raw),.CLKOUT0(clock_raw),.LOCKED(locked),
        .RST(!reset_button_n),.PWRDWN(1'b0));
    BUFG feedback_buffer(.I(feedback_raw),.O(feedback_buffered));
    BUFG system_buffer(.I(clock_raw),.O(clk_100mhz));

    // Async assertion also works when the MMCM output stops. Release only
    // after sixteen stable system-clock edges. No raw button edge is used as
    // an acquisition clock. Button bounce can extend reset, never shorten it.
    wire release_allowed=reset_button_n && locked;
    (* ASYNC_REG="TRUE", SHREG_EXTRACT="NO" *) reg [15:0] release_pipe;
    always @(posedge clk_100mhz or negedge release_allowed) begin
        if(!release_allowed) release_pipe<=0;
        else release_pipe<={release_pipe[14:0],1'b1};
    end
    assign system_reset_n=release_pipe[15];
endmodule
