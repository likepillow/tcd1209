`timescale 1ns/1ps
// Internal-IFCLK synchronous, 16-bit EP2 OUT / EP6 IN controller.
// Flags are normalized by the board wrapper: true means readable/writable.
// All pins here are logical active-low controls. Physical polarity, IOB delay,
// clock skew and package pins MUST be constrained/verified before deployment.
// Coordinated reset also resets host/SPIF session and clears endpoint contents;
// this module itself does not reset FX2 or discard its buffered USB bytes.
module fx2_slave_fifo(
    input wire ifclk,input wire rst_n,
    input wire ep2_has_data,input wire ep6_has_space,
    input wire tx_valid,output wire tx_ready,input wire [15:0] tx_data,input wire tx_last,
    output reg rx_valid,input wire rx_ready,output reg [15:0] rx_data,
    input wire [15:0] fd_in,(* IOB="TRUE" *) output reg [15:0] fd_out,output reg fd_drive,
    output reg [1:0] fifo_addr,(* IOB="TRUE" *) output reg slrd_n,(* IOB="TRUE" *) output reg slwr_n,
    (* IOB="TRUE" *) output reg sloe_n,(* IOB="TRUE" *) output reg pktend_n,output wire slcs_n
);
    localparam IDLE=0,SETUP1=1,SETUP2=2,SETUP3=3,
        TX_WAIT=4,TX_PULSE=5,TX_REC1=6,TX_REC2=7,
        COMMIT=8,COMMIT_HOLD=9,TURN1=10,TURN2=11,
        RX_ENABLE=12,RX_SETUP=13,RX_PULSE=14,RX_REC1=15,RX_REC2=16;
    reg [4:0] state;
    reg reading,prefer_read,commit_pending;
    reg [7:0] in_words; // modulo 256 words = 512-byte AUTOIN packet
    assign slcs_n=!rst_n;
    assign tx_ready=rst_n && state==TX_WAIT && ep6_has_space;
    // Async assertion forces inactive strobes / high-Z without an IFCLK edge.
    // rst_n release is synchronized by the board wrapper.
    always @(posedge ifclk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE;reading<=0;prefer_read<=1;commit_pending<=0;in_words<=0;
            rx_valid<=0;rx_data<=0;fd_out<=0;fd_drive<=0;fifo_addr<=2'b10;
            slrd_n<=1;slwr_n<=1;sloe_n<=1;pktend_n<=1;
        end else begin
            if(rx_valid && rx_ready) rx_valid<=0;
            case(state)
                IDLE:begin
                    if(ep2_has_data && !rx_valid && (prefer_read || !tx_valid || !ep6_has_space)) begin
                        fifo_addr<=2'b00;reading<=1;state<=SETUP1;
                    end else if(tx_valid && ep6_has_space) begin
                        fifo_addr<=2'b10;reading<=0;state<=SETUP1;
                    end
                end
                SETUP1:state<=SETUP2;
                SETUP2:state<=SETUP3;
                SETUP3:state<=reading ? RX_ENABLE : TX_WAIT;
                TX_WAIT:begin
                    if(tx_valid && ep6_has_space) begin
                        fd_out<=tx_data;fd_drive<=1;slwr_n<=0;
                        commit_pending<=tx_last && in_words!=8'hff;
                        in_words<=in_words+1'b1;state<=TX_PULSE;
                    end else if(ep2_has_data && !rx_valid) state<=TURN1;
                end
                // FX2 samples the registered data/strobe on this rising edge.
                TX_PULSE:begin slwr_n<=1;state<=TX_REC1;end
                TX_REC1:state<=TX_REC2;
                TX_REC2:begin
                    if(commit_pending) state<=COMMIT;
                    else if(ep2_has_data && !rx_valid) state<=TURN1;
                    else state<=TX_WAIT;
                end
                COMMIT:begin pktend_n<=0;in_words<=0;state<=COMMIT_HOLD;end
                COMMIT_HOLD:begin pktend_n<=1;commit_pending<=0;state<=TURN1;end
                RX_ENABLE:begin sloe_n<=0;state<=RX_SETUP;end
                RX_SETUP:begin
                    if(ep2_has_data) begin slrd_n<=0;state<=RX_PULSE;end
                    else state<=TURN1;
                end
                RX_PULSE:begin
                    rx_data<=fd_in;rx_valid<=1;slrd_n<=1;state<=RX_REC1;
                end
                RX_REC1:state<=RX_REC2;
                RX_REC2:state<=TURN1;
                TURN1:begin
                    sloe_n<=1;fd_drive<=0;slrd_n<=1;slwr_n<=1;
                    prefer_read<=!reading;state<=TURN2;
                end
                TURN2:state<=IDLE;
                default:begin
                    slrd_n<=1;slwr_n<=1;sloe_n<=1;pktend_n<=1;fd_drive<=0;state<=TURN1;
                end
            endcase
        end
    end
endmodule
