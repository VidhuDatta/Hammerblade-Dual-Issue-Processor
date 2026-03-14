/**
 *  scoreboard.sv
 *
 *  Simple scoreboard used by dual-issue core by instantiating multiple
 *  checkers instead of widening dependency/score ports.
 */

`include "bsg_defines.sv"

module scoreboard_dual_issue
  import bsg_vanilla_pkg::*;
  #(els_p = RV32_reg_els_gp
    , `BSG_INV_PARAM(num_src_port_p)
    , num_clear_port_p = 1
    , x0_tied_to_zero_p = 0
    , localparam id_width_lp = `BSG_SAFE_CLOG2(els_p)
  )
  (
    input clk_i
    , input reset_i

    , input [num_src_port_p-1:0][id_width_lp-1:0] src_id_i
    , input [id_width_lp-1:0] dest_id_i

    , input [num_src_port_p-1:0] op_reads_rf_i
    , input op_writes_rf_i

    , input score_i
    , input [id_width_lp-1:0] score_id_i

    , input [num_clear_port_p-1:0] clear_i
    , input [num_clear_port_p-1:0][id_width_lp-1:0] clear_id_i

    , output logic dependency_o
  );

  logic [els_p-1:0] scoreboard_r;

  logic [num_clear_port_p-1:0][els_p-1:0] clear_by_port;
  logic [els_p-1:0][num_clear_port_p-1:0] clear_by_port_t;
  logic [els_p-1:0] clear_combined;

  bsg_transpose #(
    .els_p(num_clear_port_p)
    ,.width_p(els_p)
  ) transpose_clear (
    .i(clear_by_port)
    ,.o(clear_by_port_t)
  );

  for (genvar j = 0; j < num_clear_port_p; j++) begin : clr_decode_v
    bsg_decode_with_v #(
      .num_out_p(els_p)
    ) clear_decode_v (
      .i(clear_id_i[j])
      ,.v_i(clear_i[j])
      ,.o(clear_by_port[j])
    );
  end

  always_comb begin
    for (integer i = 0; i < els_p; i++) begin
      clear_combined[i] = |clear_by_port_t[i];
    end
  end

  // synopsys translate_off
  always_ff @ (negedge clk_i) begin
    if (~reset_i) begin
      for (integer i = 0; i < els_p; i++) begin
        assert($countones(clear_by_port_t[i]) <= 1)
          else $error("[ERROR][SCOREBOARD] multiple clear on the same id. t=%0t", $time);
      end
    end
  end
  // synopsys translate_on

  wire allow_zero = (x0_tied_to_zero_p == 0) | (score_id_i != '0);

  logic [els_p-1:0] score_bits;
  bsg_decode_with_v #(
    .num_out_p(els_p)
  ) score_decode_v (
    .i(score_id_i)
    ,.v_i(score_i & allow_zero)
    ,.o(score_bits)
  );

  always_ff @ (posedge clk_i) begin
    for (integer i = 0; i < els_p; i++) begin
      if (reset_i) begin
        scoreboard_r[i] <= 1'b0;
      end
      else begin
        if (score_bits[i]) begin
          scoreboard_r[i] <= 1'b1;
        end
        else if (clear_combined[i]) begin
          scoreboard_r[i] <= 1'b0;
        end
      end
    end
  end

  logic [num_src_port_p-1:0] rs_depend_on_sb;
  logic rd_depend_on_sb;

  for (genvar i = 0; i < num_src_port_p; i++) begin
    assign rs_depend_on_sb[i] = scoreboard_r[src_id_i[i]] & op_reads_rf_i[i];
  end

  assign rd_depend_on_sb = scoreboard_r[dest_id_i] & op_writes_rf_i;

  logic [num_clear_port_p-1:0][num_src_port_p-1:0] rs_on_clear;
  logic [num_src_port_p-1:0][num_clear_port_p-1:0] rs_on_clear_t;
  logic [num_clear_port_p-1:0] rd_on_clear;

  for (genvar ci = 0; ci < num_clear_port_p; ci++) begin
    for (genvar j = 0; j < num_src_port_p; j++) begin
      assign rs_on_clear[ci][j] = clear_i[ci] & (clear_id_i[ci] == src_id_i[j]);
    end
    assign rd_on_clear[ci] = clear_i[ci] & (clear_id_i[ci] == dest_id_i);
  end

  bsg_transpose #(
    .els_p(num_clear_port_p)
    ,.width_p(num_src_port_p)
  ) transpose_rs_clear (
    .i(rs_on_clear)
    ,.o(rs_on_clear_t)
  );

  logic [num_src_port_p-1:0] rs_on_clear_combined;
  logic rd_on_clear_combined;

  for (genvar j = 0; j < num_src_port_p; j++) begin
    assign rs_on_clear_combined[j] = |rs_on_clear_t[j];
  end

  assign rd_on_clear_combined = |rd_on_clear;

  logic [num_src_port_p-1:0] rs_depend_on_score;
  logic rd_depend_on_score;

  for (genvar j = 0; j < num_src_port_p; j++) begin
    assign rs_depend_on_score[j] = (src_id_i[j] == score_id_i) & op_reads_rf_i[j];
  end

  assign rd_depend_on_score = (dest_id_i == score_id_i) & op_writes_rf_i;

  wire depend_on_sb = |({rd_depend_on_sb, rs_depend_on_sb}
                      & ~{rd_on_clear_combined, rs_on_clear_combined});
  wire depend_on_score = |{rd_depend_on_score, rs_depend_on_score};

  assign dependency_o = depend_on_sb | (depend_on_score & score_i & allow_zero);

  // synopsys translate_off
  always_ff @ (negedge clk_i) begin
    if (~reset_i) begin
      assert((score_bits & clear_combined) == '0)
        else $error("[BSG_ERROR] score and clear on the same id cannot happen.");
    end
  end
  // synopsys translate_on

endmodule

`BSG_ABSTRACT_MODULE(scoreboard_dual_issue)

