`timescale 1ns/1ps
// Store-and-forward SPIF SOURCE/K receiver. No calibration side effects until
// complete header/payload CRC and coefficient semantics pass.
// abort discards partial or pending packets; coordinate it with consumer reset.
module config_packet_rx(
    input wire clk,input wire rst_n,input wire abort,
    input wire s_valid,output wire s_ready,input wire [7:0] s_data,
    output wire cmd_valid,input wire cmd_ready,output wire [7:0] cmd_kind,
    output wire [31:0] cmd_sequence,output wire [12:0] cmd_length,
    output wire m_valid,input wire m_ready,output reg [7:0] m_data,output wire m_last,
    output reg error
);
    localparam SEARCH=0,HEADER=1,CHECK=2,PAYLOAD=3,CRC=4,OFFER=5,LOAD=6,SEND=7;
    reg [2:0] state;
    reg [31:0] window,crc,received_crc;
    reg [287:0] header;
    reg [12:0] index,length;
    reg [5:0] count;
    reg [31:0] coefficient;
    reg signed [40:0] weight_sum;
    reg semantic_bad;
    wire [31:0] incoming_word={s_data,coefficient[31:8]};
    (* ram_style="block" *) reg [7:0] memory[0:4095];
    function [31:0] crc_byte(input [31:0] current,input [7:0] value);
        reg [31:0] c;integer i;
        begin
            c=current^{24'b0,value};
            for(i=0;i<8;i=i+1) c=c[0] ? (c>>1)^32'hedb88320 : c>>1;
            crc_byte=c;
        end
    endfunction
    assign s_ready=rst_n && !abort && (state==SEARCH || state==HEADER || state==PAYLOAD || state==CRC);
    assign cmd_valid=rst_n && !abort && state==OFFER;
    assign cmd_kind=header[47:40];
    assign cmd_sequence=header[127:96];
    assign cmd_length=length;
    assign m_valid=rst_n && !abort && state==SEND;
    assign m_last=(index==length-1);
    wire legal=((header[47:40]==8'h20 && header[95:64]==4096) ||
                (header[47:40]==8'h21 && header[95:64]==2052) ||
                (header[47:40]==8'h23 && header[95:64]==4) ||
                (header[47:40]==8'h24 && header[95:64]==8) ||
                (header[47:40]==8'h25 && header[95:64]==4) ||
                (header[47:40]==8'h27 && header[95:64]==16)) &&
                header[39:32]==1 && (header[63:48]&16'hfff8)==0 &&
                (header[50] || header[223:160]==0);
    always @(posedge clk) begin
        if(!rst_n || abort) begin
            state<=SEARCH;window<=0;header<=0;crc<=32'hffffffff;
            received_crc<=0;index<=0;length<=0;count<=0;m_data<=0;error<=0;
            coefficient<=0;weight_sum<=0;semantic_bad<=0;
        end else begin
            error<=0;
            case(state)
                SEARCH:if(s_valid) begin
                    window<={s_data,window[31:8]};
                    if({s_data,window[31:8]}==32'h46495053) begin
                        header<=288'h46495053;count<=4;state<=HEADER;
                        crc<=crc_byte(crc_byte(crc_byte(crc_byte(32'hffffffff,8'h53),8'h50),8'h49),8'h46);
                        window<=0;
                    end
                end
                HEADER:if(s_valid) begin
                    header[count*8+:8]<=s_data;crc<=crc_byte(crc,s_data);
                    if(count==35) state<=CHECK;else count<=count+1'b1;
                end
                CHECK:begin
                    if(!legal) begin state<=SEARCH;error<=1;window<=0;end
                    else begin
                        length<=header[76:64];index<=0;state<=PAYLOAD;
                        coefficient<=0;weight_sum<=0;semantic_bad<=0;
                    end
                end
                PAYLOAD:if(s_valid) begin
                    memory[index[11:0]]<=s_data;crc<=crc_byte(crc,s_data);
                    coefficient<=incoming_word;
                    if(header[47:40]==8'h20 && index[1:0]==3) begin
                        if(incoming_word==0 || incoming_word>32'h40000000) semantic_bad<=1;
                    end
                    if(header[47:40]==8'h21) begin
                        if((index==2 || index==3) && s_data!=0) semantic_bad<=1;
                        if(index>=4 && index[1:0]==3)
                            weight_sum<=weight_sum+$signed({{9{incoming_word[31]}},incoming_word});
                    end
                    if(header[47:40]==8'h24 && index[1:0]==3) begin
                        if(index==3 && incoming_word>1024) semantic_bad<=1;
                        if(index==7 && (incoming_word<2114 || incoming_word>4999)) semantic_bad<=1;
                    end
                    if(header[47:40]==8'h25 && index==3 && incoming_word>1)
                        semantic_bad<=1;
                    if(header[47:40]==8'h27 && index[1:0]==3) begin
                        if(index==3 && incoming_word>1024) semantic_bad<=1;
                        // Save the low period word until the complete uint64 is checked.
                        if(index==7) weight_sum<={9'b0,incoming_word};
                        if(index==11 && (incoming_word[31:29]!=0 ||
                           (incoming_word==0 && weight_sum<2500))) semantic_bad<=1;
                        if(index==15 && incoming_word==0) semantic_bad<=1;
                    end
                    if(index==length-1) begin count<=0;received_crc<=0;state<=CRC;end
                    else index<=index+1'b1;
                end
                CRC:if(s_valid) begin
                    received_crc<={s_data,received_crc[31:8]};
                    if(count==3) begin
                        if({s_data,received_crc[31:8]}==~crc && !semantic_bad &&
                           (header[47:40]!=8'h21 || weight_sum==0)) begin state<=OFFER;index<=0;end
                        else begin state<=SEARCH;window<=0;error<=1;end
                    end else count<=count+1'b1;
                end
                OFFER:if(cmd_ready) state<=LOAD;
                LOAD:begin m_data<=memory[index[11:0]];state<=SEND;end
                SEND:if(m_ready) begin
                    if(index==length-1) begin state<=SEARCH;window<=0;end
                    else begin index<=index+1'b1;state<=LOAD;end
                end
            endcase
        end
    end
endmodule
