-- =============================================================================
-- sus_bird.vhd
-- Top-level entity for Flappy Bird interim demo (COMPSYS 305)
-- DE0-CV board
--
-- Overview:
--   This is the top-level "glue" file. It wires together four sub-modules:
--     - VGA_SYNC  : generates VGA timing and outputs RGB pixel signals
--     - MOUSE     : reads PS/2 mouse packets; left-click makes the bird flap
--     - char_rom  : font ROM used to render text overlays on screen
--     - (starfield, bird, pause logic implemented directly in this file)
--
--   Every frame (~60 Hz) the vert_sync pulse triggers movement updates for
--   the bird and the scrolling star background. The 25 MHz pixel clock drives
--   everything else (VGA scan, text pipeline, pause debounce).
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
    -- Each letter maps to a decimal address:
    -- A=1 B=2 C=3 D=4 E=5 F=6 G=7 H=8 I=9 J=10 K=11 L=12 M=13
    -- N=14 O=15 P=16 Q=17 R=18 S=19 T=20 U=21 V=22 W=23 X=24 Y=25 Z=26
    -- =========================================================================

    -- -------------------------------------------------------------------------
    -- Clock / reset
    -- -------------------------------------------------------------------------
    SIGNAL clk_25   : STD_LOGIC := '0'; -- 25 MHz derived from 50 MHz by /2 divider
    SIGNAL reset    : STD_LOGIC;        -- Active-HIGH reset (inverted from KEY[0])

    -- -------------------------------------------------------------------------
    -- VGA pixel signals
    -- -------------------------------------------------------------------------
    SIGNAL pixel_row    : STD_LOGIC_VECTOR(9 DOWNTO 0); -- Current row    being drawn (0-479)
    SIGNAL pixel_column : STD_LOGIC_VECTOR(9 DOWNTO 0); -- Current column being drawn (0-639)
    SIGNAL vert_sync    : STD_LOGIC; -- Vertical sync pulse (~60 Hz) — used as frame tick
    SIGNAL horiz_sync   : STD_LOGIC; -- Horizontal sync pulse
    -- Colour inputs sent into VGA_SYNC (driven by game logic below)
    SIGNAL red_in       : STD_LOGIC;
    SIGNAL green_in     : STD_LOGIC;
    SIGNAL blue_in      : STD_LOGIC;
    -- Colour outputs after blanking applied inside VGA_SYNC
    SIGNAL red_out      : STD_LOGIC;
    SIGNAL green_out    : STD_LOGIC;
    SIGNAL blue_out     : STD_LOGIC;

    -- -------------------------------------------------------------------------
    -- Mouse signals
    -- -------------------------------------------------------------------------
    SIGNAL mouse_row  : STD_LOGIC_VECTOR(9 DOWNTO 0); -- Mouse cursor row    (debug display only)
    SIGNAL mouse_col  : STD_LOGIC_VECTOR(9 DOWNTO 0); -- Mouse cursor column (debug display only)
    SIGNAL left_btn   : STD_LOGIC; -- Left mouse button  — triggers a flap
    SIGNAL right_btn  : STD_LOGIC; -- Right mouse button — unused in gameplay

    -- -------------------------------------------------------------------------
    -- Bird constants and signals
    -- -------------------------------------------------------------------------
    -- Bird is always drawn at a fixed horizontal position (column 100)
    CONSTANT BIRD_X    : STD_LOGIC_VECTOR(9 DOWNTO 0) := CONV_STD_LOGIC_VECTOR(100, 10);
    -- Half-size of the bird sprite in pixels (bounding box ±12 px around centre)
    CONSTANT BIRD_SIZE : STD_LOGIC_VECTOR(9 DOWNTO 0) := CONV_STD_LOGIC_VECTOR(12,  10);
    -- Row below which the bird is considered to have hit the ground
    CONSTANT GROUND    : STD_LOGIC_VECTOR(9 DOWNTO 0) := CONV_STD_LOGIC_VECTOR(460, 10);
    -- Minimum row the bird can reach (top of play area)
    CONSTANT CEILING   : STD_LOGIC_VECTOR(9 DOWNTO 0) := CONV_STD_LOGIC_VECTOR(20,  10);

    SIGNAL bird_on      : STD_LOGIC; -- '1' when current pixel is inside bird bounding box
    SIGNAL bird_y_pos   : STD_LOGIC_VECTOR(9 DOWNTO 0); -- Bird's current vertical position (row)
    SIGNAL ground_on    : STD_LOGIC; -- '1' when current pixel is on or below the ground line
    SIGNAL fall_speed   : STD_LOGIC_VECTOR(9 DOWNTO 0); -- Current downward velocity (pixels/frame), max 6
    SIGNAL bird_falling : STD_LOGIC; -- '1' = bird is falling, '0' = bird just flapped

    -- -------------------------------------------------------------------------
    -- Pause signals
    -- -------------------------------------------------------------------------
    SIGNAL paused    : STD_LOGIC; -- '1' = game is currently paused
    SIGNAL key1_prev : STD_LOGIC; -- Previous state of KEY[1], used to detect falling edge

    -- =========================================================================
    -- Text overlay signals
    --
    -- Three text regions are drawn on screen:
    --
    --   "SUS"    2× scale (16×16 px/char): cols 0–47,   rows 16–31
    --     Characters are 8×8 in the font ROM, doubled by dividing pixel
    --     coordinates by 2 before feeding into the ROM (pixel_row(3:1) etc.)
    --
    --   "BIRD"   1× scale (8×8 px/char):  cols 0–31,   rows 32–39
    --     Characters are displayed at native font resolution.
    --
    --   "PAUSED" 1× scale (8×8 px/char):  cols 296–343, rows 240–247
    --     Only visible when paused = '1'. Centred roughly on screen.
    --
    -- The char_rom has a 1-cycle output latency (registered ROM), so the
    -- "active" flags must be delayed 1 cycle before being used to gate
    -- rom_pixel into the final text_on signal.
    --
    -- Title text (SUS/BIRD) is gated by SW[1] so it can be hidden.
    -- PAUSED text is always shown when paused regardless of SW[1].
    -- =========================================================================

    -- Region enable flags (combinatorial, set by pixel_row/column comparisons)
    SIGNAL large_text_on  : STD_LOGIC; -- High when pixel is in the "SUS"    region
    SIGNAL small_text_on  : STD_LOGIC; -- High when pixel is in the "BIRD"   region
    SIGNAL title_active   : STD_LOGIC; -- OR of the two title regions
    SIGNAL title_active_d : STD_LOGIC; -- title_active delayed 1 cycle (ROM pipeline align)

    -- Character index: which character within the string is being drawn
    SIGNAL large_char_idx  : STD_LOGIC_VECTOR(1 DOWNTO 0); -- 0-2 for S,U,S
    SIGNAL small_char_idx  : STD_LOGIC_VECTOR(1 DOWNTO 0); -- 0-3 for B,I,R,D

    -- ROM address for each text region
    SIGNAL large_char_addr : STD_LOGIC_VECTOR(5 DOWNTO 0);
    SIGNAL small_char_addr : STD_LOGIC_VECTOR(5 DOWNTO 0);

    -- PAUSED region signals
    SIGNAL paused_text_on   : STD_LOGIC;                    -- High when pixel is in "PAUSED" region (and paused)
    SIGNAL paused_active_d  : STD_LOGIC;                    -- paused_text_on delayed 1 cycle
    SIGNAL paused_col_off   : STD_LOGIC_VECTOR(9 DOWNTO 0); -- Column offset from start of "PAUSED" text (col - 296)
    SIGNAL paused_char_idx  : STD_LOGIC_VECTOR(2 DOWNTO 0); -- 0-5 for P,A,U,S,E,D
    SIGNAL paused_char_addr : STD_LOGIC_VECTOR(5 DOWNTO 0); -- ROM address for current PAUSED character

    -- Shared char_rom inputs/outputs (one instance serves all three text regions)
    SIGNAL char_addr     : STD_LOGIC_VECTOR(5 DOWNTO 0); -- Muxed character address into ROM
    SIGNAL char_font_row : STD_LOGIC_VECTOR(2 DOWNTO 0); -- Font row  (0-7) into ROM
    SIGNAL char_font_col : STD_LOGIC_VECTOR(2 DOWNTO 0); -- Font col  (0-7) into ROM
    SIGNAL rom_pixel     : STD_LOGIC; -- Single pixel output from ROM ('1' = lit)
    SIGNAL text_on       : STD_LOGIC; -- Final gated text pixel (after pipeline delay + SW gate)

    -- =========================================================================
    -- Starfield
    -- 40 single-pixel stars scroll right-to-left at 2 px/frame (~120 px/sec).
    -- When a star reaches x < 2 it wraps back to x = 639 with a new random Y.
    -- Random Y positions come from a 16-bit Galois LFSR
    -- (polynomial x^16 + x^14 + x^13 + x^11 + 1).
    -- Stars freeze while the game is paused.
    -- =========================================================================
    CONSTANT NUM_STARS : INTEGER := 200;

    -- Arrays holding X and Y screen coordinates for each star
    TYPE pos_array IS ARRAY(0 TO NUM_STARS-1) OF STD_LOGIC_VECTOR(9 DOWNTO 0);
    SIGNAL star_x    : pos_array;
    SIGNAL star_y    : pos_array;

    -- LFSR state register — seeded with a non-zero constant at reset
    SIGNAL lfsr_reg  : STD_LOGIC_VECTOR(15 DOWNTO 0) := "1010110011010101";

    SIGNAL star_on   : STD_LOGIC; -- '1' when the current pixel matches any star position

