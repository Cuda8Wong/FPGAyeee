-- timer_top.vhd
-- COMPSYS 305 Lab 3 - Programmable Timer (Board-Ready Top Level)
--
-- Port names match DE0-CV pin assignment signal names EXACTLY so
-- Quartus can auto-map them from timer_pins.qsf without manual binding.
--
-- Board mapping:
--   CLOCK_50        50 MHz system clock  (PIN_M9)
--   KEY[0]          Reset (active low)   (PIN_U7)
--   KEY[1]          Start (active low)   (PIN_W9)
--   SW[9:0]         Data_In              (PIN_AB12 .. PIN_U13)
--   HEX0[6:0]       Seconds units        (PIN_U21  .. PIN_AA22)
--   HEX1[6:0]       Seconds tens         (PIN_AA20 .. PIN_U22)
--   HEX2[6:0]       Minutes              (PIN_Y19  .. PIN_AB21)
--   HEX3[6:0]       Blanked              (PIN_Y16  .. PIN_V19)
--   HEX4[6:0]        Blanked              (PIN_U20  .. PIN_P9)
--   HEX5[6:0]        Blanked              (PIN_N9   .. PIN_W19)
--   LEDR[0]          Time_Out indicator   (PIN_AA2)
--   LEDR[9:1]        Driven low (unused)
--
-- Data_In (SW) bit layout:
--   SW[9:8]  = minutes    (2-bit, 0..3)
--   SW[7:4]  = sec tens   (BCD,   0..5, clamped if > 5)
--   SW[3:0]  = sec units  (BCD,   0..9, clamped if > 9)
--
-- Example from lab brief: SW = "01 0010 0100" = 1 min 24 sec

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity timer_top is
    port (
        CLOCK_50  : in  std_logic;                      -- 50 MHz clock  (PIN_M9)
        KEY       : in  std_logic_vector(3 downto 0);   -- Push buttons  (active low)
        SW        : in  std_logic_vector(9 downto 0);   -- Slide switches
        HEX0      : out std_logic_vector(6 downto 0);   -- Seconds units
        HEX1      : out std_logic_vector(6 downto 0);   -- Seconds tens
        HEX2      : out std_logic_vector(6 downto 0);   -- Minutes
        HEX3      : out std_logic_vector(6 downto 0);   -- Blanked
        HEX4      : out std_logic_vector(6 downto 0);   -- Blanked
        HEX5      : out std_logic_vector(6 downto 0);   -- Blanked
        LEDR      : out std_logic_vector(9 downto 0)    -- LEDR[0] = Time_Out
    );
end entity;

