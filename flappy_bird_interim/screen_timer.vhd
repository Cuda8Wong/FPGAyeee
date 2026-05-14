-- =============================================================================
-- screen_timer.vhd
--
-- PURPOSE:
--   Implements an on-screen countdown/up timer that counts from 0:00 to 9:59
--   at 1-second intervals. The timer is rendered directly onto a VGA display
--   as large (2x scaled) characters using the char_rom font ROM.
--
-- DISPLAY LAYOUT:
--   Each character is 8x8 pixels in the ROM, scaled to 16x16 on screen (2x).
--   Four character slots are arranged horizontally starting at column 0:
--
--     Columns  0-15  : Minutes digit        
--     Columns 16-31  : Colon separator      (char 33, the '!' char)
--     Columns 32-47  : Seconds tens digit   
--     Columns 48-63  : Seconds units digit  
--     Rows    16-31  : Vertical band shared with the "SUS" title area
--
--   Example rendered output at 3:47 → "3:47" starting at pixel (0, 16).
--
--
-- OUTPUT:
--   timer_on  - Asserted ('1') when the current pixel belongs to a lit
--               timer glyph pixel; '0' everywhere else
--
-- BEHAVIOUR:
--   - Counter increments once per second using a 25 MHz → 1 Hz divider.
--   - Counter freezes permanently at 9:59 (does not roll over).
--   - While paused='1' the counter holds its current value.
--   - reset='1' immediately returns all counters and the divider to zero.
--   - The char_rom component is used to look up the correct pixel from the font
-- =============================================================================
LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.STD_LOGIC_ARITH.ALL;
USE IEEE.STD_LOGIC_UNSIGNED.ALL;

ENTITY screen_timer IS
    PORT (
        clk_25      : IN  STD_LOGIC;   -- 25 MHz pixel clock
        clk_50      : IN  STD_LOGIC;   -- 50 MHz system clock (for 1 Hz divider)
        vert_sync   : IN  STD_LOGIC;
        reset       : IN  STD_LOGIC;   -- active high
        paused      : IN  STD_LOGIC;
        pixel_row   : IN  STD_LOGIC_VECTOR(9 DOWNTO 0);
        pixel_col   : IN  STD_LOGIC_VECTOR(9 DOWNTO 0);
        timer_on    : OUT STD_LOGIC    -- '1' when this pixel belongs to a lit timer glyph
    );
END screen_timer;

