-- clk_divider.vhd
-- Divides a 50 MHz clock down to 1 Hz
-- 50,000,000 cycles per second → count to 49,999,999 then toggle

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity clk_divider is
    port (
        Clk_In  : in  std_logic;   -- 50 MHz input clock
        Reset   : in  std_logic;   -- Synchronous reset
        Clk_Out : out std_logic    -- 1 Hz output clock enable pulse
    );
end entity;

architecture behavior of clk_divider is
    -- For 50 MHz → 1 Hz we need to count 50,000,000 cycles
    constant MAX_COUNT : integer := 49_999_999;
    signal count       : integer range 0 to MAX_COUNT := 0;
begin
    process(Clk_In)
    begin
        if rising_edge(Clk_In) then
            if Reset = '1' then
                count   <= 0;
                Clk_Out <= '0';
            elsif count = MAX_COUNT then
                count   <= 0;
                Clk_Out <= '1';   -- one-cycle pulse every second
            else
                count   <= count + 1;
                Clk_Out <= '0';
            end if;
        end if;
    end process;
end architecture;