`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// tb_top : RTL controller + sigma-delta DAC, connected to the real-number model
// -----------------------------------------------------------------------------
module tb_top;
  import uvm_pkg::*;
  import ring_pkg::*;
  `include "uvm_macros.svh"

  logic clk = 0;
  always #5 clk = ~clk;

  ring_if vif (.clk(clk));

  ring_tuner_top dut (
    .clk(clk), .rst_n(vif.rst_n), .start(vif.start),
    .adc_code(vif.adc_code), .adc_valid(vif.adc_valid),
    .heater_bit(vif.heater_bit), .heater_code(vif.heater_code),
    .locked(vif.locked), .phase(vif.phase), .sweep_min(vif.sweep_min)
  );

  ring_plant_rnm plant (
    .clk(clk), .rst_n(vif.rst_n), .heater_bit(vif.heater_bit),
    .adc_code(vif.adc_code), .adc_valid(vif.adc_valid)
  );

  // scenario knobs in, analog state out
  always @(vif.laser_offset_pm or vif.drift_k_per_ms or vif.noise_lsb) begin
    plant.laser_offset_pm = vif.laser_offset_pm;
    plant.drift_k_per_ms  = vif.drift_k_per_ms;
    plant.noise_lsb       = vif.noise_lsb;
  end
  always @(negedge clk) begin
    vif.detune_pm = plant.detune_pm;
    vif.amb_k     = plant.amb_k;
  end

  initial begin
    uvm_config_db#(virtual ring_if)::set(null, "uvm_test_top.*", "vif", vif);
    run_test("ring_lock_test");
  end
endmodule
