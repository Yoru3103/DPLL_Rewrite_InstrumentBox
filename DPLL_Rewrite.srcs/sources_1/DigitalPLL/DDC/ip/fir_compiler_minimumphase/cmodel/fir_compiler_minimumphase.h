
//------------------------------------------------------------------------------
// (c) Copyright 2014 Xilinx, Inc. All rights reserved.
//
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
//
// DISCLAIMER
// This disclaimer is not a license and does not grant any
// rights to the materials distributed herewith. Except as
// otherwise provided in a valid license issued to you by
// Xilinx, and to the maximum extent permitted by applicable
// law: (1) THESE MATERIALS ARE MADE AVAILABLE "AS IS" AND
// WITH ALL FAULTS, AND XILINX HEREBY DISCLAIMS ALL WARRANTIES
// AND CONDITIONS, EXPRESS, IMPLIED, OR STATUTORY, INCLUDING
// BUT NOT LIMITED TO WARRANTIES OF MERCHANTABILITY, NON-
// INFRINGEMENT, OR FITNESS FOR ANY PARTICULAR PURPOSE; and
// (2) Xilinx shall not be liable (whether in contract or tort,
// including negligence, or under any other theory of
// liability) for any loss or damage of any kind or nature
// related to, arising under or in connection with these
// materials, including for any direct, or any indirect,
// special, incidental, or consequential loss or damage
// (including loss of data, profits, goodwill, or any type of
// loss or damage suffered as a result of any action brought
// by a third party) even if such damage or loss was
// reasonably foreseeable or Xilinx had been advised of the
// possibility of the same.
//
// CRITICAL APPLICATIONS
// Xilinx products are not designed or intended to be fail-
// safe, or for use in any application requiring fail-safe
// performance, such as life-support or safety devices or
// systems, Class III medical devices, nuclear facilities,
// applications related to the deployment of airbags, or any
// other applications that could lead to death, personal
// injury, or severe property or environmental damage
// (individually and collectively, "Critical
// Applications"). Customer assumes the sole risk and
// liability of any use of Xilinx products in Critical
// Applications, subject only to applicable laws and
// regulations governing limitations on product liability.
//
// THIS COPYRIGHT NOTICE AND DISCLAIMER MUST BE RETAINED AS
// PART OF THIS FILE AT ALL TIMES.
//------------------------------------------------------------------------------ 
//
// C Model configuration for the "fir_compiler_minimumphase" instance.
//
//------------------------------------------------------------------------------
//
// coefficients: 190,110,141,177,220,269,325,389,461,543,634,736,849,974,1111,1262,1427,1607,1802,2013,2241,2486,2749,3030,3330,3649,3988,4347,4726,5125,5544,5984,6444,6925,7425,7945,8483,9041,9616,10208,10817,11442,12080,12733,13397,14072,14756,15449,16148,16852,17559,18268,18976,19682,20383,21079,21767,22445,23111,23764,24400,25019,25618,26196,26750,27279,27781,28255,28699,29111,29491,29836,30146,30420,30656,30854,31013,31133,31214,31254,31254,31214,31133,31013,30854,30656,30420,30146,29836,29491,29111,28699,28255,27781,27279,26750,26196,25618,25019,24400,23764,23111,22445,21767,21079,20383,19682,18976,18268,17559,16852,16148,15449,14756,14072,13397,12733,12080,11442,10817,10208,9616,9041,8483,7945,7425,6925,6444,5984,5544,5125,4726,4347,3988,3649,3330,3030,2749,2486,2241,2013,1802,1607,1427,1262,1111,974,849,736,634,543,461,389,325,269,220,177,141,110,190
// chanpats: 173
// name: fir_compiler_minimumphase
// filter_type: 0
// rate_change: 0
// interp_rate: 1
// decim_rate: 1
// zero_pack_factor: 1
// coeff_padding: 0
// num_coeffs: 160
// coeff_sets: 1
// reloadable: 0
// is_halfband: 0
// quantization: 0
// coeff_width: 16
// coeff_fract_width: 0
// chan_seq: 0
// num_channels: 1
// num_paths: 1
// data_width: 16
// data_fract_width: 0
// output_rounding_mode: 4
// output_width: 16
// output_fract_width: 0
// config_method: 0

const double fir_compiler_minimumphase_coefficients[160] = {190,110,141,177,220,269,325,389,461,543,634,736,849,974,1111,1262,1427,1607,1802,2013,2241,2486,2749,3030,3330,3649,3988,4347,4726,5125,5544,5984,6444,6925,7425,7945,8483,9041,9616,10208,10817,11442,12080,12733,13397,14072,14756,15449,16148,16852,17559,18268,18976,19682,20383,21079,21767,22445,23111,23764,24400,25019,25618,26196,26750,27279,27781,28255,28699,29111,29491,29836,30146,30420,30656,30854,31013,31133,31214,31254,31254,31214,31133,31013,30854,30656,30420,30146,29836,29491,29111,28699,28255,27781,27279,26750,26196,25618,25019,24400,23764,23111,22445,21767,21079,20383,19682,18976,18268,17559,16852,16148,15449,14756,14072,13397,12733,12080,11442,10817,10208,9616,9041,8483,7945,7425,6925,6444,5984,5544,5125,4726,4347,3988,3649,3330,3030,2749,2486,2241,2013,1802,1607,1427,1262,1111,974,849,736,634,543,461,389,325,269,220,177,141,110,190};

const xip_fir_v7_2_pattern fir_compiler_minimumphase_chanpats[1] = {P_BASIC};

static xip_fir_v7_2_config gen_fir_compiler_minimumphase_config() {
  xip_fir_v7_2_config config;
  config.name                = "fir_compiler_minimumphase";
  config.filter_type         = 0;
  config.rate_change         = XIP_FIR_INTEGER_RATE;
  config.interp_rate         = 1;
  config.decim_rate          = 1;
  config.zero_pack_factor    = 1;
  config.coeff               = &fir_compiler_minimumphase_coefficients[0];
  config.coeff_padding       = 0;
  config.num_coeffs          = 160;
  config.coeff_sets          = 1;
  config.reloadable          = 0;
  config.is_halfband         = 0;
  config.quantization        = XIP_FIR_INTEGER_COEFF;
  config.coeff_width         = 16;
  config.coeff_fract_width   = 0;
  config.chan_seq            = XIP_FIR_BASIC_CHAN_SEQ;
  config.num_channels        = 1;
  config.init_pattern        = fir_compiler_minimumphase_chanpats[0];
  config.num_paths           = 1;
  config.data_width          = 16;
  config.data_fract_width    = 0;
  config.output_rounding_mode= XIP_FIR_CONVERGENT_EVEN;
  config.output_width        = 16;
  config.output_fract_width  = 0,
  config.config_method       = XIP_FIR_CONFIG_SINGLE;
  return config;
}

const xip_fir_v7_2_config fir_compiler_minimumphase_config = gen_fir_compiler_minimumphase_config();

