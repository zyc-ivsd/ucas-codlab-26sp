`timescale 10ns / 1ns

`define CACHE_SET 8
`define CACHE_WAY 4
`define TAG_LEN	 24
`define LINE_LEN  256

// ============================================================================
// D-Cache : 1KB / 4-way / 32B block, write-back + write-allocate
//   地址: tag[31:8] | index[7:5] | offset[4:0] (offset[4:2]=word, [1:0]=byte)
//   旁路(不可缓存)区:
//     1) addr < 0x20  或  addr >= 0x4000_0000
//     2) DNN共享缓冲区 0x0700_0000 ~ 0x080f_ffff
//   以上地址直接读写内存(len=0)
//   非流水阻塞: 一次只处理一个请求, 处理完回 WAIT 才收下一个。
//   存储: 4 路各 tag_array + data_array; valid/dirty/轮转指针用 reg 维护。
// ============================================================================
module dcache_top (
	input	      clk,
	input	      rst,

	//CPU interface
	input         from_cpu_mem_req_valid,
	input         from_cpu_mem_req,          // 0=read 1=write
	input  [31:0] from_cpu_mem_req_addr,
	input  [31:0] from_cpu_mem_req_wdata,
	input  [ 3:0] from_cpu_mem_req_wstrb,
	output        to_cpu_mem_req_ready,

	output        to_cpu_cache_rsp_valid,
	output [31:0] to_cpu_cache_rsp_data,
	input         from_cpu_cache_rsp_ready,

	//Memory read interface
	output        to_mem_rd_req_valid,
	output [31:0] to_mem_rd_req_addr,
	output [ 7:0] to_mem_rd_req_len,
	input	      from_mem_rd_req_ready,

	input	      from_mem_rd_rsp_valid,
	input  [31:0] from_mem_rd_rsp_data,
	input	      from_mem_rd_rsp_last,
	output        to_mem_rd_rsp_ready,

	//Memory write interface
	output        to_mem_wr_req_valid,
	output [31:0] to_mem_wr_req_addr,
	output [ 7:0] to_mem_wr_req_len,
	input         from_mem_wr_req_ready,

	output        to_mem_wr_data_valid,
	output [31:0] to_mem_wr_data,
	output [ 3:0] to_mem_wr_data_strb,
	output        to_mem_wr_data_last,
	input	      from_mem_wr_data_ready
);

// 状态编码

	localparam D_WAIT   = 4'd0;
	localparam D_TAG    = 4'd1;    // 读 tag/valid/dirty, 判 hit / bypass
	localparam D_RESP   = 4'd2;    // 读命中/缺失填完, 返回读数据
	localparam D_WHIT   = 4'd3;    // 写命中: merge 写 data_array, 置 dirty
	localparam D_WB     = 4'd4;    // 写回脏块: 发写请求
	localparam D_WBD    = 4'd5;    // 写回脏块: 发 8 拍数据
	localparam D_MREQ   = 4'd6;    // 缺失: 发内存读请求
	localparam D_RECV   = 4'd7;    // 缺失: 收 8 拍
	localparam D_REFILL = 4'd8;    // 写入新块 tag/valid, 读->RESP 写->merge
	localparam D_BPR    = 4'd9;    // 旁路读: 发请求
	localparam D_BPRD   = 4'd10;   // 旁路读: 收 1 拍 -> RESP
	localparam D_BPW    = 4'd11;   // 旁路写: 发请求
	localparam D_BPWD   = 4'd12;   // 旁路写: 发 1 拍数据

	reg [3:0]  state;

// 请求锁存
	reg [31:0] req_addr;
	reg        req_wr;         
	reg [31:0] req_wdata;
	reg [3:0]  req_wstrb;

	wire [2:0]  idx  = req_addr[7:5];
	wire [23:0] tag  = req_addr[31:8];
	wire [2:0]  woff = req_addr[4:2];

	// 旁路判定
	wire bypass_io  = (req_addr < 32'h20) | (req_addr >= 32'h4000_0000);
	wire bypass_dnn = (req_addr >= 32'h0700_0000) & (req_addr < 32'h0810_0000);
	wire bypass = bypass_io | bypass_dnn;

// valid / dirty / 轮转指针
	reg        valid [0:`CACHE_SET-1][0:`CACHE_WAY-1];
	reg        dirty [0:`CACHE_SET-1][0:`CACHE_WAY-1];
	reg [1:0]  rr_ptr[0:`CACHE_SET-1];

	integer si, wi;

