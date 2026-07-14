`timescale 10ns / 1ns

module pipeline_reg #(
	parameter BUS_WIDTH = 1
)(
	input  clk,
	input  rst,
	input  flush,
	input  allowin,
	input  in_valid,
	input  [BUS_WIDTH-1:0]   in_bus,
	output reg out_valid,
	output reg [BUS_WIDTH-1:0] out_bus
);

	always @(posedge clk) begin
		if (rst | flush) begin
			out_valid <= 1'b0;
			out_bus   <= {BUS_WIDTH{1'b0}};
		end
		else if (allowin) begin
			out_valid <= in_valid;
			if (in_valid)
				out_bus <= in_bus;
		end
	end

endmodule
