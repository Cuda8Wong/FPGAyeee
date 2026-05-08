-- =============================================================================
-- sus_bird.vhd
-- Top-level entity (COMPSYS 305) — DE0-CV board
--
-- Sub-modules instantiated here:
--   VGA_SYNC   : 640×480 @ 60 Hz timing generator + RGB blanking
--   MOUSE      : PS/2 mouse driver; left-click = flap
--   char_rom   : 8×8 font ROM (TCGROM.MIF) for all text overlays
--   game_timer : MM:SS BCD counter displayed in the top-left corner
--   star_field : 200 scrolling background stars (self-contained)
--
-- Screen layout:
--   Rows  0-15,  cols 256-383 : "SUS BIRD" title (2× scale, gated by SW[1])
--   Rows  0-7,   cols   0-31  : MM:SS timer (1× scale, always visible)
--   Rows  240-247, cols 296-343 : "PAUSED" overlay (only when paused)
--   Col  100,   any row        : Bird (red filled square, ±12 px)
--   Background                 : 200 scrolling white stars on black
--
-- Colour scheme:
--   Bird  → red  (R=1, G=0, B=0)
--   Stars, text → white (R=G=B=1)
--   Background  → black (R=G=B=0)
-- =============================================================================

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.STD_LOGIC_ARITH.ALL;
USE IEEE.STD_LOGIC_UNSIGNED.ALL;

