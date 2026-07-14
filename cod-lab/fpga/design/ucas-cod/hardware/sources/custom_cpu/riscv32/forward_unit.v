`timescale 10ns / 1ns

module forward_unit(
	input        ex_uses_rs1,
	input        ex_uses_rs2,
	input  [4:0] ex_rs1,
	input  [4:0] ex_rs2,

	input        mem_valid,
	input        mem_reg_write,
	input        mem_is_load,
	input  [4:0] mem_rd,

	input        wb_valid,
	input        wb_reg_write,
	input  [4:0] wb_rd,

	output [1:0] forward_a,
	output [1:0] forward_b
);

	wire mem_hit_rs1 = ex_uses_rs1 & mem_valid & mem_reg_write & ~mem_is_load &
	                   (mem_rd != 5'd0) & (mem_rd == ex_rs1);
	wire mem_hit_rs2 = ex_uses_rs2 & mem_valid & mem_reg_write & ~mem_is_load &
	                   (mem_rd != 5'd0) & (mem_rd == ex_rs2);
	wire wb_hit_rs1  = ex_uses_rs1 & wb_valid & wb_reg_write &
	                   (wb_rd != 5'd0) & (wb_rd == ex_rs1);
	wire wb_hit_rs2  = ex_uses_rs2 & wb_valid & wb_reg_write &
	                   (wb_rd != 5'd0) & (wb_rd == ex_rs2);

	assign forward_a = ({2{mem_hit_rs1}} & 2'b01) |
	                   ({2{~mem_hit_rs1 & wb_hit_rs1}} & 2'b10);
	assign forward_b = ({2{mem_hit_rs2}} & 2'b01) |
	                   ({2{~mem_hit_rs2 & wb_hit_rs2}} & 2'b10);

endmodule
