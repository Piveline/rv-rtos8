// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// Copyright 2022-2026 Advanced Micro Devices, Inc. All Rights Reserved.
// -------------------------------------------------------------------------------
// This file contains confidential and proprietary information
// of AMD and is protected under U.S. and international copyright
// and other intellectual property laws.
//
// DISCLAIMER
// This disclaimer is not a license and does not grant any
// rights to the materials distributed herewith. Except as
// otherwise provided in a valid license issued to you by
// AMD, and to the maximum extent permitted by applicable
// law: (1) THESE MATERIALS ARE MADE AVAILABLE "AS IS" AND
// WITH ALL FAULTS, AND AMD HEREBY DISCLAIMS ALL WARRANTIES
// AND CONDITIONS, EXPRESS, IMPLIED, OR STATUTORY, INCLUDING
// BUT NOT LIMITED TO WARRANTIES OF MERCHANTABILITY, NON-
// INFRINGEMENT, OR FITNESS FOR ANY PARTICULAR PURPOSE; and
// (2) AMD shall not be liable (whether in contract or tort,
// including negligence, or under any other theory of
// liability) for any loss or damage of any kind or nature
// related to, arising under or in connection with these
// materials, including for any direct, or any indirect,
// special, incidental, or consequential loss or damage
// (including loss of data, profits, goodwill, or any type of
// loss or damage suffered as a result of any action brought
// by a third party) even if such damage or loss was
// reasonably foreseeable or AMD had been advised of the
// possibility of the same.
//
// CRITICAL APPLICATIONS
// AMD products are not designed or intended to be fail-
// safe, or for use in any application requiring fail-safe
// performance, such as life-support or safety devices or
// systems, Class III medical devices, nuclear facilities,
// applications related to the deployment of airbags, or any
// other applications that could lead to death, personal
// injury, or severe property or environmental damage
// (individually and collectively, "Critical
// Applications"). Customer assumes the sole risk and
// liability of any use of AMD products in Critical
// Applications, subject only to applicable laws and
// regulations governing limitations on product liability.
//
// THIS COPYRIGHT NOTICE AND DISCLAIMER MUST BE RETAINED AS
// PART OF THIS FILE AT ALL TIMES.
//
// DO NOT MODIFY THIS FILE.

// MODULE VLNV: digilentinc.com:ip:rgb2dvi:1.4

`timescale 1ps / 1ps

`include "vivado_interfaces.svh"

module rgb2dvi_0_sv (
  (* X_INTERFACE_IGNORE = "true" *)
  output wire TMDS_Clk_p,
  (* X_INTERFACE_IGNORE = "true" *)
  output wire TMDS_Clk_n,
  (* X_INTERFACE_IGNORE = "true" *)
  output wire [2:0] TMDS_Data_p,
  (* X_INTERFACE_IGNORE = "true" *)
  output wire [2:0] TMDS_Data_n,
  (* X_INTERFACE_IGNORE = "true" *)
  input wire aRst,
  (* X_INTERFACE_IGNORE = "true" *)
  input wire [23:0] vid_pData,
  (* X_INTERFACE_IGNORE = "true" *)
  input wire vid_pVDE,
  (* X_INTERFACE_IGNORE = "true" *)
  input wire vid_pHSync,
  (* X_INTERFACE_IGNORE = "true" *)
  input wire vid_pVSync,
  (* X_INTERFACE_IGNORE = "true" *)
  input wire PixelClk,
  (* X_INTERFACE_IGNORE = "true" *)
  input wire SerialClk
);

  rgb2dvi_0 inst (
    .TMDS_Clk_p(TMDS_Clk_p),
    .TMDS_Clk_n(TMDS_Clk_n),
    .TMDS_Data_p(TMDS_Data_p),
    .TMDS_Data_n(TMDS_Data_n),
    .aRst(aRst),
    .vid_pData(vid_pData),
    .vid_pVDE(vid_pVDE),
    .vid_pHSync(vid_pHSync),
    .vid_pVSync(vid_pVSync),
    .PixelClk(PixelClk),
    .SerialClk(SerialClk)
  );

endmodule