BEGIN

    -- =========================================================================
    -- Clock divider: 50 MHz → 25 MHz
    -- Toggles clk_25 on every rising edge of CLOCK_50, halving the frequency.
    -- =========================================================================
    clk_div : PROCESS (CLOCK_50)
    BEGIN
        IF rising_edge(CLOCK_50) THEN
            clk_25 <= NOT clk_25;
        END IF;
    END PROCESS clk_div;

    -- KEY[0] is active LOW on the DE0-CV, so invert it to get active-HIGH reset
    reset <= NOT KEY(0);

    -- =========================================================================
    -- VGA_SYNC instantiation
    -- Drives the VGA monitor with correct sync timing and gates RGB output.
    -- pixel_row / pixel_column update every clock to tell us which pixel
    -- the display is currently drawing — all rendering logic reads these.
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

    -- Fan the single-bit VGA outputs out to the 4-bit DAC pins.
    -- Replicating the bit to all 4 pins gives full-brightness white/black only.
    VGA_HS <= horiz_sync;
    VGA_VS <= vert_sync;
    VGA_R  <= (OTHERS => red_out);
    VGA_G  <= (OTHERS => green_out);
    VGA_B  <= (OTHERS => blue_out);

    -- =========================================================================
    -- MOUSE instantiation
    -- Decodes PS/2 packets and tracks cursor position.
    -- Only left_btn is used for gameplay (flap); mouse_row/col go to 7-seg.
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
    -- char_rom instantiation
    -- One shared instance services all three text regions.
    -- The correct character address and font coordinates are muxed in
    -- combinatorially below, and the registered output (rom_pixel) arrives
    -- one clock later — hence the pipeline delay registers further down.
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
    -- Bird sprite: bounding-box pixel test
    -- The bird is a filled square. bird_on is '1' for every pixel whose
    -- (row, column) falls within ±BIRD_SIZE of the bird's centre.
    -- The '0' & prefix sign-extends the 10-bit values to 11 bits to avoid
    -- unsigned overflow when the bird is near an edge.
    -- =========================================================================
    bird_on <= '1' WHEN (
            ('0' & BIRD_X    <= pixel_column + BIRD_SIZE) AND
            ('0' & pixel_column <= '0' & BIRD_X    + BIRD_SIZE) AND
            ('0' & bird_y_pos  <= pixel_row   + BIRD_SIZE) AND
            ('0' & pixel_row   <= '0' & bird_y_pos + BIRD_SIZE)
        ) ELSE '0';

    -- Ground line: any pixel at row 469 or below is "ground"
    -- (Currently unused in the colour output but available for collision)
    ground_on <= '1' WHEN pixel_row >= CONV_STD_LOGIC_VECTOR(469, 40) ELSE '0';

    -- =========================================================================
    -- Text region enable signals (combinatorial bounding-box checks)
    -- =========================================================================

    -- "SUS" title: 3 characters × 16 px wide = 48 px → columns 0-47
    --              displayed at 2× scale → rows 16-31 (16 px tall)
    large_text_on <= '1' WHEN pixel_column <= 47 AND
                              pixel_row    >= 16  AND
                              pixel_row    <= 31  ELSE '0';

    -- "BIRD" title: 4 characters × 8 px wide = 32 px → columns 0-31
    --               displayed at 1× scale → rows 32-39 (8 px tall)
    small_text_on <= '1' WHEN pixel_column <= 31 AND
                              pixel_row    >= 32  AND
                              pixel_row    <= 39  ELSE '0';

    -- "PAUSED": 6 characters × 8 px = 48 px → columns 296-343
    --            rows 240-247, only rendered while paused flag is set
    paused_text_on <= '1' WHEN pixel_column >= 296 AND
                               pixel_column <= 343 AND
                               pixel_row    >= 240 AND
                               pixel_row    <= 247 AND
                               paused = '1'        ELSE '0';

    -- Combined flag for both title regions (used for pipeline register)
    title_active <= large_text_on OR small_text_on;

    -- =========================================================================
    -- Character index and ROM address lookup
    --
    -- For each region we need to know *which* character in the string is being
    -- drawn. We do this by dividing the pixel column by the character width:
    --   2× scale → 16 px/char: use bits [5:4] of column (= column / 16)
    --   1× scale → 8 px/char:  use bits [4:3] of column (= column / 8)
    -- Then we map that index to the ROM address for that letter.
    -- =========================================================================

    -- "SUS" — character index selects which of the 3 characters we are in
    large_char_idx <= pixel_column(5 DOWNTO 4); -- 0="S", 1="U", 2="S"

    WITH large_char_idx SELECT large_char_addr <=
        CONV_STD_LOGIC_VECTOR(19, 6) WHEN "00",   -- S (address 19 in TCGROM)
        CONV_STD_LOGIC_VECTOR(21, 6) WHEN "01",   -- U (address 21)
        CONV_STD_LOGIC_VECTOR(19, 6) WHEN OTHERS; -- S (address 19)

    -- "BIRD" — column bits [4:3] give the character index within the 4-char string
    small_char_idx <= pixel_column(4 DOWNTO 3); -- 0="B", 1="I", 2="R", 3="D"

    WITH small_char_idx SELECT small_char_addr <=
        CONV_STD_LOGIC_VECTOR(2,  6) WHEN "00",   -- B (address 2)
        CONV_STD_LOGIC_VECTOR(9,  6) WHEN "01",   -- I (address 9)
        CONV_STD_LOGIC_VECTOR(18, 6) WHEN "10",   -- R (address 18)
        CONV_STD_LOGIC_VECTOR(4,  6) WHEN OTHERS; -- D (address 4)

    -- "PAUSED" — subtract the region's starting column (296) to get a
    -- local offset, then divide by 8 (bits [5:3]) to get the character index
    paused_col_off  <= pixel_column - CONV_STD_LOGIC_VECTOR(296, 10);
    paused_char_idx <= paused_col_off(5 DOWNTO 3); -- 0=P, 1=A, 2=U, 3=S, 4=E, 5=D

    WITH paused_char_idx SELECT paused_char_addr <=
        CONV_STD_LOGIC_VECTOR(16, 6) WHEN "000",  -- P (address 16)
        CONV_STD_LOGIC_VECTOR(1,  6) WHEN "001",  -- A (address 1)
        CONV_STD_LOGIC_VECTOR(21, 6) WHEN "010",  -- U (address 21)
        CONV_STD_LOGIC_VECTOR(19, 6) WHEN "011",  -- S (address 19)
        CONV_STD_LOGIC_VECTOR(5,  6) WHEN "100",  -- E (address 5)
        CONV_STD_LOGIC_VECTOR(4,  6) WHEN OTHERS; -- D (address 4)

    -- =========================================================================
    -- char_rom input mux
    -- Only one text region is active at any pixel position (they don't overlap),
    -- so we just priority-mux the three address sources.
    -- PAUSED has highest priority (though it can never overlap the title regions
    -- spatially — this is just good practice).
    -- =========================================================================
    char_addr <= paused_char_addr WHEN paused_text_on = '1' ELSE
                 large_char_addr  WHEN large_text_on  = '1' ELSE
                 small_char_addr  WHEN small_text_on  = '1' ELSE
                 (OTHERS => '0');

    -- -------------------------------------------------------------------------
    -- Font row selection:
    --   2× scale (SUS, rows 16-31):  divide pixel_row by 2 → bits [3:1]
    --     Because the region starts at row 16 which is a multiple of 16,
    --     the lower bits naturally index into the character with no subtraction.
    --   1× scale (BIRD/PAUSED):      pixel_row bits [2:0] directly give row 0-7
    --     Both regions start on 8-aligned rows so again no subtraction needed.
    -- -------------------------------------------------------------------------
    char_font_row <= pixel_row(3 DOWNTO 1) WHEN large_text_on = '1' ELSE
                     pixel_row(2 DOWNTO 0);

    -- -------------------------------------------------------------------------
    -- Font column selection:
    --   2× scale (SUS):    divide pixel_column by 2 → bits [3:1]
    --   1× scale (others): pixel_column bits [2:0] directly give col 0-7
    --     Column origins (0 and 296) are both multiples of 8, so the low bits
    --     correctly index within the character without subtraction.
    -- -------------------------------------------------------------------------
    char_font_col <= pixel_column(3 DOWNTO 1) WHEN large_text_on = '1' ELSE
                     pixel_column(2 DOWNTO 0);

    -- =========================================================================
    -- ROM output pipeline register
    -- char_rom is a synchronous ROM so its output (rom_pixel) is valid one
    -- clock *after* the address was presented. We register the region-active
    -- flags by one cycle here to stay in sync with that output.
    -- =========================================================================
    Text_Pipeline : PROCESS (clk_25)
    BEGIN
        IF rising_edge(clk_25) THEN
            title_active_d  <= title_active;   -- Delayed title region flag
            paused_active_d <= paused_text_on; -- Delayed PAUSED region flag
        END IF;
    END PROCESS Text_Pipeline;

    -- Gate rom_pixel with the delayed active flags:
    --   - Title text (SUS/BIRD) additionally gated by SW[1] (hide/show toggle)
    --   - PAUSED text shown whenever paused, regardless of SW[1]
    text_on <= rom_pixel AND ((title_active_d AND SW(1)) OR paused_active_d);

    -- =========================================================================
    -- Colour generation
    -- This game uses only black (all off) and white (all on).
    -- A pixel is white if it belongs to: text, the bird sprite, or a star.
    -- All three colour channels receive the same signal → white on black.
    -- =========================================================================
    red_in   <= text_on OR bird_on OR star_on;
    green_in <= text_on OR bird_on OR star_on;
    blue_in  <= text_on OR bird_on OR star_on;

    -- =========================================================================
    -- Star display: combinatorial pixel-match process
    -- Runs every time pixel_row, pixel_column, or any star position changes.
    -- Loops over all 40 stars and asserts star_on if the current pixel
    -- exactly matches any star's (x, y) coordinate.
    -- Note: star_x holds column values and star_y holds row values.
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
    -- Star movement: triggered on vert_sync rising edge (~60 Hz per frame)
    -- Each frame (when not paused) every star moves 2 pixels to the left.
    -- When a star's X falls below 2 it has scrolled off the left edge, so it
    -- wraps to X = 639 (right edge) with a new pseudo-random Y coordinate.
    --
    -- The LFSR (Linear Feedback Shift Register) generates the random Y:
    --   Feedback bit = XOR of taps at bits 15, 13, 12, 10
    --   (implements polynomial x^16 + x^14 + x^13 + x^11 + 1)
    --   One LFSR step is run per star per frame. The lower 9 bits of the
    --   LFSR output (masked to rows 0-479) become the new star Y position.
    -- =========================================================================
    Star_Move : PROCESS(vert_sync, reset)
        VARIABLE lv : STD_LOGIC_VECTOR(15 DOWNTO 0); -- Local copy of LFSR state
        VARIABLE fb : STD_LOGIC;                      -- Computed feedback bit
    BEGIN
        IF reset = '1' THEN
            -- Seed the LFSR and scatter all stars across random initial positions
            lv := "1010110011010101";
            FOR i IN 0 TO NUM_STARS-1 LOOP
                -- Step LFSR once for X position
                fb := lv(15) XOR lv(13) XOR lv(12) XOR lv(10);
                lv := lv(14 DOWNTO 0) & fb;
                star_x(i) <= lv(9 DOWNTO 0); -- Use 10 bits for column (0-639)
                -- Step LFSR again for Y position
                fb := lv(15) XOR lv(13) XOR lv(12) XOR lv(10);
                lv := lv(14 DOWNTO 0) & fb;
                star_y(i) <= '0' & lv(8 DOWNTO 0); -- Use 9 bits for row (0-479)
            END LOOP;
            lfsr_reg <= lv; -- Save final LFSR state back to the register

        ELSIF rising_edge(vert_sync) THEN
            IF paused = '0' THEN   -- Stars freeze when the game is paused
                lv := lfsr_reg;    -- Load current LFSR state into local variable
                FOR i IN 0 TO NUM_STARS-1 LOOP
                    -- Advance LFSR one step to generate next pseudo-random value
                    fb := lv(15) XOR lv(13) XOR lv(12) XOR lv(10);
                    lv := lv(14 DOWNTO 0) & fb;
                    IF star_x(i) < CONV_STD_LOGIC_VECTOR(2, 10) THEN
                        -- Star has scrolled off the left edge — wrap to right
                        star_x(i) <= CONV_STD_LOGIC_VECTOR(639, 10);
                        star_y(i) <= '0' & lv(8 DOWNTO 0); -- New random row
                    ELSE
                        -- Normal scroll: move 2 pixels left each frame
                        star_x(i) <= star_x(i) - CONV_STD_LOGIC_VECTOR(2, 10);
                    END IF;
                END LOOP;
                lfsr_reg <= lv; -- Save updated LFSR state for next frame
            END IF;
        END IF;
    END PROCESS Star_Move;

    -- =========================================================================
    -- Bird movement: triggered on vert_sync rising edge (~60 Hz per frame)
    --
    -- Physics model:
    --   - Left mouse button held: bird moves UP 4 px/frame (flap), speed resets to 4
    --   - Otherwise:              gravity accelerates bird DOWN, capped at 6 px/frame
    -- The bird is clamped between CEILING (top) and GROUND (bottom).
    -- =========================================================================
    Move_Bird : PROCESS(vert_sync, reset)
    BEGIN
        IF reset = '1' THEN
            -- Place bird in the middle of the screen, stationary
            bird_y_pos   <= CONV_STD_LOGIC_VECTOR(240, 10);
            fall_speed   <= CONV_STD_LOGIC_VECTOR(0,   10);
            bird_falling <= '1';

        ELSIF rising_edge(vert_sync) THEN
            IF paused = '0' THEN -- Only update position when not paused

                IF left_btn = '1' THEN
                    -- ---- FLAP ----
                    -- Bird moves upward 4 px; fall_speed stored so it can be
                    -- used as initial downward speed when button is released
                    bird_falling <= '0';
                    fall_speed   <= CONV_STD_LOGIC_VECTOR(3, 10);
                    IF bird_y_pos > CEILING + CONV_STD_LOGIC_VECTOR(3, 10) THEN
                        bird_y_pos <= bird_y_pos - CONV_STD_LOGIC_VECTOR(3, 10);
                    ELSE
                        bird_y_pos <= CEILING; -- Clamp to ceiling if almost there
                    END IF;

                ELSE
                    -- ---- FALL (gravity) ----
                    bird_falling <= '1';
                    -- Accelerate downward by 1 px/frame each frame, up to max 6
                    IF fall_speed < CONV_STD_LOGIC_VECTOR(3, 10) THEN
                        fall_speed <= fall_speed + 1;
                    END IF;
                    -- Move down by fall_speed, clamping at ground level
                    IF bird_y_pos + fall_speed < GROUND THEN
                        bird_y_pos <= bird_y_pos + fall_speed;
                    ELSE
                        bird_y_pos <= GROUND;                       -- Hit ground: stop
                        fall_speed <= CONV_STD_LOGIC_VECTOR(0, 10); -- Reset speed
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
                paused <= NOT paused; -- Toggle pause on falling edge
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
    -- Seven-segment displays (hex_to_seg converts 4-bit nibble to segments)
    -- HEX0/1: bird Y position (useful for debugging vertical movement)
    -- HEX2/3: mouse cursor column
    -- HEX4/5: mouse cursor row
    -- =========================================================================
    HEX0 <= hex_to_seg(bird_y_pos(3  DOWNTO 0)); -- Bird Y, bits [3:0]  (low nibble)
    HEX1 <= hex_to_seg(bird_y_pos(7  DOWNTO 4)); -- Bird Y, bits [7:4]  (high nibble)
    HEX2 <= hex_to_seg(mouse_col(3   DOWNTO 0)); -- Mouse col, bits [3:0]
    HEX3 <= hex_to_seg(mouse_col(7   DOWNTO 4)); -- Mouse col, bits [7:4]
    HEX4 <= hex_to_seg(mouse_row(3   DOWNTO 0)); -- Mouse row, bits [3:0]
    HEX5 <= hex_to_seg(mouse_row(7   DOWNTO 4)); -- Mouse row, bits [7:4]

END behavior;