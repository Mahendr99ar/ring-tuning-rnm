// -----------------------------------------------------------------------------
// Scoreboard, environment, sequences and tests
//
// Pass rules for every scenario (from the requirements in docs/verification_plan.md):
//   lock within 150 000 clocks (1.5 ms)
//   |detuning| under 25 pm (a quarter linewidth) for the whole tracking window
//   locked never claims lock while |detuning| > 50 pm
//   no loss of lock while tracking
// -----------------------------------------------------------------------------
class ring_scoreboard extends uvm_subscriber #(ring_res);
  `uvm_component_utils(ring_scoreboard)

  real spec_pm = 25.0;                  // a quarter of the 100 pm linewidth
  int  n_pass, n_fail;
  real worst_err;
  int  worst_lock;

  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  function void write(ring_res t);
    ring_res r = t;
    bit ok = 1;
    if (r.lock_clocks < 0) begin
      `uvm_error("SB", $sformatf("offset %0d pm: never locked", r.offset_pm)); ok = 0;
    end else begin
      if (r.max_err_pm > spec_pm) begin
        `uvm_error("SB", $sformatf("offset %0d pm, drift %0d mK/ms, noise %0d: max |detune| %0.1f pm > %0.1f pm",
                   r.offset_pm, r.drift_mk_per_ms, r.noise_lsb, r.max_err_pm, spec_pm)); ok = 0;
      end
      if (r.false_lock != 0) begin
        `uvm_error("SB", $sformatf("offset %0d pm: locked was high for %0d clocks while |detune| > 50 pm",
                   r.offset_pm, r.false_lock)); ok = 0;
      end
      if (r.lost_lock != 0) begin
        `uvm_error("SB", $sformatf("offset %0d pm: lock dropped for %0d clocks while tracking",
                   r.offset_pm, r.lost_lock)); ok = 0;
      end
    end
    if (ok) n_pass++; else n_fail++;
    if (r.max_err_pm > worst_err) worst_err = r.max_err_pm;
    if (r.lock_clocks > worst_lock) worst_lock = r.lock_clocks;
    `uvm_info("SB", $sformatf("%s offset %4d pm | drift %5d mK/ms | noise %0d | lock %0d clk (%0.3f ms) | |detune| mean %0.1f max %0.1f pm | ambient moved %0.2f K",
              ok ? "PASS" : "FAIL", r.offset_pm, r.drift_mk_per_ms, r.noise_lsb, r.lock_clocks,
              r.lock_clocks * 1.0e-5, r.mean_err_pm, r.max_err_pm, r.amb_moved_k), UVM_LOW)
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("SB", $sformatf("scenarios passed=%0d failed=%0d  slowest lock=%0d clk  worst |detune|=%0.1f pm",
              n_pass, n_fail, worst_lock, worst_err), UVM_LOW)
  endfunction
endclass

class ring_env extends uvm_env;
  `uvm_component_utils(ring_env)
  ring_agent      agt;
  ring_scoreboard sb;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    agt = ring_agent::type_id::create("agt", this);
    sb  = ring_scoreboard::type_id::create("sb", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    agt.mon.ap.connect(sb.analysis_export);
  endfunction
endclass

// n random scenarios; the knobs choose which kind
class ring_scn_seq extends uvm_sequence #(ring_scn);
  `uvm_object_utils(ring_scn_seq)
  int n = 4;
  int drift_min = 0, drift_max = 0;   // mK/ms
  int noise_min = 0, noise_max = 2;
  function new(string name = "ring_scn_seq"); super.new(name); endfunction
  task body();
    repeat (n) begin
      req = ring_scn::type_id::create("req");
      start_item(req);
      if (!req.randomize() with {
            drift_mk_per_ms inside {[drift_min:drift_max]};
            noise_lsb       inside {[noise_min:noise_max]};
          })
        `uvm_fatal("RAND", "ring_scn randomization failed")
      finish_item(req);
    end
  endtask
endclass

class ring_base_test extends uvm_test;
  `uvm_component_utils(ring_base_test)
  ring_env env;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = ring_env::type_id::create("env", this);
  endfunction
  function void end_of_elaboration_phase(uvm_phase phase);
    uvm_top.print_topology();
  endfunction
  virtual function void setup(ring_scn_seq s); endfunction
  task run_phase(uvm_phase phase);
    ring_scn_seq s = ring_scn_seq::type_id::create("s");
    setup(s);
    phase.raise_objection(this);
    s.start(env.agt.sqr);
    #1us;
    phase.drop_objection(this);
  endtask
  function void report_phase(uvm_phase phase);
    uvm_report_server rs = uvm_report_server::get_server();
    int errs = rs.get_severity_count(UVM_ERROR) + rs.get_severity_count(UVM_FATAL);
    $display("\n==============================================");
    $display("  %s : %s", get_type_name(), (errs == 0) ? "PASSED" : "FAILED");
    $display("==============================================\n");
  endfunction
endclass

// lock from random offsets, no drift, a little noise
class ring_lock_test extends ring_base_test;
  `uvm_component_utils(ring_lock_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void setup(ring_scn_seq s);
    s.n = 5; s.drift_min = 0; s.drift_max = 0; s.noise_min = 0; s.noise_max = 2;
  endfunction
endclass

// ambient drifts up or down while tracking (inside the 1.0 K/ms requirement)
class ring_drift_test extends ring_base_test;
  `uvm_component_utils(ring_drift_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void setup(ring_scn_seq s);
    s.n = 6; s.drift_min = -1000; s.drift_max = 1000; s.noise_min = 0; s.noise_max = 2;
  endfunction
endclass

// noisy ADC, small drift
class ring_noise_test extends ring_base_test;
  `uvm_component_utils(ring_noise_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void setup(ring_scn_seq s);
    s.n = 4; s.drift_min = -300; s.drift_max = 300; s.noise_min = 3; s.noise_max = 4;
  endfunction
endclass
