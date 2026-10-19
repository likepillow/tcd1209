`timescale 1ns/1ps
module tb_normalize_clipping;
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0,cfg_begin=0,cfg_we=0,cfg_commit=0;
    reg [9:0] cfg_addr=0;
    reg [30:0] cfg_gain=31'd1048576;
    wire cfg_ack,cfg_error,configured;
    reg s_valid=0,s_first=0,s_last=0;
    reg [11:0] s_data=0;
    reg [31:0] s_frame_id=0;
    wire s_ready,m_valid,m_first,m_last,frame_clipped,frame_error,frame_overflow;
    reg m_ready=0;
    wire [31:0] m_frame_id;
    integer cycles=0,received=0,index=0;
    normalize_frame dut(.clk(clk),.rst_n(rst_n),.cfg_begin(cfg_begin),.cfg_we(cfg_we),
        .cfg_addr(cfg_addr),.cfg_gain(cfg_gain),.cfg_commit(cfg_commit),.cfg_ack(cfg_ack),
        .cfg_error(cfg_error),.configured(configured),.s_valid(s_valid),.s_ready(s_ready),
        .s_data(s_data),.s_first(s_first),.s_last(s_last),.s_frame_id(s_frame_id),
        .m_valid(m_valid),.m_ready(m_ready),.m_first(m_first),.m_last(m_last),
        .m_frame_id(m_frame_id),.frame_clipped(frame_clipped),
        .frame_error(frame_error),.frame_overflow(frame_overflow));
    always @(negedge clk) if(rst_n) begin
        cycles=cycles+1;m_ready=(cycles%9<5);
    end
    always @(posedge clk) if(rst_n) begin
        if(cfg_error || frame_error || frame_overflow) $fatal(1,"Unexpected error");
        if(m_valid && m_ready) begin
            if(frame_clipped !== (m_frame_id==2 || m_frame_id==3 || m_frame_id==5))
                $fatal(1,"Clipping flag frame %0d index %0d",m_frame_id,index);
            if(m_first!=(index==0) || m_last!=(index==1023)) $fatal(1,"Frame truncated");
            if(m_last) begin received=received+1;index=0;end
            else index=index+1;
        end
    end
    task send(input integer id);
        integer i;
        begin
            for(i=0;i<1024;i=i+1) begin
                @(negedge clk);s_valid=1;s_first=(i==0);s_last=(i==1023);s_frame_id=id;
                s_data=12'd1024;
                if(id==2 && i==0) s_data=12'd4095;
                if(id==3 && i==1023) s_data=12'd0;
                if(id==5) s_data=12'd4095;
                @(posedge clk);while(!s_ready) @(posedge clk);
            end
            @(negedge clk);s_valid=0;s_first=0;s_last=0;
            wait(received==id);
        end
    endtask
    integer i;
    initial begin
        repeat(4) @(negedge clk);rst_n=1;
        @(negedge clk);cfg_begin=1;
        @(negedge clk);cfg_begin=0;
        for(i=0;i<1024;i=i+1) begin cfg_we=1;cfg_addr=i;@(negedge clk);end
        cfg_we=0;cfg_commit=1;@(negedge clk);cfg_commit=0;
        wait(cfg_ack);
        send(1);send(2);send(3);send(4);send(5);
        $display("PASS: clipping first/last/all pixels, healthy-frame recovery and backpressure");$finish;
    end
    initial begin #3000000;$fatal(1,"Timeout");end
endmodule
