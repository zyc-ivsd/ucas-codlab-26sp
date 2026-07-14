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

/* The following signal is leveraged for behavioral simulation,
* which is delivered to testbench.
*
* STUDENTS MUST CONTROL LOGICAL BEHAVIORS of THIS SIGNAL.
*
* inst_retired (70-bit): detailed information of the retired instruction,
* mainly including (in order)
* {
*   reg_file write-back enable  (69:69,  1-bit),
*   reg_file write-back address (68:64,  5-bit),
*   reg_file write-back data    (63:32, 32-bit),
*   retired PC                  (31: 0, 32-bit)
* }
*
*/
// ==================================================
// Section 1: define Instruction type according to opcode7
	localparam LUI   = 7'b0110111;   
	localparam AUIpc = 7'b0010111;   
	localparam JAL   = 7'b1101111;   
	localparam JALR  = 7'b1100111;   
	localparam B_TYPE = 7'b1100011;  
	localparam L_TYPE = 7'b0000011;  
	localparam S_TYPE = 7'b0100011;  
	localparam I_TYPE = 7'b0010011;  
	localparam R_TYPE = 7'b0110011;  

// define 9 state of FSM (one-hot):
	localparam
		INIT = 9'b000000001, INIT_ = 0,
		IF = 9'b000000010, IF_ = 1,
		IW = 9'b000000100, IW_ = 2,
		ID = 9'b000001000, ID_ = 3,
		EX = 9'b000010000, EX_ = 4,
		LD  = 9'b000100000, LD_ = 5,
		RDW = 9'b001000000, RDW_ = 6,
		ST = 9'b010000000, ST_ = 7,
		WB = 9'b100000000, WB_ = 8;
		

	reg [8:0] current_state, next_state;
	initial current_state = INIT;
// =========================================

// Section 2: PC
	reg [31:0] pc_reg;
	reg [31:0] pc_plus4;
	wire [31:0] pc_next;
	wire [31:0] pc_seq;
	wire  branch_taken;
// ======================================

// Section 3: decode instruction
	wire [6:0] opcode;
	wire [4:0] rd;
	wire [2:0] funct3;
	wire [6:0] funct7;
	wire [4:0] rs1, rs2, shamt;
	wire [31:0] imm;
// =================================

// Section 4: execution
	wire [31:0] alu_a, alu_b;
	wire [31:0] alu_res;
	wire [1:0]  addr_offset;
	wire [2:0]  aluop;
	wire        zero;
	wire [1:0]  shiftop;
	wire [31:0] shift_res;
	wire [4:0]  shift_b;
// =====================================

// Section 5: reg_file
	wire [31:0] rdata1, rdata2;
// ==================================

// Section 6: registers
	reg [31:0] aluout;
	reg [31:0] a_reg;
	reg [31:0] b_reg;
	reg [31:0] inst_reg;
	reg [31:0] Mdr;
	reg [31:0] pc_old; 
// ================================

// Section 7: load
	wire [31:0] load_data;
	wire [15:0] lh_data;
	wire [7:0]  lb_data;
// ============================

// Section 8: write back
	wire [31:0] data_wb;
// ===============================

// Section 9: control signals
	wire a_pc,a_from_reg,a_pc_old;
	wire b_four,b_imm,b_form_reg;
	wire RegWrite;
	wire pc_from_alures,pc_from_aluout; 
	wire  MemtoReg;
	wire PCwrite;
	wire PCwriteCond;
	wire IRwrite;
	wire is_shift;
// ==================================================

// Section 10: instruction type signals
	wire uimm, jalimm, jalrimm, stimm, bimm;
	wire is_lui, is_auipc, is_ltype, is_stype, is_itype, is_rtype;
	wire is_comp,is_logic;
	wire is_addr, is_addi, is_def;
	wire beq, bne, blt, bge, bltu, bgeu;
	wire sb, sh, sw, lb, lh, lw;
	wire is_jal, is_jalr, is_btype;
	wire lh_high,lh_low,lb_one,lb_two,lb_three,lb_four;
	wire fini_inst;
// ==================================================


