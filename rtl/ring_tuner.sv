`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// ring_tuner : finds and tracks the resonance of a micro-ring by driving its
//              heater and watching the through-port photodiode.
//
//  At resonance the through-port power is lowest, so the controller looks for
//  the heater code that gives the minimum ADC reading.
//
//  1. SWEEP  : step the heater code from 0 up to the top in SWEEP_STEP steps.
//              At each step wait SETTLE clocks (the heater is slow), then
//              average 2^NAVG_LOG2 ADC samples. Keep the code with the lowest
//              average.
//  2. TRACK  : dither around the current centre: measure at centre+DITHER and
//              at centre-DITHER, then move the centre TRACK_STEP codes toward
//              the lower reading. Repeat forever, so slow temperature drift is
//              followed.
//  locked = in TRACK and the lower of the two readings is within LOCK_MARGIN
//           ADC codes of the best reading found during the sweep.
//
//  Every heater change goes through one "measure" routine:
//  set code -> wait SETTLE -> average N samples -> return to the caller state.
// -----------------------------------------------------------------------------
module ring_tuner #(
  parameter int CW          = 12,     // heater code width
  parameter int AW          = 10,     // ADC width
  parameter int SWEEP_STEP  = 64,
  parameter int SETTLE      = 512,    // clocks to wait after a heater change
  parameter int NAVG_LOG2   = 3,      // average 8 samples
  parameter int DITHER      = 16,
  parameter int TRACK_STEP  = 4,
  parameter int LOCK_MARGIN = 40
) (
  input  logic          clk,
  input  logic          rst_n,
  input  logic          start,        // pulse: (re)start sweep and lock
  input  logic [AW-1:0] adc_code,
  input  logic          adc_valid,
  output logic [CW-1:0] heater_code,
  output logic          locked,
  output logic [1:0]    phase,        // 0 idle, 1 sweep, 2 track
  output logic [AW-1:0] sweep_min     // lowest reading found by the sweep
);

  localparam int NAVG   = 1 << NAVG_LOG2;
  localparam int CMAX   = (1 << CW) - 1;
  // sized copies of the parameters, so no casts are needed below
  localparam int SETTLE_M1 = SETTLE - 1;
  localparam logic [CW-1:0]      STEP_C   = SWEEP_STEP[CW-1:0];
  localparam logic [CW-1:0]      DITHER_C = DITHER[CW-1:0];
  localparam logic [CW-1:0]      TSTEP_C  = TRACK_STEP[CW-1:0];
  localparam logic [CW-1:0]      CMAX_C   = CMAX[CW-1:0];
  localparam logic [CW-1:0]      CHI_C    = CMAX_C - DITHER_C;      // highest allowed centre
  localparam logic [AW-1:0]      MARGIN_C = LOCK_MARGIN[AW-1:0];
  localparam logic [15:0]        SETTLE_C = SETTLE_M1[15:0];
  localparam logic [NAVG_LOG2:0] NAVG_C   = NAVG[NAVG_LOG2:0];

  typedef enum logic [2:0] {S_IDLE, S_SETTLE, S_ACC, S_SWEEP_NEXT, S_TRACK_PLUS, S_TRACK_MINUS, S_TRACK_DECIDE} st_t;
  typedef enum logic [1:0] {M_SWEEP, M_PLUS, M_MINUS} meas_t;

  st_t     st;
  meas_t   who;                       // which caller started the measurement
  logic [15:0]             settle_cnt;
  logic [NAVG_LOG2:0]      n_acc;
  logic [AW+NAVG_LOG2-1:0] acc;
  logic [AW-1:0]           avg, p_plus, best;
  logic [CW-1:0]           sweep_code, best_code, centre;

  assign avg = acc[AW+NAVG_LOG2-1:NAVG_LOG2];

  // keep the dither inside the code range
  function automatic logic [CW-1:0] clamp_code(input logic [CW-1:0] c);
    if (c < DITHER_C)   clamp_code = DITHER_C;
    else if (c > CHI_C) clamp_code = CHI_C;
    else                clamp_code = c;
  endfunction

  // centre +/- TRACK_STEP, saturating at the dither limits
  logic [CW-1:0] centre_up, centre_dn;
  assign centre_up = (centre >= CHI_C - TSTEP_C)    ? CHI_C    : centre + TSTEP_C;
  assign centre_dn = (centre <= DITHER_C + TSTEP_C) ? DITHER_C : centre - TSTEP_C;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st          <= S_IDLE;
      who         <= M_SWEEP;
      settle_cnt  <= '0;
      n_acc       <= '0;
      acc         <= '0;
      heater_code <= '0;
      sweep_code  <= '0;
      best        <= '1;
      best_code   <= '0;
      centre      <= '0;
      p_plus      <= '0;
      locked      <= 1'b0;
      phase       <= 2'd0;
    end else if (start) begin
      sweep_code  <= '0;
      heater_code <= '0;
      best        <= '1;
      best_code   <= '0;
      locked      <= 1'b0;
      phase       <= 2'd1;
      who         <= M_SWEEP;
      settle_cnt  <= '0;
      st          <= S_SETTLE;
    end else begin
      case (st)
        S_IDLE: ;

        // ---------------- measure routine ----------------
        S_SETTLE: begin
          if (settle_cnt == SETTLE_C) begin
            settle_cnt <= '0;
            n_acc      <= '0;
            acc        <= '0;
            st         <= S_ACC;
          end else settle_cnt <= settle_cnt + 16'd1;
        end

        S_ACC: begin
          if (adc_valid && n_acc != NAVG_C) begin
            acc   <= acc + {{NAVG_LOG2{1'b0}}, adc_code};
            n_acc <= n_acc + 1'b1;
          end
          if (n_acc == NAVG_C) begin
            case (who)
              M_SWEEP: st <= S_SWEEP_NEXT;
              M_PLUS:  st <= S_TRACK_MINUS;
              default: st <= S_TRACK_DECIDE;
            endcase
          end
        end

        // ---------------- sweep ----------------
        S_SWEEP_NEXT: begin
          if (avg < best) begin
            best      <= avg;
            best_code <= sweep_code;
          end
          if (sweep_code > CMAX_C - STEP_C) begin
            // sweep done: start tracking from the best code
            centre      <= clamp_code((avg < best) ? sweep_code : best_code);
            phase       <= 2'd2;
            st          <= S_TRACK_PLUS;
          end else begin
            sweep_code  <= sweep_code + STEP_C;
            heater_code <= sweep_code + STEP_C;
            who         <= M_SWEEP;
            st          <= S_SETTLE;
          end
        end

        // ---------------- track (dither) ----------------
        S_TRACK_PLUS: begin
          heater_code <= centre + DITHER_C;
          who         <= M_PLUS;
          st          <= S_SETTLE;
        end

        S_TRACK_MINUS: begin
          p_plus      <= avg;
          heater_code <= centre - DITHER_C;
          who         <= M_MINUS;
          st          <= S_SETTLE;
        end

        S_TRACK_DECIDE: begin
          if (p_plus < avg)      centre <= centre_up;
          else if (avg < p_plus) centre <= centre_dn;
          locked <= (((p_plus < avg) ? p_plus : avg) <= best + MARGIN_C);
          st     <= S_TRACK_PLUS;
        end

        default: st <= S_IDLE;
      endcase
    end
  end

  assign sweep_min = best;

endmodule
