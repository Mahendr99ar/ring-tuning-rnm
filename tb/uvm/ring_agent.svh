// -----------------------------------------------------------------------------
// Driver: applies a scenario to the analog model and runs it.
// Monitor: measures lock time and tracking error from the true detuning.
// -----------------------------------------------------------------------------
typedef uvm_sequencer #(ring_scn) ring_sequencer;

class ring_driver extends uvm_driver #(ring_scn);
  `uvm_component_utils(ring_driver)

  virtual ring_if vif;
  int unsigned lock_timeout = 150000;   // 1.5 ms
  int unsigned settle       = 20000;    // let the dither settle before measuring

  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual ring_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "virtual interface not set for ring_driver")
  endfunction

  task run_phase(uvm_phase phase);
    vif.rst_n = 0; vif.start = 0; vif.measuring = 0; vif.scn_done = 0;
    vif.laser_offset_pm = 1000.0; vif.drift_k_per_ms = 0.0; vif.noise_lsb = 0;
    forever begin
      int unsigned n;
      seq_item_port.get_next_item(req);
      `uvm_info("DRV", $sformatf("scenario: offset %0d pm, drift %0d mK/ms, noise %0d LSB, track %0d us",
                req.offset_pm, req.drift_mk_per_ms, req.noise_lsb, req.track_us), UVM_LOW)
      // fresh start: cold ring, new laser offset
      vif.laser_offset_pm = req.offset_pm;
      vif.drift_k_per_ms  = 0.0;
      vif.noise_lsb       = req.noise_lsb;
      vif.rst_n = 0; repeat (5) @(posedge vif.clk);
      @(negedge vif.clk); vif.rst_n = 1;
      @(negedge vif.clk); vif.start = 1;
      @(negedge vif.clk); vif.start = 0;
      n = 0;
      while (vif.locked !== 1'b1 && n < lock_timeout) begin @(posedge vif.clk); n++; end
      if (vif.locked === 1'b1) begin
        repeat (settle) @(posedge vif.clk);
        vif.drift_k_per_ms = req.drift_mk_per_ms / 1000.0;
        vif.measuring = 1;
        repeat (req.track_us * 100) @(posedge vif.clk);
        vif.measuring = 0;
      end
      vif.drift_k_per_ms = 0.0;
      @(negedge vif.clk); vif.scn_done = 1;
      @(negedge vif.clk); vif.scn_done = 0;
      seq_item_port.item_done();
    end
  endtask
endclass

class ring_monitor extends uvm_monitor;
  `uvm_component_utils(ring_monitor)

  virtual ring_if             vif;
  uvm_analysis_port #(ring_res) ap;

  // coverage samples
  int c_offset, c_drift, c_noise, c_lock;

  covergroup cg_scn;
    option.per_instance = 1;
    cp_offset : coverpoint c_offset { bins near = {[300:800]}; bins mid = {[801:1400]}; bins far = {[1401:2000]}; }
    cp_drift  : coverpoint c_drift  { bins falling = {[-1000:-200]}; bins none = {[-199:199]}; bins rising = {[200:1000]}; }
    cp_noise  : coverpoint c_noise  { bins quiet = {0}; bins some = {[1:2]}; bins high = {[3:4]}; }
    cp_lock   : coverpoint c_lock   { bins fast = {[0:69000]}; bins normal = {[69001:150000]}; }
    x_off_drift : cross cp_offset, cp_drift;
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
    cg_scn = new();
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual ring_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "virtual interface not set for ring_monitor")
  endfunction

  task run_phase(uvm_phase phase);
    ring_res r;
    int  clk_since_start, n;
    real d, sum, amb0;
    bit  started;
    forever begin
      @(posedge vif.clk);
      if (vif.start === 1'b1) begin
        r = ring_res::type_id::create("r");
        r.offset_pm = $rtoi(vif.laser_offset_pm);
        r.noise_lsb = vif.noise_lsb;
        r.lock_clocks = -1; r.max_err_pm = 0; r.mean_err_pm = 0;
        r.false_lock = 0; r.lost_lock = 0;
        clk_since_start = 0; n = 0; sum = 0; started = 1; amb0 = vif.amb_k;
        continue;
      end
      if (!started) continue;
      clk_since_start++;
      d = (vif.detune_pm < 0) ? -vif.detune_pm : vif.detune_pm;
      if (r.lock_clocks < 0 && vif.locked === 1'b1) r.lock_clocks = clk_since_start;
      if (vif.locked === 1'b1 && d > 50.0) r.false_lock++;
      if (vif.measuring === 1'b1) begin
        if (n == 0) amb0 = vif.amb_k;
        r.drift_mk_per_ms = $rtoi(vif.drift_k_per_ms * 1000.0);
        if (d > r.max_err_pm) r.max_err_pm = d;
        sum += d; n++;
        if (vif.locked !== 1'b1) r.lost_lock++;
        r.amb_moved_k = vif.amb_k - amb0;
      end
      if (vif.scn_done === 1'b1) begin
        if (n > 0) r.mean_err_pm = sum / n;
        c_offset = r.offset_pm; c_drift = r.drift_mk_per_ms; c_noise = r.noise_lsb;
        c_lock = (r.lock_clocks < 0) ? 999999 : r.lock_clocks;
        cg_scn.sample();
        ap.write(r);
        started = 0;
      end
    end
  endtask

  function void report_phase(uvm_phase phase);
    `uvm_info("MON", $sformatf("coverage %0.1f%% (offset %0.1f%%, drift %0.1f%%, noise %0.1f%%, lock %0.1f%%, offset x drift %0.1f%%)",
              cg_scn.get_inst_coverage(), cg_scn.cp_offset.get_inst_coverage(),
              cg_scn.cp_drift.get_inst_coverage(), cg_scn.cp_noise.get_inst_coverage(),
              cg_scn.cp_lock.get_inst_coverage(), cg_scn.x_off_drift.get_inst_coverage()), UVM_LOW)
  endfunction
endclass

class ring_agent extends uvm_agent;
  `uvm_component_utils(ring_agent)
  ring_sequencer sqr;
  ring_driver    drv;
  ring_monitor   mon;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    sqr = ring_sequencer::type_id::create("sqr", this);
    drv = ring_driver   ::type_id::create("drv", this);
    mon = ring_monitor  ::type_id::create("mon", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass
