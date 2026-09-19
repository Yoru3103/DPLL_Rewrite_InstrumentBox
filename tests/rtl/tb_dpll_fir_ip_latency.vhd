-- Compare the production wrapper to its pre-synchronizer behavior using
-- the existing generated FIR IP functional netlist, not a FIR substitute.
library ieee;
use ieee.std_logic_1164.all;
entity dpll_fir_old_reference is port (
 slow, fast: in std_logic; din: in std_logic_vector(15 downto 0);
 dout: out std_logic_vector(15 downto 0)); end;
architecture reference of dpll_fir_old_reference is
 component fir_compiler_minimumphase is port (
  aclk,s_axis_data_tvalid: in std_logic; s_axis_data_tready: out std_logic;
  s_axis_data_tdata: in std_logic_vector(15 downto 0);
  m_axis_data_tvalid: out std_logic; m_axis_data_tdata: out std_logic_vector(15 downto 0)); end component;
 signal flag,d1,d2,enable1,enable2,valid: std_logic:='0';
 signal data1,data2,ipout,out1,out2: std_logic_vector(15 downto 0):=(others=>'0');
begin
 process(slow) begin if rising_edge(slow) then flag<=not flag; dout<=out2; end if; end process;
 process(fast) begin
  if rising_edge(fast) then
   d1<=flag; d2<=d1; enable1<='0';
   if d1/=d2 then data1<=din; enable1<='1'; end if;
   data2<=data1; enable2<=enable1;
   if valid='1' then out1<=ipout; end if;
   out2<=out1;
  end if;
 end process;
 fir: fir_compiler_minimumphase port map(aclk=>fast,s_axis_data_tvalid=>enable2,
  s_axis_data_tready=>open,s_axis_data_tdata=>data2,m_axis_data_tvalid=>valid,m_axis_data_tdata=>ipout);
end;
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
entity tb_dpll_fir_ip_latency is end;
architecture test of tb_dpll_fir_ip_latency is
 signal fast: std_logic:='0';
 type time_array is array(natural range <>) of time;
 constant offsets: time_array := (0 ns,100 ps,500 ps,1 ns,2 ns,3 ns,3900 ps);
begin
 fast<=not fast after 2 ns;
 cases: for k in offsets'range generate
  signal slow: std_logic:='0';
  signal din: std_logic_vector(15 downto 0):=(others=>'0');
  signal sum: std_logic_vector(16 downto 0);
  signal oldout,newout: std_logic_vector(15 downto 0);
 begin
  box: entity work.boxcar_2_pts_filter port map(clk=>slow,data_input=>din,data_output=>sum);
  old_wrapper: entity work.dpll_fir_old_reference port map(slow=>slow,fast=>fast,din=>sum(15 downto 0),dout=>oldout);
  new_wrapper: entity work.N_times_clk_FIR_wrapper port map(clk_times_1=>slow,clk_times_N=>fast,data_in=>sum(15 downto 0),data_out=>newout);
  process
   variable lfsr: unsigned(15 downto 0):=x"ace1";
   variable previous: std_logic_vector(15 downto 0):=(others=>'0');
   variable changes: natural:=0;
  begin
   wait for offsets(k)+2 ns;
   for n in 0 to 511 loop
    lfsr:=lfsr(14 downto 0)&(lfsr(15) xor lfsr(13) xor lfsr(12) xor lfsr(10));
    din<=std_logic_vector(lfsr);
    wait for 160 ns; slow<='1'; wait for 1 ns;
    if n>=200 then
     assert not is_x(oldout) and not is_x(newout) report "FIR output unknown after warm-up" severity failure;
     assert oldout=newout report "Extra synchronizer stage changed slow-clock output or sample latency" severity failure;
     if newout/=previous then changes:=changes+1; end if;
     previous:=newout;
    end if;
    wait for 159 ns; slow<='0';
   end loop;
   assert changes>100 report "Insufficient varying output to prove comparison" severity failure;
   wait;
  end process;
 end generate;
 process begin
  wait for 165 us;
  report "PASS: real FIR IP old/new wrappers have identical slow outputs at seven phases (312 checked samples each)";
  stop;
 end process;
end;
