`timescale 10 ns / 1 ns

`define DATA_WIDTH 32
// shiftop: according to risc-v 32:
`define SLL_OP 2'b00
`define SRL_OP 2'b01
`define SRA_OP 2'b11

module shifter (
	input  [`DATA_WIDTH - 1:0] A,
	input  [              4:0] B,
	input  [              1:0] Shiftop,
	output [`DATA_WIDTH - 1:0] Result
);
	// TODO: Please add your logic code here
	wire [(2*`DATA_WIDTH)-1:0] a_sign_ext;
	wire [(2*`DATA_WIDTH)-1:0] sra_shifted;

	assign a_sign_ext = {{`DATA_WIDTH{A[`DATA_WIDTH-1]}}, A};
	assign sra_shifted = a_sign_ext >> B;
	assign Result = ({32{Shiftop == `SLL_OP}} & (A << B)) |
					({32{Shiftop == `SRL_OP}} & (A >> B)) |
					({32{Shiftop == `SRA_OP}} & (sra_shifted[`DATA_WIDTH-1:0])) |
					({32{1'b0}});

endmodule
