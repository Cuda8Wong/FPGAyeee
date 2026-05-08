-- =============================================================================
-- sus_bird.vhd
-- Top-level entity for Flappy Bird interim demo (COMPSYS 305)
-- DE0-CV board
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
    -- Character ROM address map (TCGROM.MIF)
    -- A=1 B=2 C=3 D=4 E=5 F=6 G=7 H=8 I=9 J=10 K=11 L=12 M=13
    -- N=14 O=15 P=16 Q=17 R=18 S=19 T=20 U=21 V=22 W=23 X=24 Y=25 Z=26
    -- =========================================================================

    -- Clock / reset
    SIGNAL clk_25           : STD_LOGIC := '0';
    SIGNAL reset            : STD_LOGIC;

    -- VGA
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

    -- Mouse
    SIGNAL mouse_row        : STD_LOGIC_VECTOR(9 DOWNTO 0);
    SIGNAL mouse_col        : STD_LOGIC_VECTOR(9 DOWNTO 0);
    SIGNAL left_btn         : STD_LOGIC;
    SIGNAL right_btn        : STD_LOGIC;

    -- Bird
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

    -- Pause
    SIGNAL paused           : STD_LOGIC;
    SIGNAL key1_prev        : STD_LOGIC;

    -- =========================================================================
    -- Text overlay signals
    --
    -- "SUS"    2x scale (16x16 px/char): cols 0-47,   rows 16-31
    --   Start row=16  (multiple of 16) so font_row = pixel_row(3:1)  (no subtract)
    --
    -- "BIRD"   1x scale (8x8   px/char): cols 0-31,   rows 32-39
    --   Start row=32  (multiple of  8) so font_row = pixel_row(2:0)  (no subtract)
    --
    -- "PAUSED" 1x scale (8x8   px/char): cols 296-343, rows 240-247  (when paused)
    --   Start col=296 (multiple of  8) so font_col = pixel_column(2:0)
    --   Start row=240 (multiple of  8) so font_row = pixel_row(2:0)
    --   char_idx needs col offset: paused_col_off = pixel_column - 296
    --
    -- Title text (SUS/BIRD) gated by SW[1].
    -- PAUSED text always visible when paused, not gated by SW[1].
    -- =========================================================================

    -- Title region signals
    SIGNAL large_text_on    : STD_LOGIC;   -- SUS  region
    SIGNAL small_text_on    : STD_LOGIC;   -- BIRD region
    SIGNAL title_active     : STD_LOGIC;
    SIGNAL title_active_d   : STD_LOGIC;   -- 1-cycle delayed for ROM pipeline

    SIGNAL large_char_idx   : STD_LOGIC_VECTOR(1 DOWNTO 0);
    SIGNAL small_char_idx   : STD_LOGIC_VECTOR(1 DOWNTO 0);
    SIGNAL large_char_addr  : STD_LOGIC_VECTOR(5 DOWNTO 0);
    SIGNAL small_char_addr  : STD_LOGIC_VECTOR(5 DOWNTO 0);

    -- PAUSED region signals
    SIGNAL paused_text_on   : STD_LOGIC;
    SIGNAL paused_active_d  : STD_LOGIC;   -- 1-cycle delayed for ROM pipeline
    SIGNAL paused_col_off   : STD_LOGIC_VECTOR(9 DOWNTO 0);
    SIGNAL paused_char_idx  : STD_LOGIC_VECTOR(2 DOWNTO 0);
    SIGNAL paused_char_addr : STD_LOGIC_VECTOR(5 DOWNTO 0);

    -- Shared char_rom signals
    SIGNAL char_addr        : STD_LOGIC_VECTOR(5 DOWNTO 0);
    SIGNAL char_font_row    : STD_LOGIC_VECTOR(2 DOWNTO 0);
    SIGNAL char_font_col    : STD_LOGIC_VECTOR(2 DOWNTO 0);
    SIGNAL rom_pixel        : STD_LOGIC;
    SIGNAL text_on          : STD_LOGIC;

    -- =========================================================================
    -- Starfield
    -- 40 stars, 1 pixel each, scrolling right-to-left at 2 px/frame
    -- 16-bit LFSR (x^16+x^14+x^13+x^11+1) for pseudo-random Y on respawn
    -- Stars pause when game is paused
    -- =========================================================================
    CONSTANT NUM_STARS      : INTEGER := 40;
    TYPE pos_array IS ARRAY(0 TO NUM_STARS-1) OF STD_LOGIC_VECTOR(9 DOWNTO 0);
    SIGNAL star_x           : pos_array;
    SIGNAL star_y           : pos_array;
    SIGNAL lfsr_reg         : STD_LOGIC_VECTOR(15 DOWNTO 0) := "1010110011010101";
    SIGNAL star_on          : STD_LOGIC;

