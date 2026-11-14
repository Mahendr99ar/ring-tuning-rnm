// -----------------------------------------------------------------------------
// tb_ring_directed : RTL controller + real-number plant, self-checking (Icarus, CI)
//
//  T1-T3  lock from three laser offsets (400, 1100, 1900 pm), no drift
//  T4     after lock, ambient rises 1 K/ms for 1.5 ms  -> resonance moves +120 pm
//  T5     after lock, ambient falls 1 K/ms for 1.5 ms
//  T6     lock with 3 LSB of ADC noise
//  Pass: locked within LOCK_LIMIT clocks, and |detuning| stays under SPEC_PM
//        while tracking.  +TRACE writes results/trace_rtl.csv for the Python
//        correlation (T1 settings, no noise).
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_ring_directed;

  localparam int  LOCK_LIMIT = 150000;   // 1.5 ms
  localparam real SPEC_PM    = 25.0;   // a quarter of the 100 pm linewidth

  logic clk = 0, rst_n = 0, start = 0;
  logic [9:0]  adc_code, sweep_min;
  logic        adc_valid, heater_bit, locked;
  logic [11:0] heater_code;
  logic [1:0]  phase;
  int errors = 0;
  integer tf;
  bit trace = 0;

  always #5 clk = ~clk;

  ring_tuner_top dut (.*);
  ring_plant_rnm plant (.clk, .rst_n, .heater_bit, .adc_code, .adc_valid);

  real worst;

  task automatic run_case(input string name, input real offset_pm, input real drift,
                          input int noise, input int track_clocks);
    int t;
    real d, sum_abs;
    int n;
    plant.laser_offset_pm = offset_pm;
    plant.amb_start_k     = 0.0;
    plant.drift_k_per_ms  = 0.0;
    plant.noise_lsb       = noise;
    rst_n = 0; repeat (5) @(posedge clk); rst_n = 1;
    @(negedge clk); start = 1; @(negedge clk); start = 0;
    t = 0;
    while (!locked && t < LOCK_LIMIT) begin @(posedge clk); t++; end
    if (!locked) begin
      $display("ERROR %s: no lock after %0d clocks (detune %0.1f pm)", name, t, plant.detune_pm);
      errors++;
    end else begin
    $display("  %s: locked after %0d clocks (%0.2f ms), sweep min %0d, detune %0.1f pm",
             name, t, t * 10.0e-6, sweep_min, plant.detune_pm);
    // let the dither settle, then start drift and measure tracking error
    repeat (20000) @(posedge clk);
    plant.drift_k_per_ms = drift;
    worst = 0.0; sum_abs = 0.0; n = 0;
    for (int k = 0; k < track_clocks; k++) begin
      @(posedge clk);
      d = (plant.detune_pm < 0) ? -plant.detune_pm : plant.detune_pm;
      if (k % 64 == 0) begin sum_abs += d; n++; end
      if (d > worst) worst = d;
    end
    $display("  %s: tracking %0.2f ms, ambient moved %0.2f K, |detune| mean %0.1f pm, max %0.1f pm, locked=%0b",
             name, track_clocks * 10.0e-6, plant.amb_k, sum_abs / n, worst, locked);
    if (worst > SPEC_PM) begin
      $display("ERROR %s: detuning %0.1f pm is over the %0.1f pm spec", name, worst, SPEC_PM);
      errors++;
    end
    if (!locked) begin $display("ERROR %s: lost lock while tracking", name); errors++; end
    end
  endtask

  // optional trace for the Python correlation
  always @(posedge clk) if (trace && rst_n && (plant.div_cnt == 0))
    $fwrite(tf, "%0d,%0d,%0d,%0.3f,%0d\n", $time/10, heater_code, adc_code, plant.detune_pm, locked);

  initial begin
    if ($test$plusargs("TRACE")) begin
      trace = 1;
      tf = $fopen("results/trace_rtl.csv", "w");
      $fwrite(tf, "clk,heater_code,adc_code,detune_pm,locked\n");
      run_case("TRACE", 1100.0, 0.0, 0, 20000);
      $fclose(tf);
      $finish;
    end
    $display("[ring tuner + RNM]");
    run_case("T1 offset 400 pm ", 400.0,  0.0, 0, 30000);
    run_case("T2 offset 1100 pm", 1100.0, 0.0, 0, 30000);
    run_case("T3 offset 1900 pm", 1900.0, 0.0, 0, 30000);
    run_case("T4 drift +1 K/ms ", 1100.0, 1.0, 0, 150000);
    run_case("T5 drift -1 K/ms ", 1100.0, -1.0, 0, 150000);
    run_case("T6 noise 3 LSB   ", 1100.0, 0.0, 3, 30000);
    $display("--------------------------------------------");
    if (errors == 0) $display(" RESULT: PASS");
    else             $display(" RESULT: FAIL (%0d errors)", errors);
    $display("--------------------------------------------");
    $finish;
  end

endmodule
