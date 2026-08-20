----------------------------------------------------------------------------------
-- Company: 
-- Engineer: 
-- 
-- Create Date:    15:00:29 02/24/2014 
-- Design Name: 
-- Module Name:    ddc_frontend_lowpass_filter - Behavioral 
-- Project Name: 
-- Target Devices: 
-- Tool versions: 
-- Description: Implements a cascade of : (4-pts boxcar) -> (2-pts boxcar) -> (2-pts boxcar) 
-- In MATLAB notation, the operation of the filter is: y = round(filter(conv(ones(2, 1), conv(ones(2, 1), ones(4, 1))), 1, x)/16)
-- Overall DC gain is equal to 1.  There are 5 extra clock cycles of processing delay, in addition to any group delay from the impulse response
-- 
-- Description for the new version with a filter select input: Simple low-pass filter, tuned for the FPGA-based frequency comb phase-locks.  There are two different filters.
-- filter_select = b"00" selects a convolution of 2x 2-samples long boxcar filters by a 4-samples long boxcar, so that the filter coefficients are: [1 3 4 4 3 1].
-- This filter has 3 zeros at Nyquist which is where most of the undesired energy has in this application when the input tone is tuned at 25 MHz. (this filter is applied after the complex multiplication with the LO, making the undesired tone appear at -50 MHz)
-- filter_select = b"01" selects a convolution of a 4-samples long boxcar with a 16-samples long boxcar.
-- the output is divided either by 16 to cancel the wideband filter gain, or 16*4 to cancel the narrowband filter.
-- filter_select = b"10" selects a convolution of a 16-taps minimum-phase FIR and a 2-points boxcar
--
-- the wideband filter has 5 cycles of processing delay in addition to the filter's group delay, while
-- the narrowband filter has 4 cycles of processing delay in addition to the filter's group delay.
-- the minimum-phase fir has 10 cycles of processing delay in addition to the filter's group delay. EDIT: In the new version for the Zynq (Red Pitaya), the delay is now 9 cycles instead of 10.



-- Dependencies: 
--
-- Revision: 
-- Revision 0.01 - File Created
-- Additional Comments: 
--
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

-- Uncomment the following library declaration if using
-- arithmetic functions with Signed or Unsigned values
use IEEE.NUMERIC_STD.ALL;

-- Uncomment the following library declaration if instantiating
-- any Xilinx primitives in this code.
--library UNISIM;
--use UNISIM.VComponents.all;

entity ddc_frontend_lowpass_filter_H is
	Generic (
		INPUT_SIZE : integer := 16
	);
    Port (
		rst           : in  std_logic;
		clk           : in  std_logic;
		clk_times_N   : in  std_logic;
		data_input    : in  std_logic_vector (INPUT_SIZE-1 downto 0);
		data_output   : out std_logic_vector (INPUT_SIZE-1 downto 0)

	);
end ddc_frontend_lowpass_filter_H;

architecture Behavioral of ddc_frontend_lowpass_filter_H is


	-- intermediate signals for the wideband filter
	signal data_interm1 : std_logic_vector(INPUT_SIZE+2-1 downto 0) := (others => '0');
	signal data_interm2 : std_logic_vector(INPUT_SIZE+3-1 downto 0) := (others => '0');
	signal data_interm3 : std_logic_vector(INPUT_SIZE+4-1 downto 0) := (others => '0');
	
	-- signals for the narrowband filter (16 pts boxcar)
	constant LOG2_MAXIMUM_SIZE_16_PTS : integer := 5;
	constant N_16_PTS : std_logic_vector(LOG2_MAXIMUM_SIZE_16_PTS-1 downto 0) := std_logic_vector(to_unsigned(16, LOG2_MAXIMUM_SIZE_16_PTS));
	signal data_narrowband : std_logic_vector(16+5+2-1 downto 0);
	
	
	
	-- signals for the minimum phase FIR:
	signal data_to_fir_wide : std_logic_vector(17-1 downto 0) := (others => '0');
	signal data_to_fir : std_logic_vector(16-1 downto 0) := (others => '0');
	signal data_fir : std_logic_vector(16-1 downto 0) := (others => '0');

	
	-- selects between the two filters and also cancels the filter gain:
	signal data_output_register : std_logic_vector(INPUT_SIZE-1 downto 0) := (others => '0');
	-- Divides the output of the filter by 2^BIT_SHIFT_AFTER_FILTER to keep gain approximately equal to 1.
	constant BIT_SHIFT_AFTER_WIDEBAND_FILTER : positive := 4;
	constant BIT_SHIFT_AFTER_NARROWBAND_FILTER : positive := 2+4;
	constant BIT_SHIFT_AFTER_IIR_FILTER : positive := 38-16;
begin

	
	-- 3rd filter option (filter_select = b"10":
	-- convolution of a 2-points boxcar + a 16-taps, minimum phase fir
   boxcar_2_pts_filter_inst3: entity work.boxcar_2_pts_filter
	GENERIC MAP (
		INPUT_SIZE => data_input'length
	)
	PORT MAP (
          clk => clk,
          data_input => data_input,
          data_output => data_to_fir_wide
        );
	data_to_fir <= data_to_fir_wide(data_to_fir'range);	-- this is not 100% clean since it can wrap for the largest inputs.

	-- Changed 13-08-2016 to fit the Red Pitaya Zynq, we now use a FIR that runs the multipliers at N times the data clk rate

		
	N_times_clk_FIR_wrapper_H_inst: entity work.N_times_clk_FIR_wrapper_H
	port map (
		clk_times_1 => clk,
		clk_times_N => clk_times_N,
		data_in     => data_to_fir,
		data_out    => data_fir
	);

	process (clk)
	begin
        data_output_register <= data_fir;
	end process;
	
	data_output <= data_output_register;
	
end Behavioral;

