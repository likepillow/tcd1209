`timescale 1ns/1ps
// System-domain instrument: framed ADC pixels + USB command bytes -> SPIF bytes.
// Board clocking/frontend and FX2 transport are intentionally outside this module.
// Reset is a coordinated session reset, including packet transport and FX2 queues.
module instrument_core #(parameter RUNTIME_ACQUISITION=0,parameter FAST_PROFILE=0)(
    input wire clk,input wire rst_n,
    input wire frontend_busy,
    output wire acquisition_stop,
    output wire [63:0] active_period,
    input wire s_valid,input wire [11:0] s_data,input wire s_first,input wire s_last,
    input wire [31:0] s_frame_id,input wire [63:0] s_timestamp,
    input wire rx_valid,output wire rx_ready,input wire [7:0] rx_data,
    output wire tx_valid,input wire tx_ready,output wire [7:0] tx_data,output wire tx_last,
    output wire configured,output wire fault,output wire receive_error,
    output wire [31:0] dropped_frames,output wire [31:0] malformed_frames,
    output wire [31:0] busy_skipped_frames,output wire [31:0] rate_skipped_frames
);
    wire source_begin,source_we,source_commit,source_ack,source_error;
    wire [9:0] source_addr;wire [30:0] source_gain;
    wire k_begin,k_we,k_commit,k_ack,k_error;
    wire [8:0] k_addr;wire signed [31:0] k_weight;wire signed [15:0] k_exponent;
    wire [31:0] active_source_version,active_k_version,export_period_frames;
    wire raw_valid,raw_ready,raw_first,raw_last;
    wire [11:0] raw_data;wire [31:0] raw_frame_id;wire [63:0] raw_timestamp;
    wire result_valid,result_ready,result_invalid,selected_result_ready;
    wire acquisition_reset_n;
    wire [31:0] requested_result_stride;
    wire publish_result;
    result_export_control result_selection(.clk(clk),.rst_n(acquisition_reset_n),
        .stride(requested_result_stride),.s_valid(result_valid),.s_ready(result_ready),
        .m_valid(publish_result),.m_ready(selected_result_ready));
    wire signed [83:0] result_accumulator;wire signed [15:0] result_exponent;
    wire [31:0] result_frame_id,result_k_version,result_source_version;wire [63:0] result_timestamp;
    wire [9:0] result_peak,result_left,result_right;
    wire control_request,control_grant,control_valid,control_ready,control_last;
    wire [31:0] control_sequence;wire [7:0] control_data;
    wire acquisition_fault,export_fault;
    wire acquisition_request,acquisition_ack,acquisition_idle,output_idle;
    wire run_request,run_ack,requested_run,run_enabled,reconfigure_stop;
    wire [10:0] requested_window;
    wire [63:0] requested_period;
    wire [10:0] active_window;
    acquisition_reconfigure #(.ENABLED(RUNTIME_ACQUISITION),.FAST_PROFILE(FAST_PROFILE)) reconfigure(
        .clk(clk),.rst_n(rst_n),.request(acquisition_request),.ack(acquisition_ack),
        .requested_window(requested_window),.requested_period(requested_period),
        .frontend_busy(frontend_busy),.acquisition_idle(acquisition_idle),.output_idle(output_idle),
        .stop(reconfigure_stop),.pipeline_reset_n(acquisition_reset_n),
        .active_window(active_window),.active_period(active_period));
    acquisition_run_control run_control(
        .clk(clk),.rst_n(rst_n),.request(run_request),.requested_run(requested_run),.ack(run_ack),
        .frontend_busy(frontend_busy),.acquisition_idle(acquisition_idle),.output_idle(output_idle),
        .enabled(run_enabled));
    assign acquisition_stop=reconfigure_stop || !run_enabled;
    assign fault=acquisition_fault || export_fault;
    acquisition_core #(.DYNAMIC_WINDOW(RUNTIME_ACQUISITION)) acquisition(.clk(clk),.rst_n(acquisition_reset_n),
        .capture_first(active_window),.idle(acquisition_idle),
        .source_begin(source_begin),.source_we(source_we),.source_commit(source_commit),
        .source_addr(source_addr),.source_gain(source_gain),.source_ack(source_ack),.source_error(source_error),
        .k_begin(k_begin),.k_we(k_we),.k_commit(k_commit),.k_addr(k_addr),.k_weight(k_weight),
        .k_exponent(k_exponent),.k_ack(k_ack),.k_error(k_error),
        .configured(configured),.fault(acquisition_fault),
        .active_source_version(active_source_version),.active_k_version(active_k_version),
        .s_valid(s_valid),.s_data(s_data),.s_first(s_first),.s_last(s_last),.s_frame_id(s_frame_id),.s_timestamp(s_timestamp),
        .dropped_frames(dropped_frames),.malformed_frames(malformed_frames),
        .raw_valid(raw_valid),.raw_ready(raw_ready),.raw_data(raw_data),.raw_first(raw_first),.raw_last(raw_last),.raw_frame_id(raw_frame_id),.raw_timestamp(raw_timestamp),
        .spectrum_ready(1'b1),.phase_ready(1'b1),
        .result_valid(result_valid),.result_ready(result_ready),.result_accumulator(result_accumulator),
        .result_exponent(result_exponent),.result_frame_id(result_frame_id),.result_k_version(result_k_version),
        .result_source_version(result_source_version),.result_invalid(result_invalid),.result_timestamp(result_timestamp),
        .result_peak(result_peak),.result_left(result_left),.result_right(result_right));
    calibration_control #(.FAST_PROFILE(FAST_PROFILE)) control(.clk(clk),.rst_n(rst_n),
        .acquisition_request(acquisition_request),.acquisition_ack(acquisition_ack),
        .requested_window(requested_window),.requested_period(requested_period),
        .requested_result_stride(requested_result_stride),
        .run_request(run_request),.run_ack(run_ack),.requested_run(requested_run),
        .rx_valid(rx_valid),.rx_ready(rx_ready),.rx_data(rx_data),
        .tx_valid(control_valid),.tx_ready(control_ready),.tx_data(control_data),.tx_last(control_last),
        .tx_request(control_request),.tx_grant(control_grant),.packet_sequence(control_sequence),
        .sequence_take(),.receive_error(receive_error),
        .source_version(active_source_version),.k_version(active_k_version),
        .source_begin(source_begin),.source_we(source_we),.source_commit(source_commit),
        .source_addr(source_addr),.source_gain(source_gain),.source_ack(source_ack),.source_error(source_error),
        .k_begin(k_begin),.k_we(k_we),.k_commit(k_commit),.k_addr(k_addr),.k_weight(k_weight),
        .k_exponent(k_exponent),.k_ack(k_ack),.k_error(k_error),.export_period_frames(export_period_frames));
    s0_measurement_packet_tx output_packets(.*,
        .result_valid(publish_result),.result_ready(selected_result_ready),
        .idle(output_idle),
        .period_frames(export_period_frames),
        .raw_timestamp_valid(1'b1),.result_timestamp_valid(1'b1),
        .m_valid(tx_valid),.m_ready(tx_ready),.m_data(tx_data),.m_last(tx_last));
endmodule

// Select complete RESULT transactions without slowing the CCD/algorithm.
// stride is latched only during the drained configuration reset.
module result_export_control(
    input wire clk,input wire rst_n,input wire [31:0] stride,
    input wire s_valid,output wire s_ready,output wire m_valid,input wire m_ready
);
    reg [31:0] active_stride,remaining;
    assign m_valid=rst_n && s_valid && remaining==0;
    assign s_ready=rst_n && (remaining!=0 || m_ready);
    always @(posedge clk) begin
        if(!rst_n) begin active_stride<=stride;remaining<=0;end
        else if(s_valid && s_ready) begin
            if(remaining==0) remaining<=active_stride-1'b1;
            else remaining<=remaining-1'b1;
        end
    end
endmodule

// Power-up is deliberately stopped. A stop request prevents the next frame,
// then waits for the active frame, processing pipeline and packetizer to drain.
module acquisition_run_control(
    input wire clk,input wire rst_n,input wire request,input wire requested_run,output wire ack,
    input wire frontend_busy,input wire acquisition_idle,input wire output_idle,
    output reg enabled
);
    reg [1:0] state;
    reg [3:0] quiet_count;
    assign ack=state==2;
    always @(posedge clk) begin
        if(!rst_n) begin enabled<=0;state<=0;quiet_count<=0;end
        else case(state)
            0:if(request) begin
                quiet_count<=0;
                if(requested_run) begin enabled<=1;state<=2;end
                else begin enabled<=0;state<=1;end
            end
            1:begin
                if(!frontend_busy && acquisition_idle && output_idle) begin
                    if(quiet_count==15) begin state<=2;quiet_count<=0;end
                    else quiet_count<=quiet_count+1'b1;
                end else quiet_count<=0;
            end
            2:if(!request) state<=0;
        endcase
    end
endmodule

// Drain before changing coordinates or clearing calibration. No transport reset.
module acquisition_reconfigure #(parameter ENABLED=1,parameter FAST_PROFILE=0)(
    input wire clk,input wire rst_n,input wire request,output wire ack,
    input wire [10:0] requested_window,input wire [63:0] requested_period,
    input wire frontend_busy,input wire acquisition_idle,input wire output_idle,
    output wire stop,output wire pipeline_reset_n,
    output reg [10:0] active_window,output reg [63:0] active_period
);
    reg [1:0] state;
    reg [3:0] quiet_count;
    assign stop=ENABLED && state!=0;
    assign ack=state==3;
    assign pipeline_reset_n=rst_n && state!=2;
    always @(posedge clk) begin
        if(!rst_n) begin
            active_window<=512;active_period<=FAST_PROFILE ? 2500 : 2114;state<=0;quiet_count<=0;
        end else case(state)
            0:if(request && ENABLED) begin state<=1;quiet_count<=0;end
            1:begin
                if(!frontend_busy && acquisition_idle && output_idle) begin
                    if(quiet_count==15) begin
                        active_window<=requested_window;active_period<=requested_period;
                        state<=2;quiet_count<=0;
                    end else quiet_count<=quiet_count+1'b1;
                end else quiet_count<=0;
            end
            2:if(quiet_count==15) state<=3;
              else quiet_count<=quiet_count+1'b1;
            3:if(!request) state<=0;
        endcase
    end
endmodule
