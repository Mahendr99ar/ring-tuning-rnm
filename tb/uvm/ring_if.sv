`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// ring_if : digital pins of the tuner, plus the analog scenario knobs and the
//           true detuning from the real-number model (for checking only).
// -----------------------------------------------------------------------------
interface ring_if (input logic clk);

  logic        rst_n;
  logic        start;
  logic        heater_bit;
  logic [11:0] heater_code;
  logic [9:0]  adc_code, sweep_min;
  logic        adc_valid;
  logic        locked;
  logic [1:0]  phase;

  // scenario knobs, copied into the real-number model by tb_top
  real laser_offset_pm;
  real drift_k_per_ms;
  int  noise_lsb;

  // observed analog state, copied from the real-number model by tb_top
  real detune_pm;
  real amb_k;

  // testbench markers
  logic measuring;                    // driver: tracking window is running
  logic scn_done;                     // driver: scenario finished, take results

endinterface
