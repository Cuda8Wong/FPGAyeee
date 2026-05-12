-- =============================================================================
-- sus_bird.vhd
-- Top-level entity for Flappy Bird interim demo (COMPSYS 305)
-- DE0-CV board
--
-- Changes from previous version:
--   * Bird moved to horizontal centre (~column 320)
--   * "SUS BIRD" title moved to centre-top (cols 272-319 approx)
--   * On-screen up-counting timer added at top-left (cols 0-63, rows 16-31)
--     via screen_timer.vhd sub-module
--   * Starfield extracted to star_field.vhd sub-module
--   * Bird colour selectable via SW[3:8]
-- =============================================================================

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.STD_LOGIC_ARITH.ALL;
USE IEEE.STD_LOGIC_UNSIGNED.ALL;

ENTITY sus_bird IS
    PORT (
        CLOCK_50        : IN    STD_LOGIC;
        KEY             : IN    STD_LOGIC_VECTOR(3 DOWNTO 0);
        SW              : IN    STD_LOGIC_VECTOR(9 DOWNTO 0);
        VGA_R           : OUT   STD_LOGIC_VECTOR(3 DOWNTO 0);
        VGA_G           : OUT   STD_LOGIC_VECTOR(3 DOWNTO 0);
        VGA_B           : OUT   STD_LOGIC_VECTOR(3 DOWNTO 0);
        VGA_HS          : OUT   STD_LOGIC;
        VGA_VS          : OUT   STD_LOGIC;
        PS2_CLK         : INOUT STD_LOGIC;
        PS2_DAT         : INOUT STD_LOGIC;
        HEX0            : OUT   STD_LOGIC_VECTOR(6 DOWNTO 0);
        HEX1            : OUT   STD_LOGIC_VECTOR(6 DOWNTO 0);
        HEX2            : OUT   STD_LOGIC_VECTOR(6 DOWNTO 0);
        HEX3            : OUT   STD_LOGIC_VECTOR(6 DOWNTO 0);
        HEX4            : OUT   STD_LOGIC_VECTOR(6 DOWNTO 0);
        HEX5            : OUT   STD_LOGIC_VECTOR(6 DOWNTO 0);
        LEDR            : OUT   STD_LOGIC_VECTOR(9 DOWNTO 0)
    );
END sus_bird;


