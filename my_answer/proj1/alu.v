`timescale 10 ns / 1 ns

`define DATA_WIDTH 32

module alu(                                   //alu是适用于proj2的最终版本，不完全适用于proj1
	input  [`DATA_WIDTH - 1:0]  A,
	input  [`DATA_WIDTH - 1:0]  B,
	input  [              2:0]  ALUop,
	output                      Overflow,
	output                      CarryOut,
	output                      Zero,
	output [`DATA_WIDTH - 1:0]  Result
);
	// TODO: Please add your logic design here
	wire Cin;
	wire [`DATA_WIDTH:0] add_res;
	wire [`DATA_WIDTH-1:0] Signed_B;  //the value of "B" that join caculate 
	wire [`DATA_WIDTH-1:0]slt; 
	wire [`DATA_WIDTH-1:0]sltu;
	wire [`DATA_WIDTH-1:0]sel_and;   //signs that enable multi_select 
	wire [`DATA_WIDTH-1:0]sel_or;
	wire [`DATA_WIDTH-1:0]sel_add;
	wire [`DATA_WIDTH-1:0]sel_slt;
	wire [`DATA_WIDTH-1:0]sel_xor;
	wire [`DATA_WIDTH-1:0]sel_nor;
	wire [`DATA_WIDTH-1:0]sel_sltu;


	assign Signed_B = (ALUop[2] | ALUop[0])? ~B:B;   //110 --sub --> A+(~B+1),  010 -- add -->a+B 
	assign Cin = ALUop[2] | ALUop[0];   
	assign add_res = A + Signed_B + Cin; 
	assign CarryOut = (ALUop[2] | ALUop[0])? ~add_res[`DATA_WIDTH] : add_res[`DATA_WIDTH];
	assign Overflow = (A[`DATA_WIDTH-1] == Signed_B[`DATA_WIDTH-1]) && 
	(A[`DATA_WIDTH-1] ^ add_res[`DATA_WIDTH-1]);
	assign slt = {31'd0,(add_res[`DATA_WIDTH-1] ^ Overflow)};
	assign sltu = {31'd0,CarryOut};

	assign sel_and = {32{(ALUop == 3'b000)}};
	assign sel_or = {32{(ALUop == 3'b001)}};
	assign sel_add = {32{(~ALUop[0] & ALUop[1])}};
	assign sel_slt = {32{(ALUop == 3'b111)}};
	assign sel_xor = {32{(ALUop == 3'b100)}};
	assign sel_nor = {32{(ALUop == 3'b101)}};
	assign sel_sltu = {32{(ALUop == 3'b011)}};


	assign Result = (sel_and & (A&B)) | (sel_or & (A|B)) |     //use mul_sel 
	(sel_add & add_res[`DATA_WIDTH-1:0]) | (sel_slt & slt)|
	(sel_xor & (A ^ B))|(sel_nor & ~(A | B))|(sel_sltu & sltu);
	assign Zero = ~(|Result);


endmodule
