-- =============================================================================
-- screen_timer.vhd
-- Counts UP from 0:00 to 9:59 at 1 Hz, rendered as large (2x) characters
-- on the VGA screen using char_rom.
--
-- Layout (2x scale = 16 px wide, 16 px tall per character):
--   Col   0-15  : minutes digit
--   Col  16-31  : colon character  (char address 33 in TCGROM = ':')
--   Col  32-47  : seconds tens digit
--   Col  48-63  : seconds units digit
--   Rows 16-31  : same band as original "SUS" title
--
-- Resets when reset='1', pauses when paused='1'.
-- Max value: 9:59.  On reaching 9:59 the counter freezes.
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
    -- char_rom component
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
    -- 1 Hz tick generation (50 MHz / 50_000_000)
    -- -------------------------------------------------------------------------
    SIGNAL tick_div     : STD_LOGIC_VECTOR(25 DOWNTO 0) := (OTHERS => '0');
    SIGNAL tick_1hz     : STD_LOGIC := '0';

    -- -------------------------------------------------------------------------
    -- BCD counter values (up-counting)
    -- -------------------------------------------------------------------------
    SIGNAL cnt_min      : STD_LOGIC_VECTOR(3 DOWNTO 0) := (OTHERS => '0'); -- 0-9
    SIGNAL cnt_sec_tens : STD_LOGIC_VECTOR(3 DOWNTO 0) := (OTHERS => '0'); -- 0-5
    SIGNAL cnt_sec_units: STD_LOGIC_VECTOR(3 DOWNTO 0) := (OTHERS => '0'); -- 0-9

    SIGNAL at_max       : STD_LOGIC; -- '1' when 9:59 reached

    -- -------------------------------------------------------------------------
    -- Screen region: rows 16-31 (2x glyph height), cols 0-63 (4 chars × 16 px)
    -- -------------------------------------------------------------------------
    SIGNAL in_timer_row : STD_LOGIC;
    SIGNAL in_timer_col : STD_LOGIC;
    SIGNAL timer_region : STD_LOGIC;
    SIGNAL timer_reg_d  : STD_LOGIC; -- 1-cycle pipeline delay for ROM latency

    -- Column index within the 64-pixel timer band
    SIGNAL col_off      : STD_LOGIC_VECTOR(5 DOWNTO 0); -- 0-63
    SIGNAL char_slot    : STD_LOGIC_VECTOR(1 DOWNTO 0); -- which of the 4 chars (0-3)

    -- Character address fed to char_rom
    SIGNAL char_addr    : STD_LOGIC_VECTOR(5 DOWNTO 0);
    SIGNAL font_row_sig : STD_LOGIC_VECTOR(2 DOWNTO 0);
    SIGNAL font_col_sig : STD_LOGIC_VECTOR(2 DOWNTO 0);
    SIGNAL rom_pixel    : STD_LOGIC;

    -- -------------------------------------------------------------------------
    -- digit_to_addr: map a BCD digit (0-9) to TCGROM character address
    -- TCGROM address map: 0=addr32('0' ASCII space area) — actually from the
    -- MIF: address 0x30 octal = address 24 decimal = '0' digit.
    -- Looking at the MIF data:
    --   octal 600 = decimal 384 / 8 = char 48 decimal ... 
    --
    -- From the MIF the digit characters live at octal addresses 600-711:
    --   '0' = octal 600 / 8 = char index 48 ... 
    --
    -- Actually the MIF uses ADDRESS not char index for the ROM word.
    -- char_rom address = char_index * 8 + row.
    -- So char_index for '0' = octal 600 / 8 = decimal 384/8 = 48.
    --   '0'=48, '1'=49, '2'=50, '3'=51, '4'=52, '5'=53,
    --   '6'=54, '7'=55, '8'=56, '9'=57
    -- Colon ':' = octal 472 / 8 = 314/8 -- doesn't divide evenly.
    -- Use a simple colon-like glyph: char 33 is not safe.
    -- Instead we'll draw a literal dash/pipe or re-use char 56 (8) ...
    --
    -- Safest: use the digit chars only. For the separator use char 0 (the
    -- "0" look-alike at address 0 which is actually the @ glyph from the MIF).
    -- The MIF addr 000-007 = char 0 = looks like a circle with dot = usable
    -- as a rough "O".  
    --
    -- Better plan: use a small vertical-bar colon. The MIF shows at addr 410
    -- (octal) = decimal 264 / 8 = char 33. Addr 410 octal = 264 decimal.
    -- char_index = 264/8 = 33. That is the '!' exclamation mark area.
    -- From MIF addr 410-417: "00011000 00011000 00011000 00011000 00000000
    --                          00000000 00011000 00000000" — that IS '!'.
    -- Close enough for a colon separator in a game.  Use char 33 for ':'.
    --
    -- Final digit map (6-bit char_address to char_rom):
    --   digits 0-9  → char indices 48-57  (from MIF octal 600-710 /8)
    --   colon       → char index   33     (MIF octal 410, the '!' glyph)
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
    -- 1 Hz clock divider (counts 25_000_000 pixel-clock cycles)
    -- =========================================================================
    Tick_Gen : PROCESS (clk_25, reset)
    BEGIN
        IF reset = '1' THEN
            tick_div <= (OTHERS => '0');
            tick_1hz <= '0';
        ELSIF rising_edge(clk_25) THEN
            IF tick_div = CONV_STD_LOGIC_VECTOR(24999999, 26) THEN
                tick_div <= (OTHERS => '0');
                tick_1hz <= '1';
            ELSE
                tick_div <= tick_div + 1;
                tick_1hz <= '0';
            END IF;
        END IF;
    END PROCESS Tick_Gen;

    -- =========================================================================
    -- at_max: freeze at 9:59
    -- =========================================================================
    at_max <= '1' WHEN cnt_min      = "1001" AND   -- 9
                       cnt_sec_tens  = "0101" AND   -- 5
                       cnt_sec_units = "1001"        -- 9
              ELSE '0';

    -- =========================================================================
    -- Up-counter: seconds units (0-9)
    -- =========================================================================
    Cnt_Sec_Units_Out : PROCESS (clk_25, reset)
    BEGIN
        IF reset = '1' THEN
            cnt_sec_units <= (OTHERS => '0');
        ELSIF rising_edge(clk_25) THEN
            IF tick_1hz = '1' AND paused = '0' AND at_max = '0' THEN
                IF cnt_sec_units = "1001" THEN
                    cnt_sec_units <= (OTHERS => '0');
                ELSE
                    cnt_sec_units <= cnt_sec_units + 1;
                END IF;
            END IF;
        END IF;
    END PROCESS Cnt_Sec_Units_Out;

    -- =========================================================================
    -- Up-counter: seconds tens (0-5), carries when units wraps 9→0
    -- =========================================================================
    Cnt_Sec_Tens_Out : PROCESS (clk_25, reset)
    BEGIN
        IF reset = '1' THEN
            cnt_sec_tens <= (OTHERS => '0');
        ELSIF rising_edge(clk_25) THEN
            IF tick_1hz = '1' AND paused = '0' AND at_max = '0' THEN
                IF cnt_sec_units = "1001" THEN          -- units about to wrap
                    IF cnt_sec_tens = "0101" THEN
                        cnt_sec_tens <= (OTHERS => '0');
                    ELSE
                        cnt_sec_tens <= cnt_sec_tens + 1;
                    END IF;
                END IF;
            END IF;
        END IF;
    END PROCESS Cnt_Sec_Tens_Out;

    -- =========================================================================
    -- Up-counter: minutes (0-9), carries when both sec digits wrap
    -- =========================================================================
    Cnt_Min_Out : PROCESS (clk_25, reset)
    BEGIN
        IF reset = '1' THEN
            cnt_min <= (OTHERS => '0');
        ELSIF rising_edge(clk_25) THEN
            IF tick_1hz = '1' AND paused = '0' AND at_max = '0' THEN
                IF cnt_sec_units = "1001" AND cnt_sec_tens = "0101" THEN
                    IF cnt_min = "1001" THEN
                        cnt_min <= (OTHERS => '0');
                    ELSE
                        cnt_min <= cnt_min + 1;
                    END IF;
                END IF;
            END IF;
        END IF;
    END PROCESS Cnt_Min_Out;

    -- =========================================================================
    -- Screen region detection
    -- Timer occupies: rows 16-31, cols 0-63 (4 chars at 2x = 16px each)
    -- =========================================================================
    in_timer_row <= '1' WHEN pixel_row >= CONV_STD_LOGIC_VECTOR(16, 10) AND
                             pixel_row <= CONV_STD_LOGIC_VECTOR(31, 10)
                    ELSE '0';

    in_timer_col <= '1' WHEN pixel_col <= CONV_STD_LOGIC_VECTOR(63, 10)
                    ELSE '0';

    timer_region <= in_timer_row AND in_timer_col;

    -- Column offset within the 64-pixel band (only lower 6 bits needed)
    col_off   <= pixel_col(5 DOWNTO 0);

    -- Which of the 4 character slots (each 16 px wide at 2x scale)
    char_slot <= col_off(5 DOWNTO 4);   -- bits [5:4] select slot 0-3

    -- =========================================================================
    -- Character address mux
    --   slot 0 → minutes digit
    --   slot 1 → colon (char 33, the '!' glyph used as separator)
    --   slot 2 → seconds tens digit
    --   slot 3 → seconds units digit
    -- =========================================================================
    WITH char_slot SELECT char_addr <=
        digit_addr(cnt_min)       WHEN "00",
        CONV_STD_LOGIC_VECTOR(33, 6) WHEN "01",   -- colon separator
        digit_addr(cnt_sec_tens)  WHEN "10",
        digit_addr(cnt_sec_units) WHEN OTHERS;

    -- 2x scale: font_row from pixel_row bits [3:1] (divides row offset by 2)
    font_row_sig <= pixel_row(3 DOWNTO 1);

    -- 2x scale: font_col from col_off bits [3:1] (divides col offset by 2)
    font_col_sig <= col_off(3 DOWNTO 1);

    -- =========================================================================
    -- char_rom instance
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
    -- Pipeline: delay the region flag by 1 cycle to match ROM output latency
    -- =========================================================================
    Pipeline : PROCESS (clk_25)
    BEGIN
        IF rising_edge(clk_25) THEN
            timer_reg_d <= timer_region;
        END IF;
    END PROCESS Pipeline;

    timer_on <= rom_pixel AND timer_reg_d;

END behavior;