ARCHITECTURE behavior OF screen_timer IS

    -- -------------------------------------------------------------------------
    -- char_rom: external font ROM component
    --
    -- Stores 64 characters, each 8 rows x 8 columns = 8 bytes per character.
    -- Addressing:  ROM word address = character_index * 8 + font_row
    -- Output:      rom_mux_output is the single pixel bit at (font_row, font_col)
    -- -------------------------------------------------------------------------
    COMPONENT char_rom
        PORT (
            character_address : IN  STD_LOGIC_VECTOR(5 DOWNTO 0);
            font_row          : IN  STD_LOGIC_VECTOR(2 DOWNTO 0);
            font_col          : IN  STD_LOGIC_VECTOR(2 DOWNTO 0);
            clock             : IN  STD_LOGIC;
            rom_mux_output    : OUT STD_LOGIC
        );
    END COMPONENT;

    -- -------------------------------------------------------------------------
    -- 1 Hz tick generation
    --
    -- The pixel clock runs at 25 MHz.  We divide it down to exactly 1 Hz by
    -- counting 25,000,000 cycles (0 to 24,999,999) and pulsing tick_1hz high
    -- for exactly one cycle when the count rolls over.
    --
    -- tick_div  : 26-bit counter (max value 24,999,999 < 2^25 = 33,554,432)
    -- tick_1hz  : single-cycle strobe, high once every 25,000,000 clk_25 ticks
    -- -------------------------------------------------------------------------
    SIGNAL tick_div     : STD_LOGIC_VECTOR(25 DOWNTO 0) := (OTHERS => '0');
    SIGNAL tick_1hz     : STD_LOGIC := '0';

    -- -------------------------------------------------------------------------
    -- BCD timer counter registers
    --
    -- The time M:SS is stored in three separate BCD digits so each can be
    -- decoded independently to a font character without binary-to-BCD conversion.
    --
    -- cnt_min       : minutes digit, range 0-9
    -- cnt_sec_tens  : seconds tens digit, range 0-5  (seconds never exceed 59)
    -- cnt_sec_units : seconds units digit, range 0-9
    -- -------------------------------------------------------------------------
    SIGNAL cnt_min      : STD_LOGIC_VECTOR(3 DOWNTO 0) := (OTHERS => '0');
    SIGNAL cnt_sec_tens : STD_LOGIC_VECTOR(3 DOWNTO 0) := (OTHERS => '0');
    SIGNAL cnt_sec_units: STD_LOGIC_VECTOR(3 DOWNTO 0) := (OTHERS => '0');

    -- at_max: combinational flag that goes high when the counter reaches 9:59.
    -- Used to freeze all three digit counters so the display stops at 9:59
    -- rather than wrapping back to 0:00.
    SIGNAL at_max       : STD_LOGIC;

    -- -------------------------------------------------------------------------
    -- Timer screen-region detection signals
    --
    -- in_timer_row  : '1' when the scan is within rows 16-31 (the timer band)
    -- in_timer_col  : '1' when the scan is within cols 0-63  (the 4-char width)
    -- timer_region  : '1' only when BOTH row and column are inside the timer area
    -- timer_reg_d   : timer_region delayed by one clock cycle to compensate for
    --                 the one-cycle read latency of the synchronous char_rom ROM
    -- -------------------------------------------------------------------------
    SIGNAL in_timer_row : STD_LOGIC;
    SIGNAL in_timer_col : STD_LOGIC;
    SIGNAL timer_region : STD_LOGIC;
    SIGNAL timer_reg_d  : STD_LOGIC;

    -- -------------------------------------------------------------------------
    -- Character-slot addressing signals
    --
    -- col_off   : column offset relative to the left edge of the timer band
    --             (lower 6 bits of pixel_col; valid range 0-63)
    -- char_slot : which of the 4 character slots the current pixel falls in
    --             derived from col_off bits [5:4]:
    --               "00" → slot 0 = minutes digit
    --               "01" → slot 1 = colon separator
    --               "10" → slot 2 = seconds tens digit
    --               "11" → slot 3 = seconds units digit
    -- -------------------------------------------------------------------------
    SIGNAL col_off      : STD_LOGIC_VECTOR(5 DOWNTO 0);
    SIGNAL char_slot    : STD_LOGIC_VECTOR(1 DOWNTO 0);

    -- -------------------------------------------------------------------------
    -- char_rom interface signals
    --
    -- char_addr    : 6-bit character index passed to char_rom (0-63)
    -- font_row_sig : selects which of the 8 pixel rows within the glyph to read
    --                At 2x scale, derived from pixel_row bits [3:1] (÷2)
    -- font_col_sig : selects which of the 8 pixel columns within the glyph
    --                At 2x scale, derived from col_off bits [3:1] (÷2)
    -- rom_pixel    : single-bit output from char_rom; '1' = foreground pixel
    -- -------------------------------------------------------------------------
    SIGNAL char_addr    : STD_LOGIC_VECTOR(5 DOWNTO 0);
    SIGNAL font_row_sig : STD_LOGIC_VECTOR(2 DOWNTO 0);
    SIGNAL font_col_sig : STD_LOGIC_VECTOR(2 DOWNTO 0);
    SIGNAL rom_pixel    : STD_LOGIC;

    -- -------------------------------------------------------------------------
    -- digit_addr: pure function — maps a 4-bit BCD digit (0-9) to the
    -- 6-bit char_rom character index for the corresponding ASCII digit glyph.
    --
    -- char_rom character index derivation from the MIF file:
    --   The MIF stores font data at word addresses: char_index * 8 + row.
    --   Digit '0' begins at MIF octal address 600 = decimal 384.
    --     char_index('0') = 384 / 8 = 48
    --   Digits '1'-'9' follow consecutively: char indices 49-57.
    --
    -- Colon separator:
    --   A true ':' is not cleanly aligned in this ROM.  Instead, char index 33
    --   (the '!' exclamation mark, MIF octal 410) is used as a visual separator.
    --   Its bitmap has a vertical stroke in the centre — acceptable for a game HUD.
    --   The colon is NOT handled here; it is hard-coded in the char_addr mux below.
    -- -------------------------------------------------------------------------
    FUNCTION digit_addr(d : STD_LOGIC_VECTOR(3 DOWNTO 0))
            RETURN STD_LOGIC_VECTOR IS
    BEGIN
        CASE d IS
            WHEN "0000" => RETURN CONV_STD_LOGIC_VECTOR(48, 6); -- '0'
            WHEN "0001" => RETURN CONV_STD_LOGIC_VECTOR(49, 6); -- '1'
            WHEN "0010" => RETURN CONV_STD_LOGIC_VECTOR(50, 6); -- '2'
            WHEN "0011" => RETURN CONV_STD_LOGIC_VECTOR(51, 6); -- '3'
            WHEN "0100" => RETURN CONV_STD_LOGIC_VECTOR(52, 6); -- '4'
            WHEN "0101" => RETURN CONV_STD_LOGIC_VECTOR(53, 6); -- '5'
            WHEN "0110" => RETURN CONV_STD_LOGIC_VECTOR(54, 6); -- '6'
            WHEN "0111" => RETURN CONV_STD_LOGIC_VECTOR(55, 6); -- '7'
            WHEN "1000" => RETURN CONV_STD_LOGIC_VECTOR(56, 6); -- '8'
            WHEN "1001" => RETURN CONV_STD_LOGIC_VECTOR(57, 6); -- '9'
            WHEN OTHERS => RETURN CONV_STD_LOGIC_VECTOR(48, 6); -- fallback '0'
        END CASE;
    END FUNCTION;

