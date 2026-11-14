`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// ring_sva : controller checks, bound into ring_tuner
// -----------------------------------------------------------------------------
module ring_sva #(parameter int CW = 12, parameter int DITHER = 16, parameter int TRACK_STEP = 4) (
  input logic          clk, rst_n, start, locked,
  input logic [1:0]    phase,
  input logic [CW-1:0] heater_code, centre
);
  // lock can only be claimed while tracking
  a_lock_only_tracking: assert property (@(posedge clk) disable iff (!rst_n)
    locked |-> phase == 2'd2)
    else $error("SVA: locked while not tracking");

  // while tracking, the heater stays within +/- DITHER of the centre
  a_dither_window: assert property (@(posedge clk) disable iff (!rst_n || start)
    (phase == 2'd2 && $past(phase) == 2'd2 && heater_code != $past(heater_code))
      |-> (heater_code == centre + DITHER[CW-1:0]) || (heater_code == centre - DITHER[CW-1:0]))
    else $error("SVA: heater code outside the dither window");

  // the centre moves at most TRACK_STEP codes per decision
  a_small_steps: assert property (@(posedge clk) disable iff (!rst_n || start)
    (phase == 2'd2 && $past(phase) == 2'd2 && centre != $past(centre))
      |-> ((centre > $past(centre)) ? (centre - $past(centre)) : ($past(centre) - centre)) <= TRACK_STEP[CW-1:0])
    else $error("SVA: tracking step larger than TRACK_STEP");
endmodule

bind ring_tuner ring_sva #(.CW(CW), .DITHER(DITHER), .TRACK_STEP(TRACK_STEP)) u_ring_sva (.*);
