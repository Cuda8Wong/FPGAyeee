library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity bcd_counter is
    port (
        Clk       : in std_logic;             -- Clock
        Reset     : in std_logic;             -- Synchronous reset
        Enable    : in std_logic;             -- Enable
        Direction : in std_logic;             -- 0 = up, 1 = down
        Q         : out unsigned(3 downto 0)  -- BCD output
    );
end;

architecture behavior of bcd_counter is
    signal count : unsigned(3 downto 0) :=(others => '0');
begin

process(Clk)
begin
    if rising_edge(Clk) then

        -- Reset behavior
        if Reset = '1' then
            if Direction = '0' then
                count <= to_unsigned(0,4);   -- start at 0 for up
            else
                count <= to_unsigned(9,4);   -- start at 9 for down
            end if;

        -- Normal operation
        elsif Enable = '1' then

            -- Up counting
            if Direction = '0' then
                if count = to_unsigned(9,4) then
                    count <= to_unsigned(0,4);    -- wrap
                else
                    count <= count + 1;
                end if;

            -- Down counting
            else
                if count = to_unsigned(0,4) then
                    count <= to_unsigned(9,4);    -- wrap
                else
                    count <= count - 1;
                end if;
            end if;

        end if;
    end if;
end process;

Q <= count;

end;