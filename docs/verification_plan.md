# Verification plan: ring tuning loop

## Requirements

| ID | Requirement |
|----|-------------|
| R1 | Lock within 1.5 ms (150 000 clocks) for any laser offset from 300 to 2000 pm |
| R2 | While tracking, \|detuning\| stays under 25 pm (a quarter of the 100 pm linewidth) |
| R3 | Keep tracking for ambient drift up to ±1 K/ms |
| R4 | Meet R2 with up to 4 LSB (1 sigma) of ADC noise |
| R5 | `locked` is never high while \|detuning\| > 50 pm |
| R6 | No loss of lock during tracking |

## How each one is checked

| Req | Check | Where |
|-----|-------|-------|
| R1 | Lock time measured from `start` | directed T1 to T6, UVM monitor + scoreboard, coverage bins for offset |
| R2 | Maximum of the true \|detuning\| from the real-number model over the tracking window | directed, UVM scoreboard |
| R3 | Ramp the model's ambient temperature during tracking | directed T4/T5, `ring_drift_test`, coverage cross offset x drift |
| R4 | Gaussian ADC noise in the model | directed T6, `ring_noise_test`, coverage bins for noise |
| R5 | Monitor counts clocks with `locked` = 1 and \|detuning\| > 50 pm | UVM scoreboard |
| R6 | Monitor counts clocks with `locked` = 0 in the tracking window | directed, UVM scoreboard |
| - | Heater stays inside centre ± DITHER while tracking | SVA `a_dither_window` |
| - | Tracking moves at most TRACK_STEP codes per decision | SVA `a_small_steps` |
| - | `locked` only in the tracking phase | SVA `a_lock_only_tracking` |
| - | RTL behaves like the algorithm | Python reference model, heater code compared sample by sample |

## Known limit (found with the Python model)

Each decision moves the heater 4 codes (2.3 pm) and takes about 22 µs, so the loop can follow
drift up to roughly 1.4 K/ms. At 1.6 K/ms the worst detuning grows to 34 pm and the loop falls
behind. R3 asks for 1 K/ms, which leaves margin.