// Compatibility wrapper for legacy instantiations.
module scoreboard
  import bsg_vanilla_pkg::*;
  #(els_p = RV32_reg_els_gp
    , `BSG_INV_PARAM(num_src_port_p)
    , num_clear_port_p = 1
    , x0_tied_to_zero_p = 0
    , localparam id_width_lp = `BSG_SAFE_CLOG2(els_p)
  )
  (
    input clk_i
    , input reset_i
    , input [num_src_port_p-1:0][id_width_lp-1:0] src_id_i
    , input [id_width_lp-1:0] dest_id_i
    , input [num_src_port_p-1:0] op_reads_rf_i
    , input op_writes_rf_i
    , input score_i
    , input [id_width_lp-1:0] score_id_i
    , input [num_clear_port_p-1:0] clear_i
    , input [num_clear_port_p-1:0][id_width_lp-1:0] clear_id_i
    , output logic dependency_o
  );

  scoreboard_dual_issue #(
    .els_p(els_p)
    ,.num_src_port_p(num_src_port_p)
    ,.num_clear_port_p(num_clear_port_p)
    ,.x0_tied_to_zero_p(x0_tied_to_zero_p)
  ) scoreboard_dual_issue_compat (
    .clk_i(clk_i)
    ,.reset_i(reset_i)
    ,.src_id_i(src_id_i)
    ,.dest_id_i(dest_id_i)
    ,.op_reads_rf_i(op_reads_rf_i)
    ,.op_writes_rf_i(op_writes_rf_i)
    ,.score_i(score_i)
    ,.score_id_i(score_id_i)
    ,.clear_i(clear_i)
    ,.clear_id_i(clear_id_i)
    ,.dependency_o(dependency_o)
  );

endmodule

`BSG_ABSTRACT_MODULE(scoreboard)
