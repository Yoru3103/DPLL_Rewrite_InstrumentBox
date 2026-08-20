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
    .gain_changed(pll0_gain_changed), 
    .data_in(inst_frequency0), 
    .gain_p(pll0_gainp), 
    .gain_i(pll0_gaini), 
    .gain_ii(pll0_gainii),
    .gain_d(pll0_gaind),
    .coef_d_filter(pll0_coefdfilter),
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
