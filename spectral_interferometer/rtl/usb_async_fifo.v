`timescale 1ns/1ps
// Xilinx 2018.3 XPM-backed ready/valid crossing. Payload includes packet end.
// rst must be synchronous to wr_clk; both clocks must run during reset/recovery.
// Reset discards queued words: the surrounding packet stream must restart too.
module usb_async_fifo #(parameter integer DEPTH=1024)(
    input wire wr_clk,input wire rd_clk,input wire rst,
    input wire s_valid,output wire s_ready,input wire [15:0] s_data,input wire s_last,
    output wire m_valid,input wire m_ready,output wire [15:0] m_data,output wire m_last,
    output wire wr_busy,output wire rd_busy
);
    wire full,empty;
    wire [16:0] dout;
    (* ASYNC_REG="TRUE" *) reg [1:0] read_reset=2'b11;
    always @(posedge rd_clk or posedge rst)
        if(rst) read_reset<=2'b11;
        else read_reset<={read_reset[0],1'b0};
    assign s_ready=!rst && !wr_busy && !full;
    assign m_valid=!read_reset[1] && !rd_busy && !empty;
    assign {m_last,m_data}=dout;
    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE("block"),.ECC_MODE("no_ecc"),.RELATED_CLOCKS(0),
        .FIFO_WRITE_DEPTH(DEPTH),.WRITE_DATA_WIDTH(17),.READ_DATA_WIDTH(17),
        .READ_MODE("fwft"),.FIFO_READ_LATENCY(0),.CDC_SYNC_STAGES(2),
        .USE_ADV_FEATURES("0000"),.WR_DATA_COUNT_WIDTH($clog2(DEPTH)+1),.RD_DATA_COUNT_WIDTH($clog2(DEPTH)+1)
    ) storage(
        .rst(rst),.sleep(1'b0),.wr_clk(wr_clk),.rd_clk(rd_clk),
        .din({s_last,s_data}),.wr_en(s_valid && s_ready),.full(full),.wr_rst_busy(wr_busy),
        .dout(dout),.rd_en(m_valid && m_ready),.empty(empty),.rd_rst_busy(rd_busy),
        .injectsbiterr(1'b0),.injectdbiterr(1'b0)
    );
endmodule
