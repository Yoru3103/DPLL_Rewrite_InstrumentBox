----------------------------------------------------------------------------------
-- Company: 
-- Engineer: 
-- 
-- Create Date: 2020/04/19 22:08:35
-- Design Name: 
-- Module Name: VCO_16bits - Behavioral
-- Project Name: 
-- Target Devices: 
-- Tool Versions: 
-- Description: 
-- 
-- Dependencies: 
-- 
-- Revision:
-- Revision 0.01 - File Created
-- Additional Comments:
-- 
----------------------------------------------------------------------------------


library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;

-- Uncomment the following library declaration if using
-- arithmetic functions with Signed or Unsigned values
--use IEEE.NUMERIC_STD.ALL;

-- Uncomment the following library declaration if instantiating
-- any Xilinx leaf cells in this code.
--library UNISIM;
--use UNISIM.VComponents.all;

entity VCO_32bits is
Generic (
    IN_DATA_WIDTH       : integer := 32;
	OUT_DATA_WIDTH		: integer := 16;	-- this cannot be changed without recompiling the DDS core
	AMPLITUDE_WIDTH    : integer := 16;			-- this should fit in a DSP47 mult
	OFFSET_WIDTH    : integer := 14
);
port (
	
    clk                                    : in  std_logic;

    -- frequency in counts: analog frequency is equal to: frequency/2^48*clock frequency (currently 125 MHz)
    VCO_Fre_input                          : in  std_logic_vector(IN_DATA_WIDTH-1 downto 0);
    VCO_Phase_input                        : in  std_logic_vector(IN_DATA_WIDTH-1 downto 0);
    VCO_offset                             : in  std_logic_vector(OFFSET_WIDTH-1 downto 0);
    VCO_amplitude                          : in  std_logic_vector(AMPLITUDE_WIDTH-1 downto 0);

    -- Complex exponential output:
    VCO_DAC_out                             : out std_logic_vector (OUT_DATA_WIDTH-1 downto 0)
	);
end VCO_32bits;

architecture Behavioral of VCO_32bits is


    -- Coregen IP
    component DAC_DDS
        port (
        aclk : IN STD_LOGIC;
        s_axis_phase_tvalid : IN STD_LOGIC;
        s_axis_phase_tdata : IN STD_LOGIC_VECTOR(63 DOWNTO 0);  -- phase increments
        m_axis_data_tvalid : OUT STD_LOGIC;
        m_axis_data_tdata : OUT STD_LOGIC_VECTOR(15 DOWNTO 0)  -- cos and sine (16 bits signed each)
        );
    end component;
    signal s_axis_phase_tvalid                    : std_logic                                      := '1';  -- compiler complains otherwise
    signal lo_dds_m_axis_data_tdata               : std_logic_vector(15 DOWNTO 0)                  := (others => '0');
    
    
    -- internal signals
    signal DDS_cosine_tmp                         : std_logic_vector(OUT_DATA_WIDTH-1 downto 0)        := (others => '0');
    --signal DDS_sine_tmp                           : std_logic_vector(OUT_DATA_WIDTH-1 downto 0)        := (others => '0');
    
    signal cos_times_amplitude_wide               : signed(OUT_DATA_WIDTH+AMPLITUDE_WIDTH-1 downto 0)  := (others => '0');
    --signal sin_times_amplitude_wide               : signed(OUT_DATA_WIDTH+AMPLITUDE_WIDTH-1 downto 0)  := (others => '0');
    
    signal cos_times_amplitude                    : std_logic_vector(OUT_DATA_WIDTH-1 downto 0)        := (others => '0');
    --signal sin_times_amplitude                    : std_logic_vector(OUT_DATA_WIDTH-1 downto 0)        := (others => '0');
    
    constant BIT_SHIFT_AFTER_MULT                 : positive                                       := AMPLITUDE_WIDTH-1;    -- Divides the output of the filter by 2^BIT_SHIFT_AFTER_MULT to keep max amplitude at maximum possible size at 16 bits.
    
    signal vco_phase_frequency 		: std_logic_vector (64-1 downto 0) ; -- signal that contains the value of the frequency of the vco

begin

--vco_phase_frequency <= std_logic_vector(VCO_Phase_input & VCO_Fre_input) ;
vco_phase_frequency(31 downto 0) <= std_logic_vector(VCO_Fre_input) ;
vco_phase_frequency(63 downto 32) <= std_logic_vector(VCO_Phase_input) ;

-- Compute cos() and sin(), or more precisely, round((2^15-1)*cos()) and round((2^15-1)*sin())
    DAC_DDS_inst : DAC_DDS
    port map (
    
        aclk                    => clk,
        s_axis_phase_tvalid     => s_axis_phase_tvalid,
        s_axis_phase_tdata      => vco_phase_frequency,
        m_axis_data_tvalid      => open,
        m_axis_data_tdata       => lo_dds_m_axis_data_tdata
    );
    DDS_cosine_tmp  <= lo_dds_m_axis_data_tdata(15 downto 0);
    --DDS_sine_tmp    <= lo_dds_m_axis_data_tdata(31 downto 16);
    --控制增益
     process (clk)
    begin
        if rising_edge(clk) then
        	-- multiply by amplitude, result has a max value of (2^15-1)*(2^(AMPLITUDE_WIDTH-1)-1)
        	cos_times_amplitude_wide <= signed(DDS_cosine_tmp) * signed(VCO_amplitude);
        	--sin_times_amplitude_wide <= signed(DDS_sine_tmp)   * signed(VCO_amplitude);

        	-- Cancel the multiplier gain and round the multiplication product.
    		-- we want to make the result fit in max of 2^(DATA_WIDTH-1) = 2^15 = (2^15-1)*(2^(AMPLITUDE_WIDTH-1)-1)*2^-BIT_SHIFT_AFTER_MULT
        	-- so we want: 15 = (15)+(AMPLITUDE_WIDTH-1)-BIT_SHIFT_AFTER_MULT (where we neglected some -1s when we took the log)
        	-- BIT_SHIFT_AFTER_MULT = (AMPLITUDE_WIDTH-1)
            cos_times_amplitude <= std_logic_vector(resize(shift_right(
                                        cos_times_amplitude_wide + to_signed(2**(BIT_SHIFT_AFTER_MULT-1), cos_times_amplitude_wide'length)
                                        , BIT_SHIFT_AFTER_MULT), cos_times_amplitude'length));

           -- sin_times_amplitude <= std_logic_vector(resize(shift_right(
           --                             sin_times_amplitude_wide + to_signed(2**(BIT_SHIFT_AFTER_MULT-1), sin_times_amplitude_wide'length)
           --                             , BIT_SHIFT_AFTER_MULT), sin_times_amplitude'length));
        end if;
    end process;
    --添加offset
    VCO_DAC_out <= std_logic_vector(resize(signed(cos_times_amplitude(16-1 downto 2)),VCO_DAC_out'length) + resize(signed(VCO_offset),VCO_DAC_out'length));
	--cosine_out <= cos_times_amplitude;
	--sine_out   <= sin_times_amplitude;   
    

end Behavioral;