BEGIN

    -- 50 MHz -> 25 MHz
    clk_div : PROCESS (CLOCK_50)
    BEGIN
        IF rising_edge(CLOCK_50) THEN
            clk_25 <= NOT clk_25;
        END IF;
    END PROCESS clk_div;

    reset <= NOT KEY(0);

    -- =========================================================================
    -- VGA_SYNC
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
    -- MOUSE
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
    -- char_rom
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
    -- Bird display
    -- =========================================================================
    bird_on <= '1' WHEN (
            ('0' & BIRD_X     <= pixel_column + BIRD_SIZE) AND
            ('0' & pixel_column <= '0' & BIRD_X    + BIRD_SIZE) AND
            ('0' & bird_y_pos  <= pixel_row   + BIRD_SIZE) AND
            ('0' & pixel_row   <= '0' & bird_y_pos + BIRD_SIZE)
        ) ELSE '0';

    ground_on <= '1' WHEN pixel_row >= CONV_STD_LOGIC_VECTOR(469, 40) ELSE '0';

    -- =========================================================================
    -- Text overlay: active regions
    -- =========================================================================

    -- "SUS" 2x (16x16 px/char): cols 0-47, rows 16-31
    large_text_on <= '1' WHEN pixel_column <= 47 AND
                              pixel_row    >= 16  AND
                              pixel_row    <= 31  ELSE '0';

    -- "BIRD" 1x (8x8 px/char): cols 0-31, rows 32-39
    small_text_on <= '1' WHEN pixel_column <= 31 AND
                              pixel_row    >= 32  AND
                              pixel_row    <= 39  ELSE '0';

    -- "PAUSED" 1x (8x8 px/char): cols 296-343, rows 240-247, only when paused
    paused_text_on <= '1' WHEN pixel_column >= 296 AND
                               pixel_column <= 343 AND
                               pixel_row    >= 240 AND
                               pixel_row    <= 247 AND
                               paused = '1'        ELSE '0';

    title_active <= large_text_on OR small_text_on;

    -- =========================================================================
    -- Character index and address lookup
    -- =========================================================================

    -- "SUS": char index from 16-px column blocks
    large_char_idx <= pixel_column(5 DOWNTO 4);

    WITH large_char_idx SELECT large_char_addr <=
        CONV_STD_LOGIC_VECTOR(19, 6) WHEN "00",   -- S
        CONV_STD_LOGIC_VECTOR(21, 6) WHEN "01",   -- U
        CONV_STD_LOGIC_VECTOR(19, 6) WHEN OTHERS; -- S

    -- "BIRD": char index from 8-px column blocks
    small_char_idx <= pixel_column(4 DOWNTO 3);

    WITH small_char_idx SELECT small_char_addr <=
        CONV_STD_LOGIC_VECTOR(2,  6) WHEN "00",   -- B
        CONV_STD_LOGIC_VECTOR(9,  6) WHEN "01",   -- I
        CONV_STD_LOGIC_VECTOR(18, 6) WHEN "10",   -- R
        CONV_STD_LOGIC_VECTOR(4,  6) WHEN OTHERS; -- D

    -- "PAUSED": char index from column offset (col - 296), 8-px blocks
    -- P=16, A=1, U=21, S=19, E=5, D=4
    paused_col_off  <= pixel_column - CONV_STD_LOGIC_VECTOR(296, 10);
    paused_char_idx <= paused_col_off(5 DOWNTO 3);

    WITH paused_char_idx SELECT paused_char_addr <=
        CONV_STD_LOGIC_VECTOR(16, 6) WHEN "000",  -- P
        CONV_STD_LOGIC_VECTOR(1,  6) WHEN "001",  -- A
        CONV_STD_LOGIC_VECTOR(21, 6) WHEN "010",  -- U
        CONV_STD_LOGIC_VECTOR(19, 6) WHEN "011",  -- S
        CONV_STD_LOGIC_VECTOR(5,  6) WHEN "100",  -- E
        CONV_STD_LOGIC_VECTOR(4,  6) WHEN OTHERS; -- D

    -- =========================================================================
    -- char_rom input mux
    -- Priority: PAUSED > SUS > BIRD (regions do not overlap)
    -- =========================================================================
    char_addr <= paused_char_addr WHEN paused_text_on = '1' ELSE
                 large_char_addr  WHEN large_text_on  = '1' ELSE
                 small_char_addr  WHEN small_text_on  = '1' ELSE
                 (OTHERS => '0');

    -- font_row:
    --   2x scale (SUS rows 16-31):  pixel_row(3:1) = (row-16)/2 with no subtract
    --   1x scale (BIRD rows 32-39): pixel_row(2:0) = row-32 with no subtract
    --   1x scale (PAUSED row 240+): pixel_row(2:0) = row-240 with no subtract
    char_font_row <= pixel_row(3 DOWNTO 1) WHEN large_text_on = '1' ELSE
                     pixel_row(2 DOWNTO 0);

    -- font_col:
    --   2x scale (SUS):    pixel_column(3:1)
    --   1x scale (others): pixel_column(2:0)
    --   296 and 0 are multiples of 8 so no subtract needed for lower bits
    char_font_col <= pixel_column(3 DOWNTO 1) WHEN large_text_on = '1' ELSE
                     pixel_column(2 DOWNTO 0);

    -- =========================================================================
    -- Register active flags by 1 cycle to align with char_rom output latency
    -- =========================================================================
    Text_Pipeline : PROCESS (clk_25)
    BEGIN
        IF rising_edge(clk_25) THEN
            title_active_d  <= title_active;
            paused_active_d <= paused_text_on;
        END IF;
    END PROCESS Text_Pipeline;

    -- Title text gated by SW[1]; PAUSED text always visible when paused
    text_on <= rom_pixel AND ((title_active_d AND SW(1)) OR paused_active_d);

    -- =========================================================================
    -- Colour generation: black background, white everything else
    -- =========================================================================
    red_in   <= text_on OR bird_on OR star_on;
    green_in <= text_on OR bird_on OR star_on;
    blue_in  <= text_on OR bird_on OR star_on;

    -- =========================================================================
    -- Star display: check current pixel against all star positions
    -- =========================================================================
    Star_Display : PROCESS(pixel_row, pixel_column, star_x, star_y)
        VARIABLE hit : STD_LOGIC;
    BEGIN
        hit := '0';
        FOR i IN 0 TO NUM_STARS-1 LOOP
            IF pixel_column = star_x(i) AND pixel_row = star_y(i) THEN
                hit := '1';
            END IF;
        END LOOP;
        star_on <= hit;
    END PROCESS Star_Display;

    -- =========================================================================
    -- Star movement: ~60 Hz on vert_sync, pauses when game is paused
    -- =========================================================================
    Star_Move : PROCESS(vert_sync, reset)
        VARIABLE lv : STD_LOGIC_VECTOR(15 DOWNTO 0);
        VARIABLE fb : STD_LOGIC;
    BEGIN
        IF reset = '1' THEN
            lv := "1010110011010101";
            FOR i IN 0 TO NUM_STARS-1 LOOP
                fb := lv(15) XOR lv(13) XOR lv(12) XOR lv(10);
                lv := lv(14 DOWNTO 0) & fb;
                star_x(i) <= lv(9 DOWNTO 0);
                fb := lv(15) XOR lv(13) XOR lv(12) XOR lv(10);
                lv := lv(14 DOWNTO 0) & fb;
                star_y(i) <= '0' & lv(8 DOWNTO 0);
            END LOOP;
            lfsr_reg <= lv;

        ELSIF rising_edge(vert_sync) THEN
            IF paused = '0' THEN   -- stars freeze when paused
                lv := lfsr_reg;
                FOR i IN 0 TO NUM_STARS-1 LOOP
                    fb := lv(15) XOR lv(13) XOR lv(12) XOR lv(10);
                    lv := lv(14 DOWNTO 0) & fb;
                    IF star_x(i) < CONV_STD_LOGIC_VECTOR(2, 10) THEN
                        star_x(i) <= CONV_STD_LOGIC_VECTOR(639, 10);
                        star_y(i) <= '0' & lv(8 DOWNTO 0);
                    ELSE
                        star_x(i) <= star_x(i) - CONV_STD_LOGIC_VECTOR(2, 10);
                    END IF;
                END LOOP;
                lfsr_reg <= lv;
            END IF;
        END IF;
    END PROCESS Star_Move;

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
	 LEDR(9) 			<= '0';
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