architecture structural of timer_top is

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

    component BCD_to_SevenSeg
        port (
            BCD_digit    : in  std_logic_vector(3 downto 0);
            SevenSeg_out : out std_logic_vector(6 downto 0)
        );
    end component;

    -- ----------------------------------------------------------------
    -- Internal signals
    -- ----------------------------------------------------------------

    -- Active-high versions of active-low board inputs
    signal reset_sync    : std_logic;
    signal start_sync    : std_logic;

    -- 1 Hz tick from clock divider
    signal tick_1hz      : std_logic;

    -- Registered set-point (latched when Start pressed)
    signal reg_min       : unsigned(1 downto 0);   -- 0..3
    signal reg_sec_tens  : unsigned(3 downto 0);   -- 0..5
    signal reg_sec_units : unsigned(3 downto 0);   -- 0..9

    -- Live countdown values
    signal cnt_min       : unsigned(3 downto 0);
    signal cnt_sec_tens  : unsigned(3 downto 0);
    signal cnt_sec_units : unsigned(3 downto 0);

    -- State control
    signal running       : std_logic := '0';
    signal cnt_reset     : std_logic := '1';

    -- Enable cascade for down-counting
    signal sec_units_en  : std_logic;
    signal sec_tens_en   : std_logic;
    signal min_en        : std_logic;
    signal borrow_units  : std_logic;
    signal borrow_tens   : std_logic;
    signal all_zero      : std_logic;

    -- ----------------------------------------------------------------
    -- BCD clamp helper: values > 9 - 9
    -- ----------------------------------------------------------------
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
    -- Board inputs: KEY is active low - invert to active high internally
    -- KEY[0] = Reset_N,  KEY[1] = Start
    -- ----------------------------------------------------------------
    reset_sync <= not KEY(0);
    start_sync <= not KEY(1);

    -- ----------------------------------------------------------------
    -- Clock divider: 50 MHz - 1 Hz pulse
    -- (Use clk_divider_sim.vhd during ModelSim, clk_divider.vhd for board)
    -- ----------------------------------------------------------------
    U_CLK_DIV : clk_divider
        port map (
            Clk_In  => CLOCK_50,
            Reset   => reset_sync,
            Clk_Out => tick_1hz
        );

    -- ----------------------------------------------------------------
    -- State machine: latch SW into registers on Start press
    -- ----------------------------------------------------------------
    process(CLOCK_50)
    begin
        if rising_edge(CLOCK_50) then
            if reset_sync = '1' then
                reg_min       <= (others => '0');
                reg_sec_tens  <= (others => '0');
                reg_sec_units <= (others => '0');
                running       <= '0';
                cnt_reset     <= '1';

            elsif start_sync = '1' and running = '0' then
                -- Load and clamp SW values into registers
                -- Seconds tens: max valid is 5 (for 0..59)
                if unsigned(SW(7 downto 4)) > 5 then
                    reg_sec_tens <= to_unsigned(5, 4);
                else
                    reg_sec_tens <= clamp_bcd(SW(7 downto 4));
                end if;
                -- Seconds units: max valid BCD is 9
                reg_sec_units <= clamp_bcd(SW(3 downto 0));
                -- Minutes: 2-bit field, already limited to 0..3 by width
                reg_min       <= unsigned(SW(9 downto 8));
                cnt_reset     <= '1';
                running       <= '0';

            elsif start_sync = '1' and running = '1' then
                -- Re-press while running: stop and reset
                running   <= '0';
                cnt_reset <= '1';

            elsif running = '0' and cnt_reset = '1' then
                -- One cycle after cnt_reset goes high: load done, start running
                cnt_reset <= '0';
                running   <= '1';
            end if;

            -- Stop automatically when countdown reaches zero
            if all_zero = '1' and running = '1' then
                running <= '0';
            end if;
        end if;
    end process;

    -- ----------------------------------------------------------------
    -- Down-counter enable cascade
    -- Units  : tick every second
    -- Tens   : tick when units borrows (was 0, wraps to 9)
    -- Minutes: tick when tens  borrows (was 0, wraps to 5)
    -- ----------------------------------------------------------------
    sec_units_en <= tick_1hz and running;

    borrow_units <= '1' when (cnt_sec_units = 0 and sec_units_en = '1') else '0';
    sec_tens_en  <= borrow_units;

    borrow_tens  <= '1' when (cnt_sec_tens = 0 and sec_tens_en = '1') else '0';
    min_en       <= borrow_tens;

    -- All-zero: all digits are 0 AND a tick just arrived = timer done
    all_zero <= '1' when (cnt_min = 0 and cnt_sec_tens = 0 and cnt_sec_units = 0') else '0';

    -- ----------------------------------------------------------------
    -- Seconds units counter (down, arbitrary load)
    -- ----------------------------------------------------------------
    process(CLOCK_50)
    begin
        if rising_edge(CLOCK_50) then
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

    -- ----------------------------------------------------------------
    -- Seconds tens counter (down, arbitrary load, wraps 0-5)
    -- ----------------------------------------------------------------
    process(CLOCK_50)
    begin
        if rising_edge(CLOCK_50) then
            if reset_sync = '1' then
                cnt_sec_tens <= (others => '0');
            elsif cnt_reset = '1' then
                cnt_sec_tens <= reg_sec_tens;
            elsif sec_tens_en = '1' then
                if cnt_sec_tens = 0 then
                    cnt_sec_tens <= to_unsigned(5, 4);
                else
                    cnt_sec_tens <= cnt_sec_tens - 1;
                end if;
            end if;
        end if;
    end process;

    -- ----------------------------------------------------------------
    -- Minutes counter (down, arbitrary load, wraps 0-3)
    -- ----------------------------------------------------------------
    process(CLOCK_50)
    begin
        if rising_edge(CLOCK_50) then
            if reset_sync = '1' then
                cnt_min <= (others => '0');
            elsif cnt_reset = '1' then
                cnt_min <= "00" & reg_min;
            elsif min_en = '1' then
                if cnt_min = 0 then
                    cnt_min <= to_unsigned(3, 4);
                else
                    cnt_min <= cnt_min - 1;
                end if;
            end if;
        end if;
    end process;

    -- ----------------------------------------------------------------
    -- Outputs
    -- ----------------------------------------------------------------

    -- LEDR[0] = Time_Out indicator, LEDR[9:1] = off
    LEDR(0) <= all_zero;
    LEDR(9 downto 1) <= (others => '0');

    -- 7-segment: seconds units on HEX0
    U_SEG0 : BCD_to_SevenSeg
        port map (
            BCD_digit    => std_logic_vector(cnt_sec_units),
            SevenSeg_out => HEX0
        );

    -- 7-segment: seconds tens on HEX1
    U_SEG1 : BCD_to_SevenSeg
        port map (
            BCD_digit    => std_logic_vector(cnt_sec_tens),
            SevenSeg_out => HEX1
        );

    -- 7-segment: minutes on HEX2
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
