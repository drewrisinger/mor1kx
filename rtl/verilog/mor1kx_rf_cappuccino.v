/* ****************************************************************************
  This Source Code Form is subject to the terms of the
  Open Hardware Description License, v. 1.0. If a copy
  of the OHDL was not distributed with this file, You
  can obtain one at http://juliusbaxter.net/ohdl/ohdl.txt

  Description: Register file for cappuccino pipeline
  Handles reading the register file rams and register bypassing.

  Copyright (C) 2012 Authors

  Author(s): Julius Baxter <juliusbaxter@gmail.com>
             Stefan Kristiansson <stefan.kristiansson@saunalahti.fi>

***************************************************************************** */

`include "mor1kx-defines.v"

module mor1kx_rf_cappuccino
  #(
    parameter OPTION_RF_ADDR_WIDTH = 5,
    parameter OPTION_RF_WORDS = 32,

    parameter OPTION_OPERAND_WIDTH = 32
    )
   (
    input 			      clk,
    input 			      rst,

    // pipeline control signal in
    input 			      padv_decode_i,
    input 			      padv_execute_i,
    input 			      padv_ctrl_i,


    input 			      decode_valid_i,

    input 			      fetch_rf_adr_valid_i,

    // GPR numbers
    input [OPTION_RF_ADDR_WIDTH-1:0]  fetch_rfb_adr_i,

    input [OPTION_RF_ADDR_WIDTH-1:0]  decode_rfa_adr_i,
    input [OPTION_RF_ADDR_WIDTH-1:0]  decode_rfb_adr_i,

    input [OPTION_RF_ADDR_WIDTH-1:0]  execute_rfd_adr_i,
    input [OPTION_RF_ADDR_WIDTH-1:0]  ctrl_rfd_adr_i,
    input [OPTION_RF_ADDR_WIDTH-1:0]  wb_rfd_adr_i,

    // Write back signal indications
    input 			      execute_rf_wb_i,
    input 			      ctrl_rf_wb_i,
    input 			      wb_rf_wb_i,

    input 			      execute_op_jal_i,
    input 			      ctrl_op_jal_i,

    input [OPTION_OPERAND_WIDTH-1:0]  result_i,
    input [OPTION_OPERAND_WIDTH-1:0]  ctrl_alu_result_i,
    input [OPTION_OPERAND_WIDTH-1:0]  execute_jal_result_i,

    input 			      pipeline_flush_i,

    output [OPTION_OPERAND_WIDTH-1:0] decode_rfb_o,
    output [OPTION_OPERAND_WIDTH-1:0] execute_rfa_o,
    output [OPTION_OPERAND_WIDTH-1:0] execute_rfb_o
    );

   wire [OPTION_OPERAND_WIDTH-1:0]    rfa_ram_o;
   wire [OPTION_OPERAND_WIDTH-1:0]    rfb_ram_o;

   reg [OPTION_OPERAND_WIDTH-1:0]     wb_hazard_result;
   reg [OPTION_OPERAND_WIDTH-1:0]     execute_rfb;

   wire 			      rfa_rden;
   wire 			      rfb_rden;

   wire 			      rf_wren;

   reg 				      flushing;

   // Keep track of the flush signal, this is needed to not wrongly assert
   // execute_hazard after an exception (or rfe) has happened.
   // What happens in that case is that the instruction in execute stage is
   // invalid until the next padv_decode, so it's execute_rfd_adr can not be
   // used to evaluate the execute_hazard.
   always @(posedge clk)
     if (pipeline_flush_i)
       flushing <= 1;
     else if (padv_decode_i)
       flushing <= 0;

   // Detect hazards
   reg execute_hazard_a;
   reg execute_hazard_b;
   always @(posedge clk)
     if (pipeline_flush_i) begin
	execute_hazard_a <= 0;
	execute_hazard_b <= 0;
     end else if (padv_decode_i & !flushing) begin
	execute_hazard_a <= execute_rf_wb_i &
			    (execute_rfd_adr_i == decode_rfa_adr_i);
	execute_hazard_b <= execute_rf_wb_i &
			    (execute_rfd_adr_i == decode_rfb_adr_i);
     end

   reg [OPTION_OPERAND_WIDTH-1:0] execute_hazard_result_r;
   always @(posedge clk)
     if (decode_valid_i)
       execute_hazard_result_r <= ctrl_alu_result_i;

   wire [OPTION_OPERAND_WIDTH-1:0] execute_hazard_result;
   assign execute_hazard_result = decode_valid_i ? ctrl_alu_result_i :
				  execute_hazard_result_r;

   reg ctrl_hazard_a;
   reg ctrl_hazard_b;
   always @(posedge clk)
      if (padv_decode_i) begin
	 ctrl_hazard_a <= ctrl_rf_wb_i & (ctrl_rfd_adr_i == decode_rfa_adr_i);
	 ctrl_hazard_b <= ctrl_rf_wb_i & (ctrl_rfd_adr_i == decode_rfb_adr_i);
     end

   reg [OPTION_OPERAND_WIDTH-1:0] ctrl_hazard_result_r;
   always @(posedge clk)
     if (decode_valid_i)
       ctrl_hazard_result_r <= result_i;

   wire [OPTION_OPERAND_WIDTH-1:0] ctrl_hazard_result;
   assign ctrl_hazard_result = decode_valid_i ? result_i : ctrl_hazard_result_r;

   reg wb_hazard_a;
   reg wb_hazard_b;
   always @(posedge clk)
     if (padv_decode_i) begin
	wb_hazard_a <= wb_rf_wb_i & (wb_rfd_adr_i == decode_rfa_adr_i);
	wb_hazard_b <= wb_rf_wb_i & (wb_rfd_adr_i == decode_rfb_adr_i);
     end

   always @(posedge clk `OR_ASYNC_RST)
     if (rst)
       wb_hazard_result <= 0;
     else if (padv_decode_i)
       wb_hazard_result <= result_i;

   // Since the decode stage doesn't read from the register file, we have to
   // save any writes to the current read addresses in decode stage until
   // fetch latch in new values.
   reg 				  use_last_wb_b;
   reg [OPTION_OPERAND_WIDTH-1:0] last_wb_result_b;
   always @(posedge clk)
     if (fetch_rf_adr_valid_i) begin
	use_last_wb_b <= 0;
     end else if (wb_rf_wb_i) begin
	if (decode_rfb_adr_i == wb_rfd_adr_i) begin
	   last_wb_result_b <= result_i;
	   use_last_wb_b <= 1;
	end
     end

   // Bypassing to decode stage
   //
   // Bypassing is only done to port B, since the only instructions
   // that need register output in decode stage is the jump to register
   // instructions, which all use port B as its input.

   // This bypass can probably be omitted.
   // For this to happen, a 'l.jr r9' has to be in a delay slot of a 'l.jal(r)'.
   // (Remember, only 'l.jal(r)' produces a register result in decode stage)
   wire decode_to_decode_bypass_b;
   assign decode_to_decode_bypass_b = execute_op_jal_i &
				      (decode_rfb_adr_i == 9);

   wire execute_to_decode_bypass_b;
   assign execute_to_decode_bypass_b = ctrl_rf_wb_i &
				       (ctrl_rfd_adr_i == decode_rfb_adr_i);

   wire ctrl_to_decode_bypass_b;
   assign ctrl_to_decode_bypass_b = use_last_wb_b | wb_rf_wb_i &
				    (wb_rfd_adr_i == decode_rfb_adr_i);

   wire [OPTION_OPERAND_WIDTH-1:0] ctrl_to_decode_result;
   assign ctrl_to_decode_result = use_last_wb_b ? last_wb_result_b : result_i;

   // TODO: Can this be combined with 'use_last_wb_b' to save a 32 bit register?
   reg wb_to_decode_bypass_b;
   always @(posedge clk)
     if (fetch_rf_adr_valid_i) begin
	wb_to_decode_bypass_b <= wb_rf_wb_i & (wb_rfd_adr_i == fetch_rfb_adr_i);
     end

   reg [OPTION_OPERAND_WIDTH-1:0] wb_to_decode_result;
   always @(posedge clk `OR_ASYNC_RST)
     if (rst)
       wb_to_decode_result <= 0;
     else if (fetch_rf_adr_valid_i)
       wb_to_decode_result <= result_i;

   assign decode_rfb_o = decode_to_decode_bypass_b ? execute_jal_result_i :
			 execute_to_decode_bypass_b ? ctrl_alu_result_i :
			 ctrl_to_decode_bypass_b ? ctrl_to_decode_result :
			 wb_to_decode_bypass_b ? wb_to_decode_result :
			 rfb_ram_o;

   assign execute_rfa_o = execute_hazard_a ? execute_hazard_result :
			  ctrl_hazard_a ? ctrl_hazard_result :
			  wb_hazard_a ? wb_hazard_result :
			  rfa_ram_o;

   assign execute_rfb_o = execute_hazard_b ? execute_hazard_result :
			  ctrl_hazard_b ? ctrl_hazard_result :
			  wb_hazard_b ? wb_hazard_result :
			  execute_rfb;

   always @(posedge clk)
     if (padv_decode_i)
       execute_rfb <= decode_rfb_o;

   assign rfa_rden = padv_decode_i;
   assign rfb_rden = fetch_rf_adr_valid_i;
   assign rf_wren =  wb_rf_wb_i;

   mor1kx_rf_ram
     #(
       .OPTION_OPERAND_WIDTH(OPTION_OPERAND_WIDTH),
       .OPTION_RF_ADDR_WIDTH(OPTION_RF_ADDR_WIDTH),
       .OPTION_RF_WORDS(OPTION_RF_WORDS)
       )
     rfa
     (
      .clk(clk),
      .rst(rst),
      .rdad_i(decode_rfa_adr_i),
      .rden_i(rfa_rden),
      .rdda_o(rfa_ram_o),
      .wrad_i(wb_rfd_adr_i),
      .wren_i(rf_wren),
      .wrda_i(result_i)
      );

   mor1kx_rf_ram
     #(
       .OPTION_OPERAND_WIDTH(OPTION_OPERAND_WIDTH),
       .OPTION_RF_ADDR_WIDTH(OPTION_RF_ADDR_WIDTH),
       .OPTION_RF_WORDS(OPTION_RF_WORDS)
       )
   rfb
     (
      .clk(clk),
      .rst(rst),
      .rdad_i(fetch_rfb_adr_i),
      .rden_i(rfb_rden),
      .rdda_o(rfb_ram_o),
      .wrad_i(wb_rfd_adr_i),
      .wren_i(rf_wren),
      .wrda_i(result_i)
      );

endmodule // mor1kx_rf_cappuccino
