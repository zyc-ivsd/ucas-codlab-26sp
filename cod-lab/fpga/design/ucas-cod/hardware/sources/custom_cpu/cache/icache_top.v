`timescale 10ns / 1ns

`define CACHE_SET	8
`define CACHE_WAY	4
`define TAG_LEN		24
`define LINE_LEN	256

// ============================================================================
// I-Cache : 1KB / 4-way set-associative / 32B block (8 x 32-bit)
//   地址划分: tag[31:8] | index[7:5] | offset[4:0] (offset[4:2]=word下标)
//   只读, 不需要写回/dirty; miss 时直接覆盖一路 (优先无效路, 否则轮转替换)。
//   存储: 4 路各 1 个 tag_array(24b x8) + 1 个 data_array(256b x8);
//         valid 与轮转指针用 reg 数组自行维护。
//   阵列同步写异步读 -> refill 收满 8 拍进 refill_buf, 直接选 word 返回,
//         不依赖"写完同拍读出"。
// ----------------------------------------------------------------------------
// 状态机:
//   I_WAIT -> I_TAG_RD -> (Hit: I_CACHE_RD -> I_RESP)
//                          (Miss: I_EVICT -> I_MEM_RD -> I_RECV -> I_REFILL -> I_RESP)
// ============================================================================
module icache_top (
	input	      clk,
	input	      rst,

	//CPU interface
	input         from_cpu_inst_req_valid,
	input  [31:0] from_cpu_inst_req_addr,
	output        to_cpu_inst_req_ready,

	output        to_cpu_cache_rsp_valid,
	output [31:0] to_cpu_cache_rsp_data,
	input	      from_cpu_cache_rsp_ready,

	//Memory interface (32 byte aligned address)
	output        to_mem_rd_req_valid,
	output [31:0] to_mem_rd_req_addr,
	input         from_mem_rd_req_ready,

	input         from_mem_rd_rsp_valid,
	input  [31:0] from_mem_rd_rsp_data,
	input         from_mem_rd_rsp_last,
	output        to_mem_rd_rsp_ready
);

// 状态编码
	localparam I_WAIT     = 3'd0;
	localparam I_TAG_RD   = 3'd1;
	localparam I_CACHE_RD = 3'd2;
	localparam I_RESP     = 3'd3;
	localparam I_EVICT    = 3'd4;
	localparam I_MEM_RD   = 3'd5;
	localparam I_RECV     = 3'd6;
	localparam I_REFILL   = 3'd7;

	reg [2:0]  state;
	reg [31:0] req_addr;        

	wire [2:0]  idx    = req_addr[7:5];
	wire [23:0] tag    = req_addr[31:8];
	wire [2:0]  woff   = req_addr[4:2];   

// valid + 轮转替换指针 (8 set x 4 way)
	reg        valid [0:`CACHE_SET-1][0:`CACHE_WAY-1];
	reg [1:0]  rr_ptr[0:`CACHE_SET-1];     // 每 set 的轮转指针

	integer si, wi;

