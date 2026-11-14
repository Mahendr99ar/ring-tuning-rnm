#!/usr/bin/env bash
# Run UVM tests in Vivado xsim.  bash run_xsim.sh [test|all]
set -e; cd "$(dirname "$0")"; R=..
xvlog -sv -L uvm -i $R/tb/uvm $R/rtl/sigma_delta_dac.sv $R/rtl/ring_tuner.sv $R/rtl/ring_tuner_top.sv \
  $R/tb/rnm/ring_plant_rnm.sv $R/tb/uvm/ring_if.sv $R/tb/uvm/ring_pkg.sv $R/tb/uvm/ring_sva.sv $R/tb/uvm/tb_top.sv
xelab tb_top -L uvm -timescale 1ns/1ps -debug typical -s ring_sim
T=${1:-ring_lock_test}
[ "$T" = all ] && T="ring_lock_test ring_drift_test ring_noise_test"
for t in $T; do xsim ring_sim -R -log "xsim_$t.log" -testplusarg UVM_TESTNAME=$t; grep -E "PASSED|FAILED" "xsim_$t.log" | tail -1; done
