-- Functional proof for the DPLL-specific, 3.125 MHz -> 250 MHz crossing.
-- Production boxcar and wrapper are compiled unchanged. Only the FIR IP is
-- replaced with the checker below; this file must use an isolated work library.
-- At aligned clocks: slow launch=162 ns, d1 sees toggle=166 ns,
-- d2 resolves=170 ns, data_times_N capture=174 ns, extra stage=178 ns, FIR accepts=182 ns.
-- Seven source phase offsets cover [0,4 ns). These are functional simulations;
-- timing closure after d1, including d2/CE paths, remains separately mandatory.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
entity fir_compiler_minimumphase is port (
 aclk: in std_logic; s_axis_data_tvalid: in std_logic; s_axis_data_tready: out std_logic;
 s_axis_data_tdata: in std_logic_vector(15 downto 0);
 m_axis_data_tvalid: out std_logic; m_axis_data_tdata: out std_logic_vector(15 downto 0));
end;
architecture checker of fir_compiler_minimumphase is
 signal accepted: integer := 0;
begin
 s_axis_data_tready <= '1';
 process(aclk)
  variable count: integer := 0;
  variable previous: time := 0 ns;
 begin
  if rising_edge(aclk) then
   m_axis_data_tvalid <= '0';
   if s_axis_data_tvalid='1' then
    assert to_integer(signed(s_axis_data_tdata))=2*count+1
     report "Data mismatch or duplicate/missing sample" severity failure;
    if count=0 then
     assert now=182 ns report "Initial crossing was not captured on the expected third fast edge" severity failure;
    else
     assert now-previous=320 ns report "Expected one capture per slow period" severity failure;
    end if;
    previous:=now; count:=count+1; accepted<=count;
    m_axis_data_tvalid<='1'; m_axis_data_tdata<=s_axis_data_tdata;
   end if;
  end if;
 end process;
 process begin
  wait for 20900 ns;
  assert accepted=64 report "Missing last sample or unexpected startup transfer" severity failure;
  wait;
 end process;
end;
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
entity tb_dpll_fir_multicycle is end;
architecture test of tb_dpll_fir_multicycle is
 signal fast: std_logic := '0';
 type times is array(natural range <>) of time;
 constant offsets: times := (0 ns, 100 ps, 500 ps, 1 ns, 2 ns, 3 ns, 3900 ps);
begin
 fast<=not fast after 2 ns;
 channels: for k in offsets'range generate
  signal slow: std_logic:='0';
  signal input_data: std_logic_vector(15 downto 0):=(others=>'0');
  signal sum: std_logic_vector(16 downto 0);
  signal output_data: std_logic_vector(15 downto 0);
 begin
  box: entity work.boxcar_2_pts_filter port map(clk=>slow,data_input=>input_data,data_output=>sum);
  wrapper: entity work.N_times_clk_FIR_wrapper port map(clk_times_1=>slow,clk_times_N=>fast,data_in=>sum(15 downto 0),data_out=>output_data);
  process begin
   wait for offsets(k)+2 ns;
   for n in 0 to 63 loop
    input_data<=std_logic_vector(to_signed(n+1,16));
    wait for 160 ns; slow<='1';
    wait for 160 ns; slow<='0';
   end loop;
   wait;
  end process;
 end generate;
 process begin
  wait for 21000 ns;
  report "PASS: production boxcar and FIR wrapper, seven phase offsets, 64 ordered single captures per channel";
  stop;
 end process;
end;
