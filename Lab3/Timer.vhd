-- timer.vhd
--
-- Counts DOWN from the value loaded via Data_In to 00:00
-- (or up from 00:00 to the loaded value – we use DOWN here).
--
-- Data_In mapping (10 switches, SW[9:0]):
--   SW[9:8]   = minutes tens  (only 0..3 valid, max 3)
--   SW[7:4]   = minutes units (BCD 0..9)
--   SW[3:0]   = (unused – only 1 digit seconds tens + units)
-- Wait – the lab says "up to 3 minutes 59 seconds" with
-- the bit layout:
--   bits [9:8]  → minutes (01 = 1 min)   2-bit → 0..3
--   bits [7:4]  → seconds tens (BCD)
--   bits [3:0]  → seconds units (BCD)
--
-- So three displayed digits:
--   HEX2 = minutes   (1 digit)
--   HEX1 = seconds tens
--   HEX0 = seconds units
--
-- Time_Out goes '1' when count reaches 00:00 (all zeros).

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity timer is
    port (
        Clk       : in  std_logic;                     -- 50 MHz system clock
        Reset_N   : in  std_logic;                     -- Active-low async reset (KEY[0])
        Start     : in  std_logic;                     -- Active-low push-button  (KEY[1])
        Data_In   : in  std_logic_vector(9 downto 0);  -- SW[9:0]
        HEX0      : out std_logic_vector(6 downto 0);  -- seconds units
        HEX1      : out std_logic_vector(6 downto 0);  -- seconds tens
        HEX2      : out std_logic_vector(6 downto 0);  -- minutes
        HEX3      : out std_logic_vector(6 downto 0);  -- blank
        HEX4      : out std_logic_vector(6 downto 0);  -- blank
        HEX5      : out std_logic_vector(6 downto 0);  -- blank
        Time_Out  : out std_logic;                     -- '1' when timer expires
        LEDR      : out std_logic_vector(9 downto 0)   -- LEDR[0] mirrors Time_Out
    );
end entity;

architecture structural of timer is

    -- ----------------------------------------------------------------
    -- Component declarations
    -- ----------------------------------------------------------------
    component clk_divider
        port (
            Clk_In  : in  std_logic;
            Reset   : in  std_logic;
            Clk_Out : out std_logic
        );
    end component;

    component bcd_counter
        port (
            Clk       : in  std_logic;
            Reset     : in  std_logic;
            Enable    : in  std_logic;
            Direction : in  std_logic;
            Q         : out unsigned(3 downto 0)
        );
    end component;

    component BCD_to_SevenSeg
        port (
            BCD_digit    : in  std_logic_vector(3 downto 0);
            SevenSeg_out : out std_logic_vector(6 downto 0)
        );
    end component;

    -- ----------------------------------------------------------------
    -- Internal signals
    -- ----------------------------------------------------------------
    signal reset_sync   : std_logic;        -- synchronous reset (active-high)
    signal start_sync   : std_logic;        -- de-bounced start (active-high)

    signal tick_1hz     : std_logic;        -- 1-Hz enable pulse

    -- Registered set-point (loaded when Start pressed)
    signal reg_min      : unsigned(1 downto 0);   -- 0..3
    signal reg_sec_tens : unsigned(3 downto 0);   -- 0..5  (BCD, clamped)
    signal reg_sec_units: unsigned(3 downto 0);   -- 0..9  (BCD, clamped)

    -- Live counter values
    signal cnt_min       : unsigned(3 downto 0);
    signal cnt_sec_tens  : unsigned(3 downto 0);
    signal cnt_sec_units : unsigned(3 downto 0);

    -- Counter control
    signal running       : std_logic := '0';
    signal cnt_reset     : std_logic := '1';
    signal sec_units_en  : std_logic;
    signal sec_tens_en   : std_logic;
    signal min_en        : std_logic;

    -- Borrow signals for down-counting cascade
    signal borrow_units  : std_logic;   -- sec_units wrapped 0→9
    signal borrow_tens   : std_logic;   -- sec_tens  wrapped 0→9 after borrow
    signal all_zero      : std_logic;

    -- BCD clamping helper
    function clamp_bcd(val : std_logic_vector(3 downto 0)) return unsigned is
    begin
        if unsigned(val) > 9 then
            return to_unsigned(9, 4);
        else
            return unsigned(val);
        end if;
    end function;

