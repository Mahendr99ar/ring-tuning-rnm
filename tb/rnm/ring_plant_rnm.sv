`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// ring_plant_rnm : real-number model of the analog side
//
//   heater_bit ──► thermal low-pass (time constant TAU_CLK clocks)
//                    └─► heater temperature rise = duty_filt * DT_MAX_K
//   resonance shift (pm) = KT_PM_PER_K * (heater rise + ambient change)
//   detuning (pm)        = laser offset - resonance shift
//   through-port power   = 1 - EXT / (1 + (2*detuning/FWHM)^2)      (Lorentzian dip)
//   photodiode + ADC     : every ADC_DIV clocks, code = round(power * ADC_FS)
//                          + gaussian noise (noise_lsb), clamped to 0..1023
//
//  Numbers are typical for a silicon micro-ring:
//    80 pm/K thermal shift, 100 pm linewidth, 90 % dip depth, 30 K heater range
//  (so the full heater range moves the resonance by 2400 pm).
//
//  Inputs set by the testbench: laser_offset_pm (where the laser sits above the
//  cold resonance), amb_start_k, drift_k_per_ms, noise_lsb.
//  Outputs for checking: detune_pm (true detuning), amb_k, power.
// -----------------------------------------------------------------------------
module ring_plant_rnm #(
  parameter real CLK_NS      = 10.0,
  parameter real TAU_CLK     = 256.0,
  parameter real DT_MAX_K    = 30.0,
  parameter real KT_PM_PER_K = 80.0,
  parameter real FWHM_PM     = 100.0,
  parameter real EXT         = 0.9,
  parameter real ADC_FS      = 1000.0,
  parameter int  ADC_DIV     = 64
) (
  input  logic       clk,
  input  logic       rst_n,
  input  logic       heater_bit,
  output logic [9:0] adc_code,
  output logic       adc_valid
);

  // scenario knobs (written by the testbench through hierarchy or the interface)
  real laser_offset_pm = 1000.0;
  real amb_start_k     = 0.0;
  real drift_k_per_ms  = 0.0;
  int  noise_lsb       = 0;
  int  seed            = 1;

  // state visible to checkers
  real duty_filt = 0.0;
  real amb_k     = 0.0;
  real detune_pm = 0.0;
  real power     = 1.0;

  int  div_cnt;
  real alpha, drift_per_clk, shift_pm, x, raw;
  int  code_i, nz;

  initial begin
    alpha         = 1.0 / TAU_CLK;
    adc_code      = '0;
    adc_valid     = 1'b0;
    div_cnt       = 0;
  end

  always @(posedge clk) begin
    if (!rst_n) begin
      duty_filt = 0.0;
      amb_k     = amb_start_k;
      div_cnt   = 0;
      adc_valid <= 1'b0;
    end else begin
      // heater: first-order thermal filter of the sigma-delta bit stream
      duty_filt = duty_filt + alpha * ((heater_bit ? 1.0 : 0.0) - duty_filt);
      // ambient temperature drift
      drift_per_clk = drift_k_per_ms * CLK_NS * 1.0e-6;
      amb_k = amb_k + drift_per_clk;
      // ring
      shift_pm  = KT_PM_PER_K * (duty_filt * DT_MAX_K + amb_k);
      detune_pm = laser_offset_pm - shift_pm;
      x         = 2.0 * detune_pm / FWHM_PM;
      power     = 1.0 - EXT / (1.0 + x * x);
      // photodiode + ADC
      adc_valid <= 1'b0;
      div_cnt = div_cnt + 1;
      if (div_cnt == ADC_DIV) begin
        div_cnt = 0;
        raw = power * ADC_FS;
        nz  = (noise_lsb > 0) ? $dist_normal(seed, 0, noise_lsb) : 0;
        code_i = $rtoi(raw + 0.5) + nz;
        if (code_i < 0)    code_i = 0;
        if (code_i > 1023) code_i = 1023;
        adc_code  <= code_i[9:0];
        adc_valid <= 1'b1;
      end
    end
  end

endmodule
