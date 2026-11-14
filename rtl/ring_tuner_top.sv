`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// ring_tuner_top : controller + sigma-delta heater DAC
//   heater_bit drives the heater switch; the ADC samples the through-port
//   photodiode.
// -----------------------------------------------------------------------------
module ring_tuner_top (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        start,
  input  logic [9:0]  adc_code,
  input  logic        adc_valid,
  output logic        heater_bit,
  output logic [11:0] heater_code,
  output logic        locked,
  output logic [1:0]  phase,
  output logic [9:0]  sweep_min
);

  ring_tuner #(.CW(12), .AW(10)) u_ctrl (
    .clk, .rst_n, .start, .adc_code, .adc_valid,
    .heater_code, .locked, .phase, .sweep_min
  );

  sigma_delta_dac #(.CW(12)) u_dac (
    .clk, .rst_n, .code(heater_code), .bit_out(heater_bit)
  );

endmodule
