// Digital-PLL wrapper
// JDD 2016

`default_nettype none   // This disables implicit variable declaration, which I really don't like as a feature as it lets bugs go unreported

module dpll_wrapper(

    
    input  wire               clk1,         // global clock, designed for 125 MHz clock rate
    input  wire               clk1_timesN,  //3.125MHZ*16=50M this should be N times the clock, phase-locked to clk1, N matching what was input in the FIR compiler for fir_compiler_minimumphase_N_times_clk
    input  wire               clk_dpll,  //dpll clock 3.125MHz
    input  wire               rst,

    // analog data input/output interface
    input  wire signed [15:0] ADCraw0,
    input  wire signed [15:0] ADCraw1,
    output wire signed [15:0] DACout0,
    output wire signed [15:0] DACout1,

    // Data logger port:
    //output wire [16-1:0]      LoggerData,
    //output wire               LoggerData_clk_enable,
    //input  wire               LoggerIsWriting,

    // System bus
    input  wire [ 32-1:0]     sys_addr   ,  // bus address
    input  wire [ 32-1:0]     sys_wdata  ,  // bus write data
    input  wire [  4-1:0]     sys_sel    ,  // bus write byte select
    input  wire               sys_wen    ,  // bus write enable
    input  wire               sys_ren    ,  // bus read enable
    output reg [ 32-1:0]     sys_rdata  ,  // bus read data
    output reg               sys_err    ,  // bus error indicator
    output reg               sys_ack    ,   // bus acknowledge signal

    output wire [  7-1:0]     led
);

// Parameters
localparam SIGNAL_SIZE = 16;


///////////////////////////////////////////////////////////////////////////////
// Wires for the configuration bus
//整理地址总线
wire [15:0]          cmd_addr;
wire [32:0]          cmd_datain;
wire                 cmd_trig;


// conversion from Zynq-style parallel bus to the legacy Opal-Kelly-style bus:
assign cmd_trig    = sys_wen;
assign cmd_addr    = sys_addr [16-1+2:2];   // note that we divide the Zynq addresses by 4 when mapping to the DPLL addresses.  This is because the Zynq cannot address memory locations that are not on 32-bits boundaries, but the legacy bus didn't have this restriction.
assign cmd_datain = sys_wdata;



///////////////////////////////////////////////////////////////////////////////
// Replacement for the Opal Kelly "Triggers"

// 2015-01-27 Modification by Hugo Bergeron: added wire in for resetting the fifo
// wire [15:0] WireIn00, WireIn01, WireIn02, WireIn03, WireIn04_Clock_source_select, WireIn05_fifo_reset;
// wire [15:0] WireOut20, WireOut21, WireOut22, WireOut23, WireOut24, WireOut25StatusFlags;
// wire [15:0] TrigIn40;

// new style triggers:
// each "trigger" is actually the update_flag signal of an empty register:
parallel_bus_register_32bits_or_less # (
    .REGISTER_SIZE(8),
    .REGISTER_DEFAULT_VALUE(32'b0),
    .ADDRESS(16'h0000)
)
parallel_bus_register_ok_reset (
     .clk(clk1), 
     .bus_strobe(cmd_trig), 
     .bus_address(cmd_addr), 
     .bus_data(cmd_datain), 
     .register_output(), 
     .update_flag(ok_reset)
     );

//parallel_bus_register_32bits_or_less # (
//    .REGISTER_SIZE(8),
//    .REGISTER_DEFAULT_VALUE(32'b0),
//    .ADDRESS(16'h0044)
//)
//parallel_bus_register_phase_ok_reset_frontend (
//     .clk(clk1), 
//     .bus_strobe(cmd_trig), 
//     .bus_address(cmd_addr), 
//     .bus_data({cmd_data2in, cmd_data1in}), 
//     .register_output(), 
//     .update_flag(ok_reset_frontend)
//     );


///////////////////////////////////////////////////////////////////////////////
// Reset signals
//wire bus_rst;

wire ok_reset;
//wire ok_reset_frontend;

//reg rst_peripherals, rst_peripherals_output1, rst_peripherals_output2, rst_peripherals_internal, rst_peripherals_output1_internal, rst_peripherals_output2_internal;    // we split the reset signal in a tree to try help with the fanout, and hope that xst won't combine our register
reg rst_frontend0, rst_frontend1, rst_frontend0_internal, rst_frontend1_internal;

reg [15:0] reset_counter = 16'b1111111111111111;    // 2**16 cycles * 10 ns/cycle = 655 us of maximum reset time
reg [15:0] reset_counter_frontend = 16'b1111111111111111;   // 2**16 cycles * 10 ns/cycle = 655 us of maximum reset time


//assign DOUT[2] = rst_frontend0;
//always @(posedge clk1) begin
    
//    if (rst == 1'b1 | bus_rst == 1'b1) begin
//        reset_counter <= 16'b1111111111111111;
//    end
//    else begin
//        if (reset_counter > 0) begin
//            reset_counter <= reset_counter - 1'b1;
//        end
        
//        // The different reset groups are compared each to a different value,
//        // to make sure that Xilinx doesn't combine the registers into a single reset signal driving a very large fanout
//        rst_peripherals_internal         <= ((reset_counter > 3) ? 1'b1 : 1'b0);
//        rst_peripherals_output1_internal <= ((reset_counter > 4) ? 1'b1 : 1'b0);
//        rst_peripherals_output2_internal <= ((reset_counter > 5) ? 1'b1 : 1'b0);
        
//        // An extra register stage to help with routing
//        rst_peripherals <= rst_peripherals_internal;
//        rst_peripherals_output1 <= rst_peripherals_output1_internal;
//        rst_peripherals_output2 <= rst_peripherals_output2_internal;
        
//    end
//end

always @(posedge clk1) begin
    
    //if ((ok_reset == 1'b1) || (ok_reset_frontend == 1'b1)) 
    if (ok_reset == 1'b1)
    begin
        reset_counter_frontend <= 16'b1111111111111111;
    end
    else begin
        if (reset_counter_frontend > 0) begin
            reset_counter_frontend <= reset_counter_frontend - 1'b1;
        end
        
        // The different reset groups are compared each to a different value,
        // to make sure that Xilinx doesn't combine the registers into a single reset signal driving a very large fanout
        rst_frontend0_internal              <= ((reset_counter_frontend > 1) ? 1'b1 : 1'b0);
        rst_frontend1_internal              <= ((reset_counter_frontend > 2) ? 1'b1 : 1'b0);
        
        // An extra register stage to help with routing
        rst_frontend0 <= rst_frontend0_internal;
        rst_frontend1 <= rst_frontend1_internal;
        
    end
end





///////////////////////////////////////////////////////////////////////////////
//鉴相器
// Direct-digital converter (brings a signal to baseband, low-pass filters it, and outputs the phase and frequency) for ADC 0
///////////////////////////////////////////////////////////////////////////////
wire        [14-1:0]       wrapped_phase0;     // phi/(2*pi) * 2^14
wire        [14-1:0]       inst_frequency0;        // diff(phi)/(2*pi) * 2^14

//wire select_phase_or_freq0;
wire [3:0] angleSelect_0;

    wire [32-1:0]Centre_Freq;    
    reg  [47:0]reference_frequency0 ;
    wire [48-1:0]DDC_Phase;
    wire [32-1:0]PID_OUT_With_Limit;
    wire [48-1:0]PID_OUT_ADD;
    
   //中心频率       
   parallel_bus_register_32bits_or_less # (
        .REGISTER_SIZE(32),
        .REGISTER_DEFAULT_VALUE(32'h0A3D70A3),//125khz
        .ADDRESS(16'h0010)
    ) parallel_bus_register_32_bits_or_less_freq_c0 (
         .clk(clk1), 
         .bus_strobe(cmd_trig), 
         .bus_address(cmd_addr), 
         .bus_data(cmd_datain), 
         .register_output(Centre_Freq), 
         .update_flag()
    );     
       
   parallel_bus_register_32bits_or_less # (
        .REGISTER_SIZE(4),
        .REGISTER_DEFAULT_VALUE(4'b0),
        .ADDRESS(16'h0011)
    ) parallel_bus_register_32_bits_or_less_angleSelect (
         .clk(clk1), 
         .bus_strobe(cmd_trig), 
         .bus_address(cmd_addr), 
         .bus_data(cmd_datain), 
         .register_output(angleSelect_0), 
         .update_flag()
    );
    

//    parallel_bus_register_32bits_or_less # (
//        .REGISTER_SIZE(1),
//        .REGISTER_DEFAULT_VALUE(1'b0),
//        .ADDRESS(16'h1002)
//    )
//    parallel_bus_register_ddc_filter_select (
//         .clk(clk1), 
//         .bus_strobe(cmd_trig), 
//         .bus_address(cmd_addr), 
//         .bus_data({cmd_data2in, cmd_data1in}), 
//         .register_output(select_phase_or_freq0), 
//         .update_flag()
//         );

assign PID_OUT_ADD = {{4{PID_OUT_With_Limit[32-1]}},PID_OUT_With_Limit,12'h000};
assign DDC_Phase = {Centre_Freq,16'h0000};
wire [16-1:0]         ref_cosine_0, ref_sine_0;
wire [16-1:0]         DDC_Amplitude_0;

always @(posedge clk_dpll) begin
    reference_frequency0 <= DDC_Phase+PID_OUT_ADD;
    //reference_frequency0 <= DDC_Phase;
end


DDC_wideband_filters DDC0_inst (
    .rst(rst_frontend0), 
    .clk(clk1), 
    .clk_times_N(clk1_timesN),
    .clk_dpll(clk_dpll),
    .data_input(ADCraw0),     // 
     
     // Configuration
    .reference_frequency(reference_frequency0), 
     //.ddc_filter_select(ddc0_filter_select),
     
    // Reference tone output:
    .ref_cosine_out(ref_cosine_0),
    .ref_sine_out(ref_sine_0),
    
    // Used for nulling the lock phase offset:
    .lock(pll0_lock),
    .angleSelect(angleSelect_0),
     
     // Output
    .amplitude(DDC_Amplitude_0), 
    .wrapped_phase(wrapped_phase0), 
    .inst_frequency(inst_frequency0)
    );




///////////////////////////////////////////////////////////////////////////////
// Loop filters for DAC 0:  
//PID
wire pll0_lock,pll0_lock_i, pll0_gain_changedp, pll0_gain_changedi, pll0_gain_changedii, pll0_gain_changedd, pll0_coef_changedd;
wire pll0_gain_changed;
wire [32-1:0] pll0_gainp, pll0_gaini, pll0_gainii, pll0_gaind, pll0_coefdfilter;
// 阶段 3 原子参数接口：adaptive_gain* 位于 3.125 MHz 环路侧，是 legacy/active 选择后的最终参数。
wire [31:0] adaptive_gainp, adaptive_gaini, adaptive_gainii, adaptive_gaind, adaptive_coefdfilter;
wire adaptive_gain_changed; // 已同步到 clk_dpll 域的参数变化单拍脉冲
wire [7:0] adaptive_shadow_profile, adaptive_active_profile; // bus 域待提交/活动 profile 镜像
wire [31:0] adaptive_shadow_kp, adaptive_shadow_ki, adaptive_shadow_kii;
wire [31:0] adaptive_shadow_kd, adaptive_shadow_dcoef;
wire [31:0] adaptive_applied_seq, adaptive_apply_status; // ack 确认序号和提交状态字
wire [31:0] adaptive_active_kp, adaptive_active_ki, adaptive_active_kii;
wire [31:0] adaptive_active_kd, adaptive_active_dcoef, adaptive_commit_error_count;
wire [32-1:0] pll0_output;

// Then the registers which controls the gain and locked/unlocked behavior of the filters:
parallel_bus_register_32bits_or_less # (
    .REGISTER_SIZE(1),
    .REGISTER_DEFAULT_VALUE(0),
    .ADDRESS(16'h0020)
)
parallel_bus_register_pll0_settings (
    .clk(clk1), 
    .bus_strobe(cmd_trig), 
    .bus_address(cmd_addr), 
    .bus_data(cmd_datain), 
    .register_output(pll0_lock_i), 
    .update_flag()
    );
BUFG bufg_dpll_clk    (.O (pll0_lock), .I (pll0_lock_i));   
     
     
parallel_bus_register_32bits_or_less # (
    .REGISTER_SIZE(32),
    .REGISTER_DEFAULT_VALUE(0),
    .ADDRESS(16'h0021)
)
parallel_bus_register_pll0_gainp (
    .clk(clk1), 
    .bus_strobe(cmd_trig), 
    .bus_address(cmd_addr), 
    .bus_data(cmd_datain), 
    .register_output(pll0_gainp), 
    .update_flag(pll0_gain_changedp)
    );
     
parallel_bus_register_32bits_or_less # (
    .REGISTER_SIZE(32),
    .REGISTER_DEFAULT_VALUE(0),
    .ADDRESS(16'h0022)
)
parallel_bus_register_pll0_gaini (
    .clk(clk1), 
    .bus_strobe(cmd_trig), 
    .bus_address(cmd_addr), 
    .bus_data(cmd_datain), 
    .register_output(pll0_gaini), 
    .update_flag(pll0_gain_changedi)
    );
     
     
parallel_bus_register_32bits_or_less # (
    .REGISTER_SIZE(32),
    .REGISTER_DEFAULT_VALUE(0),
    .ADDRESS(16'h0023)
)
parallel_bus_register_pll0_gainii (
    .clk(clk1), 
    .bus_strobe(cmd_trig), 
    .bus_address(cmd_addr), 
    .bus_data(cmd_datain), 
    .register_output(pll0_gainii), 
    .update_flag(pll0_gain_changedii)
    );
     
     
parallel_bus_register_32bits_or_less # (
    .REGISTER_SIZE(32),
    .REGISTER_DEFAULT_VALUE(0),
    .ADDRESS(16'h0024)
)
parallel_bus_register_pll0_gaind (
    .clk(clk1), 
    .bus_strobe(cmd_trig), 
    .bus_address(cmd_addr), 
    .bus_data(cmd_datain), 
    .register_output(pll0_gaind), 
    .update_flag(pll0_gain_changedd)
    );
    
    
parallel_bus_register_32bits_or_less # (
    .REGISTER_SIZE(18),
    .REGISTER_DEFAULT_VALUE(0),
    .ADDRESS(16'h0025)
)
parallel_bus_register_pll0_coefdfilter (
    .clk(clk1), 
    .bus_strobe(cmd_trig), 
    .bus_address(cmd_addr), 
    .bus_data(cmd_datain), 
    .register_output(pll0_coefdfilter), 
    .update_flag(pll0_coef_changedd)
    );
     
// This is used for bumpless change of the gain settings (TODO, most probably in the output summing block)
assign pll0_gain_changed = pll0_gain_changedp | pll0_gain_changedi | pll0_gain_changedii | pll0_gain_changedd | pll0_coef_changedd;

// request/ack toggle 保证 125 MHz 总线域参数在 3.125 MHz 环路域只应用一次且不丢失。
adaptive_param_commit_cdc adaptive_parameter_commit (
    .bus_clk(clk1), .loop_clk(clk_dpll), .reset_n(rst),
    .bus_write(cmd_trig), .bus_address(cmd_addr), .bus_wdata(cmd_datain[31:0]),
    .legacy_changed(pll0_gain_changed),
    .legacy_kp(pll0_gainp), .legacy_ki(pll0_gaini), .legacy_kii(pll0_gainii),
    .legacy_kd(pll0_gaind), .legacy_dcoef(pll0_coefdfilter),
    .loop_kp(adaptive_gainp), .loop_ki(adaptive_gaini), .loop_kii(adaptive_gainii),
    .loop_kd(adaptive_gaind), .loop_dcoef(adaptive_coefdfilter),
    .loop_gain_changed(adaptive_gain_changed),
    .shadow_profile(adaptive_shadow_profile), .shadow_kp(adaptive_shadow_kp),
    .shadow_ki(adaptive_shadow_ki), .shadow_kii(adaptive_shadow_kii),
    .shadow_kd(adaptive_shadow_kd), .shadow_dcoef(adaptive_shadow_dcoef),
    .applied_seq(adaptive_applied_seq), .apply_status(adaptive_apply_status),
    .active_profile_bus(adaptive_active_profile), .active_kp_bus(adaptive_active_kp),
    .active_ki_bus(adaptive_active_ki), .active_kii_bus(adaptive_active_kii),
    .active_kd_bus(adaptive_active_kd), .active_dcoef_bus(adaptive_active_dcoef),
    .commit_error_count(adaptive_commit_error_count)
);
     
// Finally the PLL itself:
PLL_loop_filters_with_saturation # (
    .N_DIVIDE_P(6),  
    .N_DIVIDE_I(8), 
    .N_DIVIDE_II(19),
    .N_DIVIDE_D(0),
    .N_OUTPUT(32)
)
PLL0_loop_filters (
    .clk(clk_dpll), 
    .lock(pll0_lock), 
    .gain_changed(adaptive_gain_changed),
    .data_in(inst_frequency0), 
    .gain_p(adaptive_gainp),
    .gain_i(adaptive_gaini),
    .gain_ii(adaptive_gainii),
    .gain_d(adaptive_gaind),
    .coef_d_filter(adaptive_coefdfilter),
    .phase_residuals(phase_residuals0),
    .data_out(pll0_output),
    .saturated_low(),
    .saturated_high()
    );
    

///////////////////////////////////////////////////////////////////////////////
// Output combiners before sending the results to the DACs:
//范围限制
wire [32-1:0] manual_offset_dac0, positive_limit_dac0, negative_limit_dac0;
//时序优化用途
reg [32-1:0] positive_limit_dac0_r,negative_limit_dac0_r;
wire dac0_railed_negative, dac0_railed_positive;
parallel_bus_register_32bits_or_less # (
    .REGISTER_SIZE(32),
    .REGISTER_DEFAULT_VALUE(32'h7fffffff),
    .ADDRESS(16'h0028)
)
parallel_bus_register_positive_limit_dac0 (
    .clk(clk1), 
    .bus_strobe(cmd_trig), 
    .bus_address(cmd_addr), 
    .bus_data(cmd_datain), 
    .register_output(positive_limit_dac0), 
    .update_flag()
    );    
parallel_bus_register_32bits_or_less # (
    .REGISTER_SIZE(32),
    .REGISTER_DEFAULT_VALUE(32'h80000001),
    .ADDRESS(16'h0029)
)
parallel_bus_register_negative_limit_dac0 (
    .clk(clk1), 
    .bus_strobe(cmd_trig), 
    .bus_address(cmd_addr), 
    .bus_data(cmd_datain), 
    .register_output(negative_limit_dac0), 
    .update_flag()
    );    
 // Register which adds a manual offset to the dac1 output:
parallel_bus_register_32bits_or_less # (
    .REGISTER_SIZE(32),
    .REGISTER_DEFAULT_VALUE(0),
    .ADDRESS(16'h002A)
)
parallel_bus_register_manual_offset_dac0 (
    .clk(clk1), 
    .bus_strobe(cmd_trig), 
    .bus_address(cmd_addr), 
    .bus_data(cmd_datain), 
    .register_output(manual_offset_dac0), 
    .update_flag()
    ); 
    
always @(posedge clk1)
begin
 positive_limit_dac0_r <= positive_limit_dac0;
 negative_limit_dac0_r <= negative_limit_dac0;
end    
    
    
output_summing #(
    .INPUT_SIZE(32),
    .OUTPUT_SIZE(32)
)
output_summing_dac0
    (
        .clk(clk_dpll),
        .in0(pll0_output),
        .in1(manual_offset_dac0),
        .data_output(PID_OUT_With_Limit),
        .positive_limit(positive_limit_dac0_r),
        .negative_limit(negative_limit_dac0_r),
        .railed_positive(dac0_railed_positive),
        .railed_negative(dac0_railed_negative)
    );
    

     
///////////////////////////////////////////////////////////////////////////////
//VCO_0
    wire [13:0]VCO_Voffset0; 
    wire [15:0]VCO_Vamplitude0; 
    wire [15:0]PLL_Mul_factor; 
    wire [15:0]PLL_Div_factor;
    reg  [15:0]PLL_Mul_factor_r,PLL_Div_factor_r;
    wire signed [48-1:0] VCO_Input0;
// Register which adds a manual offset to the dac0 output:
parallel_bus_register_32bits_or_less # (
    .REGISTER_SIZE(14),
    .REGISTER_DEFAULT_VALUE(0),
    .ADDRESS(16'h0030)
)
parallel_bus_register_VCO0_offset (
    .clk(clk1), 
    .bus_strobe(cmd_trig), 
    .bus_address(cmd_addr), 
    .bus_data(cmd_datain), 
    .register_output(VCO_Voffset0), 
    .update_flag()
    );    
 // Register which adds a amplitude to the dac0 output:
parallel_bus_register_32bits_or_less # (
    .REGISTER_SIZE(16),
    .REGISTER_DEFAULT_VALUE(0),
    .ADDRESS(16'h0031)
)
parallel_bus_register_VCO0_amplitude (
    .clk(clk1), 
    .bus_strobe(cmd_trig), 
    .bus_address(cmd_addr), 
    .bus_data(cmd_datain), 
    .register_output(VCO_Vamplitude0), 
    .update_flag()
    );     
parallel_bus_register_32bits_or_less # (
    .REGISTER_SIZE(16),
    .REGISTER_DEFAULT_VALUE(16'h0008),
    .ADDRESS(16'h0032)
)
parallel_bus_register_PLL_Mul_factor (
    .clk(clk1), 
    .bus_strobe(cmd_trig), 
    .bus_address(cmd_addr), 
    .bus_data(cmd_datain), 
    .register_output(PLL_Mul_factor), 
    .update_flag()
    );  
parallel_bus_register_32bits_or_less # (
    .REGISTER_SIZE(16),
    .REGISTER_DEFAULT_VALUE(16'h0001),
    .ADDRESS(16'h0033)
)
parallel_bus_register_PLL_Div_factor (
    .clk(clk1), 
    .bus_strobe(cmd_trig), 
    .bus_address(cmd_addr), 
    .bus_data(cmd_datain), 
    .register_output(PLL_Div_factor), 
    .update_flag()
    );
 always @(posedge clk1)
begin
 PLL_Mul_factor_r <= PLL_Mul_factor;
 PLL_Div_factor_r <= PLL_Div_factor;
end  
    
//倍频和除频处理
PLL_VCO_MUL_DIV VCO0_mul_div(
    .clk(clk1),
    .clk_dpll(clk_dpll),
    .data_in(reference_frequency0),
    .data_out(VCO_Input0),
    .PLL_Mul_factor(PLL_Mul_factor_r),
    .PLL_Div_factor(PLL_Div_factor_r)
);

    VCO_48bits DAC_VCO_CH0(
    .clk                       (clk1),
    .VCO_input                 (VCO_Input0),
    .VCO_offset                (VCO_Voffset0),
    .VCO_amplitude             (VCO_Vamplitude0),
    .VCO_DAC_out               (DACout0)
    );      
    
    
//VCO1     
    wire [13:0]VCO_Voffset1; 
    wire [15:0]VCO_Vamplitude1; 
    wire [31:0]VCO_Fre_Input1;  
    wire [31:0]VCO_Phase_Input1; 
    
// Register which adds a manual offset to the dac1 output:
parallel_bus_register_32bits_or_less # (
    .REGISTER_SIZE(14),
    .REGISTER_DEFAULT_VALUE(0),
    .ADDRESS(16'h0040)
)
parallel_bus_register_VCO1_offset (
    .clk(clk1), 
    .bus_strobe(cmd_trig), 
    .bus_address(cmd_addr), 
    .bus_data(cmd_datain), 
    .register_output(VCO_Voffset1), 
    .update_flag()
    );    
 // Register which adds a manual offset to the dac1 output:
parallel_bus_register_32bits_or_less # (
    .REGISTER_SIZE(16),
    .REGISTER_DEFAULT_VALUE(0),
    .ADDRESS(16'h0041)
)
parallel_bus_register_VCO1_amplitude (
    .clk(clk1), 
    .bus_strobe(cmd_trig), 
    .bus_address(cmd_addr), 
    .bus_data(cmd_datain), 
    .register_output(VCO_Vamplitude1), 
    .update_flag()
    );   
    
 parallel_bus_register_32bits_or_less # (
    .REGISTER_SIZE(32),
    .REGISTER_DEFAULT_VALUE(0),
    .ADDRESS(16'h0042)
)
parallel_bus_register_VCO1_Fre (
    .clk(clk1), 
    .bus_strobe(cmd_trig), 
    .bus_address(cmd_addr), 
    .bus_data(cmd_datain), 
    .register_output(VCO_Fre_Input1), 
    .update_flag()
    );   
parallel_bus_register_32bits_or_less # (
    .REGISTER_SIZE(32),
    .REGISTER_DEFAULT_VALUE(0),
    .ADDRESS(16'h0043)
)
parallel_bus_register_VCO1_Phase (
    .clk(clk1), 
    .bus_strobe(cmd_trig), 
    .bus_address(cmd_addr), 
    .bus_data(cmd_datain), 
    .register_output(VCO_Phase_Input1), 
    .update_flag()
    );        
    
VCO_32bits DAC_VCO_CH1(
    .clk                       (clk1),
    .VCO_Fre_input             (VCO_Fre_Input1),
    .VCO_Phase_input           (VCO_Phase_Input1),
    .VCO_offset                (VCO_Voffset1),
    .VCO_amplitude             (VCO_Vamplitude1),
    .VCO_DAC_out               (DACout1)
    );  
    
    
    
    
 ///////////////////////////////////////////////////////////////////////////////   
//系统监控 超出阈值//LED控制等

//系统监控
// This module outputs high if the abs value of the phase residuals is above a certain threshold
// the output of this module triggers the crash monitor
wire [31:0] phase_residuals0, phase_residuals0_threshold, phase_residuals0_offset;
wire [9:0] freq_residuals0, freq_residuals0_threshold;
reg [31:0] phase_residuals0_threshold_r;
reg [9:0] freq_residuals0_threshold_r;
wire residuals0_are_above_threshold_phase, residuals0_are_above_threshold_freq;
reg residuals0_are_above_threshold,rail_are_above_threshold;

//相位残差
// sets the phase residuals threshold for DAC0:
parallel_bus_register_32bits_or_less # (
    .REGISTER_SIZE(32),
    .REGISTER_DEFAULT_VALUE(32'b0),
    .ADDRESS(16'h0050)
)
parallel_bus_register_phase_residuals0_threshold (
     .clk(clk1), 
     .bus_strobe(cmd_trig), 
     .bus_address(cmd_addr), 
     .bus_data(cmd_datain), 
     .register_output(phase_residuals0_threshold), 
     .update_flag()
     );
     
parallel_bus_register_32bits_or_less # (
    .REGISTER_SIZE(32),
    .REGISTER_DEFAULT_VALUE(32'b0),
    .ADDRESS(16'h0051)
)
parallel_bus_register_phase_residuals0_offset (
     .clk(clk1), 
     .bus_strobe(cmd_trig), 
     .bus_address(cmd_addr), 
     .bus_data(cmd_datain), 
     .register_output(phase_residuals0_offset), 
     .update_flag()
     );    
     
     
always @(posedge clk1)
begin
 phase_residuals0_threshold_r <= phase_residuals0_threshold;
 freq_residuals0_threshold_r <= freq_residuals0_threshold;
end        
     
residuals_monitor_with_offset # (
    .N_BITS_DATA(32)
)
residuals_monitor_inst0 (
     .clk(clk_dpll), 
     .phase_residuals(phase_residuals0), 
     .residuals_offset(phase_residuals0_offset),
     .residuals_threshold(phase_residuals0_threshold_r), 
     .residuals_are_above_threshold(residuals0_are_above_threshold_phase)
     );
 //瞬时频率
// sets the frequency residuals threshold for DAC0:
parallel_bus_register_32bits_or_less # (
    .REGISTER_SIZE(10),
    .REGISTER_DEFAULT_VALUE(32'b0),
    .ADDRESS(16'h0052)
)
parallel_bus_register_freq_residuals0_threshold (
     .clk(clk1), 
     .bus_strobe(cmd_trig), 
     .bus_address(cmd_addr), 
     .bus_data(cmd_datain), 
     .register_output(freq_residuals0_threshold), 
     .update_flag()
     );
     
residuals_monitor # (
    .N_BITS_DATA(14)
)
residuals_monitor_inst0_freq (
     .clk(clk_dpll), 
     .phase_residuals(inst_frequency0), 
     .residuals_threshold(freq_residuals0_threshold_r), 
     .residuals_are_above_threshold(residuals0_are_above_threshold_freq)
     );
      

// The two trigger conditions are ORed together:
wire pll0_locked_Instant;
wire pll0_locked_Stable;
reg pll0_locked_neg;
always @(posedge clk_dpll)
begin
 residuals0_are_above_threshold <= residuals0_are_above_threshold_phase | residuals0_are_above_threshold_freq;
 rail_are_above_threshold <= dac0_railed_positive | dac0_railed_negative;
 pll0_locked_neg <= dac0_railed_positive | dac0_railed_negative | residuals0_are_above_threshold_freq | residuals0_are_above_threshold_phase;
end
not G2(pll0_locked_Instant,pll0_locked_neg);

//////////////////////////////////////////////////////////////////////
// The module which drives the front panel LEDs:
// These LEDs don't map directly to LEDs on the RedPitaya, but they still show up in the Python PC GUI so we left them there.
// they could eventually be mapped to some of the LEDs on the RP, although we don't have the nice Reg/Green LEDS anymore.
wire  LED_G0, LED_G1;
wire  LED_R0, LED_R1;

wire residuals0_threshold_phase_Stable, residuals0_threshold_freq_Stable;
wire positive_railed_Stable,negative_railed_Stable;
//assign LED_G0 = 1'b1;


Status_LED_driver # (
    .N_BITS_COUNTER(22) // 3.125 MHz/2^21 = 0.75 Hz
) Status_LED_driver0 (
    .clk(clk_dpll), 
    .lock_on(pll0_lock), 
    .residuals_above_threshold(residuals0_are_above_threshold), 
    .railed(rail_are_above_threshold), 
    //.railed(dac0_railed_positive|dac0_railed_negative), 
    .red_LED(LED_R0), 
    .green_LED(LED_G0), // LED_G0
    .Locked_LED(pll0_locked_Stable)
    );

Status_Delay_Show #
    (.N_BITS_COUNTER(20))// 3.125 MHz/2^20 = 3 Hz
    Status_Delay_Show_freq
    (
        .clk(clk_dpll), 
        .lock_on(pll0_lock), 
        .above_threshold(residuals0_are_above_threshold_freq),
        .delay_show(residuals0_threshold_freq_Stable)
    );
Status_Delay_Show #
    (.N_BITS_COUNTER(20))// 3.125 MHz/2^20 = 3 Hz
    Status_Delay_Show_phase
    (
        .clk(clk_dpll), 
        .lock_on(pll0_lock), 
        .above_threshold(residuals0_are_above_threshold_phase),
        .delay_show(residuals0_threshold_phase_Stable)
    );
Status_Delay_Show #
    (.N_BITS_COUNTER(20))// 3.125 MHz/2^20 = 3 Hz
    Status_Delay_Show_pos_rail
    (
        .clk(clk_dpll), 
        .lock_on(pll0_lock), 
        .above_threshold(dac0_railed_positive),
        .delay_show(positive_railed_Stable)
    );
Status_Delay_Show #
    (.N_BITS_COUNTER(20))// 3.125 MHz/2^20 = 3 Hz
    Status_Delay_Show_neg_rail
    (
        .clk(clk_dpll), 
        .lock_on(pll0_lock), 
        .above_threshold(dac0_railed_negative),
        .delay_show(negative_railed_Stable)
    );
//assign pll0_locked = dac0_railed_positive | dac0_railed_negative | residuals0_are_above_threshold_freq;
//and G1(pll0_locked,~dac0_railed_positive,~dac0_railed_negative,~residuals0_are_above_threshold_freq,~residuals0_are_above_threshold_phase);
assign led = {LED_G0,LED_R0,dac0_railed_positive,dac0_railed_negative,residuals0_are_above_threshold_freq,residuals0_are_above_threshold_phase,pll0_locked_Instant};

//////////////////////////////////////////////////////////////////////
//输出平均
wire [31:0]pll_output_average_value;
PLL_output_average#
    (.N_BITS_COUNTER(19))//3.125MHz/2^18=11.9Hz
    PLL_output_average0
    (
        .clk(clk_dpll),
        .lock_on(pll0_lock),
        .pll_pid_output_value(PID_OUT_With_Limit), 
        .pll_average_value(pll_output_average_value) 
    );
////////////////////////////////////////////////////////////////////////////////
//读总线
wire sys_en;
assign sys_en = sys_wen | sys_ren;

// 后缀 _loop：3.125 MHz 统计源域中的冻结快照；无后缀：已复制到 125 MHz 总线域的快照。
wire adaptive_snapshot_toggle_loop; // 每完成一个 DPLL 统计窗口翻转一次
wire [31:0] adaptive_snapshot_seq_loop, adaptive_snapshot_samples_loop;
wire [63:0] adaptive_amp_sum_loop, adaptive_freq_abs_sum_loop, adaptive_phase_abs_sum_loop;
wire [15:0] adaptive_amp_min_loop, adaptive_amp_max_loop;
wire [31:0] adaptive_freq_abs_max_loop, adaptive_phase_abs_max_loop;
wire [31:0] adaptive_output_min_loop, adaptive_output_max_loop;
wire [31:0] adaptive_locked_samples_loop, adaptive_pos_rail_samples_loop;
wire [31:0] adaptive_neg_rail_samples_loop, adaptive_freq_bad_samples_loop;
wire [31:0] adaptive_phase_bad_samples_loop, adaptive_loss_lock_events_loop;
wire [31:0] adaptive_pos_rail_events_loop, adaptive_neg_rail_events_loop;

wire [31:0] adaptive_snapshot_seq, adaptive_snapshot_samples;
wire [63:0] adaptive_amp_sum, adaptive_freq_abs_sum, adaptive_phase_abs_sum;
wire [15:0] adaptive_amp_min, adaptive_amp_max;
wire [31:0] adaptive_freq_abs_max, adaptive_phase_abs_max;
wire [31:0] adaptive_output_min, adaptive_output_max;
wire [31:0] adaptive_locked_samples, adaptive_pos_rail_samples, adaptive_neg_rail_samples;
wire [31:0] adaptive_freq_bad_samples, adaptive_phase_bad_samples;
wire [31:0] adaptive_loss_lock_events, adaptive_pos_rail_events, adaptive_neg_rail_events;
// 1024 bit bundled-data：源域保持整组数据稳定，目的域检测 toggle 后一次性锁存。
wire [1023:0] adaptive_snapshot_source_bundle, adaptive_snapshot_bus_bundle;

wire [63:0] adaptive_freq_signed_sum;
wire [63:0] adaptive_freq_square_sum;
wire [63:0] adaptive_phase_signed_sum;
wire [31:0] adaptive_phase_first;
wire [31:0] adaptive_phase_last;
wire [31:0] adaptive_residual_bad_samples;
wire [31:0] adaptive_rail_samples;
wire [31:0] adaptive_phase_sat_samples;
wire [63:0] adaptive_freq_signed_sum_loop;
wire [63:0] adaptive_freq_square_sum_loop;
wire [63:0] adaptive_phase_signed_sum_loop;
wire [31:0] adaptive_phase_first_loop;
wire [31:0] adaptive_phase_last_loop;
wire [31:0] adaptive_residual_bad_samples_loop;
wire [31:0] adaptive_rail_samples_loop;
wire [31:0] adaptive_phase_sat_samples_loop;

adaptive_statistics #(.WINDOW_LOG2(12)) adaptive_loop_statistics (
    .clk(clk_dpll), .reset_n(rst), .amplitude(DDC_Amplitude_0),
    .frequency_error(inst_frequency0), .phase_error(phase_residuals0),
    .loop_output(PID_OUT_With_Limit), .locked(pll0_lock & pll0_locked_Instant),
    .rail_positive(dac0_railed_positive), .rail_negative(dac0_railed_negative),
    .frequency_bad(residuals0_are_above_threshold_freq),
    .phase_bad(residuals0_are_above_threshold_phase),
    .snapshot_seq(adaptive_snapshot_seq_loop), .snapshot_toggle(adaptive_snapshot_toggle_loop),
    .sample_count(adaptive_snapshot_samples_loop), .amplitude_sum(adaptive_amp_sum_loop),
    .amplitude_min(adaptive_amp_min_loop), .amplitude_max(adaptive_amp_max_loop),
    .frequency_abs_sum(adaptive_freq_abs_sum_loop),
    .frequency_abs_max(adaptive_freq_abs_max_loop),
    .phase_abs_sum(adaptive_phase_abs_sum_loop), .phase_abs_max(adaptive_phase_abs_max_loop),
    .output_min(adaptive_output_min_loop), .output_max(adaptive_output_max_loop),
    .locked_sample_count(adaptive_locked_samples_loop),
    .positive_rail_sample_count(adaptive_pos_rail_samples_loop),
    .negative_rail_sample_count(adaptive_neg_rail_samples_loop),
    .frequency_bad_sample_count(adaptive_freq_bad_samples_loop),
    .phase_bad_sample_count(adaptive_phase_bad_samples_loop),
    .loss_of_lock_event_count(adaptive_loss_lock_events_loop),
    .positive_rail_event_count(adaptive_pos_rail_events_loop),
    .negative_rail_event_count(adaptive_neg_rail_events_loop),
    .frequency_signed_sum(adaptive_freq_signed_sum_loop),
    .frequency_square_sum(adaptive_freq_square_sum_loop),
    .phase_signed_sum(adaptive_phase_signed_sum_loop),
    .phase_first(adaptive_phase_first_loop),
    .phase_last(adaptive_phase_last_loop),
    .residual_bad_sample_count(adaptive_residual_bad_samples_loop),
    .rail_sample_count(adaptive_rail_samples_loop),
    .phase_saturated_sample_count(adaptive_phase_sat_samples_loop)
);

assign adaptive_snapshot_source_bundle = {
    adaptive_snapshot_seq_loop, adaptive_snapshot_samples_loop, adaptive_amp_sum_loop,
    adaptive_amp_min_loop, adaptive_amp_max_loop, adaptive_freq_abs_sum_loop,
    adaptive_freq_abs_max_loop, adaptive_phase_abs_sum_loop, adaptive_phase_abs_max_loop,
    adaptive_output_min_loop, adaptive_output_max_loop, adaptive_locked_samples_loop,
    adaptive_pos_rail_samples_loop, adaptive_neg_rail_samples_loop,
    adaptive_freq_bad_samples_loop, adaptive_phase_bad_samples_loop,
    adaptive_loss_lock_events_loop, adaptive_pos_rail_events_loop,
    adaptive_neg_rail_events_loop,
    adaptive_freq_signed_sum_loop,
    adaptive_freq_square_sum_loop,
    adaptive_phase_signed_sum_loop,
    adaptive_phase_first_loop,
    adaptive_phase_last_loop,
    adaptive_residual_bad_samples_loop,
    adaptive_rail_samples_loop,
    adaptive_phase_sat_samples_loop
};

// 只对 toggle 使用两级同步器；宽数据依靠快照保持时间完成 bundled-data CDC。
adaptive_snapshot_cdc #(.DATA_WIDTH(1024)) adaptive_statistics_cdc (
    .dst_clk(clk1), .dst_reset_n(rst), .src_toggle(adaptive_snapshot_toggle_loop),
    .src_data(adaptive_snapshot_source_bundle), .dst_data(adaptive_snapshot_bus_bundle)
);

assign {
    adaptive_snapshot_seq, adaptive_snapshot_samples, adaptive_amp_sum,
    adaptive_amp_min, adaptive_amp_max, adaptive_freq_abs_sum,
    adaptive_freq_abs_max, adaptive_phase_abs_sum, adaptive_phase_abs_max,
    adaptive_output_min, adaptive_output_max, adaptive_locked_samples,
    adaptive_pos_rail_samples, adaptive_neg_rail_samples, adaptive_freq_bad_samples,
    adaptive_phase_bad_samples, adaptive_loss_lock_events, adaptive_pos_rail_events,
    adaptive_neg_rail_events,
    adaptive_freq_signed_sum,
    adaptive_freq_square_sum,
    adaptive_phase_signed_sum,
    adaptive_phase_first,
    adaptive_phase_last,
    adaptive_residual_bad_samples,
    adaptive_rail_samples,
    adaptive_phase_sat_samples
} = adaptive_snapshot_bus_bundle;

always @(posedge clk1)
if (rst == 1'b0) begin
   sys_err <= 1'b0 ;
   sys_ack <= 1'b0 ;
end else begin
   sys_err <= 1'b0 ;
   casez (cmd_addr[16-1:0])
        16'h0010 : begin sys_ack <= sys_en;          sys_rdata <= Centre_Freq;                          end  
        16'h0011 : begin sys_ack <= sys_en;          sys_rdata <= {{32-4{1'b0}}, angleSelect_0};        end 
        
        16'h0020 : begin sys_ack <= sys_en;          sys_rdata <= {{32-1{1'b0}}, pll0_lock};            end
        16'h0021 : begin sys_ack <= sys_en;          sys_rdata <= pll0_gainp;                           end 
        16'h0022 : begin sys_ack <= sys_en;          sys_rdata <= pll0_gaini;                           end 
        16'h0023 : begin sys_ack <= sys_en;          sys_rdata <= pll0_gainii;                          end 
        16'h0024 : begin sys_ack <= sys_en;          sys_rdata <= pll0_gaind;                           end 
        16'h0025 : begin sys_ack <= sys_en;          sys_rdata <= {{32-18{1'b0}}, pll0_coefdfilter};    end
        
        16'h0028 : begin sys_ack <= sys_en;          sys_rdata <=  positive_limit_dac0;                 end
        16'h0029 : begin sys_ack <= sys_en;          sys_rdata <=  negative_limit_dac0;                 end
        16'h002A : begin sys_ack <= sys_en;          sys_rdata <=  manual_offset_dac0;                  end
        
        16'h0030 : begin sys_ack <= sys_en;          sys_rdata <= {{32-14{1'b0}}, VCO_Voffset0};        end 
        16'h0031 : begin sys_ack <= sys_en;          sys_rdata <= {{32-16{1'b0}}, VCO_Vamplitude0};     end
        16'h0032 : begin sys_ack <= sys_en;          sys_rdata <= {{32-16{1'b0}}, PLL_Mul_factor};      end 
        16'h0033 : begin sys_ack <= sys_en;          sys_rdata <= {{32-16{1'b0}}, PLL_Div_factor};      end       
        
        16'h0040 : begin sys_ack <= sys_en;          sys_rdata <= {{32-14{1'b0}}, VCO_Voffset1};        end 
        16'h0041 : begin sys_ack <= sys_en;          sys_rdata <= {{32-16{1'b0}}, VCO_Vamplitude1};     end
        16'h0042 : begin sys_ack <= sys_en;          sys_rdata <= VCO_Fre_Input1;                       end 
        16'h0043 : begin sys_ack <= sys_en;          sys_rdata <= VCO_Phase_Input1;                     end 
        
        16'h0050 : begin sys_ack <= sys_en;          sys_rdata <= phase_residuals0_threshold;           end 
        16'h0051 : begin sys_ack <= sys_en;          sys_rdata <= phase_residuals0_offset;              end 
        16'h0052 : begin sys_ack <= sys_en;          sys_rdata <= freq_residuals0_threshold;            end 

        16'h0060 : begin sys_ack <= sys_en;          sys_rdata <= 32'hAD030001;                         end
        16'h0061 : begin sys_ack <= sys_en;          sys_rdata <= {24'd0, adaptive_shadow_profile};     end
        16'h0062 : begin sys_ack <= sys_en;          sys_rdata <= adaptive_shadow_kp;                   end
        16'h0063 : begin sys_ack <= sys_en;          sys_rdata <= adaptive_shadow_ki;                   end
        16'h0064 : begin sys_ack <= sys_en;          sys_rdata <= adaptive_shadow_kii;                  end
        16'h0065 : begin sys_ack <= sys_en;          sys_rdata <= adaptive_shadow_kd;                   end
        16'h0066 : begin sys_ack <= sys_en;          sys_rdata <= adaptive_shadow_dcoef;                end
        16'h0067 : begin sys_ack <= sys_en;          sys_rdata <= 32'd0;                               end
        16'h0068 : begin sys_ack <= sys_en;          sys_rdata <= adaptive_applied_seq;                 end
        16'h0069 : begin sys_ack <= sys_en;          sys_rdata <= adaptive_apply_status;                end
        16'h006A : begin sys_ack <= sys_en;          sys_rdata <= {24'd0, adaptive_active_profile};     end
        16'h006B : begin sys_ack <= sys_en;          sys_rdata <= adaptive_active_kp;                   end
        16'h006C : begin sys_ack <= sys_en;          sys_rdata <= adaptive_active_ki;                   end
        16'h006D : begin sys_ack <= sys_en;          sys_rdata <= adaptive_active_kii;                  end
        16'h006E : begin sys_ack <= sys_en;          sys_rdata <= adaptive_active_kd;                   end
        16'h006F : begin sys_ack <= sys_en;          sys_rdata <= adaptive_active_dcoef;                end
        //纯读取
        //pll0_locked-瞬时锁定 LED_R0-长时不锁定 pll0_lock-PLL启动使能 LED_G0-长时锁定 
        //16'h0100 : begin sys_ack <= sys_en;          sys_rdata <= {{32-6{1'b0}}, pll0_locked,LED_R0,pll0_lock,LED_G0,dac0_railed_positive,dac0_railed_negative,residuals0_are_above_threshold_freq,residuals0_are_above_threshold_phase};     end//系统状态
        16'h0100 : begin sys_ack <= sys_en;          sys_rdata <= {{32-16{1'b0}}, 
                LED_R0,LED_G0,pll0_locked_Instant,dac0_railed_positive,dac0_railed_negative,residuals0_are_above_threshold_freq,residuals0_are_above_threshold_phase,
                2'b0,pll0_lock,pll0_locked_Stable,positive_railed_Stable,negative_railed_Stable,residuals0_threshold_freq_Stable,residuals0_threshold_phase_Stable};end
        16'h0101 : begin sys_ack <= sys_en;          sys_rdata <= {{32-16{1'b0}}, DDC_Amplitude_0};     end
        16'h0102 : begin sys_ack <= sys_en;          sys_rdata <= {{32-14{1'b0}}, wrapped_phase0};      end
        16'h0103 : begin sys_ack <= sys_en;          sys_rdata <= {{32-14{1'b0}}, inst_frequency0};     end        
        
        16'h0104 : begin sys_ack <= sys_en;          sys_rdata <=  pll0_output;                         end
        16'h0105 : begin sys_ack <= sys_en;          sys_rdata <=  PID_OUT_With_Limit;                  end
        16'h0106 : begin sys_ack <= sys_en;          sys_rdata <=  phase_residuals0;                    end
        16'h0107 : begin sys_ack <= sys_en;          sys_rdata <=  pll_output_average_value;            end
        16'h0120 : begin sys_ack <= sys_en;          sys_rdata <= adaptive_snapshot_seq;                end
        16'h0121 : begin sys_ack <= sys_en;          sys_rdata <= adaptive_snapshot_samples;            end
        16'h0122 : begin sys_ack <= sys_en;          sys_rdata <= adaptive_amp_sum[31:0];               end
        16'h0123 : begin sys_ack <= sys_en;          sys_rdata <= adaptive_amp_sum[63:32];              end
        16'h0124 : begin sys_ack <= sys_en;          sys_rdata <= {adaptive_amp_max, adaptive_amp_min}; end
        16'h0125 : begin sys_ack <= sys_en;          sys_rdata <= adaptive_freq_abs_sum[31:0];          end
        16'h0126 : begin sys_ack <= sys_en;          sys_rdata <= adaptive_freq_abs_sum[63:32];         end
        16'h0127 : begin sys_ack <= sys_en;          sys_rdata <= adaptive_freq_abs_max;                end
        16'h0128 : begin sys_ack <= sys_en;          sys_rdata <= adaptive_phase_abs_sum[31:0];         end
        16'h0129 : begin sys_ack <= sys_en;          sys_rdata <= adaptive_phase_abs_sum[63:32];        end
        16'h012A : begin sys_ack <= sys_en;          sys_rdata <= adaptive_phase_abs_max;               end
        16'h012B : begin sys_ack <= sys_en;          sys_rdata <= adaptive_output_min;                  end
        16'h012C : begin sys_ack <= sys_en;          sys_rdata <= adaptive_output_max;                  end
        16'h012D : begin sys_ack <= sys_en;          sys_rdata <= adaptive_locked_samples;              end
        16'h012E : begin sys_ack <= sys_en;          sys_rdata <= adaptive_pos_rail_samples;            end
        16'h012F : begin sys_ack <= sys_en;          sys_rdata <= adaptive_neg_rail_samples;            end
        16'h0130 : begin sys_ack <= sys_en;          sys_rdata <= adaptive_freq_bad_samples;            end
        16'h0131 : begin sys_ack <= sys_en;          sys_rdata <= adaptive_phase_bad_samples;           end
        16'h0132 : begin sys_ack <= sys_en;          sys_rdata <= adaptive_loss_lock_events;            end
        16'h0133 : begin sys_ack <= sys_en;          sys_rdata <= adaptive_pos_rail_events;             end
        16'h0134 : begin sys_ack <= sys_en;          sys_rdata <= adaptive_neg_rail_events;             end
        16'h0135 : begin sys_ack <= sys_en;          sys_rdata <= adaptive_commit_error_count;          end
        16'h0136 : begin sys_ack <= sys_en; sys_rdata <= 32'hAD050001; end
        16'h0137 : begin sys_ack <= sys_en; sys_rdata <= adaptive_freq_signed_sum[31:0]; end
        16'h0138 : begin sys_ack <= sys_en; sys_rdata <= adaptive_freq_signed_sum[63:32]; end
        16'h0139 : begin sys_ack <= sys_en; sys_rdata <= adaptive_freq_square_sum[31:0]; end
        16'h013A : begin sys_ack <= sys_en; sys_rdata <= adaptive_freq_square_sum[63:32]; end
        16'h013B : begin sys_ack <= sys_en; sys_rdata <= adaptive_phase_signed_sum[31:0]; end
        16'h013C : begin sys_ack <= sys_en; sys_rdata <= adaptive_phase_signed_sum[63:32]; end
        16'h013D : begin sys_ack <= sys_en; sys_rdata <= adaptive_phase_first; end
        16'h013E : begin sys_ack <= sys_en; sys_rdata <= adaptive_phase_last; end
        16'h013F : begin sys_ack <= sys_en; sys_rdata <= adaptive_residual_bad_samples; end
        16'h0140 : begin sys_ack <= sys_en; sys_rdata <= adaptive_rail_samples; end
        16'h0141 : begin sys_ack <= sys_en; sys_rdata <= adaptive_phase_sat_samples; end
        16'h01FF : begin sys_ack <= sys_en;          sys_rdata <= 32'h7FFFFFFF;                         end

        default  : begin sys_ack <= sys_en;          sys_rdata <=  32'h0;                               end
   endcase
end


endmodule