// 4 路 tag_array / data_array
	wire [23:0]  tag_rdata [0:`CACHE_WAY-1];
	wire [255:0] data_rdata[0:`CACHE_WAY-1];

	reg  [1:0]   victim;
	reg  [255:0] refill_buf;
	reg  [2:0]   recv_cnt;
	reg  [2:0]   wb_cnt;      

	// data_array 写: refill 整块写, 或写命中改一个 word
	reg          darr_wen [0:`CACHE_WAY-1];
	reg  [255:0] darr_wdata;
	wire [2:0]   darr_waddr = idx;

	// tag_array 写: 仅 refill 时写 victim 路
	wire tag_wen_fill = (state == D_REFILL);

	genvar w;
	generate
		for (w = 0; w < `CACHE_WAY; w = w + 1) begin : way
			tag_array u_tag (
				.clk   (clk),
				.waddr (idx),
				.raddr (idx),
				.wen   (tag_wen_fill & (victim == w)),
				.wdata (tag),
				.rdata (tag_rdata[w])
			);
			data_array u_data (
				.clk   (clk),
				.waddr (darr_waddr),
				.raddr (idx),
				.wen   (darr_wen[w]),
				.wdata (darr_wdata),
				.rdata (data_rdata[w])
			);
		end
	endgenerate

// 命中比较
	wire [3:0] hit_way;
	assign hit_way[0] = valid[idx][0] & (tag_rdata[0] == tag);
	assign hit_way[1] = valid[idx][1] & (tag_rdata[1] == tag);
	assign hit_way[2] = valid[idx][2] & (tag_rdata[2] == tag);
	assign hit_way[3] = valid[idx][3] & (tag_rdata[3] == tag);
	wire hit = |hit_way;
	wire [1:0] hit_sel = hit_way[0] ? 2'd0 : hit_way[1] ? 2'd1
	                   : hit_way[2] ? 2'd2 : 2'd3;

	wire [1:0] victim_sel = ~valid[idx][0] ? 2'd0
	                      : ~valid[idx][1] ? 2'd1
	                      : ~valid[idx][2] ? 2'd2
	                      : ~valid[idx][3] ? 2'd3
	                      : rr_ptr[idx];

// 命中路 / victim 路读出的整 block 锁存
	reg [1:0]   acc_way;        // 当前访问的路 (hit_sel 或 victim)
	reg [255:0] acc_block;      // 锁存的整 block (用于写回 / 写命中 merge)
	reg [23:0]  wb_tag;         // 写回用的 victim 旧 tag

	// 读返回数据来源: 读命中走 acc_block, 读缺失走 refill_buf
	reg         resp_from_buf;
	wire [255:0] resp_block = resp_from_buf ? refill_buf : acc_block;
	wire [31:0]  resp_word  = resp_block[woff*32 +: 32];

// 写数据 byte-merge: 把 req_wdata 按 wstrb 合进 base_block 的 woff word
// 为了解决cache只能block层级的写,但是store需要控制字节级别的写
	function [255:0] merge_word;
		input [255:0] base;
		input [2:0]   word_off;
		input [31:0]  wd;	
		input [3:0]   strb;    
		reg   [255:0] r;
		reg   [31:0]  old_w, new_w;
		begin
			r     = base;
			old_w = base[word_off*32 +: 32];
			new_w[7:0] = strb[0] ? wd[7:0] : old_w[7:0];
			new_w[15:8]  = strb[1] ? wd[15:8]  : old_w[15:8];
			new_w[23:16] = strb[2] ? wd[23:16] : old_w[23:16];
			new_w[31:24] = strb[3] ? wd[31:24] : old_w[31:24];
			r[word_off*32 +: 32] = new_w;
			merge_word = r;
		end
	endfunction

