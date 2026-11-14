# Free-tool checks (CI). UVM runs need Vivado: see sim/.
RTL = rtl/sigma_delta_dac.sv rtl/ring_tuner.sv rtl/ring_tuner_top.sv
.PHONY: all lint directed synth model trace clean
all: lint directed synth
lint:
	verilator --lint-only -Wall --top-module ring_tuner_top $(RTL)
	@echo "Lint: clean"
directed:
	iverilog -g2012 -o sim/directed.vvp $(RTL) tb/rnm/ring_plant_rnm.sv tb/directed/tb_ring_directed.sv
	vvp -n sim/directed.vvp | tee sim/directed.log
	@grep -q "RESULT: PASS" sim/directed.log
trace:
	@mkdir -p results
	vvp -n sim/directed.vvp +TRACE > /dev/null
synth:
	@mkdir -p results
	yosys -q -p "read_verilog -sv $(RTL); synth -top ring_tuner_top -flatten; check -assert; tee -o results/yosys_ring_tuner_top.txt stat"
	@echo "Yosys synthesis: ok"
model: directed trace
	python3 model/ring_model.py --corr
clean:
	rm -rf sim/*.vvp sim/*.log sim/xsim.dir sim/*.jou sim/*.pb sim/*.wdb vivado_proj
