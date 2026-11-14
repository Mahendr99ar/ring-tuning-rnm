// -----------------------------------------------------------------------------
// ring_scn : one analog scenario (integers, because SV cannot randomize reals)
// ring_res : what the monitor measured for that scenario
// -----------------------------------------------------------------------------
class ring_scn extends uvm_sequence_item;
  rand int offset_pm;                 // laser above cold resonance
  rand int drift_mk_per_ms;           // ambient drift while tracking (milli-kelvin per ms)
  rand int noise_lsb;                 // ADC noise, 1 sigma
  rand int track_us;                  // tracking window length

  constraint c_offset { offset_pm inside {[300:2000]}; }
  constraint c_drift  { drift_mk_per_ms inside {[-1000:1000]}; }   // the sequence picks the range
  // (no 'soft == 0' here: a soft value that fits inside the inline range always wins,
  //  so every scenario got drift 0 even in ring_drift_test)
  constraint c_noise  { noise_lsb inside {[0:4]}; }
  constraint c_track  { soft track_us inside {[300:600]}; }

  `uvm_object_utils_begin(ring_scn)
    `uvm_field_int(offset_pm,       UVM_ALL_ON | UVM_DEC)
    `uvm_field_int(drift_mk_per_ms, UVM_ALL_ON | UVM_DEC)
    `uvm_field_int(noise_lsb,       UVM_ALL_ON | UVM_DEC)
    `uvm_field_int(track_us,        UVM_ALL_ON | UVM_DEC)
  `uvm_object_utils_end

  function new(string name = "ring_scn"); super.new(name); endfunction
endclass

class ring_res extends uvm_sequence_item;
  int  offset_pm, drift_mk_per_ms, noise_lsb;
  int  lock_clocks;                   // -1 if it never locked
  real max_err_pm, mean_err_pm, amb_moved_k;
  int  false_lock;                    // clocks with locked=1 but |detune| > 50 pm
  int  lost_lock;                     // clocks with locked=0 during the tracking window

  `uvm_object_utils(ring_res)
  function new(string name = "ring_res"); super.new(name); endfunction
endclass