ARCHITECTURE behavior OF sus_bird IS

    -- =========================================================================
    -- Component declarations
    -- =========================================================================
    COMPONENT VGA_SYNC
        PORT (
            clock_25Mhz, red, green, blue   : IN  STD_LOGIC;
            red_out, green_out, blue_out,
            horiz_sync_out, vert_sync_out   : OUT STD_LOGIC;
            pixel_row, pixel_column         : OUT STD_LOGIC_VECTOR(9 DOWNTO 0)
        );
    END COMPONENT;

    COMPONENT MOUSE
        PORT (
            clock_25Mhz, reset  : IN    STD_LOGIC;
            mouse_data          : INOUT STD_LOGIC;
            mouse_clk           : INOUT STD_LOGIC;
            left_button,
            right_button        : OUT   STD_LOGIC;
            mouse_cursor_row    : OUT   STD_LOGIC_VECTOR(9 DOWNTO 0);
            mouse_cursor_column : OUT   STD_LOGIC_VECTOR(9 DOWNTO 0)
        );
    END COMPONENT;

    COMPONENT char_rom
        PORT (
            character_address   : IN  STD_LOGIC_VECTOR(5 DOWNTO 0);
            font_row, font_col  : IN  STD_LOGIC_VECTOR(2 DOWNTO 0);
            clock               : IN  STD_LOGIC;
            rom_mux_output      : OUT STD_LOGIC
        );
    END COMPONENT;

    COMPONENT star_field
        PORT (
            clk_25    : IN  STD_LOGIC;
            vert_sync : IN  STD_LOGIC;
            reset     : IN  STD_LOGIC;
            paused    : IN  STD_LOGIC;
            pixel_row : IN  STD_LOGIC_VECTOR(9 DOWNTO 0);
            pixel_col : IN  STD_LOGIC_VECTOR(9 DOWNTO 0);
            star_on   : OUT STD_LOGIC
        );
    END COMPONENT;

    COMPONENT screen_timer
        PORT (
            clk_25    : IN  STD_LOGIC;
            clk_50    : IN  STD_LOGIC;
            vert_sync : IN  STD_LOGIC;
            reset     : IN  STD_LOGIC;
            paused    : IN  STD_LOGIC;
            pixel_row : IN  STD_LOGIC_VECTOR(9 DOWNTO 0);
            pixel_col : IN  STD_LOGIC_VECTOR(9 DOWNTO 0);
            timer_on  : OUT STD_LOGIC
        );
    END COMPONENT;

    -- =========================================================================
    -- Helper function: 4-bit BCD → 7-segment (active-low segments)
    -- =========================================================================
    FUNCTION hex_to_seg(digit : STD_LOGIC_VECTOR(3 DOWNTO 0))
            RETURN STD_LOGIC_VECTOR IS
        VARIABLE seg : STD_LOGIC_VECTOR(6 DOWNTO 0);
    BEGIN
        CASE digit IS
            WHEN "0000" => seg := "1000000";
            WHEN "0001" => seg := "1111001";
            WHEN "0010" => seg := "0100100";
            WHEN "0011" => seg := "0110000";
            WHEN "0100" => seg := "0011001";
            WHEN "0101" => seg := "0010010";
            WHEN "0110" => seg := "0000010";
            WHEN "0111" => seg := "1111000";
            WHEN "1000" => seg := "0000000";
            WHEN "1001" => seg := "0010000";
            WHEN "1010" => seg := "0001000";
            WHEN "1011" => seg := "0000011";
            WHEN "1100" => seg := "1000110";
            WHEN "1101" => seg := "0100001";
            WHEN "1110" => seg := "0000110";
            WHEN OTHERS => seg := "0001110";
        END CASE;
        RETURN seg;
    END FUNCTION;

    -- =========================================================================
    -- Clock / reset
    -- =========================================================================
    SIGNAL clk_25           : STD_LOGIC := '0';
    SIGNAL reset            : STD_LOGIC;

    -- =========================================================================
    -- VGA signals
    -- =========================================================================
    SIGNAL pixel_row        : STD_LOGIC_VECTOR(9 DOWNTO 0);
    SIGNAL pixel_column     : STD_LOGIC_VECTOR(9 DOWNTO 0);
    SIGNAL vert_sync        : STD_LOGIC;
    SIGNAL horiz_sync       : STD_LOGIC;
    SIGNAL red_in           : STD_LOGIC;
    SIGNAL green_in         : STD_LOGIC;
    SIGNAL blue_in          : STD_LOGIC;
    SIGNAL red_out          : STD_LOGIC;
    SIGNAL green_out        : STD_LOGIC;
    SIGNAL blue_out         : STD_LOGIC;

    -- =========================================================================
    -- Mouse
    -- =========================================================================
    SIGNAL mouse_row        : STD_LOGIC_VECTOR(9 DOWNTO 0);
    SIGNAL mouse_col        : STD_LOGIC_VECTOR(9 DOWNTO 0);
    SIGNAL left_btn         : STD_LOGIC;
    SIGNAL right_btn        : STD_LOGIC;

    -- =========================================================================
    -- Bird
    -- Bird X shifted to screen centre (~320), fixed horizontal position.
    -- =========================================================================
    CONSTANT BIRD_X         : STD_LOGIC_VECTOR(9 DOWNTO 0)
                              := CONV_STD_LOGIC_VECTOR(100, 10);
    CONSTANT BIRD_SIZE      : STD_LOGIC_VECTOR(9 DOWNTO 0)
                              := CONV_STD_LOGIC_VECTOR(12,  10);
    CONSTANT GROUND         : STD_LOGIC_VECTOR(9 DOWNTO 0)
                              := CONV_STD_LOGIC_VECTOR(468, 10);
    CONSTANT CEILING        : STD_LOGIC_VECTOR(9 DOWNTO 0)
                              := CONV_STD_LOGIC_VECTOR(12,  10);

    SIGNAL bird_on          : STD_LOGIC;
    SIGNAL bird_y_pos       : STD_LOGIC_VECTOR(9 DOWNTO 0);
    SIGNAL ground_on        : STD_LOGIC;
    SIGNAL fall_speed       : STD_LOGIC_VECTOR(9 DOWNTO 0);
    SIGNAL bird_falling     : STD_LOGIC;

    -- =========================================================================
    -- Bird colour signals
    -- SW(3)=red  SW(4)=orange  SW(5)=yellow
    -- SW(6)=green  SW(7)=blue  SW(8)=purple
    -- Default (no switch): white
    -- Priority: lowest index switch wins if multiple are on
    -- =========================================================================
    SIGNAL bird_r           : STD_LOGIC;
    SIGNAL bird_g           : STD_LOGIC;
    SIGNAL bird_b           : STD_LOGIC;

    -- =========================================================================
    -- Pause
    -- =========================================================================
    SIGNAL paused           : STD_LOGIC;
    SIGNAL key1_prev        : STD_LOGIC;

    -- =========================================================================
    -- Title text overlay ("SUS BIRD" centred, rows 16-39)
    --
    -- "SUS"  2x scale (16px/char): 3 chars = 48px wide
    --   Centred at col 320: start col = 320 - 24 = 296
    --   Cols 296-343, rows 16-31
    --
    -- "BIRD" 1x scale (8px/char): 4 chars = 32px wide
    --   Centred at col 320: start col = 320 - 16 = 304
    --   Cols 304-335, rows 32-39
    -- =========================================================================
    SIGNAL large_text_on    : STD_LOGIC;
    SIGNAL small_text_on    : STD_LOGIC;
    SIGNAL title_active     : STD_LOGIC;
    SIGNAL title_active_d   : STD_LOGIC;

    SIGNAL large_char_idx   : STD_LOGIC_VECTOR(1 DOWNTO 0);
    SIGNAL small_char_idx   : STD_LOGIC_VECTOR(1 DOWNTO 0);
    SIGNAL large_char_addr  : STD_LOGIC_VECTOR(5 DOWNTO 0);
    SIGNAL small_char_addr  : STD_LOGIC_VECTOR(5 DOWNTO 0);

    -- Column offsets for centred title
    SIGNAL large_col_off    : STD_LOGIC_VECTOR(9 DOWNTO 0); -- col - 296
    SIGNAL small_col_off    : STD_LOGIC_VECTOR(9 DOWNTO 0); -- col - 304

    -- Shared char_rom signals (title text)
    SIGNAL char_addr        : STD_LOGIC_VECTOR(5 DOWNTO 0);
    SIGNAL char_font_row    : STD_LOGIC_VECTOR(2 DOWNTO 0);
    SIGNAL char_font_col    : STD_LOGIC_VECTOR(2 DOWNTO 0);
    SIGNAL rom_pixel        : STD_LOGIC;
    SIGNAL text_on          : STD_LOGIC;

    -- =========================================================================
    -- Sub-module outputs
    -- =========================================================================
    SIGNAL star_on          : STD_LOGIC;
    SIGNAL timer_on         : STD_LOGIC;