// PART 1: Instruction decode / ======

	assign opcode = inst_reg[6:0];
	assign rd = inst_reg[11:7];
	assign rs1 = inst_reg[19:15];
	assign rs2 = inst_reg[24:20];
	assign shamt = inst_reg[24:20];
	assign funct3 = inst_reg[14:12];
	assign funct7 = inst_reg[31:25];

	// Immediate generation
	assign uimm = (opcode == LUI || opcode == AUIpc);
	assign jalimm = (opcode == JAL);
	assign jalrimm= (opcode == JALR || opcode == L_TYPE || opcode == I_TYPE);
	assign stimm = (opcode == S_TYPE);
	assign bimm = (opcode == B_TYPE);

	assign imm = ({32{uimm}} & {inst_reg[31:12], 12'b0}) |
	             ({32{jalimm}} & {{11{inst_reg[31]}}, inst_reg[31], inst_reg[19:12], inst_reg[20], inst_reg[30:21], 1'b0}) |
	             ({32{jalrimm}}& {{20{inst_reg[31]}},inst_reg[31:20]}) |
	             ({32{stimm}} & {{20{inst_reg[31]}}, inst_reg[31:25], inst_reg[11:7]}) |
	             ({32{bimm}} & {{19{inst_reg[31]}}, inst_reg[31], inst_reg[7], inst_reg[30:25], inst_reg[11:8], 1'b0}) |
	             32'd0;

	// Instruction type identification
	assign is_lui   = (opcode == LUI);
	assign is_auipc = (opcode == AUIpc);
	assign is_jal   = (opcode == JAL);
	assign is_jalr  = (opcode == JALR);
	assign is_btype = (opcode == B_TYPE);
	assign is_ltype = (opcode == L_TYPE);
	assign is_stype = (opcode == S_TYPE);
	assign is_itype = (opcode == I_TYPE);
	assign is_rtype = (opcode == R_TYPE);

	// ALU operation encoding
	assign is_shift = (funct3[1:0] == 2'b01) & (is_rtype | is_itype);
	assign is_addr  = (funct3[2:0] == 3'b000) & is_rtype;
	assign is_addi  = (funct3[2:0] == 3'b000) & is_itype;
	assign is_comp  = (funct3[2:1] == 2'b01) & (is_rtype | is_itype);
	assign is_logic = (funct3[2] == 1'b1) & (is_rtype | is_itype) & ~is_shift;
	assign is_def   = ~(is_btype | is_addr | is_addi | is_comp | is_logic);

	assign aluop = ({3{is_addr & current_state[EX_]}}  & {funct7[5], 2'b10}) |
	               ({3{is_addi & current_state[EX_]}}  & 3'b010) |
	               ({3{is_logic & current_state[EX_]}} & {(funct3[2] ^ funct3[1]), 1'b0, (funct3[1] ^ funct3[0])}) |
	               ({3{is_comp & current_state[EX_]}}  & {~funct3[0], 2'b11}) |
	               ({3{is_btype & current_state[EX_]}} & {~funct3[2] | ~funct3[1], 1'b1, funct3[2] | funct3[1]}) |
				   ({3{current_state[IF_]}} & 3'b010) |
				   ({3{current_state[ID_] & is_btype}} & 3'b010) |
	               ({3{is_def}} & 3'b010);
	// IF ->PC+4  ---> add ,      ID -> pc+branch --->add,  EX-> inst

	// Shift operation
	assign shiftop = {funct7[5], funct3[2]};

	// Branch type
	assign beq  = is_btype & (funct3 == 3'b000);
	assign bne  = is_btype & (funct3 == 3'b001);
	assign blt  = is_btype & (funct3 == 3'b100);
	assign bge  = is_btype & (funct3 == 3'b101);
	assign bltu = is_btype & (funct3 == 3'b110);
	assign bgeu = is_btype & (funct3 == 3'b111);

	// Store type
	assign sb = is_stype & (funct3 == 3'b000);
	assign sh = is_stype & (funct3 == 3'b001);
	assign sw = is_stype & (funct3 == 3'b010);

	// Load type
	assign lb = is_ltype & (funct3[1:0] == 2'b00);
	assign lh = is_ltype & (funct3[1:0] == 2'b01);
	assign lw = is_ltype & (funct3[1:0] == 2'b10);




// PART 2: FSM=============================

	always @(posedge clk) begin
		if (rst)
			current_state <= INIT;
		else
			current_state <= next_state;
	end

	always @(*) begin
		case(current_state)
			INIT:begin
				if(!rst) next_state = IF;
				else next_state = INIT;
			end
			IF:begin
				if(Inst_Req_Ready) next_state = IW;
				else next_state = IF;
			end
			IW:begin
				if(Inst_Valid) next_state = ID;
				else next_state = IW;
			end
			ID:begin
				next_state = EX;
			end
			EX:begin
				if(is_btype) next_state = IF;
				else if(is_rtype | is_jal | is_jalr|is_lui | is_auipc | is_itype) next_state = WB;
				else if(is_stype) next_state = 	ST;
				else if(is_ltype) next_state = LD;
				else next_state = IF;
			end
			ST:begin
				if(Mem_Req_Ready) next_state = IF;
				else next_state = ST;
			end
			LD:begin
				if(Mem_Req_Ready) next_state = RDW; 
				else next_state = LD;
			end
			RDW:begin 
				if(Read_data_Valid) next_state = WB;
				else next_state = RDW;
			end
			WB:begin
				next_state = IF;
			end
			default: next_state = INIT;
		endcase
	end

	assign Inst_Ready = current_state[INIT_] | current_state[IW_];
	assign Read_data_Ready = current_state[INIT_] | current_state[RDW_];
	assign Inst_Req_Valid = current_state[IF_];
	assign MemRead  = current_state[LD_];
	assign MemWrite = current_state[ST_];
	assign MemtoReg = current_state[WB_];
	assign RegWrite = current_state[WB_];

// PART 3: Control signal ==========

	//pcsource
	assign pc_from_alures = current_state[EX_] & (is_jal | is_jalr);
	assign pc_from_aluout = (is_btype & branch_taken) & current_state[EX_];
	assign PCwrite = (current_state[EX_] & (is_jal | is_jalr | is_btype))|
					 (current_state[WB_] & ~(is_jal | is_jalr))|
					 current_state[ST_];

	// ALUSrcA: 
	assign a_pc = ((is_auipc | is_jal) & current_state[EX_]) | current_state[IF_];
	assign a_from_reg = (is_itype | is_rtype | is_jalr |is_ltype|is_stype|is_btype) & current_state[EX_];
	assign a_pc_old = is_btype & current_state[ID_];

	// ALUSrcB: 
	assign b_form_reg = (is_rtype | is_btype) & current_state[EX_];
	assign b_four = current_state[IF_];
	assign b_imm = ((is_auipc| is_jal | is_jalr | is_itype | is_ltype | is_stype) & current_state[EX_]) | 
					(is_btype & current_state[ID_]);

	

// PART 4: PC logic=============================
	always @(posedge clk) begin
		if (rst)
			pc_reg <= 32'd0;
		else if (PCwrite)
			pc_reg <= pc_next;
	end
	// Save current pc for branch : 
	always @(posedge clk) begin
		if (rst) begin
			pc_old <= 32'd0;
			pc_plus4 <= 32'd0;
		end
		else if (current_state[IF_]) begin
			pc_old <= pc_reg;
			pc_plus4 <= alu_res;
		end
	end

	assign PC = pc_reg;
	assign pc_seq = pc_plus4;
	assign pc_next = ({32{pc_from_aluout}} & aluout) |
					 ({32{pc_from_alures}} & exec_result) |
					 ({32{~(pc_from_aluout | pc_from_alures)}} & pc_seq);



// PART 5: ALU input ==========================
	
	assign alu_a = ({32{a_pc}} & pc_reg) | 
					({32{a_pc_old}} & pc_old) | 
					({32{a_from_reg}} & a_reg) |
					32'd0;
	
	assign alu_b = ({32{b_form_reg}} & b_reg) |
					({32{b_imm}} & imm) |
					({32{b_four}} & 32'd4)|
					32'd0;

	// Shifter B input
	assign shift_b = (is_shift & is_rtype) ? b_reg[4:0] : shamt;


// PART 6: Branch =================================

	assign branch_taken = is_btype & ((beq & zero) |
		(bne & ~zero) | (blt & alu_res[0]) | (bge & ~alu_res[0]) |
		(bltu & alu_res[0]) | (bgeu & ~alu_res[0]));

// PART 7: Memory ==============================
	assign addr_offset = aluout[1:0];
	assign Address =  {aluout[31:2] , 2'b00};
		
	// Store data 
	assign Write_data = ({32{sw}} & b_reg) |
	                    ({32{sh}} & {16'd0, b_reg[15:0]} << (16 *addr_offset[1])) |
	                    ({32{sb}} & {24'd0, b_reg[7:0]}  << (8 *addr_offset)) |
	                    32'd0;

	// Write strb
	assign Write_strb = ({4{sw}} & 4'b1111) |
	                    ({4{sh}} & (addr_offset[1] ? 4'b1100 : 4'b0011)) |
	                    ({4{sb}} & (4'd1 << addr_offset)) |
	                    4'd0;	


// PART 8: Ld  =========================
	assign lh_high = addr_offset[1];
	assign lh_low = ~addr_offset[1];
	assign lb_one = addr_offset == 2'b00;
	assign lb_two = addr_offset == 2'b01;
	assign lb_three = addr_offset == 2'b10;
	assign lb_four = addr_offset == 2'b11;

	assign lh_data = ({16{lh_low}} & Mdr[15:0]) | ({16{lh_high}} & Mdr[31:16]);
	assign lb_data = ({8{lb_one}} & Mdr[7:0]) | ({8{lb_two}} & Mdr[15:8])|
					 ({8{lb_three}} & Mdr[23:16])| ({8{lb_four}} & Mdr[31:24]);


	assign load_data = ({32{lw}} & Mdr)|
					   ({32{lh}} & {{16{~funct3[2] & lh_data[15]}},lh_data})|
					   ({32{lb}} & {{24{~funct3[2] & lb_data[7]}},lb_data}) |
					   32'd0;

// PART 9: Wb  ===============================

	wire [31:0] pc_link;
	assign pc_link = pc_plus4;

	assign data_wb = ({32{is_jal | is_jalr}} & pc_link) |
					({32{is_lui}} & imm) |
					({32{is_auipc | is_rtype | is_itype | is_shift}} & aluout) |
					({32{is_ltype}} & load_data);


// PART 10: instance  ===========

	// Register file
	reg_file u_rf(
		.clk(clk),
		.waddr(rd),
		.raddr1(rs1),
		.raddr2(rs2),
		.wen(RegWrite),
		.wdata(data_wb),
		.rdata1(rdata1),
		.rdata2(rdata2)
	);

	// ALU
	alu u_alu(
		.A(alu_a),
		.B(alu_b),
		.ALUop(aluop),
		.Zero(zero),
		.Result(alu_res)
	);

	// Shifter
	shifter u_shift(
		.A(a_reg),
		.B(shift_b),
		.Shiftop(shiftop),
		.Result(shift_res)
	);


	wire [31:0] exec_result;
	assign exec_result = (current_state[EX_] & is_shift) ? shift_res : 
						(current_state[EX_] & is_jalr) ? alu_res & ~1 :
						alu_res ;

	always @(posedge clk)begin
		if(rst) Mdr <= 32'd0;
		else if(current_state[RDW_]) begin
			Mdr <= Read_data;
		end
	end

	always @(posedge clk)begin
		if(rst) a_reg <= 32'd0;
		else if(current_state[ID_]) begin
			a_reg <= rdata1; 
		end
	end

	always @(posedge clk)begin
		if(rst) b_reg <= 32'd0;
		else if(current_state[ID_]) begin
			b_reg <= rdata2; 
		end
	end

	always @(posedge clk)begin
		if(rst) aluout <= 32'd0;
		else if(current_state[EX_]) begin
			aluout <= exec_result;
		end
		else if(current_state[ID_] && is_btype) begin
			aluout <= exec_result;
		end
	end
	always @(posedge clk)begin
		if(rst) inst_reg <= 32'd0;
		else begin
			if(current_state[IW_] && Inst_Valid) inst_reg <= Instruction;
			else inst_reg <= inst_reg;
		end
	end




// PART 10: inst_retire  ========================================

	assign inst_retire= {RegWrite, rd, data_wb, pc_old};

// PART 11: Performance counters
	
	reg [31:0] cycle_cnt;
	always @(posedge clk) begin
		if (rst) cycle_cnt <= 32'd0;
		else  cycle_cnt <= cycle_cnt + 32'd1;
	end

	reg [31:0] cycle_mem_cnt;
	always @(posedge clk) begin
		if(rst) cycle_mem_cnt <= 32'd0; 
		else if(current_state[LD_] | current_state[RDW_] | current_state[ST_])
    		cycle_mem_cnt <= cycle_mem_cnt + 32'd1;
		else cycle_mem_cnt <= cycle_mem_cnt;
	end

	reg [31:0] retired_cnt;
	assign fini_inst = current_state[WB_] | current_state[ST_] | (is_btype & current_state[EX_]);

	always @(posedge clk) begin 
		if(rst) retired_cnt <= 32'd0;
		else if(fini_inst) retired_cnt <= retired_cnt + 32'd1;
		else retired_cnt <= retired_cnt;
	end

	assign cpu_perf_cnt_0  = cycle_cnt;   
	assign cpu_perf_cnt_1  = cycle_mem_cnt;  
	assign cpu_perf_cnt_2  = retired_cnt;
	

endmodule