// 4 路 tag_array / data_array 实例
//   读地址恒用 idx; 写地址在 refill 时用 idx, 写使能按 victim 路选通。
	wire [23:0]  tag_rdata [0:`CACHE_WAY-1];
	wire [255:0] data_rdata[0:`CACHE_WAY-1];

	reg  [1:0]   victim;        // 本次 refill 选中的替换路
	reg  [255:0] refill_buf;    // 收齐的整 block
	reg  [2:0]   recv_cnt;      // RECV 计数 0..7

	wire fill_wen = (state == I_REFILL);

	genvar w;
	generate
		for (w = 0; w < `CACHE_WAY; w = w + 1) begin : way
			tag_array u_tag (
				.clk   (clk),
				.waddr (idx),
				.raddr (idx),
				.wen   (fill_wen & (victim == w)),
				.wdata (tag),
				.rdata (tag_rdata[w])
			);
			data_array u_data (
				.clk   (clk),
				.waddr (idx),
				.raddr (idx),
				.wen   (fill_wen & (victim == w)),
				.wdata (refill_buf),
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

	// 命中路编号 
	wire [1:0] hit_sel = hit_way[0] ? 2'd0
	                   : hit_way[1] ? 2'd1
	                   : hit_way[2] ? 2'd2
	                   :              2'd3;

	// victim 选择: 优先无效路, 否则轮转
	wire [1:0] victim_sel = ~valid[idx][0] ? 2'd0
	                      : ~valid[idx][1] ? 2'd1
	                      : ~valid[idx][2] ? 2'd2
	                      : ~valid[idx][3] ? 2'd3
	                      : rr_ptr[idx];

// 命中路读出的 block 
	reg [1:0] resp_way;         // hit: 命中路; miss: refill 后从 buf 取
	reg       resp_from_buf;    // 1=从 refill_buf 取, 0=从 data_rdata 取

	wire [255:0] resp_block = resp_from_buf ? refill_buf : data_rdata[resp_way];

	// 按 word 下标返回
	wire [31:0] resp_word = resp_block[woff*32 +: 32];


	always @(posedge clk) begin
		if (rst) begin
			state    <= I_WAIT;
			recv_cnt <= 3'd0;
			for (si = 0; si < `CACHE_SET; si = si + 1) begin
				rr_ptr[si] <= 2'd0;
				for (wi = 0; wi < `CACHE_WAY; wi = wi + 1)
					valid[si][wi] <= 1'b0;
			end
		end
		else begin
			case (state)
			// 等 CPU 取指请求, 锁存地址
			I_WAIT: begin
				if (from_cpu_inst_req_valid) begin
					req_addr <= from_cpu_inst_req_addr;
					state    <= I_TAG_RD;
				end
			end
			// 读标记并判断 hit/miss
			I_TAG_RD: begin
				if (hit) begin
					resp_way      <= hit_sel;
					resp_from_buf <= 1'b0;
					state         <= I_CACHE_RD;
				end
				else begin
					victim    <= victim_sel;
					recv_cnt  <= 3'd0;
					state     <= I_EVICT;
				end
			end
			I_CACHE_RD: begin
				state <= I_RESP;
			end
			I_RESP: begin
				if (from_cpu_cache_rsp_ready | from_cpu_inst_req_valid) begin
					state <= I_WAIT;
				end
			end
			I_EVICT: begin
				state <= I_MEM_RD;
			end
			I_MEM_RD: begin
				if (from_mem_rd_req_ready)
					state <= I_RECV;
			end
			// 收 8 拍 
			I_RECV: begin
				if (from_mem_rd_rsp_valid) begin
					refill_buf[recv_cnt*32 +: 32] <= from_mem_rd_rsp_data;
					recv_cnt <= recv_cnt + 3'd1;
					if (from_mem_rd_rsp_last)
						state <= I_REFILL;
				end
			end
			// 写入 block/tag/valid, 推进轮转指针, 直接从 buf 返回
			I_REFILL: begin
				valid[idx][victim] <= 1'b1;
				// 4 路全满时才推进轮转
				if (valid[idx][0] & valid[idx][1] & valid[idx][2] & valid[idx][3])
					rr_ptr[idx] <= rr_ptr[idx] + 2'd1;
				resp_way      <= victim;
				resp_from_buf <= 1'b1;
				state         <= I_RESP;
			end
			default: state <= I_WAIT;
			endcase
		end
	end

// 输出 
	assign to_cpu_inst_req_ready  = ~rst & (state == I_WAIT);
	assign to_cpu_cache_rsp_valid = ~rst & (state == I_RESP);
	assign to_cpu_cache_rsp_data  = resp_word;

	assign to_mem_rd_req_valid = ~rst & (state == I_MEM_RD);
	assign to_mem_rd_req_addr  = {req_addr[31:5], 5'b0};   
	assign to_mem_rd_rsp_ready = ~rst & (state == I_RECV);

endmodule
