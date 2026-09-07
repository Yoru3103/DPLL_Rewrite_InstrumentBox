// Digital-Frequency-meter
// JSY 2023

`default_nettype none   // This disables implicit variable declaration, which I really don't like as a feature as it lets bugs go unreported

module Digital_Freq_Meter(

    input  wire               clk1,         // global clock, designed for 125 MHz clock rate
    input  wire               clk1_timesN,  //250 MHz this should be N times the clock, phase-locked to clk1, N matching what was input in the FIR compiler for fir_compiler_minimumphase_N_times_clk
    //input  wire               clk_10M_ref,  //ref clock 10MHz
    input  wire               rst,

    input  wire signed [15:0] ADCraw,

    // System bus
    input  wire [ 32-1:0]     sys_addr   ,  // bus address
    input  wire [ 32-1:0]     sys_wdata  ,  // bus write data
    input  wire [  4-1:0]     sys_sel    ,  // bus write byte select
    input  wire               sys_wen    ,  // bus write enable
    input  wire               sys_ren    ,  // bus read enable
    output reg [ 32-1:0]     sys_rdata  ,  // bus read data
    output reg               sys_err    ,  // bus error indicator
    output reg               sys_ack       // bus acknowledge signal
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
//reset system
//输出的是正复位信号
///////////////////////////////////////////////////////////////////////////////
wire ok_reset;
reg [15:0] reset_counter = 16'b1111111111111111;    // 2**16 cycles * 10 ns/cycle = 655 us of maximum reset time
reg rst0_c, rst0_internal;
wire rst0;
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
	 
always @(posedge clk1) begin
    
    //if ((ok_reset == 1'b1) || (ok_reset_frontend == 1'b1)) 
    if (ok_reset == 1'b1)
    begin
        reset_counter <= 16'b1111111111111111;
    end
    else begin
        if (reset_counter > 0) begin
            reset_counter <= reset_counter - 1'b1;
        end
        
        // The different reset groups are compared each to a different value,
        // to make sure that Xilinx doesn't combine the registers into a single reset signal driving a very large fanout
        rst0_internal              <= ((reset_counter > 1) ? 1'b1 : 1'b0);
        //rst_frontend1_internal              <= ((reset_counter > 2) ? 1'b1 : 1'b0);
        
        // An extra register stage to help with routing
        rst0_c <= rst0_internal;
        //rst_frontend1 <= rst_frontend1_internal;
        
    end
end	 
BUFG bufg_fm_rst    (.O (rst0), .I (rst0_c));

//reg rst1;
//reg rst_buff;
//always @(posedge clk_10M_ref) begin
//    rst_buff <= rst0;
//    rst1 <= rst_buff;
//end	 
///////////////////////////////////////////////////////////////////////////////
//鉴相器
// Direct-digital converter (brings a signal to baseband, low-pass filters it, and outputs the phase and frequency) for ADC 0
//20.5~59.5MHz
//PID输出上下限 限制为2800_0000H = 9.765MHz
//PID输出上下限 限制为5000_0000H = 19.53MHz
///////////////////////////////////////////////////////////////////////////////


wire [32-1:0]Centre_Freq_Set;//寄存器设置的锁相环中心频率（相位累加字）
wire [48-1:0]Centre_Freq_DDC_Phase;//设置的锁相环中心频率-同步位数
wire [32-1:0]PID_OUT_With_Limit;//PID输出的值（相位累加字）
wire [48-1:0]PID_OUT_DDC_Phase;//PID输出的值-同步位数
reg  [47:0] Reference_frequency_DDC_Phase = 48'h0;//最终合成后输入到DDC的相位累加字
wire [32-1:0] Freq_Meter_Phase_Add;//用于频率测量的相位累计字 32位 半相位

wire pll0_lock_on,pll0_lock_on_i;
wire [16-1:0]         DDC_Amplitude_0;
wire        [14-1:0]       wrapped_phase0;     // phi/(2*pi) * 2^14
wire        [14-1:0]       inst_frequency0;        // diff(phi)/(2*pi) * 2^14

//默认中心频率  40MHz @ 125MHz    
parallel_bus_register_32bits_or_less # (
	.REGISTER_SIZE(32),
	.REGISTER_DEFAULT_VALUE(32'h51EB851E),//40MHz
	.ADDRESS(16'h0010)
) parallel_bus_register_32_bits_or_less_freq_c0 (
	 .clk(clk1), 
	 .bus_strobe(cmd_trig), 
	 .bus_address(cmd_addr), 
	 .bus_data(cmd_datain), 
	 .register_output(Centre_Freq_Set), 
	 .update_flag()
); 


assign PID_OUT_DDC_Phase = {PID_OUT_With_Limit[31],PID_OUT_With_Limit,15'h000};
assign Centre_Freq_DDC_Phase = {Centre_Freq_Set,16'h0000};

always @ (posedge clk1 or posedge rst0) begin
    if(rst0)begin
    Reference_frequency_DDC_Phase <= 48'h0;
    end
    else begin
    Reference_frequency_DDC_Phase <= PID_OUT_DDC_Phase+Centre_Freq_DDC_Phase;
    end
end 

assign Freq_Meter_Phase_Add = Reference_frequency_DDC_Phase[46:15];

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
    .register_output(pll0_lock_on_i), 
    .update_flag()
    );
BUFG bufg_dpll_clk    (.O (pll0_lock_on), .I (pll0_lock_on_i));   

Freq_Meter_DDC_wideband_filters DDC1_inst (
    .rst(rst0), 
    .clk(clk1), 
    .clk_times_N(clk1_timesN),
    .data_input(ADCraw),     // 
     
     // Configuration
    .reference_frequency(Reference_frequency_DDC_Phase), 
     
    // Reference tone output:
    .ref_cosine_out(),
    .ref_sine_out(),
    
    // Used for nulling the lock phase offset:
    .lock(pll0_lock_on),
     
     // Output
    .amplitude(DDC_Amplitude_0), 
    .wrapped_phase(wrapped_phase0), 
    .inst_frequency(inst_frequency0)
    );


///////////////////////////////////////////////////////////////////////////////
// Loop filters 
//PID
///////////////////////////////////////////////////////////////////////////////
wire pll0_gain_changed, pll0_gain_changedp, pll0_gain_changedi, pll0_gain_changedii, pll0_gain_changedd, pll0_coef_changedd;
wire [32-1:0] pll0_gainp, pll0_gaini, pll0_gainii, pll0_gaind, pll0_coefdfilter;
// 阶段 3 原子参数接口：adaptive_gain* 是最终送入环路的参数，模块内部在 legacy 与 active 参数间选择。
wire [31:0] adaptive_gainp, adaptive_gaini, adaptive_gainii, adaptive_gaind, adaptive_coefdfilter;
wire adaptive_gain_changed; // 整组参数发生变化时给环路滤波器的单拍通知
wire [7:0] adaptive_shadow_profile, adaptive_active_profile; // 待提交/已生效 profile ID
wire [31:0] adaptive_shadow_kp, adaptive_shadow_ki, adaptive_shadow_kii;
wire [31:0] adaptive_shadow_kd, adaptive_shadow_dcoef;
wire [31:0] adaptive_applied_seq, adaptive_apply_status; // 已应用事务号和打包状态字
wire [31:0] adaptive_active_kp, adaptive_active_ki, adaptive_active_kii;
wire [31:0] adaptive_active_kd, adaptive_active_dcoef, adaptive_commit_error_count;
wire [32-1:0] pll0_output;
wire [31:0] phase_residuals0;

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

// 测频参数总线与环路同为 clk1，因此可在一个 125 MHz 时钟沿直接原子提交。
adaptive_param_commit_same_clock adaptive_parameter_commit (
    .clk(clk1), .reset_n(rst), .bus_write(cmd_trig), .bus_address(cmd_addr),
    .bus_wdata(cmd_datain[31:0]), .legacy_changed(pll0_gain_changed),
    .legacy_kp(pll0_gainp), .legacy_ki(pll0_gaini), .legacy_kii(pll0_gainii),
    .legacy_kd(pll0_gaind), .legacy_dcoef(pll0_coefdfilter),
    .loop_kp(adaptive_gainp), .loop_ki(adaptive_gaini), .loop_kii(adaptive_gainii),
    .loop_kd(adaptive_gaind), .loop_dcoef(adaptive_coefdfilter),
    .loop_gain_changed(adaptive_gain_changed),
    .shadow_profile(adaptive_shadow_profile), .shadow_kp(adaptive_shadow_kp),
    .shadow_ki(adaptive_shadow_ki), .shadow_kii(adaptive_shadow_kii),
    .shadow_kd(adaptive_shadow_kd), .shadow_dcoef(adaptive_shadow_dcoef),
    .applied_seq(adaptive_applied_seq), .apply_status(adaptive_apply_status),
    .active_profile(adaptive_active_profile), .active_kp(adaptive_active_kp),
    .active_ki(adaptive_active_ki), .active_kii(adaptive_active_kii),
    .active_kd(adaptive_active_kd), .active_dcoef(adaptive_active_dcoef),
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
    .clk(clk1), 
    .lock(pll0_lock_on), 
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
///////////////////////////////////////////////////////////////////////////////
wire [32-1:0] manual_offset_dac0, positive_limit_dac0, negative_limit_dac0;
wire pid0_railed_negative, pid0_railed_positive;
parallel_bus_register_32bits_or_less # (
    .REGISTER_SIZE(32),
    .REGISTER_DEFAULT_VALUE(32'h27ffffff),
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
    .REGISTER_DEFAULT_VALUE(32'hD8000000),
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
    
output_summing #(
    .INPUT_SIZE(32),
    .OUTPUT_SIZE(32)
)
output_summing_dac0
    (
        .clk(clk1),
        .in0(pll0_output),
        .in1(manual_offset_dac0),
        .data_output(PID_OUT_With_Limit),
        .positive_limit(positive_limit_dac0),
        .negative_limit(negative_limit_dac0),
        .railed_positive(pid0_railed_positive),
        .railed_negative(pid0_railed_negative)
    );


 ///////////////////////////////////////////////////////////////////////////////   
//系统监控 超出阈值//LED控制等

//系统监控
// This module outputs high if the abs value of the phase residuals is above a certain threshold
// the output of this module triggers the crash monitor
 ///////////////////////////////////////////////////////////////////////////////   
wire [31:0]  phase_residuals0_threshold, phase_residuals0_offset;
wire [9:0]  freq_residuals0_threshold;
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
     
residuals_monitor_with_offset # (
    .N_BITS_DATA(32)
)
residuals_monitor_inst0 (
     .clk(clk1), 
     .phase_residuals(phase_residuals0), 
     .residuals_offset(phase_residuals0_offset),
     .residuals_threshold(phase_residuals0_threshold), 
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
     .clk(clk1), 
     .phase_residuals(inst_frequency0), 
     .residuals_threshold(freq_residuals0_threshold), 
     .residuals_are_above_threshold(residuals0_are_above_threshold_freq)
     );
 
// The two trigger conditions are ORed together:
wire pll0_locked_Instant;
reg pll0_locked_neg;
always @(posedge clk1)
begin
 residuals0_are_above_threshold <= residuals0_are_above_threshold_phase | residuals0_are_above_threshold_freq;
 rail_are_above_threshold <= pid0_railed_positive | pid0_railed_negative;
 pll0_locked_neg <= pid0_railed_positive | pid0_railed_negative | residuals0_are_above_threshold_freq | residuals0_are_above_threshold_phase;
end
not G2(pll0_locked_Instant,pll0_locked_neg);


//////////////////////////////////////////////////////////////////////
//供用户面板低速读取的稳定寄存器

wire residuals0_threshold_phase_Stable, residuals0_threshold_freq_Stable;
wire positive_railed_Stable,negative_railed_Stable;
wire pll0_locked_Stable,pll0_locked_Stable_neg;

Status_Delay_Show #
    (.N_BITS_COUNTER(25))// 125 MHz/2^25 = 3.7 Hz
    Status_Delay_Show_freq
    (
        .clk(clk1), 
        .lock_on(pll0_lock_on), 
        .above_threshold(residuals0_are_above_threshold_freq),
        .delay_show(residuals0_threshold_freq_Stable)
    );
Status_Delay_Show #
    (.N_BITS_COUNTER(25))// 125 MHz/2^25 = 3.7 Hz
    Status_Delay_Show_phase
    (
        .clk(clk1), 
        .lock_on(pll0_lock_on), 
        .above_threshold(residuals0_are_above_threshold_phase),
        .delay_show(residuals0_threshold_phase_Stable)
    );
Status_Delay_Show #
    (.N_BITS_COUNTER(25))// 125 MHz/2^25 = 3.7 Hz
    Status_Delay_Show_pos_rail
    (
        .clk(clk1), 
        .lock_on(pll0_lock_on), 
        .above_threshold(pid0_railed_positive),
        .delay_show(positive_railed_Stable)
    );
Status_Delay_Show #
    (.N_BITS_COUNTER(25))// 125 MHz/2^25 = 3.7 Hz
    Status_Delay_Show_neg_rail
    (
        .clk(clk1), 
        .lock_on(pll0_lock_on), 
        .above_threshold(pid0_railed_negative),
        .delay_show(negative_railed_Stable)
    );
Status_Delay_Show #
    (.N_BITS_COUNTER(25))// 125 MHz/2^25 = 3.7 Hz
    Status_Delay_Show_lock
    (
        .clk(clk1), 
        .lock_on(pll0_lock_on), 
        .above_threshold(pll0_locked_neg),
        .delay_show(pll0_locked_Stable_neg)
    );
    
not G3(pll0_locked_Stable,pll0_locked_Stable_neg);
    
//////////////////////////////////////////////////////////////////////
//频率计部分
//////////////////////////////////////////////////////////////////////
//阀门时间上限-此处指10MHz参考时钟跑过了多少个时钟周期
wire [16:0]  gate_time_clocks_h;
wire [32:0]  gate_time_clocks_l;
wire freq_meter_trig;


parallel_bus_register_32bits_or_less # (
    .REGISTER_SIZE(32),
    .REGISTER_DEFAULT_VALUE(32'b0),
    .ADDRESS(16'h0070)
)
parallel_bus_register_gate_clockL (
     .clk(clk1), 
     .bus_strobe(cmd_trig), 
     .bus_address(cmd_addr), 
     .bus_data(cmd_datain), 
     .register_output(gate_time_clocks_l), 
     .update_flag()
     );
 parallel_bus_register_32bits_or_less # (
    .REGISTER_SIZE(16),
    .REGISTER_DEFAULT_VALUE(16'b0),
    .ADDRESS(16'h0071)
)

parallel_bus_register_gate_clockH (
     .clk(clk1), 
     .bus_strobe(cmd_trig), 
     .bus_address(cmd_addr), 
     .bus_data(cmd_datain), 
     .register_output(gate_time_clocks_h), 
     .update_flag()
     );    
parallel_bus_register_32bits_or_less # (
    .REGISTER_SIZE(1),
    .REGISTER_DEFAULT_VALUE(32'b0),
    .ADDRESS(16'h0072)
)

parallel_bus_register_freq_meter_trig (
     .clk(clk1), 
     .bus_strobe(cmd_trig), 
     .bus_address(cmd_addr), 
     .bus_data(cmd_datain), 
     .register_output(), 
     .update_flag(freq_meter_trig)
     );

reg [1:0]meter_state;  
reg[79:0] phase_addr,phase_addr_out; 
reg phase_addr_run;
reg[48:0] gate_clocks_cnt;
always @(posedge clk1 or posedge rst0) begin
    if (rst0) 
    begin
        meter_state      <= 2'b00 ;
        phase_addr       <= 0;
        phase_addr_out   <= 0;
        phase_addr_run   <= 1'b0;
        gate_clocks_cnt  <= 48'h0;
    end
    else 
    begin
        case(meter_state)
            2'b00:
            begin
                if(freq_meter_trig)
                begin
                    meter_state <= 2'b01;
                end
            end    
            2'b01:
            begin  
                phase_addr_run <= 1'b1;  
                phase_addr       <= 0;
                gate_clocks_cnt <= {gate_time_clocks_h,gate_time_clocks_l};  
                meter_state <= 2'b10;                      
            end 
            2'b10:
            begin                
                if(gate_clocks_cnt > 0)
                begin
                    gate_clocks_cnt <= gate_clocks_cnt - 1'b1;
                    phase_addr <= phase_addr + Freq_Meter_Phase_Add;
                end
                else
                begin
                    meter_state <= 2'b11;
                end
            end 
            2'b11:
            begin 
                phase_addr_run <= 0;
                phase_addr_out <= phase_addr;                
                phase_addr       <= 0;
                meter_state <= 2'b00;                        
            end 
        endcase
    end
end


////////////////////////////////////////////////////////////////////////////////
//读总线
wire sys_en;
assign sys_en = sys_wen | sys_ren;

// 阶段 3 窗口统计快照；测频统计与 PS 总线同域，不需要额外的宽总线 CDC。
wire adaptive_snapshot_toggle; // 同域场景保留该端口，便于与锁相回路共用统计模块
wire [31:0] adaptive_snapshot_seq, adaptive_snapshot_samples;
wire [63:0] adaptive_amp_sum, adaptive_freq_abs_sum, adaptive_phase_abs_sum;
wire [15:0] adaptive_amp_min, adaptive_amp_max;
wire [31:0] adaptive_freq_abs_max, adaptive_phase_abs_max;
wire [31:0] adaptive_output_min, adaptive_output_max;
// 以下为当前冻结窗口内的状态样本计数和复位以来的事件计数快照。
wire [31:0] adaptive_locked_samples, adaptive_pos_rail_samples, adaptive_neg_rail_samples;
wire [31:0] adaptive_freq_bad_samples, adaptive_phase_bad_samples;
wire [31:0] adaptive_loss_lock_events, adaptive_pos_rail_events, adaptive_neg_rail_events;

wire [63:0] adaptive_freq_signed_sum;
wire [63:0] adaptive_freq_square_sum;
wire [63:0] adaptive_phase_signed_sum;
wire [31:0] adaptive_phase_first;
wire [31:0] adaptive_phase_last;
wire [31:0] adaptive_residual_bad_samples;
wire [31:0] adaptive_rail_samples;
wire [31:0] adaptive_phase_sat_samples;

adaptive_statistics #(.WINDOW_LOG2(17)) adaptive_loop_statistics (
    .clk(clk1), .reset_n(rst), .amplitude(DDC_Amplitude_0),
    .frequency_error(inst_frequency0), .phase_error(phase_residuals0),
    .loop_output(PID_OUT_With_Limit), .locked(pll0_lock_on & pll0_locked_Instant),
    .rail_positive(pid0_railed_positive), .rail_negative(pid0_railed_negative),
    .frequency_bad(residuals0_are_above_threshold_freq),
    .phase_bad(residuals0_are_above_threshold_phase),
    .snapshot_seq(adaptive_snapshot_seq), .snapshot_toggle(adaptive_snapshot_toggle),
    .sample_count(adaptive_snapshot_samples), .amplitude_sum(adaptive_amp_sum),
    .amplitude_min(adaptive_amp_min), .amplitude_max(adaptive_amp_max),
    .frequency_abs_sum(adaptive_freq_abs_sum), .frequency_abs_max(adaptive_freq_abs_max),
    .phase_abs_sum(adaptive_phase_abs_sum), .phase_abs_max(adaptive_phase_abs_max),
    .output_min(adaptive_output_min), .output_max(adaptive_output_max),
    .locked_sample_count(adaptive_locked_samples),
    .positive_rail_sample_count(adaptive_pos_rail_samples),
    .negative_rail_sample_count(adaptive_neg_rail_samples),
    .frequency_bad_sample_count(adaptive_freq_bad_samples),
    .phase_bad_sample_count(adaptive_phase_bad_samples),
    .loss_of_lock_event_count(adaptive_loss_lock_events),
    .positive_rail_event_count(adaptive_pos_rail_events),
    .negative_rail_event_count(adaptive_neg_rail_events),
    .frequency_signed_sum(adaptive_freq_signed_sum),
    .frequency_square_sum(adaptive_freq_square_sum),
    .phase_signed_sum(adaptive_phase_signed_sum),
    .phase_first(adaptive_phase_first),
    .phase_last(adaptive_phase_last),
    .residual_bad_sample_count(adaptive_residual_bad_samples),
    .rail_sample_count(adaptive_rail_samples),
    .phase_saturated_sample_count(adaptive_phase_sat_samples)
);

always @(posedge clk1)
if (rst == 1'b0) begin
   sys_err <= 1'b0 ;
   sys_ack <= 1'b0 ;
end else begin
   sys_err <= 1'b0 ;
   casez (cmd_addr[16-1:0])
        16'h0010 : begin sys_ack <= sys_en;          sys_rdata <= Centre_Freq_Set;                      end  
       
        16'h0020 : begin sys_ack <= sys_en;          sys_rdata <= {{32-1{1'b0}}, pll0_lock_on};         end
        16'h0021 : begin sys_ack <= sys_en;          sys_rdata <= pll0_gainp;                           end 
        16'h0022 : begin sys_ack <= sys_en;          sys_rdata <= pll0_gaini;                           end 
        16'h0023 : begin sys_ack <= sys_en;          sys_rdata <= pll0_gainii;                          end 
        16'h0024 : begin sys_ack <= sys_en;          sys_rdata <= pll0_gaind;                           end 
        16'h0025 : begin sys_ack <= sys_en;          sys_rdata <= {{32-18{1'b0}}, pll0_coefdfilter};    end
        
        16'h0028 : begin sys_ack <= sys_en;          sys_rdata <=  positive_limit_dac0;                 end
        16'h0029 : begin sys_ack <= sys_en;          sys_rdata <=  negative_limit_dac0;                 end
        16'h002A : begin sys_ack <= sys_en;          sys_rdata <=  manual_offset_dac0;                  end

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
        
        16'h0070 : begin sys_ack <= sys_en;          sys_rdata <= gate_time_clocks_l;                     end 
        16'h0071 : begin sys_ack <= sys_en;          sys_rdata <= gate_time_clocks_h;                     end 
        //纯读取
        //pll0_locked-瞬时锁定 LED_R0-长时不锁定 pll0_lock-PLL启动使能 LED_G0-长时锁定 
        //16'h0100 : begin sys_ack <= sys_en;          sys_rdata <= {{32-6{1'b0}}, pll0_locked,LED_R0,pll0_lock,LED_G0,dac0_railed_positive,dac0_railed_negative,residuals0_are_above_threshold_freq,residuals0_are_above_threshold_phase};     end//系统状态
        16'h0100 : begin sys_ack <= sys_en;          sys_rdata <= {{32-16{1'b0}}, 
                2'b0,pll0_locked_Instant,pid0_railed_positive,pid0_railed_negative,residuals0_are_above_threshold_freq,residuals0_are_above_threshold_phase,
                2'b0,pll0_lock_on,pll0_locked_Stable,positive_railed_Stable,negative_railed_Stable,residuals0_threshold_freq_Stable,residuals0_threshold_phase_Stable};end
        16'h0101 : begin sys_ack <= sys_en;          sys_rdata <= {{32-16{1'b0}}, DDC_Amplitude_0};     end
        16'h0102 : begin sys_ack <= sys_en;          sys_rdata <= {{32-14{1'b0}}, wrapped_phase0};      end
        16'h0103 : begin sys_ack <= sys_en;          sys_rdata <= {{32-14{1'b0}}, inst_frequency0};     end        
        
        16'h0104 : begin sys_ack <= sys_en;          sys_rdata <=  pll0_output;                         end
        16'h0105 : begin sys_ack <= sys_en;          sys_rdata <=  PID_OUT_With_Limit;                  end
        16'h0106 : begin sys_ack <= sys_en;          sys_rdata <=  phase_residuals0;                    end
        16'h0107 : begin sys_ack <= sys_en;          sys_rdata <=  Reference_frequency_DDC_Phase[47:16]; end
        
        16'h0110 : begin sys_ack <= sys_en;          sys_rdata <= {{32-1{1'b0}}, phase_addr_run};       end 
        16'h0111 : begin sys_ack <= sys_en;          sys_rdata <= phase_addr_out[31:0];                 end 
        16'h0112 : begin sys_ack <= sys_en;          sys_rdata <= phase_addr_out[63:32];                end 
        16'h0113 : begin sys_ack <= sys_en;          sys_rdata <= {{32-16{1'b0}}, phase_addr_out[79:64]};end 

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

//        16'h0115 : begin sys_ack <= sys_en;          sys_rdata <= phase_addr_o1[31:0];                 end 
//        16'h0116 : begin sys_ack <= sys_en;          sys_rdata <= phase_addr_o1[63:32];                end 
//        16'h0117 : begin sys_ack <= sys_en;          sys_rdata <= {{32-16{1'b0}}, phase_addr_o1[79:64]};end 
        
//        16'h0118 : begin sys_ack <= sys_en;          sys_rdata <= phase_addr_o2[31:0];                 end 
//        16'h0119 : begin sys_ack <= sys_en;          sys_rdata <= phase_addr_o2[63:32];                end 
//        16'h011A : begin sys_ack <= sys_en;          sys_rdata <= {{32-16{1'b0}}, phase_addr_o2[79:64]};end 
        

        default  : begin sys_ack <= sys_en;          sys_rdata <=  32'h0;                               end
   endcase
end




endmodule
