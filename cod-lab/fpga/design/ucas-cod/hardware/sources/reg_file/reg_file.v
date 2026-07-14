`timescale 10 ns / 1 ns

`define DATA_WIDTH 32
`define ADDR_WIDTH 5

module reg_file(
	input                       clk,
	input  [`ADDR_WIDTH - 1:0]  waddr,
	input  [`ADDR_WIDTH - 1:0]  raddr1,
	input  [`ADDR_WIDTH - 1:0]  raddr2,
	input                       wen,
	input  [`DATA_WIDTH - 1:0]  wdata,
	output [`DATA_WIDTH - 1:0]  rdata1,
	output [`DATA_WIDTH - 1:0]  rdata2
);

	// TODO: Please add your logic design here
	reg [31:0] rf [0:`DATA_WIDTH - 1];

	always @(posedge clk) begin
		if(wen && waddr != 5'd0) rf[waddr] <= wdata;   //shi xu logic write
	end
	assign rdata1 = (raddr1==5'd0)? 32'd0 : rf[raddr1];  // combinational logic read
	assign rdata2 = (raddr2==5'd0)? 32'd0 : rf[raddr2];

	// wire write_hit_raddr1 = wen && (waddr != {`ADDR_WIDTH{1'b0}}) && (waddr == raddr1);
	// wire write_hit_raddr2 = wen && (waddr != {`ADDR_WIDTH{1'b0}}) && (waddr == raddr2);

	// //asynchronous read
	// assign rdata1 = {`DATA_WIDTH{|raddr1}} & (write_hit_raddr1 ? wdata : rf[raddr1]);
	// assign rdata2 = {`DATA_WIDTH{|raddr2}} & (write_hit_raddr2 ? wdata : rf[raddr2]);

	
endmodule
