# Vivado project for the ring tuning UVM testbench.
#   Tools -> Run Tcl Script... -> this file, then Run Behavioral Simulation
set script_dir [file dirname [file normalize [info script]]]
set root       [file normalize "$script_dir/.."]
create_project ring_uvm "$root/vivado_proj" -force
add_files -norecurse [glob "$root/rtl/*.sv"]
set_property top ring_tuner_top [get_filesets sources_1]
add_files -fileset sim_1 -norecurse [concat [glob "$root/tb/uvm/*.sv" "$root/tb/uvm/*.svh"] [list "$root/tb/rnm/ring_plant_rnm.sv"]]
set_property include_dirs [list "$root/tb/uvm"] [get_filesets sim_1]
set_property top     tb_top         [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
set sim [get_filesets sim_1]
set_property -name {xsim.compile.xvlog.more_options}   -value {-L uvm} -objects $sim
set_property -name {xsim.elaborate.xelab.more_options} -value {-L uvm} -objects $sim
set_property -name {xsim.simulate.xsim.more_options} -value {-testplusarg UVM_TESTNAME=ring_lock_test} -objects $sim
set_property -name {xsim.simulate.runtime} -value {all} -objects $sim
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
puts "\nProject ready. Run Simulation -> Run Behavioral Simulation"
puts "Other tests: ring_drift_test, ring_noise_test"
