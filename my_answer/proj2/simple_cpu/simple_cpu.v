`timescale 10ns / 1ns

module simple_cpu(
	input             clk,
	input             rst,

	output [31:0]     PC,              // send to mem
	input  [31:0]     Instruction,     // end from mem 

	output [31:0]     Address,         // send to mem
	output            MemWrite,        // write enable
	output [31:0]     Write_data,      // send to mem to store
	output [ 3:0]     Write_strb,      // send to mem ,sel byte

	input  [31:0]     Read_data,       // read from mem
	output            MemRead          // read enable 
);

	// THESE THREE SIGNALS ARE USED IN OUR TESTBENCH
	// PLEASE DO NOT MODIFY SIGNAL NAMES
	// AND PLEASE USE THEM TO CONNECT PORTS
	// OF YOUR INSTANTIATION OF THE REGISTER FILE MODULE
	wire			RF_wen;
	wire [4:0]		RF_waddr;
	wire [31:0]		RF_wdata;

	// TODO: PLEASE ADD YOUR CODE BELOW
//------------------------------------------------------------------------
	// define Instruction type according to opcode7
	localparam LUI = 7'b0110111;      // load upper imm
	localparam AUIpc = 7'b0010111;    // add upper imm to pc
	localparam JAL = 7'b1101111;      //jump and link
	localparam JALR = 7'b1100111;     //jump and link reg
	localparam B_TYPE = 7'b1100011;   //branch
	localparam L_TYPE = 7'b0000011;   //load 
	localparam S_TYPE =  7'b0100011;   //store
	localparam I_TYPE = 7'b0010011;   //operate imm
	localparam R_TYPE = 7'b0110011;   //operate reg_data
//-------------------------------------------------------------------------
	//section 1: fetch Instruction 
	reg [31:0] pc;
	wire [31:0] pc_next;
	//section 2: decode Instruction
	wire [6:0] opcode;
	wire [4:0] rd;
	wire [2:0] funct3;
	wire [6:0] funct7;
	wire [4:0] rs1,rs2,shamt;
	wire [31:0] imm;
	wire [31:0] pc_plus4;
	wire [31:0] pc_branch;
	wire [31:0] pc_jal;
	wire [31:0] pc_jalr;
	//section 3: excute Instruction
	wire [31:0] alu_a,alu_b;
	wire [31:0] alu_res;
	wire [1:0] addr_offset;
	wire [2:0] aluop;
	wire zero;
	wire [1:0] shiftop;
	wire [31:0] shift_res;
	wire [4:0] shift_b;

	//section 4 : reg_file
	wire [31:0] rdata1,rdata2;
	
	//section 5: load
	wire [31:0] load_data;
	wire [15:0] lh_data;
	wire [7:0] lb_data;
	//section 6: wite back:
	wire [31:0] data_wb;

	//section7: control sign:
	wire MemtoReg;
	wire RegWrite;
	wire is_shift;
	wire is_logic;
	wire is_comp;
	wire branch_target;
	wire is_jalr;
	wire is_jal;
	wire is_btype;
	wire branch_taken;
	wire is_puls4;
	
	wire uimm, jalimm, jalrimm, stimm, bimm;
	wire is_lui, is_auipc, is_ltype, is_stype, is_itype, is_rtype;
	wire is_addr, is_addi, is_def;
	wire beq, bne, blt, bge, bltu, bgeu;
	wire sb, sh, sw, lb, lh, lw;
	wire a_pc, b_reg, b_imm, sel_b_zero;
	wire lh_high, lh_low, lb_one, lb_two, lb_three, lb_four;
	wire sel_alu;
//----------------------------------------------------------------------
	//PART 1: fetch Instruction
	always @(posedge clk) begin
		if(rst) pc <= 32'd0;
		else pc <= pc_next;
	end
	assign pc_plus4 = pc + 32'd4;
	assign pc_branch = pc + imm;
	assign pc_jal = pc + imm;
	assign pc_jalr = (rdata1 + imm) & ~32'd1;
	assign is_puls4 = (~is_jal) & (~is_jalr) & (~branch_taken); // except jump and branch, pc + 4
	assign pc_next = ({32{is_jal}} & pc_jal) |
					 ({32{is_jalr}} & pc_jalr) |
					 ({32{branch_taken}} & pc_branch) |
					 ({32{is_puls4}} & pc_plus4);
    assign PC = pc;		
//-----------------------------------------------------------	
	// PART 2 : decode Instruction
	assign opcode = Instruction[6:0];
	assign rd = Instruction[11:7];
	assign rs1 = Instruction[19:15];
	assign rs2 = Instruction[24:20];
	assign shamt = Instruction[24:20];
	assign funct3 = Instruction[14:12];
	assign funct7 = Instruction[31:25];
	// imm define
	assign uimm = (opcode == LUI || opcode == AUIpc);
	assign jalimm = (opcode == JAL);
	assign jalrimm = (opcode == JALR || opcode == L_TYPE||opcode == I_TYPE);
	assign stimm = (opcode == S_TYPE);
	assign bimm = (opcode == B_TYPE);

	assign imm = ({32{uimm}} & {Instruction[31:12],12'b0})|
				({32{jalimm}} & {{11{Instruction[31]}},Instruction[31],Instruction[19:12],Instruction[20],Instruction[30:21],1'b0}) |
				({32{jalrimm}} & {{20{Instruction[31]}}, Instruction[31:20]})|
				({32{stimm}} & {{20{Instruction[31]}},Instruction[31:25], Instruction[11:7]})|
				({32{bimm}} & {{19{Instruction[31]}}, Instruction[31],Instruction[7],Instruction[30:25],Instruction[11:8],1'b0}) |
				32'd0 ;
	
	// control inst
	// 1.control type :
	assign is_lui = (opcode ==  LUI);
	assign is_auipc = (opcode == AUIpc);
	assign is_jal = (opcode == JAL);
	assign is_jalr = (opcode == JALR);
	assign is_btype = (opcode == B_TYPE);
	assign is_ltype = (opcode == L_TYPE);
	assign is_stype = (opcode == S_TYPE);
	assign is_itype = (opcode == I_TYPE);
	assign is_rtype = (opcode == R_TYPE);
	assign RegWrite = is_rtype | is_auipc | is_itype |
					  is_jal | is_jalr | is_ltype | is_lui;

	//2.aluop & shiftop
	assign is_shift = (funct3[1:0] == 2'b01) & (is_rtype | is_itype);
	assign is_addr = (funct3[2:0] == 3'b000) & is_rtype;
	assign is_addi = (funct3[2:0] == 3'b000) & is_itype;
	assign is_comp = (funct3[2:1] == 2'b01) &(is_rtype | is_itype);
	assign is_logic = (funct3[2] == 1'b1) &(is_rtype | is_itype);
	assign is_def = ~(is_btype | is_addr | is_addi | is_comp | is_logic);
	assign shiftop = {funct7[5],funct3[2]};  // sll 00, srl 01, sra 11
	assign aluop = ({3{is_addr}} & {funct7[5],2'b10})|
				   ({3{is_addi}} & {3'b010}) |
				   ({3{is_logic}} & {(funct3[2]^funct3[1]),1'b0,(funct3[1]^funct3[0])})|
				   ({3{is_comp}} & {~funct3[0],2'b11})|
				   ({3{is_btype}} & {~funct3[1],1'b1,funct3[2]})|
				   ({3{is_def}} & 3'b010); // default aluop is add
	//3.branch :
	assign beq = is_btype & (funct3 == 3'b000);
	assign bne = is_btype & (funct3 == 3'b001);
	assign blt = is_btype & (funct3 == 3'b100);
	assign bge = is_btype & (funct3 == 3'b101);
	assign bltu = is_btype & (funct3 == 3'b110);
	assign bgeu = is_btype & (funct3 == 3'b111);

	//4.store:
	assign sb = is_stype & (funct3 == 3'b000);
	assign sh = is_stype & (funct3 == 3'b001);
	assign sw = is_stype & (funct3 == 3'b010);

	// 5. load:
	assign lb = is_ltype & (funct3[1:0] == 2'b00);
	assign lh = is_ltype & (funct3[1:0] == 2'b01);
	assign lw = is_ltype & (funct3[1:0] == 2'b10);


	//operate num:
	// alu & shift:
	assign a_pc = is_auipc | is_jal;
	assign b_reg = (is_rtype & ~is_shift)|is_btype;
	assign b_imm = (is_itype & ~is_shift) | is_ltype | is_stype | is_auipc | is_jalr;
	assign sel_b_zero = ~(b_reg | b_imm);
	assign alu_a = ({32{a_pc}} & pc)| ({32{~a_pc}} & rdata1);  // pc+imm<<12 , pc + imm
	assign alu_b = ({32{b_reg}} & rdata2) | (({32{b_imm}} & imm))| ({32{sel_b_zero}} & 32'd0);
	assign shift_b = ({5{is_shift & is_itype}} & shamt) |
					 ({5{is_shift & is_rtype}} & rdata2[4:0]);

//--------------------------------------------------------
	// PART3: execute instruction
	// 1.inst reg_file :
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
	assign RF_wen = RegWrite;
	assign RF_waddr = rd;
	assign RF_wdata = data_wb;

	// 2.inst alu:
	alu u_alu(
		.A(alu_a),
		.B(alu_b),
		.ALUop(aluop),
		.Zero(zero),
		.Result(alu_res)
	);
	// branch target :
	assign branch_target = (beq & zero) | (bne & ~zero)|
							(blt & alu_res[0]) | (bge & ~alu_res[0])|
							(bltu & alu_res[0]) | (bgeu & ~alu_res[0]); 
	assign branch_taken = is_btype & branch_target;

	// 3.inst shifter:
	shifter u_shift(
		.A(rdata1),
		.B(shift_b),
		.Shiftop(shiftop),
		.Result(shift_res)
	);

	// 4.mem s_type :
	assign addr_offset = alu_res[1:0];
	assign Address = {alu_res[31:2],2'b00};  //store and load word address
	assign Write_data = ({32{sw}} & rdata2)|
						({32{sh}} & ({16'd0, rdata2[15:0]} << (16*addr_offset[1])))|
						({32{sb}} & ({24'd0, rdata2[7:0]} << (8*addr_offset)))|
						32'd0;
	assign MemWrite = is_stype;
	assign Write_strb = ({4{sw}} & 4'b1111)|
						({4{sh}} & {{2{addr_offset[1]}},{2{~addr_offset[1]}}})|
						({4{sb}} & (4'd1 << addr_offset))|
						4'd0;
	
	//5.load ltype:
	assign MemRead = is_ltype;	
	assign lh_high = addr_offset[1];
	assign lh_low = ~addr_offset[1];
	assign lb_one = addr_offset == 2'b00;
	assign lb_two = addr_offset == 2'b01;
	assign lb_three = addr_offset == 2'b10;
	assign lb_four = addr_offset == 2'b11;

	assign lh_data = ({16{lh_low}} & Read_data[15:0]) | ({16{lh_high}} & Read_data[31:16]);
	assign lb_data = ({8{lb_one}} & Read_data[7:0]) | ({8{lb_two}} & Read_data[15:8])|
					 ({8{lb_three}} & Read_data[23:16])| ({8{lb_four}} & Read_data[31:24]);
					 
	assign load_data = ({32{lw}} & Read_data)|
					   ({32{lh}} & {{16{~funct3[2] & lh_data[15]}},lh_data})|
					   ({32{lb}} & {{24{~funct3[2] & lb_data[7]}},lb_data}) |
					   32'd0;
	// 6. wb 
	assign sel_alu = ~is_ltype & ~is_shift & ~is_lui & ~is_auipc & ~is_jal & ~is_jalr;  
	assign data_wb = ({32{is_ltype}} & load_data) |                //write back to reg 
					 ({32{is_jal | is_jalr}} & (pc + 4)) |
					 ({32{is_lui}} & imm) |
					 ({32{is_auipc}} & alu_res) |
					 ({32{is_shift}} & shift_res) |
					 ({32{sel_alu}} & alu_res);

	
endmodule