ENTITY sus_bird IS
    PORT (
        CLOCK_50    : IN    STD_LOGIC;                      -- 50 MHz board oscillator
        KEY         : IN    STD_LOGIC_VECTOR(3 DOWNTO 0);  -- Push-buttons (active LOW)
        SW          : IN    STD_LOGIC_VECTOR(9 DOWNTO 0);  -- Slide switches
        VGA_R       : OUT   STD_LOGIC_VECTOR(3 DOWNTO 0);  -- VGA red   (4-bit DAC)
        VGA_G       : OUT   STD_LOGIC_VECTOR(3 DOWNTO 0);  -- VGA green (4-bit DAC)
        VGA_B       : OUT   STD_LOGIC_VECTOR(3 DOWNTO 0);  -- VGA blue  (4-bit DAC)
        VGA_HS      : OUT   STD_LOGIC;                      -- VGA horizontal sync
        VGA_VS      : OUT   STD_LOGIC;                      -- VGA vertical sync
        PS2_CLK     : INOUT STD_LOGIC;                      -- PS/2 clock  (mouse)
        PS2_DAT     : INOUT STD_LOGIC;                      -- PS/2 data   (mouse)
        HEX0        : OUT   STD_LOGIC_VECTOR(6 DOWNTO 0);  -- 7-seg: bird Y low nibble
        HEX1        : OUT   STD_LOGIC_VECTOR(6 DOWNTO 0);  -- 7-seg: bird Y high nibble
        HEX2        : OUT   STD_LOGIC_VECTOR(6 DOWNTO 0);  -- 7-seg: mouse column low
        HEX3        : OUT   STD_LOGIC_VECTOR(6 DOWNTO 0);  -- 7-seg: mouse column high
        HEX4        : OUT   STD_LOGIC_VECTOR(6 DOWNTO 0);  -- 7-seg: mouse row low
        HEX5        : OUT   STD_LOGIC_VECTOR(6 DOWNTO 0);  -- 7-seg: mouse row high
        LEDR        : OUT   STD_LOGIC_VECTOR(9 DOWNTO 0)   -- Debug LEDs
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

    -- game_timer: counts elapsed game time and exposes each MM:SS digit as BCD
    COMPONENT game_timer
        PORT (
            vert_sync  : IN  STD_LOGIC;
            reset      : IN  STD_LOGIC;
            paused     : IN  STD_LOGIC;
            min_tens   : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
            min_ones   : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
            sec_tens   : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
            sec_ones   : OUT STD_LOGIC_VECTOR(3 DOWNTO 0)
        );
    END COMPONENT;

    -- star_field: owns star positions and outputs a single star_on pixel flag
    COMPONENT star_field
        PORT (
            vert_sync    : IN  STD_LOGIC;
            reset        : IN  STD_LOGIC;
            paused       : IN  STD_LOGIC;
            pixel_row    : IN  STD_LOGIC_VECTOR(9 DOWNTO 0);
            pixel_column : IN  STD_LOGIC_VECTOR(9 DOWNTO 0);
            star_on      : OUT STD_LOGIC
        );
    END COMPONENT;

    -- =========================================================================
    -- hex_to_seg: converts a 4-bit hex digit to active-LOW 7-segment encoding.
    -- Segment order: seg(6)=g, seg(5)=f, seg(4)=e, seg(3)=d,
    --                seg(2)=c, seg(1)=b, seg(0)=a  (standard DE0-CV pinout)
    -- '0' = segment ON, '1' = segment OFF.
    -- =========================================================================
    FUNCTION hex_to_seg(digit : STD_LOGIC_VECTOR(3 DOWNTO 0))
            RETURN STD_LOGIC_VECTOR IS
        VARIABLE seg : STD_LOGIC_VECTOR(6 DOWNTO 0);
    BEGIN
        CASE digit IS
            WHEN "0000" => seg := "1000000"; -- 0
            WHEN "0001" => seg := "1111001"; -- 1
            WHEN "0010" => seg := "0100100"; -- 2
            WHEN "0011" => seg := "0110000"; -- 3
            WHEN "0100" => seg := "0011001"; -- 4
            WHEN "0101" => seg := "0010010"; -- 5
            WHEN "0110" => seg := "0000010"; -- 6
            WHEN "0111" => seg := "1111000"; -- 7
            WHEN "1000" => seg := "0000000"; -- 8
            WHEN "1001" => seg := "0010000"; -- 9
            WHEN "1010" => seg := "0001000"; -- A
            WHEN "1011" => seg := "0000011"; -- B
            WHEN "1100" => seg := "1000110"; -- C
            WHEN "1101" => seg := "0100001"; -- D
            WHEN "1110" => seg := "0000110"; -- E
            WHEN OTHERS => seg := "0001110"; -- F
        END CASE;
        RETURN seg;
    END FUNCTION;

    -- =========================================================================
    -- Character ROM address map (TCGROM.MIF)
    -- A=1  B=2  C=3  D=4  E=5  F=6  G=7  H=8  I=9  J=10
    -- K=11 L=12 M=13 N=14 O=15 P=16 Q=17 R=18 S=19 T=20
    -- U=21 V=22 W=23 X=24 Y=25 Z=26
    -- DIGITS: 0→27, 1→28, 2→29, ... 9→36  (i.e. address = 27 + digit_value)
    --   NOTE: Verify digit addresses against your actual TCGROM.MIF if digits
    --         appear garbled — adjust the base offset (27) as needed.
    -- SPACE:  address 0 (assumed blank character at ROM index 0)
    -- =========================================================================

    -- -------------------------------------------------------------------------
    -- Clock / reset
    -- -------------------------------------------------------------------------
    SIGNAL clk_25   : STD_LOGIC := '0'; -- 25 MHz (CLOCK_50 divided by 2)
    SIGNAL reset    : STD_LOGIC;        -- Active-HIGH (inverted from KEY[0])

    -- -------------------------------------------------------------------------
    -- VGA signals
    -- -------------------------------------------------------------------------
    SIGNAL pixel_row    : STD_LOGIC_VECTOR(9 DOWNTO 0); -- Current row    (0-479)
    SIGNAL pixel_column : STD_LOGIC_VECTOR(9 DOWNTO 0); -- Current column (0-639)
    SIGNAL vert_sync    : STD_LOGIC; -- ~60 Hz frame tick used for all game updates
    SIGNAL horiz_sync   : STD_LOGIC;
    SIGNAL red_in       : STD_LOGIC;
    SIGNAL green_in     : STD_LOGIC;
    SIGNAL blue_in      : STD_LOGIC;
    SIGNAL red_out      : STD_LOGIC; 
    SIGNAL green_out    : STD_LOGIC;
    SIGNAL blue_out     : STD_LOGIC;

    -- -------------------------------------------------------------------------
    -- Mouse
    -- -------------------------------------------------------------------------
    SIGNAL mouse_row  : STD_LOGIC_VECTOR(9 DOWNTO 0); -- Debug display only
    SIGNAL mouse_col  : STD_LOGIC_VECTOR(9 DOWNTO 0); -- Debug display only
    SIGNAL left_btn   : STD_LOGIC; -- Left click = flap
    SIGNAL right_btn  : STD_LOGIC; -- Unused in gameplay

    -- -------------------------------------------------------------------------
    -- Bird
    -- -------------------------------------------------------------------------
    CONSTANT BIRD_X    : STD_LOGIC_VECTOR(9 DOWNTO 0) := CONV_STD_LOGIC_VECTOR(100, 10);
    CONSTANT BIRD_SIZE : STD_LOGIC_VECTOR(9 DOWNTO 0) := CONV_STD_LOGIC_VECTOR(12,  10);
    CONSTANT GROUND    : STD_LOGIC_VECTOR(9 DOWNTO 0) := CONV_STD_LOGIC_VECTOR(460, 10);
    CONSTANT CEILING   : STD_LOGIC_VECTOR(9 DOWNTO 0) := CONV_STD_LOGIC_VECTOR(20,  10);

    SIGNAL bird_on      : STD_LOGIC; -- '1' when beam is inside the bird bounding box
    SIGNAL bird_y_pos   : STD_LOGIC_VECTOR(9 DOWNTO 0);
    SIGNAL ground_on    : STD_LOGIC; -- Available for future collision use
    SIGNAL fall_speed   : STD_LOGIC_VECTOR(9 DOWNTO 0); -- Pixels/frame downward, max 3
    SIGNAL bird_falling : STD_LOGIC; -- '1' = gravity active, '0' = flapping

    -- -------------------------------------------------------------------------
    -- Pause
    -- -------------------------------------------------------------------------
    SIGNAL paused    : STD_LOGIC; -- '1' = game frozen
    SIGNAL key1_prev : STD_LOGIC; -- Edge-detect register for KEY[1]

    -- =========================================================================
    -- Text overlay signals
    --
    -- Three text regions share a single char_rom instance.
    -- All use the same pipeline trick: register the "active" flag by 1 clock
    -- to align it with char_rom's registered (1-cycle latency) output.
    --
    -- Region 1 — "SUS BIRD" title (2× scale, gated by SW[1]):
    --   Cols 256-383 (8 chars × 16 px), rows 0-15
    --   char index = (pixel_column - 256)[6:4]   (= offset / 16)
    --   font_col   = (pixel_column - 256)[3:1]   (= (offset mod 16) / 2)
    --   font_row   = pixel_row[3:1]               (= row / 2)
    --
    -- Region 2 — MM:SS timer (1× scale, always visible):
    --   Cols 0-31 (4 chars × 8 px), rows 0-7
    --   char index = pixel_column[4:3]            (= col / 8)
    --   digit ROM addr = 27 + digit_value
    --
    -- Region 3 — "PAUSED" overlay (1× scale, only when paused):
    --   Cols 296-343 (6 chars × 8 px), rows 240-247
    -- =========================================================================

    -- ---- "SUS BIRD" centered title ----
    SIGNAL title_on        : STD_LOGIC; -- High when beam is in the title region
    SIGNAL title_on_d      : STD_LOGIC; -- Delayed 1 cycle for ROM pipeline alignment
    SIGNAL title_col_off   : STD_LOGIC_VECTOR(9 DOWNTO 0); -- pixel_column - 256
    SIGNAL title_char_idx  : STD_LOGIC_VECTOR(2 DOWNTO 0); -- 0-7 → S,U,S,_,B,I,R,D
    SIGNAL title_char_addr : STD_LOGIC_VECTOR(5 DOWNTO 0); -- ROM address for current title char

    -- ---- MM:SS timer display ----
    SIGNAL timer_on        : STD_LOGIC; -- High when beam is in the timer region
    SIGNAL timer_on_d      : STD_LOGIC; -- Delayed 1 cycle for ROM pipeline alignment
    SIGNAL timer_char_idx  : STD_LOGIC_VECTOR(1 DOWNTO 0); -- 0=M1, 1=M0, 2=S1, 3=S0
    SIGNAL timer_digit_val : STD_LOGIC_VECTOR(3 DOWNTO 0); -- BCD digit value from game_timer
    SIGNAL timer_char_addr : STD_LOGIC_VECTOR(5 DOWNTO 0); -- ROM address for current digit
    SIGNAL min_tens        : STD_LOGIC_VECTOR(3 DOWNTO 0); -- From game_timer
    SIGNAL min_ones        : STD_LOGIC_VECTOR(3 DOWNTO 0);
    SIGNAL sec_tens        : STD_LOGIC_VECTOR(3 DOWNTO 0);
    SIGNAL sec_ones        : STD_LOGIC_VECTOR(3 DOWNTO 0);

    -- ---- "PAUSED" overlay ----
    SIGNAL paused_text_on   : STD_LOGIC;
    SIGNAL paused_active_d  : STD_LOGIC; -- Delayed 1 cycle for ROM pipeline alignment
    SIGNAL paused_col_off   : STD_LOGIC_VECTOR(9 DOWNTO 0); -- pixel_column - 296
    SIGNAL paused_char_idx  : STD_LOGIC_VECTOR(2 DOWNTO 0); -- 0-5 → P,A,U,S,E,D
    SIGNAL paused_char_addr : STD_LOGIC_VECTOR(5 DOWNTO 0);

    -- ---- Shared char_rom interface ----
    SIGNAL char_addr     : STD_LOGIC_VECTOR(5 DOWNTO 0); -- Muxed ROM address
    SIGNAL char_font_row : STD_LOGIC_VECTOR(2 DOWNTO 0); -- Font row  (0-7)
    SIGNAL char_font_col : STD_LOGIC_VECTOR(2 DOWNTO 0); -- Font col  (0-7)
    SIGNAL rom_pixel     : STD_LOGIC; -- Single pixel from ROM ('1' = lit)
    SIGNAL text_on       : STD_LOGIC; -- Final gated pixel for all text regions

    -- ---- Starfield (logic lives in star_field.vhd) ----
    SIGNAL star_on : STD_LOGIC; -- '1' when beam is on a star pixel

BEGIN

    -- =========================================================================
    -- Clock divider: 50 MHz → 25 MHz
    -- =========================================================================
    clk_div : PROCESS(CLOCK_50)
    BEGIN
        IF rising_edge(CLOCK_50) THEN
            clk_25 <= NOT clk_25;
        END IF;
    END PROCESS clk_div;

    reset <= NOT KEY(0); -- KEY[0] is active LOW; invert to active HIGH

    -- =========================================================================
    -- Sub-module instantiations
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

    -- Replicate single-bit outputs to all 4 DAC pins (full brightness only)
    VGA_HS <= horiz_sync;
    VGA_VS <= vert_sync;
    VGA_R  <= (OTHERS => red_out);
    VGA_G  <= (OTHERS => green_out);
    VGA_B  <= (OTHERS => blue_out);

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

    char_rom_inst : char_rom
        PORT MAP (
            character_address => char_addr,
            font_row          => char_font_row,
            font_col          => char_font_col,
            clock             => clk_25,
            rom_mux_output    => rom_pixel
        );

    -- game_timer counts vert_sync pulses and exposes MM:SS as BCD digits
    timer_inst : game_timer
        PORT MAP (
            vert_sync => vert_sync,
            reset     => reset,
            paused    => paused,
            min_tens  => min_tens,
            min_ones  => min_ones,
            sec_tens  => sec_tens,
            sec_ones  => sec_ones
        );

    -- star_field owns all star state; exposes only a single pixel-match output
    stars_inst : star_field
        PORT MAP (
            vert_sync    => vert_sync,
            reset        => reset,
            paused       => paused,
            pixel_row    => pixel_row,
            pixel_column => pixel_column,
            star_on      => star_on
        );

    -- =========================================================================
    -- Bird sprite: bounding-box pixel test
    -- The '0' & prefix widens operands to 11 bits to prevent unsigned overflow
    -- when the bird is close to row 0 or col 0.
    -- =========================================================================
    bird_on <= '1' WHEN (
            ('0' & BIRD_X      <= pixel_column + BIRD_SIZE) AND
            ('0' & pixel_column <= '0' & BIRD_X   + BIRD_SIZE) AND
            ('0' & bird_y_pos   <= pixel_row   + BIRD_SIZE) AND
            ('0' & pixel_row    <= '0' & bird_y_pos + BIRD_SIZE)
        ) ELSE '0';

    -- Ground line (available for collision detection; not currently coloured)
    ground_on <= '1' WHEN pixel_row >= CONV_STD_LOGIC_VECTOR(469, 10) ELSE '0';

    -- =========================================================================
    -- Text region enable signals (combinatorial bounding-box checks)
    -- =========================================================================

    -- "SUS BIRD" centered title: 8 chars × 16 px = 128 px, centred → cols 256-383
    --   2× scale means each font pixel covers a 2×2 screen pixel block.
    title_on <= '1' WHEN pixel_column >= 256 AND
                         pixel_column <= 383 AND
                         pixel_row    <= 15  ELSE '0';

    -- MM:SS timer: 4 digits × 8 px = 32 px wide, top-left corner
    timer_on <= '1' WHEN pixel_column <= 31 AND
                         pixel_row    <= 7  ELSE '0';

    -- "PAUSED": 6 chars × 8 px = 48 px, centred vertically, only when paused
    paused_text_on <= '1' WHEN pixel_column >= 296 AND
                               pixel_column <= 343 AND
                               pixel_row    >= 240 AND
                               pixel_row    <= 247 AND
                               paused = '1'        ELSE '0';

    -- =========================================================================
    -- Character index and ROM address lookup
    -- =========================================================================

    -- ---- "SUS BIRD" title ----
    -- Subtract starting column (256) to get a 0-based offset within the string.
    -- Divide by 16 (2× scale char width) using bits [6:4] to get char index 0-7.
    title_col_off  <= pixel_column - CONV_STD_LOGIC_VECTOR(256, 10);
    title_char_idx <= title_col_off(6 DOWNTO 4);

    WITH title_char_idx SELECT title_char_addr <=
        CONV_STD_LOGIC_VECTOR(19, 6) WHEN "000",  -- S
        CONV_STD_LOGIC_VECTOR(21, 6) WHEN "001",  -- U
        CONV_STD_LOGIC_VECTOR(19, 6) WHEN "010",  -- S
        CONV_STD_LOGIC_VECTOR(0,  6) WHEN "011",  -- space (ROM addr 0 assumed blank)
        CONV_STD_LOGIC_VECTOR(2,  6) WHEN "100",  -- B
        CONV_STD_LOGIC_VECTOR(9,  6) WHEN "101",  -- I
        CONV_STD_LOGIC_VECTOR(18, 6) WHEN "110",  -- R
        CONV_STD_LOGIC_VECTOR(4,  6) WHEN OTHERS; -- D

    -- ---- MM:SS timer ----
    -- Divide column by 8 using bits [4:3] to select which of the 4 digits to render.
    timer_char_idx <= pixel_column(4 DOWNTO 3);

    -- Map char index to the correct BCD digit from game_timer
    WITH timer_char_idx SELECT timer_digit_val <=
        min_tens WHEN "00",  -- leftmost digit: tens of minutes
        min_ones WHEN "01",  -- ones of minutes
        sec_tens WHEN "10",  -- tens of seconds
        sec_ones WHEN OTHERS; -- ones of seconds (rightmost)

    -- Convert BCD digit to ROM address: digit 0 → addr 27, digit 9 → addr 36
    -- (ROM layout: A=1..Z=26, then digits 0-9 at 27-36)
    timer_char_addr <= CONV_STD_LOGIC_VECTOR(27, 6) + ("00" & timer_digit_val);

    -- ---- "PAUSED" overlay ----
    -- Subtract starting column (296) then divide by 8 to get char index 0-5.
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
    -- Regions never overlap spatially so priority order is a safety measure.
    -- Priority: PAUSED > Timer > Title
    -- =========================================================================
    char_addr <= paused_char_addr WHEN paused_text_on = '1' ELSE
                 timer_char_addr  WHEN timer_on        = '1' ELSE
                 title_char_addr  WHEN title_on        = '1' ELSE
                 (OTHERS => '0');

    -- font_row selection:
    --   1× (timer, PAUSED): bits [2:0] of pixel_row (region starts on 8-aligned row)
    --   2× (title):         bits [3:1] of pixel_row (divides row by 2 for double-height)
    char_font_row <= pixel_row(2 DOWNTO 0) WHEN paused_text_on = '1' ELSE
                     pixel_row(2 DOWNTO 0) WHEN timer_on        = '1' ELSE
                     pixel_row(3 DOWNTO 1);  -- 2× title (default)

    -- font_col selection:
    --   PAUSED/timer: pixel_column[2:0] (region starts on 8-aligned column → no subtract)
    --   title 2×:     title_col_off[3:1] (column offset within the char, divided by 2)
    char_font_col <= pixel_column(2 DOWNTO 0)  WHEN paused_text_on = '1' ELSE
                     pixel_column(2 DOWNTO 0)  WHEN timer_on        = '1' ELSE
                     title_col_off(3 DOWNTO 1); -- 2× title (default)

    -- =========================================================================
    -- ROM output pipeline register
    -- char_rom is synchronous: output arrives 1 clock after address is presented.
    -- Registering the active flags here keeps them aligned with rom_pixel.
    -- =========================================================================
    Text_Pipeline : PROCESS(clk_25)
    BEGIN
        IF rising_edge(clk_25) THEN
            title_on_d      <= title_on;       -- Delayed title enable
            timer_on_d      <= timer_on;       -- Delayed timer enable
            paused_active_d <= paused_text_on; -- Delayed PAUSED enable
        END IF;
    END PROCESS Text_Pipeline;

    -- Gate rom_pixel with the delayed active flags:
    --   Title  : additionally gated by SW[1] (toggle title visibility)
    --   Timer  : always visible (no switch gate)
    --   PAUSED : only visible when paused (already encoded in paused_text_on)
    text_on <= rom_pixel AND (
        (title_on_d AND SW(1)) OR  -- Title hidden unless SW[1] is on
        timer_on_d             OR  -- Timer always shown
        paused_active_d            -- PAUSED overlay when paused
    );

    -- =========================================================================
    -- Colour generation
    --   Bird  → RED only   (R=1, G=0, B=0)
    --   Stars → WHITE      (R=G=B=1)
    --   Text  → WHITE      (R=G=B=1)
    --   Background → BLACK (R=G=B=0)
    -- =========================================================================
    red_in   <= text_on OR bird_on OR star_on; -- Red channel: text + bird + stars
    green_in <= text_on            OR star_on; -- Green channel: text + stars (no bird)
    blue_in  <= text_on            OR star_on; -- Blue channel:  text + stars (no bird)

    -- =========================================================================
    -- Bird movement (~60 Hz on vert_sync)
    -- Left click: bird rises 3 px/frame. Release: gravity adds 1 px/frame (cap 3).
    -- =========================================================================
    Move_Bird : PROCESS(vert_sync, reset)
    BEGIN
        IF reset = '1' THEN
            -- Place bird in the middle of the screen, stationary
            bird_y_pos   <= CONV_STD_LOGIC_VECTOR(240, 10); -- Start mid-screen
            fall_speed   <= CONV_STD_LOGIC_VECTOR(0,   10);
            bird_falling <= '1';

        ELSIF rising_edge(vert_sync) THEN
            IF paused = '0' THEN
                IF left_btn = '1' THEN
                    -- ---- FLAP ----
                    -- Bird moves upward 4 px; fall_speed stored so it can be
                    -- used as initial downward speed when button is released
                    bird_falling <= '0';
                    fall_speed   <= CONV_STD_LOGIC_VECTOR(3, 10);
                    IF bird_y_pos > CEILING + CONV_STD_LOGIC_VECTOR(3, 10) THEN
                        bird_y_pos <= bird_y_pos - CONV_STD_LOGIC_VECTOR(3, 10);
                    ELSE
                        bird_y_pos <= CEILING;
                    END IF;

                ELSE
                    -- ---- FALL: gravity accelerates to max 3 px/frame ----
                    bird_falling <= '1';
                    IF fall_speed < CONV_STD_LOGIC_VECTOR(3, 10) THEN
                        fall_speed <= fall_speed + 1;
                    END IF;
                    IF bird_y_pos + fall_speed < GROUND THEN
                        bird_y_pos <= bird_y_pos + fall_speed;
                    ELSE
                        bird_y_pos <= GROUND;                        -- Hit ground: stop
                        fall_speed <= CONV_STD_LOGIC_VECTOR(0, 10);  -- Reset speed
                    END IF;
                END IF;

            END IF;
        END IF;
    END PROCESS Move_Bird;

    -- =========================================================================
    -- Pause toggle: detected on falling edge of KEY[1]
    -- KEY[1] is active LOW, so a button press = HIGH→LOW transition.
    -- key1_prev stores the previous clock cycle's value; when prev='1' and
    -- current='0' we know the button was just pressed and flip the paused flag.
    -- =========================================================================
    Pause_Toggle : PROCESS(clk_25, reset)
    BEGIN
        IF reset = '1' THEN
            paused    <= '0'; -- Start unpaused
            key1_prev <= '1'; -- KEY[1] idle = '1' (active LOW button)
        ELSIF rising_edge(clk_25) THEN
            key1_prev <= KEY(1); -- Capture current button state for edge detection
            IF key1_prev = '1' AND KEY(1) = '0' THEN
                paused <= NOT paused; -- Toggle on button press
            END IF;
        END IF;
    END PROCESS Pause_Toggle;

    -- =========================================================================
    -- Debug LEDs
    -- =========================================================================
    LEDR(0)          <= left_btn;     -- Lights when left mouse button is held
    LEDR(1)          <= right_btn;    -- Lights when right mouse button is held
    LEDR(2)          <= paused;       -- Lights when game is paused
    LEDR(8)          <= bird_falling; -- Lights when bird is in free-fall
    LEDR(9)          <= '0';          -- Unused, driven low to avoid latch warnings
    LEDR(7 DOWNTO 3) <= (OTHERS => '0'); -- Unused LEDs forced low

    -- =========================================================================
    -- Seven-segment displays
    -- =========================================================================
    HEX0 <= hex_to_seg(bird_y_pos(3  DOWNTO 0)); -- Bird Y, bits [3:0]  (low nibble)
    HEX1 <= hex_to_seg(bird_y_pos(7  DOWNTO 4)); -- Bird Y, bits [7:4]  (high nibble)
    HEX2 <= hex_to_seg(mouse_col(3   DOWNTO 0)); -- Mouse col, bits [3:0]
    HEX3 <= hex_to_seg(mouse_col(7   DOWNTO 4)); -- Mouse col, bits [7:4]
    HEX4 <= hex_to_seg(mouse_row(3   DOWNTO 0)); -- Mouse row, bits [3:0]
    HEX5 <= hex_to_seg(mouse_row(7   DOWNTO 4)); -- Mouse row, bits [7:4]

END behavior;