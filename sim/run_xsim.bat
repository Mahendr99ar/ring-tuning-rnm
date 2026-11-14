@echo off
REM Run one UVM test in Vivado xsim (Windows). run <Vivado>\settings64.bat first.
REM   run_xsim.bat ring_lock_test | ring_drift_test | ring_noise_test
setlocal
cd /d "%~dp0"
set TEST=%1
if "%TEST%"=="" set TEST=ring_lock_test
call xvlog -sv -L uvm -i ..\tb\uvm ..\rtl\sigma_delta_dac.sv ..\rtl\ring_tuner.sv ..\rtl\ring_tuner_top.sv ..\tb\rnm\ring_plant_rnm.sv ..\tb\uvm\ring_if.sv ..\tb\uvm\ring_pkg.sv ..\tb\uvm\ring_sva.sv ..\tb\uvm\tb_top.sv
if errorlevel 1 exit /b 1
call xelab tb_top -L uvm -timescale 1ns/1ps -debug typical -s ring_sim
if errorlevel 1 exit /b 1
call xsim ring_sim -R -log xsim_%TEST%.log -testplusarg UVM_TESTNAME=%TEST%
endlocal
