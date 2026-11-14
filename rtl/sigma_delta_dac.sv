`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// sigma_delta_dac : first-order sigma-delta modulator (error feedback)
//
//  Turns a CW-bit code into a 1-bit stream whose average density is
//  code / 2^CW. The quantization error is pushed to high frequencies, and the
//  heater's thermal time constant filters it out, so the heater only "sees"
//  the average. One adder and one register, no multiplier.
// -----------------------------------------------------------------------------
module sigma_delta_dac #(
  parameter int CW = 12
) (
  input  logic          clk,
  input  logic          rst_n,
  input  logic [CW-1:0] code,
  output logic          bit_out
);

  logic [CW-1:0] acc;
  logic [CW:0]   sum;

  assign sum = {1'b0, acc} + {1'b0, code};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      acc     <= '0;
      bit_out <= 1'b0;
    end else begin
      acc     <= sum[CW-1:0];
      bit_out <= sum[CW];              // carry = 1 exactly code times every 2^CW clocks
    end
  end

endmodule
