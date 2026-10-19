`timescale 1ns/1ps
// Same-clock, non-backpressurable acquisition -> backpressurable frame stream.
// Drive s_valid once per input pixel. s_first/s_last coincide with valid.
// Retain CAPTURE_FIRST..CAPTURE_FIRST+DEPTH-1 of CAPTURE_DEPTH pixels.
// Publish only after the COMPLETE input frame passes its boundary checks.
// A bank stays owned by the reader through the LAST OUTPUT HANDSHAKE.
// If no bank is free at first pixel, discard the entire incoming frame.
// No generated clocks or multi-bit CDC: use clock enables for ADC acquisition.
module frame_ping_pong #(
    parameter WIDTH = 16,
    parameter ADDR_BITS = 10,
    parameter DEPTH = 1024,
    parameter CAPTURE_DEPTH = DEPTH,
    parameter CAPTURE_FIRST = 0,
    parameter DYNAMIC_WINDOW = 0
)(
    input wire clk, input wire rst_n,
    input wire [10:0] capture_first,
    input wire s_valid, input wire s_first, input wire s_last,
    input wire [WIDTH-1:0] s_data,
    input wire [31:0] s_frame_id,
    input wire [63:0] s_timestamp,
    output reg m_valid, input wire m_ready,
    output wire [WIDTH-1:0] m_data,
    output reg m_first, output reg m_last,
    output reg [31:0] m_frame_id,
    output reg [63:0] m_timestamp,
    output reg [31:0] dropped_frames,
    output reg [31:0] malformed_frames
    ,output wire idle
);
    (* ram_style = "block" *) reg [WIDTH-1:0] bank0 [0:DEPTH-1];
    (* ram_style = "block" *) reg [WIDTH-1:0] bank1 [0:DEPTH-1];
    reg [1:0] full;
    reg [31:0] id0, id1;
    reg [63:0] timestamp0,timestamp1,wr_timestamp;
    reg wr_active, wr_bank;
    reg [10:0] frame_capture_first;
    localparam COUNT_BITS=$clog2(CAPTURE_DEPTH+1);
    reg [COUNT_BITS-1:0] wr_count;
    reg [31:0] wr_id;
    reg rd_active, rd_bank, rd_prefer;
    assign idle=!wr_active && full==0 && !rd_active && !m_valid;
    reg [ADDR_BITS-1:0] rd_addr;
    reg [WIDTH-1:0] read0, read1;
    assign m_data = rd_bank ? read1 : read0;

    // An unfinished capture can be aborted by a new s_first. It was never full.
    wire available = !(&full);
    wire candidate = full[0];
    wire capture_enable = s_valid && (s_first ? available : wr_active);
    wire write_bank = s_first ? candidate : wr_bank;
    wire [COUNT_BITS-1:0] current_count = s_first ? 0 : wr_count;
    wire [10:0] selected_first = DYNAMIC_WINDOW ?
        (s_first ? capture_first : frame_capture_first) : CAPTURE_FIRST;
    wire [ADDR_BITS-1:0] write_address = current_count-selected_first;
    wire wrong_id = !s_first && s_frame_id!=wr_id;
    wire write_enable = capture_enable && !wrong_id && current_count>=selected_first && current_count<selected_first+DEPTH;
    wire aborted_frame = s_valid && s_first && wr_active;
    wire malformed_capture = capture_enable && (wrong_id ||
        ((s_last || current_count==CAPTURE_DEPTH-1) && !(s_last && current_count==CAPTURE_DEPTH-1)));

    // Memory itself is not reset, so Vivado can infer BRAM.
    always @(posedge clk) begin
        if (rst_n && write_enable) begin
            if (write_bank) bank1[write_address] <= s_data;
            else bank0[write_address] <= s_data;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            full <= 0;
            wr_active <= 0;
            frame_capture_first <= CAPTURE_FIRST;
            wr_bank <= 0;
            wr_count <= 0;
            wr_id <= 0;
            wr_timestamp <= 0;
            id0 <= 0;
            id1 <= 0;
            timestamp0 <= 0;
            timestamp1 <= 0;
            rd_active <= 0;
            rd_bank <= 0;
            rd_prefer <= 0;
            rd_addr <= 0;
            m_valid <= 0;
            m_first <= 0;
            m_last <= 0;
            m_frame_id <= 0;
            m_timestamp <= 0;
            dropped_frames <= 0;
            malformed_frames <= 0;
        end else begin
            if(aborted_frame || malformed_capture)
                malformed_frames<=malformed_frames+aborted_frame+malformed_capture;
            if (s_valid && s_first) begin
                frame_capture_first <= capture_first;
                wr_bank <= candidate;
                wr_id <= s_frame_id;
                wr_timestamp <= s_timestamp;
                wr_active <= available;
                wr_count <= 0;
                if (!available) dropped_frames <= dropped_frames + 1;
            end
            if (capture_enable) begin
                if (wrong_id || s_last || current_count == CAPTURE_DEPTH-1) begin
                    wr_active <= 0;
                    if (!wrong_id && s_last && current_count == CAPTURE_DEPTH-1) begin
                        full[write_bank] <= 1;
                        if (write_bank) begin
                            id1 <= s_first ? s_frame_id : wr_id;
                            timestamp1 <= s_first ? s_timestamp : wr_timestamp;
                        end else begin
                            id0 <= s_first ? s_frame_id : wr_id;
                            timestamp0 <= s_first ? s_timestamp : wr_timestamp;
                        end
                    end
                end else wr_count <= current_count + 1;
            end

            if (!rd_active) begin
                if (full != 0) begin
                    rd_bank <= full[rd_prefer] ? rd_prefer : ~rd_prefer;
                    rd_prefer <= full[rd_prefer] ? ~rd_prefer : rd_prefer;
                    rd_addr <= 0;
                    rd_active <= 1;
                end
            end else if (m_valid) begin
                if (m_ready) begin
                    m_valid <= 0;
                    if (m_last) begin
                        full[rd_bank] <= 0;
                        rd_active <= 0;
                    end else rd_addr <= rd_addr + 1;
                end
            end else begin
                m_valid <= 1;
                m_first <= (rd_addr == 0);
                m_last <= (rd_addr == DEPTH-1);
                m_frame_id <= rd_bank ? id1 : id0;
                m_timestamp <= rd_bank ? timestamp1 : timestamp0;
            end
        end
    end

    // Synchronous read, enabled only while the output register is unoccupied.
    always @(posedge clk) begin
        if (rd_active && !m_valid) begin
            read0 <= bank0[rd_addr];
            read1 <= bank1[rd_addr];
        end
    end
endmodule