BEGIN

    -- =========================================================================
    -- 1 Hz clock divider
    --
    -- Counts pixel-clock cycles from 0 up to 24,999,999 (= 25 MHz − 1).
    -- On the cycle where the count reaches that terminal value, tick_1hz is
    -- asserted for exactly one clk_25 cycle and the counter resets to zero.
    -- This gives a precise 1-second strobe with no cumulative drift.
    --
    -- Both the counter and the strobe are cleared synchronously on reset.
    -- =========================================================================
    Tick_Gen : PROCESS (clk_25, reset)
    BEGIN
        IF reset = '1' THEN
            tick_div <= (OTHERS => '0');
            tick_1hz <= '0';
        ELSIF rising_edge(clk_25) THEN
            IF tick_div = CONV_STD_LOGIC_VECTOR(24999999, 26) THEN
                tick_div <= (OTHERS => '0');
                tick_1hz <= '1';        -- one-cycle pulse: "one second has elapsed"
            ELSE
                tick_div <= tick_div + 1;
                tick_1hz <= '0';
            END IF;
        END IF;
    END PROCESS Tick_Gen;

    -- =========================================================================
    -- at_max: combinational maximum-value detector
    --
    -- Asserted ('1') when the timer shows exactly 9:59.
    -- This signal is fed back into all three counter processes to prevent any
    -- further increments, effectively freezing the display at the maximum value.
    -- =========================================================================
    at_max <= '1' WHEN cnt_min      = "1001" AND   -- minutes  = 9
                       cnt_sec_tens  = "0101" AND   -- sec tens = 5
                       cnt_sec_units = "1001"        -- sec units= 9  → 9:59
              ELSE '0';

    -- =========================================================================
    -- Seconds-units counter  (0 → 9, then wraps to 0)
    --
    -- Increments on every 1 Hz tick, provided the timer is not paused and has
    -- not yet reached the maximum value.  Wraps from 9 back to 0 each second
    -- that the seconds-tens counter carries.  This wrap simultaneously acts as
    -- the carry signal that triggers the seconds-tens counter to increment.
    -- =========================================================================
    Cnt_Sec_Units_Out : PROCESS (clk_25, reset)
    BEGIN
        IF reset = '1' THEN
            cnt_sec_units <= (OTHERS => '0');
        ELSIF rising_edge(clk_25) THEN
            IF tick_1hz = '1' AND paused = '0' AND at_max = '0' THEN
                IF cnt_sec_units = "1001" THEN      -- reached 9 → wrap to 0
                    cnt_sec_units <= (OTHERS => '0');
                ELSE
                    cnt_sec_units <= cnt_sec_units + 1;
                END IF;
            END IF;
        END IF;
    END PROCESS Cnt_Sec_Units_Out;

    -- =========================================================================
    -- Seconds-tens counter  (0 → 5, then wraps to 0)
    --
    -- Increments only when the seconds-units digit wraps (i.e., every 10 s).
    -- Wraps from 5 back to 0 (since seconds never reach 60), which in turn
    -- acts as the carry into the minutes counter.
    -- =========================================================================
    Cnt_Sec_Tens_Out : PROCESS (clk_25, reset)
    BEGIN
        IF reset = '1' THEN
            cnt_sec_tens <= (OTHERS => '0');
        ELSIF rising_edge(clk_25) THEN
            IF tick_1hz = '1' AND paused = '0' AND at_max = '0' THEN
                IF cnt_sec_units = "1001" THEN          -- carry from units digit
                    IF cnt_sec_tens = "0101" THEN        -- reached 5 → wrap to 0
                        cnt_sec_tens <= (OTHERS => '0');
                    ELSE
                        cnt_sec_tens <= cnt_sec_tens + 1;
                    END IF;
                END IF;
            END IF;
        END IF;
    END PROCESS Cnt_Sec_Tens_Out;

    -- =========================================================================
    -- Minutes counter  (0 → 9, then freezes via at_max)
    --
    -- Increments only when both the seconds-units digit wraps (= "1001") AND
    -- the seconds-tens digit is about to wrap (= "0101"), i.e., once per minute.
    -- Because at_max prevents cnt_min from ever reaching 10, the "wrap to 0"
    -- branch below is effectively dead code for the current max of 9:59, but
    -- is kept for correctness should the freeze logic ever be removed.
    -- =========================================================================
    Cnt_Min_Out : PROCESS (clk_25, reset)
    BEGIN
        IF reset = '1' THEN
            cnt_min <= (OTHERS => '0');
        ELSIF rising_edge(clk_25) THEN
            IF tick_1hz = '1' AND paused = '0' AND at_max = '0' THEN
                IF cnt_sec_units = "1001" AND cnt_sec_tens = "0101" THEN  -- carry from seconds
                    IF cnt_min = "1001" THEN    -- reached 9 → wrap to 0 (guarded by at_max)
                        cnt_min <= (OTHERS => '0');
                    ELSE
                        cnt_min <= cnt_min + 1;
                    END IF;
                END IF;
            END IF;
        END IF;
    END PROCESS Cnt_Min_Out;

    -- =========================================================================
    -- Timer screen-region detection
    --
    -- The timer occupies a rectangular band of 64 x 16 pixels:
    --   Rows : 16-31  (16 rows = one 2x-scaled character height)
    --   Cols :  0-63  (64 cols = four 2x-scaled character widths)
    --
    -- in_timer_row and in_timer_col are evaluated every pixel so that
    -- timer_region is a clean combinational window signal.
    -- =========================================================================
    in_timer_row <= '1' WHEN pixel_row >= CONV_STD_LOGIC_VECTOR(16, 10) AND
                             pixel_row <= CONV_STD_LOGIC_VECTOR(31, 10)
                    ELSE '0';

    in_timer_col <= '1' WHEN pixel_col <= CONV_STD_LOGIC_VECTOR(63, 10)
                    ELSE '0';

    timer_region <= in_timer_row AND in_timer_col;

    -- col_off: pixel column offset from the left edge of the timer band.
    -- Only the lower 6 bits of pixel_col are needed (range 0-63).
    col_off   <= pixel_col(5 DOWNTO 0);

    -- char_slot: identifies which of the four 16-pixel-wide character slots
    -- the current pixel falls into.  Bits [5:4] of col_off divide the 64-pixel
    -- band into four equal 16-pixel slots (0-3).
    char_slot <= col_off(5 DOWNTO 4);

    -- =========================================================================
    -- Character address multiplexer
    --
    -- Selects the correct char_rom index for whichever character slot is
    -- currently being scanned:
    --   Slot 0 ("00") → minutes digit glyph   (char index 48-57)
    --   Slot 1 ("01") → colon separator glyph (char index 33, the '!' shape)
    --   Slot 2 ("10") → seconds tens digit    (char index 48-57)
    --   Slot 3 ("11") → seconds units digit   (char index 48-57)
    -- =========================================================================
    WITH char_slot SELECT char_addr <=
        digit_addr(cnt_min)       WHEN "00",
        CONV_STD_LOGIC_VECTOR(33, 6) WHEN "01",   -- colon separator
        digit_addr(cnt_sec_tens)  WHEN "10",
        digit_addr(cnt_sec_units) WHEN OTHERS;

    -- font_row_sig: selects which row of the 8x8 glyph bitmap to read.
    -- At 2x vertical scale, two consecutive pixel rows map to the same glyph
    -- row.  Dividing by 2 is done by taking bits [3:1] of pixel_row, which
    -- gives values 0-7 across the 16-pixel-tall character band (rows 16-31).
    font_row_sig <= pixel_row(3 DOWNTO 1);

    -- font_col_sig: selects which column of the 8x8 glyph bitmap to read.
    -- Same 2x scaling logic as font_row_sig: bits [3:1] of col_off divide
    -- the 16-pixel slot width into 8 glyph columns.
    font_col_sig <= col_off(3 DOWNTO 1);

    -- =========================================================================
    -- char_rom instantiation
    --
    -- The ROM is synchronous (registered output), so its output arrives one
    -- clock cycle after the address is presented.  The pipeline register below
    -- compensates for this latency by delaying timer_region by one cycle to
    -- stay in sync with rom_pixel.
    -- =========================================================================
    char_rom_timer : char_rom
        PORT MAP (
            character_address => char_addr,
            font_row          => font_row_sig,
            font_col          => font_col_sig,
            clock             => clk_25,
            rom_mux_output    => rom_pixel
        );

    -- =========================================================================
    -- One-cycle pipeline delay register (ROM output latency compensation)
    --
    -- char_rom is a synchronous ROM: the pixel output (rom_pixel) is valid one
    -- clk_25 cycle after character_address/font_row/font_col are presented.
    -- timer_region is combinational and therefore "early" by one cycle.
    -- Registering timer_region into timer_reg_d aligns it with rom_pixel so
    -- that the final AND gate correctly masks ROM output to only the timer area.
    -- =========================================================================
    Pipeline : PROCESS (clk_25)
    BEGIN
        IF rising_edge(clk_25) THEN
            timer_reg_d <= timer_region;
        END IF;
    END PROCESS Pipeline;

    -- timer_on: final output pixel enable.
    -- High ('1') only when the current pixel is both inside the timer display
    -- region AND the font ROM indicates a foreground (lit) pixel at that position.
    timer_on <= rom_pixel AND timer_reg_d;

END behavior;