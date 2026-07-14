`timescale 10ns / 1ns

module custom_cpu(
	input         clk,
	input         rst,

	//Instruction request channel
	output [31:0] PC,
	output        Inst_Req_Valid,
	input         Inst_Req_Ready,

	//Instruction response channel
	input  [31:0] Instruction,
	input         Inst_Valid,
	output        Inst_Ready,

	//Memory request channel
	output [31:0] Address,
	output        MemWrite,
	output [31:0] Write_data,
	output [ 3:0] Write_strb,
	output        MemRead,
	input         Mem_Req_Ready,

	//Memory data response channel
	input  [31:0] Read_data,
	input         Read_data_Valid,
	output        Read_data_Ready,

	input         intr,

	output [31:0] cpu_perf_cnt_0,
	output [31:0] cpu_perf_cnt_1,
	output [31:0] cpu_perf_cnt_2,
	output [31:0] cpu_perf_cnt_3,
	output [31:0] cpu_perf_cnt_4,
	output [31:0] cpu_perf_cnt_5,
	output [31:0] cpu_perf_cnt_6,
	output [31:0] cpu_perf_cnt_7,
	output [31:0] cpu_perf_cnt_8,
	output [31:0] cpu_perf_cnt_9,
	output [31:0] cpu_perf_cnt_10,
	output [31:0] cpu_perf_cnt_11,
	output [31:0] cpu_perf_cnt_12,
	output [31:0] cpu_perf_cnt_13,
	output [31:0] cpu_perf_cnt_14,
	output [31:0] cpu_perf_cnt_15,

	output [69:0] inst_retire
);

	// opcodes
	localparam LUI    = 7'b0110111;
	localparam AUIpc  = 7'b0010111;
	localparam JAL    = 7'b1101111;
	localparam JALR   = 7'b1100111;
	localparam B_TYPE = 7'b1100011;
	localparam L_TYPE = 7'b0000011;
	localparam S_TYPE = 7'b0100011;
	localparam I_TYPE = 7'b0010011;
	localparam R_TYPE = 7'b0110011;

	//
	localparam GHR_BITS  = 6;
	localparam PRED_ENTRIES = (1 << GHR_BITS);
	localparam BTB_TAG_BITS = 32 - GHR_BITS - 2;
	localparam IF_ID_BUS_WIDTH = 103;
	localparam ID_EX_BUS_WIDTH = 209;
	localparam EX_MEM_BUS_WIDTH = 207;
	localparam MEM_WB_BUS_WIDTH = 70;

	// Forward declarations for pipeline control.
	wire if_id_valid;
	wire id_ex_valid;
	wire ex_mem_valid;
	wire mem_wb_valid;

	wire if_id_allowin;
	wire id_ex_allowin;
	wire mem_allowin;
	wire id_fire;
	wire ex_fire;
	wire mem_fire;

	wire ex_redirect;
	wire [31:0] ex_redirect_pc;

	// IF: request/wait FSM
	localparam IF_REQ  = 2'b01, IF_REQ_  = 1'd0;
	localparam IF_WAIT = 2'b10, IF_WAIT_ = 1'd1;

	reg  [1:0] if_state;
	reg [31:0] pc_reg;
	reg [31:0] if_req_pc;
	reg [31:0] if_req_pred_pc;
	reg   if_req_pred_taken;
	reg [GHR_BITS-1:0] if_req_ghr;
	reg   if_discard;
	reg [31:0] if_redirect_pc;

	reg [GHR_BITS-1:0] ghr;
	reg [1:0]  pht [0:PRED_ENTRIES-1];
	reg    btb_valid [0:PRED_ENTRIES-1];
	reg [BTB_TAG_BITS-1:0] btb_tag [0:PRED_ENTRIES-1];
	reg [31:0] btb_target [0:PRED_ENTRIES-1];

	wire [GHR_BITS-1:0] if_pc_index = pc_reg[GHR_BITS+1:2];
	wire [GHR_BITS-1:0] if_pht_index = if_pc_index ^ ghr;
	wire [BTB_TAG_BITS-1:0] if_tag = pc_reg[31:GHR_BITS+2];
	wire   if_btb_hit = btb_valid[if_pc_index] & (btb_tag[if_pc_index] == if_tag);
	wire   if_pred_taken = if_btb_hit & pht[if_pht_index][1];
	wire [31:0]  if_pc_plus4 = pc_reg + 32'd4;
	wire [31:0]  if_pred_pc = ({32{if_pred_taken}} & btb_target[if_pc_index]) |
	                                  ({32{~if_pred_taken}} & if_pc_plus4);

	assign PC = pc_reg;
	assign Inst_Req_Valid = ~rst & (if_state[IF_REQ_]);
	assign Inst_Ready = ~rst & (if_state[IF_WAIT_]) & (if_discard | ex_redirect | if_id_allowin);

	wire if_req_fire = Inst_Req_Valid & Inst_Req_Ready;
	wire if_rsp_fire = Inst_Valid & Inst_Ready;
	wire if_to_id_valid = if_rsp_fire & ~if_discard & ~ex_redirect;
	wire [IF_ID_BUS_WIDTH-1:0] if_to_id_bus =
		{if_req_pc, Instruction, if_req_pred_pc, if_req_pred_taken, if_req_ghr};

	always @(posedge clk) begin
		if (rst) begin
			if_state   <= IF_REQ;
			pc_reg     <= 32'd0;
			if_req_pc  <= 32'd0;
			if_req_pred_pc  <= 32'd0;
			if_req_pred_taken <= 1'b0;
			if_req_ghr     <= {GHR_BITS{1'b0}};
			if_discard     <= 1'b0;
			if_redirect_pc  <= 32'd0;
		end
		else if (ex_redirect) begin
			if (if_state[IF_WAIT_]) begin
				if (Inst_Valid) begin
					if_state   <= IF_REQ;
					pc_reg     <= ex_redirect_pc;
					if_discard  <= 1'b0;
					if_redirect_pc <= 32'd0;
				end
				else begin
					if_discard  <= 1'b1;
					if_redirect_pc <= ex_redirect_pc;
				end
			end
			else begin
				if (Inst_Req_Ready) begin
					if_state   <= IF_WAIT;
					if_req_pc  <= pc_reg;
					if_req_pred_pc  <= if_pred_pc;
					if_req_pred_taken <= if_pred_taken;
					if_req_ghr    <= ghr;
					if_discard    <= 1'b1;
					if_redirect_pc  <= ex_redirect_pc;
				end
				else begin
					pc_reg   <= ex_redirect_pc;
					if_state   <= IF_REQ;
					if_discard  <= 1'b0;
					if_redirect_pc <= 32'd0;
				end
			end
		end
		else begin
			if (if_state[IF_REQ_]) begin
				if (Inst_Req_Ready) begin
					if_state  <= IF_WAIT;
					if_req_pc  <= pc_reg;
					if_req_pred_pc <= if_pred_pc;
					if_req_pred_taken <= if_pred_taken;
					if_req_ghr  <= ghr;
				end
			end
			else if (if_rsp_fire) begin
				if_state <= IF_REQ;
				pc_reg  <= ({32{if_discard}} & if_redirect_pc) |
				            ({32{~if_discard}} & if_req_pred_pc);
				if_discard  <= 1'b0;
				if_redirect_pc <= 32'd0;
			end
		end
	end

	// IF/ID reg
	wire [IF_ID_BUS_WIDTH-1:0] if_id_bus;
	wire [31:0] if_id_pc;
	wire [31:0] if_id_inst;
	wire [31:0] if_id_pred_pc;
	wire        if_id_pred_taken;
	wire [GHR_BITS-1:0] if_id_pred_ghr;

	pipeline_reg #(.BUS_WIDTH(IF_ID_BUS_WIDTH)) u_if_id_reg (
		.clk  (clk),
		.rst  (rst),
		.flush  (ex_redirect),
		.allowin  (if_id_allowin),
		.in_valid  (if_to_id_valid),
		.in_bus  (if_to_id_bus),
		.out_valid (if_id_valid),
		.out_bus (if_id_bus)
	);

	assign {if_id_pc, if_id_inst, if_id_pred_pc, if_id_pred_taken, if_id_pred_ghr} = if_id_bus;

	// ID: decode, register read, load-use hazard.
	wire [6:0] opcode = if_id_inst[6:0];
	wire [4:0] id_rd = if_id_inst[11:7];
	wire [2:0] id_funct3 = if_id_inst[14:12];
	wire [6:0] id_funct7 = if_id_inst[31:25];
	wire [4:0] id_rs1 = if_id_inst[19:15];
	wire [4:0] id_rs2 = if_id_inst[24:20];
	wire [4:0] id_shamt = if_id_inst[24:20];
	wire [31:0] id_imm;

	wire uimm    = (opcode == LUI) | (opcode == AUIpc);
	wire jalimm  = (opcode == JAL);
	wire jalrimm = (opcode == JALR) | (opcode == L_TYPE) | (opcode == I_TYPE);
	wire stimm   = (opcode == S_TYPE);
	wire bimm    = (opcode == B_TYPE);

	assign id_imm = ({32{uimm}} & {if_id_inst[31:12], 12'b0}) |
	                ({32{jalimm}} & {{11{if_id_inst[31]}}, if_id_inst[31], if_id_inst[19:12],
	                                  if_id_inst[20], if_id_inst[30:21], 1'b0}) |
	                ({32{jalrimm}} & {{20{if_id_inst[31]}}, if_id_inst[31:20]}) |
	                ({32{stimm}} & {{20{if_id_inst[31]}}, if_id_inst[31:25], if_id_inst[11:7]}) |
	                ({32{bimm}} & {{19{if_id_inst[31]}}, if_id_inst[31], if_id_inst[7],
	                               if_id_inst[30:25], if_id_inst[11:8], 1'b0});

	wire id_is_lui   = (opcode == LUI);
	wire id_is_auipc = (opcode == AUIpc);
	wire id_is_jal   = (opcode == JAL);
	wire id_is_jalr  = (opcode == JALR);
	wire id_is_btype = (opcode == B_TYPE);
	wire id_is_ltype = (opcode == L_TYPE);
	wire id_is_stype = (opcode == S_TYPE);
	wire id_is_itype = (opcode == I_TYPE);
	wire id_is_rtype = (opcode == R_TYPE);
	wire id_is_mul   = id_is_rtype & (id_funct3 == 3'b000) & (id_funct7 == 7'b0000001);

	wire id_is_shift = (id_funct3[1:0] == 2'b01) & (id_is_rtype | id_is_itype);
	wire id_is_addr  = (id_funct3[2:0] == 3'b000) & id_is_rtype & ~id_is_mul;
	wire id_is_addi  = (id_funct3[2:0] == 3'b000) & id_is_itype;
	wire id_is_comp  = (id_funct3[2:1] == 2'b01) & (id_is_rtype | id_is_itype);
	wire id_is_logic = id_funct3[2] & (id_is_rtype | id_is_itype) & ~id_is_shift;
	wire id_is_def   = ~(id_is_btype | id_is_addr | id_is_addi | id_is_comp | id_is_logic | id_is_mul);

	wire [2:0] id_aluop = ({3{id_is_addr}}  & {id_funct7[5], 2'b10}) |
	                      ({3{id_is_addi}}  & 3'b010) |
	                      ({3{id_is_logic}} & {(id_funct3[2] ^ id_funct3[1]), 1'b0,
	                                            (id_funct3[1] ^ id_funct3[0])}) |
	                      ({3{id_is_comp}}  & {~id_funct3[0], 2'b11}) |
	                      ({3{id_is_btype}} & {~id_funct3[2] | ~id_funct3[1],
	                                            1'b1, id_funct3[2] | id_funct3[1]}) |
	                      ({3{id_is_def}}   & 3'b010);
	wire [1:0] id_shiftop = {id_funct7[5], id_funct3[2]};

	wire id_known = id_is_lui | id_is_auipc | id_is_jal | id_is_jalr | id_is_btype |
	                id_is_ltype | id_is_stype | id_is_itype | id_is_rtype;
	wire id_reg_write = id_known & ~(id_is_stype | id_is_btype);
	wire id_uses_rs1 = id_is_rtype | id_is_itype | id_is_stype | id_is_btype |
	                   id_is_ltype | id_is_jalr;
	wire id_uses_rs2 = id_is_rtype | id_is_stype | id_is_btype;

	wire [31:0] rf_rdata1;
	wire [31:0] rf_rdata2;
	wire [31:0] mem_wb_pc;
	wire [31:0] mem_wb_wdata;
	wire [4:0]  mem_wb_rd;
	wire        mem_wb_reg_write;

	wire wb_rf_wen = mem_wb_valid & mem_wb_reg_write;
	wire id_rs1_wb_hit = wb_rf_wen & (mem_wb_rd != 5'd0) & (mem_wb_rd == id_rs1);
	wire id_rs2_wb_hit = wb_rf_wen & (mem_wb_rd != 5'd0) & (mem_wb_rd == id_rs2);
	wire [31:0] id_rdata1 = ({32{id_rs1_wb_hit}} & mem_wb_wdata) |
	                        ({32{~id_rs1_wb_hit}} & rf_rdata1);
	wire [31:0] id_rdata2 = ({32{id_rs2_wb_hit}} & mem_wb_wdata) |
	                        ({32{~id_rs2_wb_hit}} & rf_rdata2);

	reg_file u_rf (
		.clk    (clk),
		.waddr  (mem_wb_rd),
		.raddr1 (id_rs1),
		.raddr2 (id_rs2),
		.wen    (wb_rf_wen),
		.wdata  (mem_wb_wdata),
		.rdata1 (rf_rdata1),
		.rdata2 (rf_rdata2)
	);

	// ID/EX
	wire [ID_EX_BUS_WIDTH-1:0] id_ex_bus;
	wire [31:0] id_ex_pc;
	wire [31:0] id_ex_pred_pc;
	wire        id_ex_pred_taken;
	wire [GHR_BITS-1:0] id_ex_pred_ghr;
	wire [31:0] id_ex_rdata1;
	wire [31:0] id_ex_rdata2;
	wire [31:0] id_ex_imm;
	wire [4:0]  id_ex_shamt;
	wire [2:0]  id_ex_aluop;
	wire [1:0]  id_ex_shiftop;
	wire [2:0]  id_ex_funct3;
	wire [4:0]  id_ex_rs1;
	wire [4:0]  id_ex_rs2;
	wire [4:0]  id_ex_rd;
	wire        id_ex_is_rtype;
	wire        id_ex_is_itype;
	wire        id_ex_is_stype;
	wire        id_ex_is_btype;
	wire        id_ex_is_ltype;
	wire        id_ex_is_lui;
	wire        id_ex_is_auipc;
	wire        id_ex_is_jal;
	wire        id_ex_is_jalr;
	wire        id_ex_is_shift;
	wire        id_ex_is_mul;
	wire        id_ex_reg_write;
	wire        id_ex_uses_rs1;
	wire        id_ex_uses_rs2;

	assign {id_ex_pc, id_ex_pred_pc, id_ex_pred_taken, id_ex_pred_ghr,
	        id_ex_rdata1, id_ex_rdata2, id_ex_imm, id_ex_shamt, id_ex_aluop,
	        id_ex_shiftop, id_ex_funct3, id_ex_rs1, id_ex_rs2, id_ex_rd,
	        id_ex_is_rtype, id_ex_is_itype, id_ex_is_stype, id_ex_is_btype,
	        id_ex_is_ltype, id_ex_is_lui, id_ex_is_auipc, id_ex_is_jal,
	        id_ex_is_jalr, id_ex_is_shift, id_ex_is_mul, id_ex_reg_write,
	        id_ex_uses_rs1, id_ex_uses_rs2} = id_ex_bus;

	wire [31:0] ex_mem_pc;
	wire [31:0] ex_mem_alu_result;
	wire [31:0] ex_mem_shift_result;
	wire [31:0] ex_mem_mul_result;
	wire [31:0] ex_mem_pc_plus4;
	wire [31:0] ex_mem_store_data;
	wire [2:0]  ex_mem_funct3;
	wire [4:0]  ex_mem_rd;
	wire        ex_mem_is_ltype;
	wire        ex_mem_is_stype;
	wire        ex_mem_is_shift;
	wire        ex_mem_is_mul;
	wire        ex_mem_is_jal;
	wire        ex_mem_is_jalr;
	wire        ex_mem_reg_write;

	wire load_use_ex = id_ex_valid & id_ex_is_ltype & (id_ex_rd != 5'd0) &
	                   ((id_uses_rs1 & (id_rs1 == id_ex_rd)) |
	                    (id_uses_rs2 & (id_rs2 == id_ex_rd)));
	wire load_use_mem = ex_mem_valid & ex_mem_is_ltype & (ex_mem_rd != 5'd0) &
	                    ((id_uses_rs1 & (id_rs1 == ex_mem_rd)) |
	                     (id_uses_rs2 & (id_rs2 == ex_mem_rd)));
	wire id_load_use_stall = if_id_valid & (load_use_ex | load_use_mem);
	wire id_readygo = ~id_load_use_stall;
	assign if_id_allowin = ~if_id_valid | id_fire | ex_redirect;
	assign id_fire = if_id_valid & id_readygo & id_ex_allowin & ~ex_redirect;

	wire [ID_EX_BUS_WIDTH-1:0] id_to_ex_bus =
		{if_id_pc, if_id_pred_pc, if_id_pred_taken, if_id_pred_ghr,
		 id_rdata1, id_rdata2, id_imm, id_shamt, id_aluop, id_shiftop, id_funct3,
		 id_rs1, id_rs2, id_rd, id_is_rtype, id_is_itype, id_is_stype,
		 id_is_btype, id_is_ltype, id_is_lui, id_is_auipc, id_is_jal,
		 id_is_jalr, id_is_shift, id_is_mul, id_reg_write, id_uses_rs1, id_uses_rs2};

	pipeline_reg #(.BUS_WIDTH(ID_EX_BUS_WIDTH)) u_id_ex_reg (
		.clk       (clk),
		.rst       (rst),
		.flush     (1'b0),
		.allowin   (id_ex_allowin),
		.in_valid  (id_fire),
		.in_bus    (id_to_ex_bus),
		.out_valid (id_ex_valid),
		.out_bus   (id_ex_bus)
	);

	// EX : forwarding, ALU/shifter/MUL, branch resolution.
	wire [31:0] ex_mem_wb_value = ({32{ex_mem_is_mul}} & ex_mem_mul_result) |
	                              ({32{ex_mem_is_shift}} & ex_mem_shift_result) |
	                              ({32{ex_mem_is_jal | ex_mem_is_jalr}} & ex_mem_pc_plus4) |
	                              ({32{~(ex_mem_is_mul | ex_mem_is_shift |
	                                      ex_mem_is_jal | ex_mem_is_jalr)}} & ex_mem_alu_result);

	wire [1:0] forward_a;
	wire [1:0] forward_b;

	forward_unit u_forward_unit (
		.ex_uses_rs1  (id_ex_uses_rs1),
		.ex_uses_rs2  (id_ex_uses_rs2),
		.ex_rs1       (id_ex_rs1),
		.ex_rs2       (id_ex_rs2),
		.mem_valid    (ex_mem_valid),
		.mem_reg_write(ex_mem_reg_write),
		.mem_is_load  (ex_mem_is_ltype),
		.mem_rd       (ex_mem_rd),
		.wb_valid     (mem_wb_valid),
		.wb_reg_write (mem_wb_reg_write),
		.wb_rd        (mem_wb_rd),
		.forward_a    (forward_a),
		.forward_b    (forward_b)
	);

	wire [31:0] ex_forward_rdata1 = ({32{forward_a == 2'b01}} & ex_mem_wb_value) |
	                                ({32{forward_a == 2'b10}} & mem_wb_wdata) |
	                                ({32{forward_a == 2'b00}} & id_ex_rdata1);
	wire [31:0] ex_forward_rdata2 = ({32{forward_b == 2'b01}} & ex_mem_wb_value) |
	                                ({32{forward_b == 2'b10}} & mem_wb_wdata) |
	                                ({32{forward_b == 2'b00}} & id_ex_rdata2);

	reg        ex_operand_hold_valid;
	reg [31:0] ex_operand_hold_rdata1;
	reg [31:0] ex_operand_hold_rdata2;

	wire [31:0] ex_rdata1 = ({32{ex_operand_hold_valid}} & ex_operand_hold_rdata1) |
	                        ({32{~ex_operand_hold_valid}} & ex_forward_rdata1);
	wire [31:0] ex_rdata2 = ({32{ex_operand_hold_valid}} & ex_operand_hold_rdata2) |
	                        ({32{~ex_operand_hold_valid}} & ex_forward_rdata2);

	always @(posedge clk) begin
		if (rst) begin
			ex_operand_hold_valid  <= 1'b0;
			ex_operand_hold_rdata1 <= 32'd0;
			ex_operand_hold_rdata2 <= 32'd0;
		end
		else if (mem_allowin) begin
			ex_operand_hold_valid  <= 1'b0;
			ex_operand_hold_rdata1 <= 32'd0;
			ex_operand_hold_rdata2 <= 32'd0;
		end
		else if (id_ex_valid & ~ex_operand_hold_valid) begin
			ex_operand_hold_valid  <= 1'b1;
			ex_operand_hold_rdata1 <= ex_forward_rdata1;
			ex_operand_hold_rdata2 <= ex_forward_rdata2;
		end
	end

	wire ex_a_pc  = id_ex_is_auipc | id_ex_is_jal;
	wire ex_a_reg = id_ex_is_itype | id_ex_is_rtype | id_ex_is_jalr |
	                id_ex_is_ltype | id_ex_is_stype | id_ex_is_btype;
	wire ex_b_reg = id_ex_is_rtype | id_ex_is_btype;
	wire ex_b_imm = id_ex_is_lui | id_ex_is_auipc | id_ex_is_jal | id_ex_is_jalr |
	                id_ex_is_itype | id_ex_is_ltype | id_ex_is_stype;

	wire [31:0] ex_alu_a = ({32{ex_a_pc}} & id_ex_pc) |
	                       ({32{ex_a_reg}} & ex_rdata1);
	wire [31:0] ex_alu_b = ({32{ex_b_reg}} & ex_rdata2) |
	                       ({32{ex_b_imm}} & id_ex_imm);

	wire [31:0] ex_alu_result_raw;
	wire        ex_alu_zero;
	wire        ex_alu_overflow;
	wire        ex_alu_carryout;

	alu u_alu (
		.A        (ex_alu_a),
		.B        (ex_alu_b),
		.ALUop    (id_ex_aluop),
		.Overflow (ex_alu_overflow),
		.CarryOut (ex_alu_carryout),
		.Zero     (ex_alu_zero),
		.Result   (ex_alu_result_raw)
	);

	wire [4:0] ex_shift_b = ({5{id_ex_is_itype}} & id_ex_shamt) |
	                        ({5{~id_ex_is_itype}} & ex_rdata2[4:0]);
	wire [31:0] ex_shift_result;

	shifter u_shifter (
		.A       (ex_rdata1),
		.B       (ex_shift_b),
		.Shiftop (id_ex_shiftop),
		.Result  (ex_shift_result)
	);

	wire [31:0] ex_mul_result = ex_rdata1 * ex_rdata2;
	wire [31:0] ex_pc_plus4 = id_ex_pc + 32'd4;
	wire [31:0] ex_branch_target = id_ex_pc + id_ex_imm;
	wire [31:0] ex_jalr_target = ex_alu_result_raw & 32'hffff_fffe;

	wire ex_beq  = id_ex_is_btype & (id_ex_funct3 == 3'b000);
	wire ex_bne  = id_ex_is_btype & (id_ex_funct3 == 3'b001);
	wire ex_blt  = id_ex_is_btype & (id_ex_funct3 == 3'b100);
	wire ex_bge  = id_ex_is_btype & (id_ex_funct3 == 3'b101);
	wire ex_bltu = id_ex_is_btype & (id_ex_funct3 == 3'b110);
	wire ex_bgeu = id_ex_is_btype & (id_ex_funct3 == 3'b111);

	wire ex_branch_taken = id_ex_is_btype & ((ex_beq & ex_alu_zero) |
	                        (ex_bne & ~ex_alu_zero) |
	                        (ex_blt & ex_alu_result_raw[0]) |
	                        (ex_bge & ~ex_alu_result_raw[0]) |
	                        (ex_bltu & ex_alu_result_raw[0]) |
	                        (ex_bgeu & ~ex_alu_result_raw[0]));
	wire ex_actual_taken = id_ex_is_jal | id_ex_is_jalr | ex_branch_taken;
	wire [31:0] ex_taken_target = ({32{id_ex_is_jalr}} & ex_jalr_target) |
	                              ({32{~id_ex_is_jalr}} & ex_branch_target);
	wire [31:0] ex_actual_next_pc = ({32{ex_actual_taken}} & ex_taken_target) |
	                                ({32{~ex_actual_taken}} & ex_pc_plus4);

	assign ex_redirect = ex_fire & (ex_actual_next_pc != id_ex_pred_pc);
	assign ex_redirect_pc = ex_actual_next_pc;

	wire [31:0] ex_alu_result = ({32{id_ex_is_jalr}} & ex_jalr_target) |
	                            ({32{~id_ex_is_jalr}} & ex_alu_result_raw);

	assign id_ex_allowin = ~id_ex_valid | mem_allowin;
	assign ex_fire = id_ex_valid & mem_allowin;

	wire [EX_MEM_BUS_WIDTH-1:0] ex_to_mem_bus =
		{id_ex_pc, ex_alu_result, ex_shift_result, ex_mul_result, ex_pc_plus4,
		 ex_rdata2, id_ex_funct3, id_ex_rd, id_ex_is_ltype, id_ex_is_stype,
		 id_ex_is_shift, id_ex_is_mul, id_ex_is_jal, id_ex_is_jalr, id_ex_reg_write};

	wire [EX_MEM_BUS_WIDTH-1:0] ex_mem_bus;

	pipeline_reg #(.BUS_WIDTH(EX_MEM_BUS_WIDTH)) u_ex_mem_reg (
		.clk       (clk),
		.rst       (rst),
		.flush     (1'b0),
		.allowin   (mem_allowin),
		.in_valid  (ex_fire),
		.in_bus    (ex_to_mem_bus),
		.out_valid (ex_mem_valid),
		.out_bus   (ex_mem_bus)
	);

	assign {ex_mem_pc, ex_mem_alu_result, ex_mem_shift_result, ex_mem_mul_result,
	        ex_mem_pc_plus4, ex_mem_store_data, ex_mem_funct3, ex_mem_rd,
	        ex_mem_is_ltype, ex_mem_is_stype, ex_mem_is_shift, ex_mem_is_mul,
	        ex_mem_is_jal, ex_mem_is_jalr, ex_mem_reg_write} = ex_mem_bus;

	// Gshare predictor training in EX.
	wire ex_is_control = id_ex_is_btype | id_ex_is_jal | id_ex_is_jalr;
	wire [GHR_BITS-1:0] ex_pc_index = id_ex_pc[GHR_BITS+1:2];
	wire [GHR_BITS-1:0] ex_train_index = ex_pc_index ^ id_ex_pred_ghr;
	wire [1:0] pht_old = pht[ex_train_index];
	reg [1:0] pht_next;

	always @(*) begin
		if (ex_actual_taken) begin
			if (pht_old == 2'b11)
				pht_next = 2'b11;
			else
				pht_next = pht_old + 2'b01;
		end
		else begin
			if (pht_old == 2'b00)
				pht_next = 2'b00;
			else
				pht_next = pht_old - 2'b01;
		end
	end

	integer pred_i;
	always @(posedge clk) begin
		if (rst) begin
			ghr <= {GHR_BITS{1'b0}};
			for (pred_i = 0; pred_i < PRED_ENTRIES; pred_i = pred_i + 1) begin
				pht[pred_i]       = 2'b01;
				btb_valid[pred_i] = 1'b0;
				btb_tag[pred_i]   = {BTB_TAG_BITS{1'b0}};
				btb_target[pred_i] = 32'd0;
			end
		end
		else if (ex_fire & ex_is_control) begin
			pht[ex_train_index] <= pht_next;
			ghr <= {ghr[GHR_BITS-2:0], ex_actual_taken};
			if (ex_actual_taken) begin
				btb_valid[ex_pc_index]  <= 1'b1;
				btb_tag[ex_pc_index]    <= id_ex_pc[31:GHR_BITS+2];
				btb_target[ex_pc_index] <= ex_actual_next_pc;
			end
		end
	end

	// MEM stage: blocking memory handshake.
	reg        mem_req_done;
	reg        mem_load_done;
	reg [31:0] mem_load_data_r;

	wire mem_req_needed = ex_mem_valid & (ex_mem_is_ltype | ex_mem_is_stype) & ~mem_req_done;
	wire mem_req_handshake = mem_req_needed & Mem_Req_Ready;
	wire mem_req_done_w = mem_req_done | mem_req_handshake;
	wire mem_wait_load_data = ex_mem_valid & ex_mem_is_ltype & mem_req_done_w & ~mem_load_done;
	wire mem_load_handshake = mem_wait_load_data & Read_data_Valid;
	wire mem_load_done_w = mem_load_done | mem_load_handshake;
	wire mem_readygo = ~ex_mem_valid |
	                   ~(ex_mem_is_ltype | ex_mem_is_stype) |
	                   (ex_mem_is_stype & mem_req_done_w) |
	                   (ex_mem_is_ltype & mem_req_done_w & mem_load_done_w);

	assign mem_allowin = ~ex_mem_valid | mem_readygo;
	assign mem_fire = ex_mem_valid & mem_readygo;

	always @(posedge clk) begin
		if (rst) begin
			mem_req_done    <= 1'b0;
			mem_load_done   <= 1'b0;
			mem_load_data_r <= 32'd0;
		end
		else if (mem_allowin) begin
			mem_req_done    <= 1'b0;
			mem_load_done   <= 1'b0;
			mem_load_data_r <= 32'd0;
		end
		else begin
			if (mem_req_handshake)
				mem_req_done <= 1'b1;
			if (mem_load_handshake) begin
				mem_load_done   <= 1'b1;
				mem_load_data_r <= Read_data;
			end
		end
	end

	wire [1:0] mem_addr_offset = ex_mem_alu_result[1:0];
	wire mem_sb = ex_mem_is_stype & (ex_mem_funct3 == 3'b000);
	wire mem_sh = ex_mem_is_stype & (ex_mem_funct3 == 3'b001);
	wire mem_sw = ex_mem_is_stype & (ex_mem_funct3 == 3'b010);

	wire [3:0] mem_sh_strb = ({4{~mem_addr_offset[1]}} & 4'b0011) |
	                         ({4{mem_addr_offset[1]}} & 4'b1100);

	assign Address = {ex_mem_alu_result[31:2], 2'b00};
	assign MemRead = ex_mem_valid & ex_mem_is_ltype & ~mem_req_done;
	assign MemWrite = ex_mem_valid & ex_mem_is_stype & ~mem_req_done;
	assign Write_data = ({32{mem_sw}} & ex_mem_store_data) |
	                    ({32{mem_sh}} & ({16'd0, ex_mem_store_data[15:0]} << (16 * mem_addr_offset[1]))) |
	                    ({32{mem_sb}} & ({24'd0, ex_mem_store_data[7:0]} << (8 * mem_addr_offset)));
	assign Write_strb = ({4{mem_sw}} & 4'b1111) |
	                    ({4{mem_sh}} & mem_sh_strb) |
	                    ({4{mem_sb}} & (4'b0001 << mem_addr_offset));
	assign Read_data_Ready = mem_wait_load_data;

	wire [31:0] mem_read_word = ({32{mem_load_done}} & mem_load_data_r) |
	                            ({32{~mem_load_done}} & Read_data);
	wire mem_lb = ex_mem_is_ltype & (ex_mem_funct3[1:0] == 2'b00);
	wire mem_lh = ex_mem_is_ltype & (ex_mem_funct3[1:0] == 2'b01);
	wire mem_lw = ex_mem_is_ltype & (ex_mem_funct3[1:0] == 2'b10);
	wire [15:0] mem_lh_data = ({16{~mem_addr_offset[1]}} & mem_read_word[15:0]) |
	                          ({16{mem_addr_offset[1]}} & mem_read_word[31:16]);
	wire [7:0] mem_lb_data = ({8{mem_addr_offset == 2'b00}} & mem_read_word[7:0]) |
	                         ({8{mem_addr_offset == 2'b01}} & mem_read_word[15:8]) |
	                         ({8{mem_addr_offset == 2'b10}} & mem_read_word[23:16]) |
	                         ({8{mem_addr_offset == 2'b11}} & mem_read_word[31:24]);
	wire [31:0] mem_load_data = ({32{mem_lw}} & mem_read_word) |
	                            ({32{mem_lh}} & {{16{~ex_mem_funct3[2] & mem_lh_data[15]}}, mem_lh_data}) |
	                            ({32{mem_lb}} & {{24{~ex_mem_funct3[2] & mem_lb_data[7]}}, mem_lb_data});
	wire [31:0] mem_stage_wdata = ({32{ex_mem_is_ltype}} & mem_load_data) |
	                              ({32{~ex_mem_is_ltype}} & ex_mem_wb_value);

	// MEM/WB pipeline register and commit interface.
	wire [MEM_WB_BUS_WIDTH-1:0] mem_to_wb_bus =
		{ex_mem_pc, mem_stage_wdata, ex_mem_rd, ex_mem_reg_write};
	wire [MEM_WB_BUS_WIDTH-1:0] mem_wb_bus;

	pipeline_reg #(.BUS_WIDTH(MEM_WB_BUS_WIDTH)) u_mem_wb_reg (
		.clk       (clk),
		.rst       (rst),
		.flush     (1'b0),
		.allowin   (1'b1),
		.in_valid  (mem_fire),
		.in_bus    (mem_to_wb_bus),
		.out_valid (mem_wb_valid),
		.out_bus   (mem_wb_bus)
	);

	assign {mem_wb_pc, mem_wb_wdata, mem_wb_rd, mem_wb_reg_write} = mem_wb_bus;
	assign inst_retire = ({70{mem_wb_valid & mem_wb_reg_write}} &
	                      {1'b1, mem_wb_rd, mem_wb_wdata, mem_wb_pc});

	// Performance counters.
	reg [31:0] cnt_cycle;
	reg [31:0] cnt_retire;
	reg [31:0] cnt_mem_req;

	always @(posedge clk) begin
		if (rst) begin
			cnt_cycle   <= 32'd0;
			cnt_retire  <= 32'd0;
			cnt_mem_req <= 32'd0;
		end
		else begin
			cnt_cycle <= cnt_cycle + 32'd1;
			if (mem_wb_valid)
				cnt_retire <= cnt_retire + 32'd1;
			if (mem_req_handshake)
				cnt_mem_req <= cnt_mem_req + 32'd1;
		end
	end

	assign cpu_perf_cnt_0  = cnt_cycle;
	assign cpu_perf_cnt_1  = cnt_retire;
	assign cpu_perf_cnt_2  = cnt_mem_req;
	assign cpu_perf_cnt_3  = 32'd0;
	assign cpu_perf_cnt_4  = 32'd0;
	assign cpu_perf_cnt_5  = 32'd0;
	assign cpu_perf_cnt_6  = 32'd0;
	assign cpu_perf_cnt_7  = 32'd0;
	assign cpu_perf_cnt_8  = 32'd0;
	assign cpu_perf_cnt_9  = 32'd0;
	assign cpu_perf_cnt_10 = 32'd0;
	assign cpu_perf_cnt_11 = 32'd0;
	assign cpu_perf_cnt_12 = 32'd0;
	assign cpu_perf_cnt_13 = 32'd0;
	assign cpu_perf_cnt_14 = 32'd0;
	assign cpu_perf_cnt_15 = 32'd0;

endmodule
