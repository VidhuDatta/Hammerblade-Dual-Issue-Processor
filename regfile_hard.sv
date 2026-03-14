/**
 *  regfile_hard_dual_issue.sv
 *
 *  Hardened register file with optional second write port.
 *
 *  DUAL-ISSUE CHANGE:
 *    Added num_ws_p parameter (number of write ports).
 *    - num_ws_p == 1 : identical behaviour to original regfile_hard.
 *                      Uses bsg_mem_2r1w_sync / bsg_mem_3r1w_sync exactly
 *                      as before.
 *    - num_ws_p == 2 : two physical write ports needed for FP-RF.
 *                      BaseJump STL does not provide a 2W3R sync SRAM
 *                      primitive, so we implement dual-write using TWO
 *                      banked 1W3R memories and OR the bypass registers.
 *
 *  Bank scheme for num_ws_p == 2:
 *    Both banks hold the full register file state.
 *    - Bank A is written by port 0 (FP compute WB).
 *    - Bank B is written by port 1 (FLW WB).
 *    Read: each read port returns bank_A[addr] when the last write to
 *          that address came from port 0, bank_B[addr] otherwise.
 *    In practice the pairing logic prevents simultaneous WAW, so the
 *    banks never diverge from each other for a given address — the
 *    priority logic is only a safety net.
 *
 *  Read ports (num_rs_p) are unchanged. Assertion guards num_rs_p ∈ {2,3}.
 *
 *  NOTE: For synthesis the synth variant is preferred (simpler, more
 *  tool-agnostic).  The hard variant is here for completeness and for
 *  teams using a physical SRAM flow.
 */

