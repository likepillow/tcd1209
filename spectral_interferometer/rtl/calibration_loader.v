`timescale 1ns/1ps
// Accept ONLY packets already validated by config_packet_rx. Reset must be
// coordinated with receiver and calibration cores; no independent mid-commit abort.
module calibration_loader #(parameter FAST_PROFILE=0)(
    input wire clk,input wire rst_n,
    input wire cmd_valid,output wire cmd_ready,input wire [7:0] cmd_kind,
    input wire [31:0] cmd_sequence,
    input wire s_valid,output wire s_ready,input wire [7:0] s_data,input wire s_last,
    output wire source_begin,output wire source_we,output wire source_commit,
    output wire [9:0] source_addr,output wire [30:0] source_gain,
    input wire source_ack,input wire source_error,
    output wire k_begin,output wire k_we,output wire k_commit,
    output wire [8:0] k_addr,output wire signed [31:0] k_weight,
    output wire signed [15:0] k_exponent,input wire k_ack,input wire k_error,
    output wire ack_valid,input wire ack_ready,output reg [31:0] ack_sequence,
    output reg [15:0] ack_status,
    output reg [31:0] export_period_frames,
    output wire acquisition_request,input wire acquisition_ack,
    output reg [10:0] requested_window,
    output reg [63:0] requested_period,
    output reg [31:0] requested_result_stride,
    output wire run_request,input wire run_ack,output reg requested_run
);
    localparam IDLE=0,BEGIN_CFG=1,READ=2,WRITE=3,COMMIT=4,WAIT_ACK=5,REPLY=6,
               WAIT_ACQUISITION=7,WAIT_RUN=8;
    reg [3:0] state;
    reg is_k,is_export,read_exponent,last_word;
    reg is_acquisition,is_run,is_extended;
    reg [1:0] byte_index;
    reg [9:0] address;
    reg [31:0] word_data;
    reg signed [15:0] exponent;
    assign cmd_ready=rst_n && state==IDLE;
    assign s_ready=rst_n && state==READ;
    assign source_begin=rst_n && state==BEGIN_CFG && !is_k;
    assign k_begin=rst_n && state==BEGIN_CFG && is_k;
    assign source_we=rst_n && state==WRITE && !is_k;
    assign k_we=rst_n && state==WRITE && is_k;
    assign source_commit=rst_n && state==COMMIT && !is_k;
    assign k_commit=rst_n && state==COMMIT && is_k;
    assign source_addr=address;assign k_addr=address[8:0];
    assign source_gain=word_data[30:0];assign k_weight=word_data;assign k_exponent=exponent;
    assign ack_valid=rst_n && state==REPLY;
    assign acquisition_request=rst_n && state==WAIT_ACQUISITION;
    assign run_request=rst_n && state==WAIT_RUN;
    always @(posedge clk) begin
        if(!rst_n) begin
            state<=IDLE;is_k<=0;is_export<=0;read_exponent<=0;last_word<=0;
            export_period_frames<=1;
            is_acquisition<=0;is_run<=0;requested_run<=0;
            requested_window<=512;requested_period<=FAST_PROFILE ? 2500 : 2114;
            requested_result_stride<=1;is_extended<=0;
            byte_index<=0;address<=0;word_data<=0;exponent<=0;ack_sequence<=0;ack_status<=0;
        end else begin
            case(state)
                IDLE:if(cmd_valid) begin
                    ack_sequence<=cmd_sequence;ack_status<=0;address<=0;byte_index<=0;
                    is_k<=(cmd_kind==8'h21);read_exponent<=(cmd_kind==8'h21);
                    is_export<=(cmd_kind==8'h23);
                    is_acquisition<=(cmd_kind==8'h24 || cmd_kind==8'h27);
                    is_extended<=(cmd_kind==8'h27);
                    is_run<=(cmd_kind==8'h25);
                    if(cmd_kind==8'h20) state<=BEGIN_CFG;
                    else if((cmd_kind==8'h24 && FAST_PROFILE) || (cmd_kind==8'h27 && !FAST_PROFILE)) begin
                        // Consume the verified payload before replying unsupported.
                        ack_status<=1;state<=READ;
                    end
                    else if(cmd_kind==8'h21 || cmd_kind==8'h23 || cmd_kind==8'h24 || cmd_kind==8'h25 || cmd_kind==8'h27) state<=READ;
                    else begin ack_status<=1;state<=REPLY;end
                end
                BEGIN_CFG:state<=READ;
                READ:if(s_valid) begin
                    word_data<={s_data,word_data[31:8]};
                    if(byte_index==3) begin
                        byte_index<=0;
                        if(ack_status!=0) begin
                            if(s_last) state<=REPLY;
                        end else if(is_run) begin
                            requested_run<=word_data[8];state<=WAIT_RUN;
                        end else if(is_acquisition) begin
                            if(address==0) begin
                                requested_window<=word_data[18:8];address<=1;
                            end else if(!is_extended) begin
                                requested_period<={51'b0,word_data[20:8]};
                                requested_result_stride<=1;state<=WAIT_ACQUISITION;
                            end else if(address==1) begin
                                requested_period[31:0]<={s_data,word_data[31:8]};address<=2;
                            end else if(address==2) begin
                                requested_period[63:32]<={s_data,word_data[31:8]};address<=3;
                            end else begin
                                requested_result_stride<={s_data,word_data[31:8]};state<=WAIT_ACQUISITION;
                            end
                        end else if(is_export) begin
                            export_period_frames<={s_data,word_data[31:8]};state<=REPLY;
                        end else if(read_exponent) begin
                            exponent<=word_data[23:8];read_exponent<=0;state<=BEGIN_CFG;
                        end else begin last_word<=s_last;state<=WRITE;end
                    end else byte_index<=byte_index+1'b1;
                end
                WRITE:begin
                    if(last_word) state<=COMMIT;
                    else begin address<=address+1'b1;state<=READ;end
                end
                COMMIT:state<=WAIT_ACK;
                WAIT_ACK:if(is_k ? k_ack : source_ack) begin ack_status<=0;state<=REPLY;end
                WAIT_ACQUISITION:if(acquisition_ack) begin ack_status<=0;state<=REPLY;end
                WAIT_RUN:if(run_ack) begin ack_status<=0;state<=REPLY;end
                REPLY:if(ack_ready) state<=IDLE;
            endcase
            if(state!=IDLE && state!=REPLY && !is_export && !is_acquisition && !is_run && (is_k ? k_error : source_error)) begin
                ack_status<=3;state<=REPLY;
            end
        end
    end
endmodule