BEGIN

    -- =========================================================================
    -- 50 MHz → 25 MHz clock divider
    -- =========================================================================
    clk_div : PROCESS (CLOCK_50)
    BEGIN
        IF rising_edge(CLOCK_50) THEN
            clk_25 <= NOT clk_25;
        END IF;
    END PROCESS clk_div;

    reset <= NOT KEY(0);

    -- =========================================================================
    -- VGA_SYNC instance
    -- =========================================================================
    vga_inst : VGA_SYNC
        PORT MAP (
            clock_25Mhz    => clk_25,
            red            => red_in,
            green          => green_in,
            blue           => blue_in,
            red_out        => red_out,
            green_out      => green_out,
            blue_out       => blue_out,
            horiz_sync_out => horiz_sync,
            vert_sync_out  => vert_sync,
            pixel_row      => pixel_row,
            pixel_column   => pixel_column
        );

    VGA_HS <= horiz_sync;
    VGA_VS <= vert_sync;
    VGA_R  <= (OTHERS => red_out);
    VGA_G  <= (OTHERS => green_out);
    VGA_B  <= (OTHERS => blue_out);

    -- =========================================================================
    -- MOUSE instance
    -- =========================================================================
    mouse_inst : MOUSE
        PORT MAP (
            clock_25Mhz         => clk_25,
            reset               => reset,
            mouse_data          => PS2_DAT,
            mouse_clk           => PS2_CLK,
            left_button         => left_btn,
            right_button        => right_btn,
            mouse_cursor_row    => mouse_row,
            mouse_cursor_column => mouse_col
        );

    -- =========================================================================
    -- char_rom instance (title text only — timer has its own instance)
    -- =========================================================================
    char_rom_inst : char_rom
        PORT MAP (
            character_address => char_addr,
            font_row          => char_font_row,
            font_col          => char_font_col,
            clock             => clk_25,
            rom_mux_output    => rom_pixel
        );

    -- =========================================================================
    -- star_field sub-module
    -- =========================================================================
    stars : star_field
        PORT MAP (
            clk_25    => clk_25,
            vert_sync => vert_sync,
            reset     => reset,
            paused    => paused,
            pixel_row => pixel_row,
            pixel_col => pixel_column,
            star_on   => star_on
        );

    -- =========================================================================
    -- screen_timer sub-module
    -- =========================================================================
    tmr : screen_timer
        PORT MAP (
            clk_25    => clk_25,
            clk_50    => CLOCK_50,
            vert_sync => vert_sync,
            reset     => reset,
            paused    => paused,
            pixel_row => pixel_row,
            pixel_col => pixel_column,
            timer_on  => timer_on
        );

    -- =========================================================================
    -- Bird display
    -- =========================================================================
    bird_on <= '1' WHEN (
            ('0' & BIRD_X      <= pixel_column + BIRD_SIZE) AND
            ('0' & pixel_column <= '0' & BIRD_X    + BIRD_SIZE) AND
            ('0' & bird_y_pos   <= pixel_row   + BIRD_SIZE) AND
            ('0' & pixel_row    <= '0' & bird_y_pos + BIRD_SIZE)
        ) ELSE '0';

    ground_on <= '1' WHEN pixel_row >= CONV_STD_LOGIC_VECTOR(469, 10) ELSE '0';

    -- =========================================================================
    -- Bird colour selection
    -- SW(3)=red, SW(4)=orange*, SW(5)=yellow,
    -- SW(6)=green, SW(7)=blue, SW(8)=purple
    -- Default: white.  Lowest active switch wins.
    -- *Orange and yellow are identical on a 1-bit-per-channel VGA output.
    -- =========================================================================
    bird_r <= bird_on WHEN SW(3) = '1' ELSE
        bird_on WHEN SW(4) = '1' ELSE
        '0'     WHEN SW(5) = '1' ELSE
        '0'     WHEN SW(6) = '1' ELSE
        '0'     WHEN SW(7) = '1' ELSE
        bird_on WHEN SW(8) = '1' ELSE
        bird_on;

    bird_g <= '0'     WHEN SW(3) = '1' ELSE
        bird_on WHEN SW(4) = '1' ELSE
        bird_on WHEN SW(5) = '1' ELSE
        bird_on WHEN SW(6) = '1' ELSE
        '0'     WHEN SW(7) = '1' ELSE
        '0'     WHEN SW(8) = '1' ELSE
        bird_on;

    bird_b <= '0'     WHEN SW(3) = '1' ELSE
        '0'     WHEN SW(4) = '1' ELSE
        bird_on WHEN SW(5) = '1' ELSE
        '0'     WHEN SW(6) = '1' ELSE
        bird_on WHEN SW(7) = '1' ELSE
        bird_on WHEN SW(8) = '1' ELSE
        bird_on;

    -- =========================================================================
    -- Title text overlay
    -- "SUS" 2x: cols 296-343, rows 16-31
    -- "BIRD" 1x: cols 304-335, rows 32-39
    -- =========================================================================

    -- "SUS" region
    large_text_on <= '1' WHEN pixel_column >= 296 AND pixel_column <= 343 AND
                              pixel_row    >= 16  AND pixel_row    <= 31
                    ELSE '0';

    -- "BIRD" region
    small_text_on <= '1' WHEN pixel_column >= 304 AND pixel_column <= 335 AND
                              pixel_row    >= 32  AND pixel_row    <= 39
                    ELSE '0';

    title_active <= large_text_on OR small_text_on;

    -- Column offsets (subtract start column to get local pixel within text band)
    large_col_off <= pixel_column - CONV_STD_LOGIC_VECTOR(296, 10);
    small_col_off <= pixel_column - CONV_STD_LOGIC_VECTOR(304, 10);

    -- "SUS": each char is 16 px wide (2x), so char index = col_off[5:4]
    large_char_idx <= large_col_off(5 DOWNTO 4);

    WITH large_char_idx SELECT large_char_addr <=
        CONV_STD_LOGIC_VECTOR(19, 6) WHEN "00",   -- S
        CONV_STD_LOGIC_VECTOR(21, 6) WHEN "01",   -- U
        CONV_STD_LOGIC_VECTOR(19, 6) WHEN OTHERS; -- S

    -- "BIRD": each char is 8 px wide (1x), so char index = col_off[4:3]
    small_char_idx <= small_col_off(4 DOWNTO 3);

    WITH small_char_idx SELECT small_char_addr <=
        CONV_STD_LOGIC_VECTOR(2,  6) WHEN "00",   -- B
        CONV_STD_LOGIC_VECTOR(9,  6) WHEN "01",   -- I
        CONV_STD_LOGIC_VECTOR(18, 6) WHEN "10",   -- R
        CONV_STD_LOGIC_VECTOR(4,  6) WHEN OTHERS; -- D

    -- char_rom mux: SUS takes priority over BIRD (no overlap at new positions)
    char_addr <= large_char_addr WHEN large_text_on = '1' ELSE
                 small_char_addr WHEN small_text_on  = '1' ELSE
                 (OTHERS => '0');

    -- font_row: 2x for SUS (pixel_row[3:1]), 1x for BIRD (pixel_row[2:0])
    char_font_row <= pixel_row(3 DOWNTO 1) WHEN large_text_on = '1' ELSE
                     pixel_row(2 DOWNTO 0);

    -- font_col: 2x for SUS (col_off[3:1]), 1x for BIRD (col_off[2:0])
    char_font_col <= large_col_off(3 DOWNTO 1) WHEN large_text_on = '1' ELSE
                     small_col_off(2 DOWNTO 0);

    -- 1-cycle pipeline delay to match char_rom latency
    Text_Pipeline : PROCESS (clk_25)
    BEGIN
        IF rising_edge(clk_25) THEN
            title_active_d <= title_active;
        END IF;
    END PROCESS Text_Pipeline;

    -- Title text gated by SW[1]
    text_on <= rom_pixel AND title_active_d AND SW(1);

    -- =========================================================================
    -- Colour generation
    -- Bird uses per-channel colour signals.
    -- Text, timer, and stars are always white.
    -- =========================================================================
    red_in   <= (text_on OR star_on OR timer_on) OR bird_r;
    green_in <= (text_on OR star_on OR timer_on) OR bird_g;
    blue_in  <= (text_on OR star_on OR timer_on) OR bird_b;

    -- =========================================================================
    -- Bird movement (~60 Hz on vert_sync)
    -- =========================================================================
    Move_Bird : PROCESS(vert_sync, reset)
    BEGIN
        IF reset = '1' THEN
            bird_y_pos   <= CONV_STD_LOGIC_VECTOR(240, 10);
            fall_speed   <= CONV_STD_LOGIC_VECTOR(0,   10);
            bird_falling <= '1';
        ELSIF rising_edge(vert_sync) THEN
            IF paused = '0' THEN
                IF left_btn = '1' THEN
                    bird_falling <= '0';
                    fall_speed   <= CONV_STD_LOGIC_VECTOR(4, 10);
                    IF bird_y_pos > CEILING + CONV_STD_LOGIC_VECTOR(4, 10) THEN
                        bird_y_pos <= bird_y_pos - CONV_STD_LOGIC_VECTOR(4, 10);
                    ELSE
                        bird_y_pos <= CEILING;
                    END IF;
                ELSE
                    bird_falling <= '1';
                    IF fall_speed < CONV_STD_LOGIC_VECTOR(6, 10) THEN
                        fall_speed <= fall_speed + 1;
                    END IF;
                    IF bird_y_pos + fall_speed < GROUND THEN
                        bird_y_pos <= bird_y_pos + fall_speed;
                    ELSE
                        bird_y_pos <= GROUND;
                        fall_speed <= CONV_STD_LOGIC_VECTOR(0, 10);
                    END IF;
                END IF;
            END IF;
        END IF;
    END PROCESS Move_Bird;

    -- =========================================================================
    -- Pause toggle: falling edge on KEY[1]
    -- =========================================================================
    Pause_Toggle : PROCESS(clk_25, reset)
    BEGIN
        IF reset = '1' THEN
            paused    <= '0';
            key1_prev <= '1';
        ELSIF rising_edge(clk_25) THEN
            key1_prev <= KEY(1);
            IF key1_prev = '1' AND KEY(1) = '0' THEN
                paused <= NOT paused;
            END IF;
        END IF;
    END PROCESS Pause_Toggle;

    -- =========================================================================
    -- LEDs
    -- =========================================================================
    LEDR(0)          <= left_btn;
    LEDR(1)          <= right_btn;
    LEDR(2)          <= paused;
    LEDR(8)          <= bird_falling;
    LEDR(9)          <= '0';
    LEDR(7 DOWNTO 3) <= (OTHERS => '0');

    -- =========================================================================
    -- Seven-segment displays 
    -- =========================================================================
    HEX0 <= hex_to_seg(bird_y_pos(3  DOWNTO 0));
    HEX1 <= hex_to_seg(bird_y_pos(7  DOWNTO 4));
    HEX2 <= hex_to_seg(mouse_col(3   DOWNTO 0));
    HEX3 <= hex_to_seg(mouse_col(7   DOWNTO 4));
    HEX4 <= hex_to_seg(mouse_row(3   DOWNTO 0));
    HEX5 <= hex_to_seg(mouse_row(7   DOWNTO 4));

END behavior;