begin

    -- ----------------------------------------------------------------
    -- Convert active-low inputs to active-high internal signals
    -- ----------------------------------------------------------------
    reset_sync <= not Reset_N;
    start_sync <= not Start;

    -- ----------------------------------------------------------------
    -- 50 MHz → 1 Hz divider
    -- ----------------------------------------------------------------
    U_CLK_DIV : clk_divider
        port map (
            Clk_In  => Clk,
            Reset   => reset_sync,
            Clk_Out => tick_1hz
        );

    -- ----------------------------------------------------------------
    -- Latch Data_In into registers when Start is pressed
    -- Clamp any BCD digit > 9 to 9 as specified.
    -- Minutes field is bits [9:8] (2 bits, so max value = 3 already).
    -- ----------------------------------------------------------------
    process(Clk)
    begin
        if rising_edge(Clk) then
            if reset_sync = '1' then
                reg_min        <= (others => '0');
                reg_sec_tens   <= (others => '0');
                reg_sec_units  <= (others => '0');
                running        <= '0';
                cnt_reset      <= '1';
            elsif start_sync = '1' and running = '0' then
                -- Clamp seconds tens to 0..5 (max 59 seconds)
                if unsigned(Data_In(7 downto 4)) > 5 then
                    reg_sec_tens <= to_unsigned(5, 4);
                else
                    reg_sec_tens <= clamp_bcd(Data_In(7 downto 4));
                end if;
                reg_sec_units <= clamp_bcd(Data_In(3 downto 0));
                reg_min       <= unsigned(Data_In(9 downto 8));
                cnt_reset     <= '1';   -- load will happen via reset in counter
                running       <= '0';  -- we start on next tick
            elsif start_sync = '1' and running = '1' then
                -- Re-press while running: stop/reset
                running   <= '0';
                cnt_reset <= '1';
            elsif running = '0' and cnt_reset = '1' then
                -- After one cycle with reset high, start running
                cnt_reset <= '0';
                running   <= '1';
            end if;

            -- Stop when all zero
            if all_zero = '1' and running = '1' then
                running <= '0';
            end if;
        end if;
    end process;

    -- ----------------------------------------------------------------
    -- Enable signals for down-counting cascade
    -- Units tick every second.
    -- Tens tick when units borrows (units was 0 and ticked down → wraps to 9).
    -- Minutes tick when tens borrows after units borrow.
    -- ----------------------------------------------------------------
    sec_units_en <= tick_1hz and running;

    -- borrow_units: units was at 0 when the tick arrived → it will wrap to 9
    borrow_units <= '1' when (cnt_sec_units = 0 and sec_units_en = '1') else '0';

    sec_tens_en  <= borrow_units;

    -- borrow_tens: tens was at 0 AND units borrowed
    borrow_tens  <= '1' when (cnt_sec_tens = 0 and sec_tens_en = '1') else '0';

    min_en       <= borrow_tens;

    -- All-zero detect (timer just about to underflow = done)
    all_zero <= '1' when (cnt_min = 0 and cnt_sec_tens = 0 and cnt_sec_units = 0
                          and tick_1hz = '1' and running = '1') else '0';

    -- ----------------------------------------------------------------
    -- Three BCD down-counters
    -- Direction = '1' → down, Reset loads 9 for down counter.
    -- We override the reset value by pulsing Reset and then letting
    -- the counter free-run — but bcd_counter always resets to 9 (down)
    -- or 0 (up).  We need to load an ARBITRARY value.
    --
    -- Solution: use a parallel-load wrapper approach:
    -- On cnt_reset, we force-load the registered value using a 
    -- separate process rather than the bcd_counter's built-in reset.
    -- ----------------------------------------------------------------

    -- We implement the three counters directly (not via bcd_counter
    -- component) to allow arbitrary load values.

    process(Clk)
    begin
        if rising_edge(Clk) then
            if reset_sync = '1' then
                cnt_sec_units <= (others => '0');
            elsif cnt_reset = '1' then
                cnt_sec_units <= reg_sec_units;
            elsif sec_units_en = '1' then
                if cnt_sec_units = 0 then
                    cnt_sec_units <= to_unsigned(9, 4);
                else
                    cnt_sec_units <= cnt_sec_units - 1;
                end if;
            end if;
        end if;
    end process;

    process(Clk)
    begin
        if rising_edge(Clk) then
            if reset_sync = '1' then
                cnt_sec_tens <= (others => '0');
            elsif cnt_reset = '1' then
                cnt_sec_tens <= reg_sec_tens;
            elsif sec_tens_en = '1' then
                if cnt_sec_tens = 0 then
                    cnt_sec_tens <= to_unsigned(5, 4);  -- max is 5 for tens digit
                else
                    cnt_sec_tens <= cnt_sec_tens - 1;
                end if;
            end if;
        end if;
    end process;

    process(Clk)
    begin
        if rising_edge(Clk) then
            if reset_sync = '1' then
                cnt_min <= (others => '0');
            elsif cnt_reset = '1' then
                cnt_min <= "00" & reg_min;  -- 2-bit value zero-extended
            elsif min_en = '1' then
                if cnt_min = 0 then
                    cnt_min <= to_unsigned(3, 4);  -- max 3 minutes
                else
                    cnt_min <= cnt_min - 1;
                end if;
            end if;
        end if;
    end process;

    -- ----------------------------------------------------------------
    -- Time_Out
    -- ----------------------------------------------------------------
    Time_Out   <= all_zero;
    LEDR(0)    <= all_zero;
    LEDR(9 downto 1) <= (others => '0');

    -- ----------------------------------------------------------------
    -- 7-Segment display instances
    -- ----------------------------------------------------------------
    U_SEG0 : BCD_to_SevenSeg
        port map (
            BCD_digit    => std_logic_vector(cnt_sec_units),
            SevenSeg_out => HEX0
        );

    U_SEG1 : BCD_to_SevenSeg
        port map (
            BCD_digit    => std_logic_vector(cnt_sec_tens),
            SevenSeg_out => HEX1
        );

    U_SEG2 : BCD_to_SevenSeg
        port map (
            BCD_digit    => std_logic_vector(cnt_min),
            SevenSeg_out => HEX2
        );

    -- Blank unused displays
    HEX3 <= "1111111";
    HEX4 <= "1111111";
    HEX5 <= "1111111";

end architecture structural;