// data_array 写
	integer k;
	always @(*) begin
		for (k = 0; k < `CACHE_WAY; k = k + 1)
			darr_wen[k] = 1'b0;
		darr_wdata = 256'b0;

		if (state == D_WHIT) begin
			// 写命中: 把命中块 merge 后写回命中路
			darr_wen[acc_way] = 1'b1;
			darr_wdata = merge_word(acc_block, woff, req_wdata, req_wstrb);
		end
		else if (state == D_REFILL) begin
			// 缺失填充: read 直接填 refill_buf; write 填 merge 后的块
			darr_wen[victim] = 1'b1;
			darr_wdata = req_wr ? merge_word(refill_buf, woff, req_wdata, req_wstrb)
			                    : refill_buf;
		end
	end


	always @(posedge clk) begin
		if (rst) begin
			state    <= D_WAIT;
			recv_cnt <= 3'd0;
			wb_cnt   <= 3'd0;
			for (si = 0; si < `CACHE_SET; si = si + 1) begin
				rr_ptr[si] <= 2'd0;
				for (wi = 0; wi < `CACHE_WAY; wi = wi + 1) begin
					valid[si][wi] <= 1'b0;
					dirty[si][wi] <= 1'b0;
				end
			end
		end
		else begin
			case (state)
			// 等 CPU 访存请求, 锁存
			D_WAIT: begin
				if (from_cpu_mem_req_valid) begin
					req_addr  <= from_cpu_mem_req_addr;
					req_wr    <= from_cpu_mem_req;
					req_wdata <= from_cpu_mem_req_wdata;
					req_wstrb <= from_cpu_mem_req_wstrb;
					state     <= D_TAG;
				end
			end
			// 判 bypass / hit / miss
			D_TAG: begin
				if (bypass) begin
					state <= req_wr ? D_BPW : D_BPR;
				end
				else if (hit) begin
					acc_way   <= hit_sel;
					acc_block <= data_rdata[hit_sel];
					if (req_wr)
						state <= D_WHIT;
					else begin
						resp_from_buf <= 1'b0;
						state         <= D_RESP;
					end
				end
				else begin
					// miss: 选 victim, 锁存其 block 与旧 tag 备写回
					victim    <= victim_sel;
					acc_block <= data_rdata[victim_sel];
					wb_tag    <= tag_rdata[victim_sel];
					recv_cnt <= 3'd0;
					if (valid[idx][victim_sel] & dirty[idx][victim_sel])
						state <= D_WB;
					else
						state <= D_MREQ;
				end
			end
			// 写命中: data_array 已在组合中 merge 写入, 置 dirty
			D_WHIT: begin
				dirty[idx][acc_way] <= 1'b1;
				state <= D_WAIT;
			end
			// 写回脏块: 发写请求 (32B 对齐, 旧 tag 地址)
			D_WB: begin
				wb_cnt <= 3'd0;
				if (from_mem_wr_req_ready)
					state <= D_WBD;
			end
			// 写回脏块: 发 8 拍数据
			D_WBD: begin
				if (from_mem_wr_data_ready) begin
					wb_cnt <= wb_cnt + 3'd1;
					if (wb_cnt == 3'd7)
						state <= D_MREQ;
				end
			end
			// 缺失: 发内存读请求
			D_MREQ: begin
				if (from_mem_rd_req_ready)
					state <= D_RECV;
			end
			// 收 8 拍
			D_RECV: begin
				if (from_mem_rd_rsp_valid) begin
					refill_buf[recv_cnt*32 +: 32] <= from_mem_rd_rsp_data;
					recv_cnt <= recv_cnt + 3'd1;
					if (from_mem_rd_rsp_last)
						state <= D_REFILL;
				end
			end
			// 写入新块: tag/valid 更新, dirty 按读/写决定
			D_REFILL: begin
				valid[idx][victim] <= 1'b1;
				dirty[idx][victim] <= req_wr;     // 写分配 -> dirty=1,写缺失在refill时立刻做了merge,故直接dirty
				if (valid[idx][0] & valid[idx][1] & valid[idx][2] & valid[idx][3])
					rr_ptr[idx] <= rr_ptr[idx] + 2'd1;
				if (req_wr) begin
					// 写缺失: merge 已在组合写入 data_array, 直接完成
					state <= D_WAIT;
				end
				else begin
					// 读缺失: 从 refill_buf 返回
					resp_from_buf <= 1'b1;
					state         <= D_RESP;
				end
			end
			// 返回读数据
			D_RESP: begin
				if (from_cpu_cache_rsp_ready)
					state <= D_WAIT;
			end
			// 旁路读: 发请求 (len=0)
			D_BPR: begin
				if (from_mem_rd_req_ready)
					state <= D_BPRD;
			end
			// 旁路读: 收 1 拍,4个字节
			D_BPRD: begin
				if (from_mem_rd_rsp_valid) begin
					refill_buf[31:0] <= from_mem_rd_rsp_data;
					resp_from_buf    <= 1'b1;
					state            <= D_RESP;
				end
			end
			// 旁路写: 发请求 (len=0)
			D_BPW: begin
				if (from_mem_wr_req_ready)
					state <= D_BPWD;
			end
			// 旁路写: 发 1 拍数据
			D_BPWD: begin
				if (from_mem_wr_data_ready)
					state <= D_WAIT;
			end
			default: state <= D_WAIT;
			endcase
		end
	end

// 旁路读返回的 word: 旁路读直接是请求的那个 word
//   resp_block[woff] 对旁路无意义, 单独走 refill_buf[31:0]
	reg resp_is_bypass;
	always @(posedge clk) begin
		if (rst) resp_is_bypass <= 1'b0;
		else if (state == D_BPRD & from_mem_rd_rsp_valid) resp_is_bypass <= 1'b1;
		else if (state == D_TAG) resp_is_bypass <= 1'b0;
	end
	wire [31:0] cpu_rsp_data = resp_is_bypass ? refill_buf[31:0] : resp_word;

// 写回数据: 按 wb_cnt 从 acc_block 取出对应 word
	wire [31:0] wb_word = acc_block[wb_cnt*32 +: 32];

// 输出
	assign to_cpu_mem_req_ready   = ~rst & (state == D_WAIT);
	assign to_cpu_cache_rsp_valid = ~rst & (state == D_RESP);
	assign to_cpu_cache_rsp_data  = cpu_rsp_data;

	// 内存读: 缺失 refill (len=7, 32B对齐) 或 旁路读 (len=0, 4B对齐)
	assign to_mem_rd_req_valid = ~rst & ((state == D_MREQ) | (state == D_BPR));
	assign to_mem_rd_req_addr  = (state == D_BPR) ? {req_addr[31:2], 2'b0}
	                                              : {req_addr[31:5], 5'b0};
	assign to_mem_rd_req_len   = (state == D_BPR) ? 8'd0 : 8'd7;
	assign to_mem_rd_rsp_ready = ~rst & ((state == D_RECV) | (state == D_BPRD));

	// 内存写: 写回 (len=7, 32B对齐旧tag) 或 旁路写 (len=0, 4B对齐)
	assign to_mem_wr_req_valid = ~rst & ((state == D_WB) | (state == D_BPW));
	assign to_mem_wr_req_addr  = (state == D_BPW) ? {req_addr[31:2], 2'b0}
	                                              : {wb_tag, idx, 5'b0};
	assign to_mem_wr_req_len   = (state == D_BPW) ? 8'd0 : 8'd7;

	// 写数据: 写回逐拍发 block word(strb全1); 旁路写发请求 word + 原 strb
	assign to_mem_wr_data_valid = ~rst & ((state == D_WBD) | (state == D_BPWD));
	assign to_mem_wr_data       = (state == D_BPWD) ? req_wdata : wb_word;
	assign to_mem_wr_data_strb  = (state == D_BPWD) ? req_wstrb : 4'b1111;
	assign to_mem_wr_data_last  = (state == D_BPWD) ? 1'b1 : (wb_cnt == 3'd7);

endmodule