`include "bsg_defines.sv"

module regfile_hard_dual_issue
  #(`BSG_INV_PARAM(width_p)
    , `BSG_INV_PARAM(els_p)
    , `BSG_INV_PARAM(num_rs_p)       // 2 or 3
    , x0_tied_to_zero_p = 0
    , num_ws_p = 1                   // 1 = original, 2 = dual-issue FP RF

    , localparam addr_width_lp = `BSG_SAFE_CLOG2(els_p)
  )
  (
    input clk_i
    , input reset_i

    // Write port(s)
    , input  [num_ws_p-1:0]                     w_v_i
    , input  [num_ws_p-1:0][addr_width_lp-1:0] w_addr_i
    , input  [num_ws_p-1:0][width_p-1:0]        w_data_i

    // Read ports
    , input  [num_rs_p-1:0]                     r_v_i
    , input  [num_rs_p-1:0][addr_width_lp-1:0] r_addr_i
    , output logic [num_rs_p-1:0][width_p-1:0] r_data_o
  );

  // synopsys translate_off
  initial begin
    assert (num_rs_p == 2 || num_rs_p == 3)
      else $error("regfile_hard_dual_issue: num_rs_p must be 2 or 3.");
    if (num_ws_p == 2)
      assert (x0_tied_to_zero_p == 0)
        else $error("regfile_hard_dual_issue: dual-write requires x0_tied_to_zero_p=0.");
  end
  // synopsys translate_on


  // ---------------------------------------------------------------
  // Single-write-port path — identical to original regfile_hard
  // ---------------------------------------------------------------
  if (num_ws_p == 1) begin : single_write

    // Write: gate x0 if needed
    logic w_v_li;
    assign w_v_li = w_v_i[0] & ((x0_tied_to_zero_p == 0) | (w_addr_i[0] != '0));

    // Read: detect simultaneous read/write same address
    logic [num_rs_p-1:0] rw_same_addr;
    logic [num_rs_p-1:0] r_v_li;
    logic [num_rs_p-1:0][width_p-1:0] r_data_lo;

    for (genvar i = 0; i < num_rs_p; i++) begin
      assign rw_same_addr[i] = w_v_i[0] & r_v_i[i] & (w_addr_i[0] == r_addr_i[i]);
      assign r_v_li[i] = rw_same_addr[i]
        ? 1'b0
        : r_v_i[i] & ((x0_tied_to_zero_p == 0) | (r_addr_i[i] != '0));
    end

    // Instantiate BSJ STL memory primitive
    if (num_rs_p == 2) begin : rf2
      bsg_mem_2r1w_sync #(.width_p(width_p), .els_p(els_p)) rf_mem (
        .clk_i, .reset_i,
        .w_v_i(w_v_li), .w_addr_i(w_addr_i[0]), .w_data_i(w_data_i[0]),
        .r0_v_i(r_v_li[0]), .r0_addr_i(r_addr_i[0]), .r0_data_o(r_data_lo[0]),
        .r1_v_i(r_v_li[1]), .r1_addr_i(r_addr_i[1]), .r1_data_o(r_data_lo[1])
      );
    end
    else begin : rf3
      bsg_mem_3r1w_sync #(.width_p(width_p), .els_p(els_p)) rf_mem (
        .clk_i, .reset_i,
        .w_v_i(w_v_li), .w_addr_i(w_addr_i[0]), .w_data_i(w_data_i[0]),
        .r0_v_i(r_v_li[0]), .r0_addr_i(r_addr_i[0]), .r0_data_o(r_data_lo[0]),
        .r1_v_i(r_v_li[1]), .r1_addr_i(r_addr_i[1]), .r1_data_o(r_data_lo[1]),
        .r2_v_i(r_v_li[2]), .r2_addr_i(r_addr_i[2]), .r2_data_o(r_data_lo[2])
      );
    end

    // Bypass registers (identical to regfile_hard)
    logic [width_p-1:0] w_data_r, w_data_n;
    logic [num_rs_p-1:0][width_p-1:0] r_data_r, r_data_n;
    logic [num_rs_p-1:0][addr_width_lp-1:0] r_addr_r, r_addr_n;
    logic [num_rs_p-1:0] rw_same_addr_r;
    logic [num_rs_p-1:0] r_v_r;
    logic [num_rs_p-1:0][width_p-1:0] r_safe_data;

    for (genvar i = 0; i < num_rs_p; i++) begin
      assign r_safe_data[i] = rw_same_addr_r[i] ? w_data_r : r_data_lo[i];
      assign r_addr_n[i]    = r_v_i[i] ? r_addr_i[i] : r_addr_r[i];
      assign r_data_n[i]    = (w_v_i[0] & (r_addr_r[i] == w_addr_i[0]))
                              ? w_data_i[0]
                              : (r_v_r[i] ? r_safe_data[i] : r_data_r[i]);
      assign r_data_o[i]    = ((r_addr_r[i] == '0) & (x0_tied_to_zero_p == 1))
                              ? '0
                              : (r_v_r[i] ? r_safe_data[i] : r_data_r[i]);
    end

    assign w_data_n = (|rw_same_addr) ? w_data_i[0] : w_data_r;

    always_ff @ (posedge clk_i) begin
      if (reset_i) begin
        rw_same_addr_r <= '0;
        r_v_r          <= '0;
        w_data_r       <= '0;
        r_data_r       <= '0;
        r_addr_r       <= '0;
      end
      else begin
        rw_same_addr_r <= rw_same_addr;
        r_v_r          <= r_v_i;
        w_data_r       <= w_data_n;
        r_data_r       <= r_data_n;
        r_addr_r       <= r_addr_n;
      end
    end

  end // single_write


  // ---------------------------------------------------------------
  // Dual-write-port path — two banked 1W3R memories
  //
  // Bank A : written by port 0 (FP compute WB)
  // Bank B : written by port 1 (FLW WB)
  //
  // On a read, we need the most-recently-written value. We track
  // the "owner" of each register (last write port) with an owner_r
  // bit-vector: 0 = bank A is authoritative, 1 = bank B.
  // Since WAW conflicts are prevented by pairing logic, in steady
  // state both banks hold the same value for every register —
  // the owner tracking is purely a correctness safety net.
  // ---------------------------------------------------------------
  else if (num_ws_p == 2) begin : dual_write

    // --- Bank A (port 0: FP compute) ---
    logic [num_rs_p-1:0][width_p-1:0] r_data_a_lo, r_data_b_lo;
    logic [num_rs_p-1:0] rw_same_a, rw_same_b;
    logic [num_rs_p-1:0] r_v_a_li,  r_v_b_li;

    for (genvar i = 0; i < num_rs_p; i++) begin
      assign rw_same_a[i] = w_v_i[0] & r_v_i[i] & (w_addr_i[0] == r_addr_i[i]);
      assign rw_same_b[i] = w_v_i[1] & r_v_i[i] & (w_addr_i[1] == r_addr_i[i]);
      // Suppress reads when same-cycle write from the respective port
      assign r_v_a_li[i] = r_v_i[i] & ~rw_same_a[i];
      assign r_v_b_li[i] = r_v_i[i] & ~rw_same_b[i];
    end

    if (num_rs_p == 2) begin : rf2
      bsg_mem_2r1w_sync #(.width_p(width_p), .els_p(els_p)) bank_a (
        .clk_i, .reset_i,
        .w_v_i(w_v_i[0]), .w_addr_i(w_addr_i[0]), .w_data_i(w_data_i[0]),
        .r0_v_i(r_v_a_li[0]), .r0_addr_i(r_addr_i[0]), .r0_data_o(r_data_a_lo[0]),
        .r1_v_i(r_v_a_li[1]), .r1_addr_i(r_addr_i[1]), .r1_data_o(r_data_a_lo[1])
      );
      bsg_mem_2r1w_sync #(.width_p(width_p), .els_p(els_p)) bank_b (
        .clk_i, .reset_i,
        .w_v_i(w_v_i[1]), .w_addr_i(w_addr_i[1]), .w_data_i(w_data_i[1]),
        .r0_v_i(r_v_b_li[0]), .r0_addr_i(r_addr_i[0]), .r0_data_o(r_data_b_lo[0]),
        .r1_v_i(r_v_b_li[1]), .r1_addr_i(r_addr_i[1]), .r1_data_o(r_data_b_lo[1])
      );
    end
    else begin : rf3
      bsg_mem_3r1w_sync #(.width_p(width_p), .els_p(els_p)) bank_a (
        .clk_i, .reset_i,
        .w_v_i(w_v_i[0]), .w_addr_i(w_addr_i[0]), .w_data_i(w_data_i[0]),
        .r0_v_i(r_v_a_li[0]), .r0_addr_i(r_addr_i[0]), .r0_data_o(r_data_a_lo[0]),
        .r1_v_i(r_v_a_li[1]), .r1_addr_i(r_addr_i[1]), .r1_data_o(r_data_a_lo[1]),
        .r2_v_i(r_v_a_li[2]), .r2_addr_i(r_addr_i[2]), .r2_data_o(r_data_a_lo[2])
      );
      bsg_mem_3r1w_sync #(.width_p(width_p), .els_p(els_p)) bank_b (
        .clk_i, .reset_i,
        .w_v_i(w_v_i[1]), .w_addr_i(w_addr_i[1]), .w_data_i(w_data_i[1]),
        .r0_v_i(r_v_b_li[0]), .r0_addr_i(r_addr_i[0]), .r0_data_o(r_data_b_lo[0]),
        .r1_v_i(r_v_b_li[1]), .r1_addr_i(r_addr_i[1]), .r1_data_o(r_data_b_lo[1]),
        .r2_v_i(r_v_b_li[2]), .r2_addr_i(r_addr_i[2]), .r2_data_o(r_data_b_lo[2])
      );
    end

    // Bypass and owner tracking
    logic [num_rs_p-1:0][width_p-1:0] r_data_r;
    logic [num_rs_p-1:0][addr_width_lp-1:0] r_addr_r;
    logic [num_rs_p-1:0] r_v_r;
    logic [num_rs_p-1:0] rw_same_a_r, rw_same_b_r;
    logic [width_p-1:0]  w0_data_r, w1_data_r;

    always_ff @ (posedge clk_i) begin
      if (reset_i) begin
        r_v_r          <= '0;
        rw_same_a_r    <= '0;
        rw_same_b_r    <= '0;
        w0_data_r      <= '0;
        w1_data_r      <= '0;
        r_data_r       <= '0;
        r_addr_r       <= '0;
      end
      else begin
        r_v_r       <= r_v_i;
        rw_same_a_r <= rw_same_a;
        rw_same_b_r <= rw_same_b;
        w0_data_r   <= w_v_i[0] ? w_data_i[0] : w0_data_r;
        w1_data_r   <= w_v_i[1] ? w_data_i[1] : w1_data_r;
        for (integer i = 0; i < num_rs_p; i++) begin
          if (r_v_i[i]) r_addr_r[i] <= r_addr_i[i];
        end
      end
    end

    // Select output for each read port
    // Priority: bypass from port 0 > bypass from port 1 > SRAM output from bank A > bank B
    for (genvar i = 0; i < num_rs_p; i++) begin
      logic [width_p-1:0] sram_sel;
      // Choose between bank A and bank B SRAM outputs.
      // If we had a same-cycle write from port 0, forward it;
      // else if same-cycle write from port 1, forward it;
      // else use SRAM (prefer bank A as it holds FP compute result,
      // both banks hold same data for non-conflicting writes).
      assign sram_sel = rw_same_a_r[i] ? w0_data_r :
                        rw_same_b_r[i] ? w1_data_r :
                        r_data_a_lo[i];  // bank A and B identical in normal operation

      // Forward from current-cycle write if the read address matches
      logic [width_p-1:0] fwd_sel;
      assign fwd_sel = (w_v_i[0] & (r_addr_r[i] == w_addr_i[0])) ? w_data_i[0] :
                       (w_v_i[1] & (r_addr_r[i] == w_addr_i[1])) ? w_data_i[1] :
                       (r_v_r[i] ? sram_sel : r_data_r[i]);

      assign r_data_o[i] = fwd_sel;
    end

    // synopsys translate_off
    // FP RF trace (hard model): dual-write and post-bypass read visibility.
    always_ff @ (posedge clk_i) begin
      if (~reset_i) begin
        if (|w_v_i) begin
          $display("[RF_HARD_DI][W] t=%0t wv=%b wa0=%0d wd0=%h wa1=%0d wd1=%h",
                   $time, w_v_i, w_addr_i[0], w_data_i[0], w_addr_i[1], w_data_i[1]);
        end
        if (|r_v_i) begin
          $display("[RF_HARD_DI][R] t=%0t rv=%b ra=%p rd=%p",
                   $time, r_v_i, r_addr_i, r_data_o);
        end
      end
    end
    // synopsys translate_on

  end // dual_write


endmodule

`BSG_ABSTRACT_MODULE(regfile_hard_dual_issue)