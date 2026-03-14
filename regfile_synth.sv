/**
 *  regfile_synth_dual_issue.sv
 *
 *  Synthesized register file with optional second write port.
 *
 *  DUAL-ISSUE CHANGE:
 *    Added num_ws_p parameter (number of write ports).
 *    - num_ws_p == 1 : identical behaviour to original regfile_synth
 *    - num_ws_p == 2 : adds a second write port for FP-RF dual writeback
 *                      (FP-compute WB uses port 0, FLW WB uses port 1)
 *
 *  Port convention when num_ws_p == 2:
 *    w_v_i    [1:0]       — write valid for each port
 *    w_addr_i [1:0][4:0]  — write address for each port
 *    w_data_i [1:0][31:0] — write data for each port
 *
 *  WAW policy:
 *    Port 0 (FP compute) takes priority over port 1 (FLW) when both
 *    write the same register in the same cycle.  The pairing logic
 *    in vanilla_core already prevents this case for valid programs,
 *    so this is just a safe-default tie-break.
 *
 *  Read ports (num_rs_p) are unchanged.
 */

`include "bsg_defines.sv"

module regfile_synth_dual_issue
  #(`BSG_INV_PARAM(width_p)
    , `BSG_INV_PARAM(els_p)
    , `BSG_INV_PARAM(num_rs_p)
    , `BSG_INV_PARAM(x0_tied_to_zero_p)
    , num_ws_p = 1   // number of write ports (1 = original, 2 = dual-issue FP RF)

    , localparam addr_width_lp = `BSG_SAFE_CLOG2(els_p)
  )
  (
    input clk_i
    , input reset_i

    // Write port(s) — packed arrays; [0] = primary (original), [1] = FLW port
    , input  [num_ws_p-1:0]                      w_v_i
    , input  [num_ws_p-1:0][addr_width_lp-1:0]  w_addr_i
    , input  [num_ws_p-1:0][width_p-1:0]         w_data_i

    // Read ports — unchanged
    , input  [num_rs_p-1:0]                      r_v_i
    , input  [num_rs_p-1:0][addr_width_lp-1:0]  r_addr_i
    , output logic [num_rs_p-1:0][width_p-1:0]  r_data_o
  );

  // Suppress unused warning on reset (same as original)
  wire unused = reset_i;

  // Register the read addresses (sync read, same as original)
  logic [num_rs_p-1:0][addr_width_lp-1:0] r_addr_r;

  always_ff @ (posedge clk_i)
    for (integer i = 0; i < num_rs_p; i++)
      if (r_v_i[i]) r_addr_r[i] <= r_addr_i[i];


  // ---------------------------------------------------------------
  // Single-write-port path (num_ws_p == 1)
  // Identical to the original regfile_synth. Generated only when
  // num_ws_p is 1 so there is no extra logic for the INT RF.
  // ---------------------------------------------------------------
  if (num_ws_p == 1) begin : single_write

    if (x0_tied_to_zero_p) begin : xz
      logic [width_p-1:0] mem_r [els_p-1:1];

      for (genvar i = 0; i < num_rs_p; i++)
        assign r_data_o[i] = (r_addr_r[i] == '0) ? '0 : mem_r[r_addr_r[i]];

      always_ff @ (posedge clk_i)
        if (w_v_i[0] & (w_addr_i[0] != '0))
          mem_r[w_addr_i[0]] <= w_data_i[0];
    end

    else begin : xnz
      logic [width_p-1:0] mem_r [els_p-1:0];

      for (genvar i = 0; i < num_rs_p; i++)
        assign r_data_o[i] = mem_r[r_addr_r[i]];

      always_ff @ (posedge clk_i)
        if (w_v_i[0])
          mem_r[w_addr_i[0]] <= w_data_i[0];
    end

  end // single_write


  // ---------------------------------------------------------------
  // Dual-write-port path (num_ws_p == 2)
  // Used exclusively for the FP register file in the dual-issue core.
  //
  // Implementation strategy: two independent always_ff write blocks.
  // Port 0 (FP compute) fires last in the always_ff sensitivity list,
  // so it naturally wins any same-cycle WAW conflict (safe tie-break).
  // The pairing logic guarantees this never happens for correct programs.
  //
  // FP RF never has x0-tied-to-zero (floating-point f0 is a real reg),
  // so only the xnz path is implemented here. An assertion guards this.
  // ---------------------------------------------------------------
  else if (num_ws_p == 2) begin : dual_write

    // synopsys translate_off
    initial begin
      assert (x0_tied_to_zero_p == 0)
        else $error("regfile_synth_dual_issue: dual-write port is only supported with x0_tied_to_zero_p=0 (FP RF does not tie f0 to zero).");
    end
    // synopsys translate_on

    logic [width_p-1:0] mem_r [els_p-1:0];

    // Read output — combinational from registered address
    for (genvar i = 0; i < num_rs_p; i++)
      assign r_data_o[i] = mem_r[r_addr_r[i]];

    // Write port 1 (FLW writeback) — lower priority
    // Fires when valid and target is not x0 (for safety, though FP RF
    // never maps f0 to zero — kept consistent with port 0 behaviour).
    always_ff @ (posedge clk_i) begin
      if (w_v_i[1])
        mem_r[w_addr_i[1]] <= w_data_i[1];
      if (w_v_i[0])
        mem_r[w_addr_i[0]] <= w_data_i[0];
      end

    // synopsys translate_off
    // FP RF trace (synth model): write/read activity for dual-write path.
    always_ff @ (posedge clk_i) begin
      if (~reset_i) begin
        if (|w_v_i) begin
          $display("[RF_SYN_DI][W] t=%0t wv=%b wa0=%0d wd0=%h wa1=%0d wd1=%h",
                   $time, w_v_i, w_addr_i[0], w_data_i[0], w_addr_i[1], w_data_i[1]);
        end
        if (|r_v_i) begin
          $display("[RF_SYN_DI][R] t=%0t rv=%b ra=%p rd=%p",
                   $time, r_v_i, r_addr_i, r_data_o);
        end
      end
    end
    // synopsys translate_on

    // Write port 0 (FP compute writeback) — higher priority
    // Declared AFTER port 1 so it wins on same-address same-cycle writes
    // (SystemVerilog non-blocking assignment semantics: last scheduled wins
    //  when both write the same element in the same time step).


  end // dual_write


endmodule

`BSG_ABSTRACT_MODULE(regfile_synth_dual_issue)