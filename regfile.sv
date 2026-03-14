/**
 *  regfile_dual_issue.sv
 *
 *  Register file — top-level wrapper with optional second write port.
 *
 *  DUAL-ISSUE CHANGE vs original regfile.sv:
 *    Added num_ws_p parameter (number of write ports, default = 1).
 *
 *  When num_ws_p == 1:
 *    Port interface is structurally identical to the original regfile.sv
 *    EXCEPT that write signals are now packed arrays of size 1:
 *      w_v_i    [0:0]       instead of a scalar
 *      w_addr_i [0:0][4:0]  instead of a plain [4:0]
 *      w_data_i [0:0][31:0] instead of a plain [31:0]
 *    SystemVerilog allows connecting a scalar to a [0:0] packed array,
 *    so existing instantiation sites require only the num_ws_p parameter
 *    addition and no signal renames.
 *
 *  When num_ws_p == 2 (FP register file in dual-issue core):
 *    w_v_i    [1:0]
 *    w_addr_i [1:0][4:0]
 *    w_data_i [1:0][31:0]
 *    Port [0] = FP-compute writeback (original path)
 *    Port [1] = FLW writeback (new dual-issue path)
 *
 *  Read ports (num_rs_p) are completely unchanged.
 *
 *  Instantiation in vanilla_core_dual_issue.sv
 *  -------------------------------------------
 *  INT register file (unchanged behaviour):
 *    regfile_dual_issue #(
 *      .width_p(32), .els_p(32), .num_rs_p(2),
 *      .x0_tied_to_zero_p(1), .num_ws_p(1),
 *      .harden_p(harden_p)
 *    ) int_rf (
 *      .w_v_i   ({1'b0, int_wb_v}),     // or just {int_wb_v}
 *      .w_addr_i({5'b0, int_wb_addr}),
 *      .w_data_i({32'b0, int_wb_data}),
 *      ...
 *    );
 *
 *  FP register file (dual-write):
 *    regfile_dual_issue #(
 *      .width_p(33), .els_p(32), .num_rs_p(3),
 *      .x0_tied_to_zero_p(0), .num_ws_p(2),
 *      .harden_p(harden_p)
 *    ) fp_rf (
 *      .w_v_i   ({flw_wb_v,   fp_wb_v  }),  // [1]=FLW, [0]=FP compute
 *      .w_addr_i({flw_wb_addr, fp_wb_addr}),
 *      .w_data_i({flw_wb_data, fp_wb_data}),
 *      ...
 *    );
 */

`include "bsg_defines.sv"

module regfile_dual_issue
  #(`BSG_INV_PARAM(width_p)
    , `BSG_INV_PARAM(els_p)
    , `BSG_INV_PARAM(num_rs_p)
    , `BSG_INV_PARAM(x0_tied_to_zero_p)
    , harden_p  = 0
    , num_ws_p  = 1   // NEW: 1 = single write (original), 2 = dual write (FP RF)

    , localparam addr_width_lp = `BSG_SAFE_CLOG2(els_p)
  )
  (
    input clk_i
    , input reset_i

    // Write port(s) — size-1 arrays when num_ws_p==1 are wire-compatible
    // with plain scalars in SystemVerilog.
    , input  [num_ws_p-1:0]                     w_v_i
    , input  [num_ws_p-1:0][addr_width_lp-1:0] w_addr_i
    , input  [num_ws_p-1:0][width_p-1:0]        w_data_i

    // Read ports — unchanged
    , input  [num_rs_p-1:0]                     r_v_i
    , input  [num_rs_p-1:0][addr_width_lp-1:0] r_addr_i
    , output logic [num_rs_p-1:0][width_p-1:0] r_data_o
  );


  if (harden_p) begin : hard
    regfile_hard_dual_issue #(
      .width_p          (width_p)
      ,.els_p           (els_p)
      ,.num_rs_p        (num_rs_p)
      ,.x0_tied_to_zero_p(x0_tied_to_zero_p)
      ,.num_ws_p        (num_ws_p)
    ) rf (.*);
  end
  else begin : synth
    regfile_synth_dual_issue #(
      .width_p          (width_p)
      ,.els_p           (els_p)
      ,.num_rs_p        (num_rs_p)
      ,.x0_tied_to_zero_p(x0_tied_to_zero_p)
      ,.num_ws_p        (num_ws_p)
    ) rf (.*);
  end


endmodule

`BSG_ABSTRACT_MODULE(regfile_dual_issue)

// Compatibility wrapper for legacy instantiations.
module regfile
  #(`BSG_INV_PARAM(width_p)
    , `BSG_INV_PARAM(els_p)
    , `BSG_INV_PARAM(num_rs_p)
    , `BSG_INV_PARAM(x0_tied_to_zero_p)
    , harden_p = 0
    , localparam addr_width_lp = `BSG_SAFE_CLOG2(els_p)
  )
  (
    input clk_i
    , input reset_i
    , input w_v_i
    , input [addr_width_lp-1:0] w_addr_i
    , input [width_p-1:0] w_data_i
    , input [num_rs_p-1:0] r_v_i
    , input [num_rs_p-1:0][addr_width_lp-1:0] r_addr_i
    , output logic [num_rs_p-1:0][width_p-1:0] r_data_o
  );

  regfile_dual_issue #(
    .width_p(width_p)
    ,.els_p(els_p)
    ,.num_rs_p(num_rs_p)
    ,.x0_tied_to_zero_p(x0_tied_to_zero_p)
    ,.harden_p(harden_p)
    ,.num_ws_p(1)
  ) regfile_dual_issue_compat (
    .clk_i(clk_i)
    ,.reset_i(reset_i)
    ,.w_v_i({w_v_i})
    ,.w_addr_i({w_addr_i})
    ,.w_data_i({w_data_i})
    ,.r_v_i(r_v_i)
    ,.r_addr_i(r_addr_i)
    ,.r_data_o(r_data_o)
  );

endmodule

`BSG_ABSTRACT_MODULE(regfile)