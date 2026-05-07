-- =============================================================================
-- sus_bird.vhd
-- Top-level entity for Flappy Bird mini-project (COMPSYS 305, 2026)
-- DE0-CV board
--
-- Connects: vga_pll -> VGA_SYNC -> bird display logic
--                    -> MOUSE   -> bird position
--
-- INTERIM DEMO functionality:
--   - VGA: yellow bird on blue sky, controlled by PS/2 mouse
--   - Left mouse button: flap (move bird up)
--   - No click / holding: bird falls (gravity)
--   - KEY[0]: reset (active low)
--   - KEY[1]: pause / resume (active low, press to toggle)
--   - SW[0]:  '1' = TRAINING mode (no gravity, bird strictly follows mouse Y)
--             '0' = GAME mode    (gravity active, left click to flap)
--   - HEX1:HEX0 : bird Y position in hex
--   - HEX3:HEX2 : mouse column (X) in hex
--   - HEX5:HEX4 : mouse row    (Y) in hex
--   - LEDR[0]   : left mouse button indicator
--   - LEDR[1]   : right mouse button indicator
--   - LEDR[9]   : training mode indicator
-- =============================================================================

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.STD_LOGIC_ARITH.ALL;
USE IEEE.STD_LOGIC_UNSIGNED.ALL;

ENTITY sus_bird IS
    PORT (
        CLOCK_50        : IN    STD_LOGIC;

        -- Push-buttons (active LOW on DE0-CV)
        KEY             : IN    STD_LOGIC_VECTOR(3 DOWNTO 0);

        -- DIP switches
        SW              : IN    STD_LOGIC_VECTOR(9 DOWNTO 0);

        -- VGA output  (4 bits per channel)
        VGA_R           : OUT   STD_LOGIC_VECTOR(3 DOWNTO 0);
        VGA_G           : OUT   STD_LOGIC_VECTOR(3 DOWNTO 0);
        VGA_B           : OUT   STD_LOGIC_VECTOR(3 DOWNTO 0);
        VGA_HS          : OUT   STD_LOGIC;
        VGA_VS          : OUT   STD_LOGIC;

        -- PS/2 mouse (bidirectional)
        PS2_CLK         : INOUT STD_LOGIC;
        PS2_DAT         : INOUT STD_LOGIC;

        -- Seven-segment displays (active LOW segments on DE0-CV)
        HEX0            : OUT   STD_LOGIC_VECTOR(6 DOWNTO 0);
        HEX1            : OUT   STD_LOGIC_VECTOR(6 DOWNTO 0);
        HEX2            : OUT   STD_LOGIC_VECTOR(6 DOWNTO 0);
        HEX3            : OUT   STD_LOGIC_VECTOR(6 DOWNTO 0);
        HEX4            : OUT   STD_LOGIC_VECTOR(6 DOWNTO 0);
        HEX5            : OUT   STD_LOGIC_VECTOR(6 DOWNTO 0);

        -- LEDs
        LEDR            : OUT   STD_LOGIC_VECTOR(9 DOWNTO 0)
    );
END sus_bird;


ARCHITECTURE behavior OF sus_bird IS

    -- =========================================================================
    -- Component declarations
    -- =========================================================================



    -- VGA sync generator (from provided file vga_sync.vhd)
    COMPONENT VGA_SYNC
        PORT (
            clock_25Mhz,
            red, green, blue        : IN  STD_LOGIC;
            red_out, green_out,
            blue_out,
            horiz_sync_out,
            vert_sync_out           : OUT STD_LOGIC;
            pixel_row,
            pixel_column            : OUT STD_LOGIC_VECTOR(9 DOWNTO 0)
        );
    END COMPONENT;

    -- PS/2 Mouse interface (from provided file mouse.vhd)
    COMPONENT MOUSE
        PORT (
            clock_25Mhz, reset      : IN    STD_LOGIC;
            mouse_data              : INOUT STD_LOGIC;
            mouse_clk               : INOUT STD_LOGIC;
            left_button,
            right_button            : OUT   STD_LOGIC;
            mouse_cursor_row        : OUT   STD_LOGIC_VECTOR(9 DOWNTO 0);
            mouse_cursor_column     : OUT   STD_LOGIC_VECTOR(9 DOWNTO 0)
        );
    END COMPONENT;

    -- =========================================================================
    -- Internal signals
    -- =========================================================================

    -- Clocks and reset
    SIGNAL clk_25           : STD_LOGIC;
    SIGNAL reset            : STD_LOGIC;   -- active HIGH internally

    -- VGA pixel address
    SIGNAL pixel_row        : STD_LOGIC_VECTOR(9 DOWNTO 0);
    SIGNAL pixel_column     : STD_LOGIC_VECTOR(9 DOWNTO 0);
    SIGNAL vert_sync        : STD_LOGIC;

    -- Colour signals going INTO VGA_SYNC (1-bit each)
    SIGNAL red_in           : STD_LOGIC;
    SIGNAL green_in         : STD_LOGIC;
    SIGNAL blue_in          : STD_LOGIC;

    -- Colour signals coming OUT of VGA_SYNC (gated with video_on)
    SIGNAL red_out          : STD_LOGIC;
    SIGNAL green_out        : STD_LOGIC;
    SIGNAL blue_out         : STD_LOGIC;
    SIGNAL horiz_sync_out   : STD_LOGIC;

    -- Mouse outputs
    SIGNAL mouse_row        : STD_LOGIC_VECTOR(9 DOWNTO 0);
    SIGNAL mouse_col        : STD_LOGIC_VECTOR(9 DOWNTO 0);
    SIGNAL left_btn         : STD_LOGIC;
    SIGNAL right_btn        : STD_LOGIC;

    -- Bird position and display
    SIGNAL bird_on          : STD_LOGIC;
    SIGNAL bird_x_pos       : STD_LOGIC_VECTOR(9 DOWNTO 0);
    SIGNAL bird_y_pos       : STD_LOGIC_VECTOR(9 DOWNTO 0);
    CONSTANT BIRD_SIZE      : STD_LOGIC_VECTOR(9 DOWNTO 0)
                              := CONV_STD_LOGIC_VECTOR(12, 10);  -- half-size (pixels)
    CONSTANT BIRD_X_FIXED   : STD_LOGIC_VECTOR(9 DOWNTO 0)
                              := CONV_STD_LOGIC_VECTOR(100, 10); -- fixed X column

    -- Gravity / motion
    -- bird_y_motion is SIGNED: positive = moving DOWN, negative = moving UP.
    -- We use a plain std_logic_vector and do explicit add/subtract checks.
    SIGNAL bird_falling     : STD_LOGIC;   -- '1' = currently falling
    SIGNAL fall_speed       : STD_LOGIC_VECTOR(9 DOWNTO 0);

    -- Ground and ceiling
    CONSTANT GROUND         : STD_LOGIC_VECTOR(9 DOWNTO 0)
                              := CONV_STD_LOGIC_VECTOR(468, 10);
    CONSTANT CEILING        : STD_LOGIC_VECTOR(9 DOWNTO 0)
                              := CONV_STD_LOGIC_VECTOR(12,  10);

    -- Pause / game state
    SIGNAL paused           : STD_LOGIC;
    SIGNAL key1_prev        : STD_LOGIC;   -- for edge detection on KEY[1]
    SIGNAL training_mode    : STD_LOGIC;

    -- Ground bar colour
    SIGNAL ground_on        : STD_LOGIC;

    -- 7-segment nibbles
    SIGNAL seg_bird_y_lo    : STD_LOGIC_VECTOR(3 DOWNTO 0);
    SIGNAL seg_bird_y_hi    : STD_LOGIC_VECTOR(3 DOWNTO 0);
    SIGNAL seg_mouse_col_lo : STD_LOGIC_VECTOR(3 DOWNTO 0);
    SIGNAL seg_mouse_col_hi : STD_LOGIC_VECTOR(3 DOWNTO 0);
    SIGNAL seg_mouse_row_lo : STD_LOGIC_VECTOR(3 DOWNTO 0);
    SIGNAL seg_mouse_row_hi : STD_LOGIC_VECTOR(3 DOWNTO 0);


    -- =========================================================================
    -- Function: 4-bit hex digit -> 7-segment encoding (active LOW)
    --   Segment order: g f e d c b a  (HEX[6] = g, HEX[0] = a)
    -- =========================================================================
    FUNCTION hex_to_seg(digit : STD_LOGIC_VECTOR(3 DOWNTO 0))
            RETURN STD_LOGIC_VECTOR IS
        VARIABLE seg : STD_LOGIC_VECTOR(6 DOWNTO 0);
    BEGIN
        CASE digit IS
            WHEN "0000" => seg := "1000000";  -- 0
            WHEN "0001" => seg := "1111001";  -- 1
            WHEN "0010" => seg := "0100100";  -- 2
            WHEN "0011" => seg := "0110000";  -- 3
            WHEN "0100" => seg := "0011001";  -- 4
            WHEN "0101" => seg := "0010010";  -- 5
            WHEN "0110" => seg := "0000010";  -- 6
            WHEN "0111" => seg := "1111000";  -- 7
            WHEN "1000" => seg := "0000000";  -- 8
            WHEN "1001" => seg := "0010000";  -- 9
            WHEN "1010" => seg := "0001000";  -- A
            WHEN "1011" => seg := "0000011";  -- b
            WHEN "1100" => seg := "1000110";  -- C
            WHEN "1101" => seg := "0100001";  -- d
            WHEN "1110" => seg := "0000110";  -- E
            WHEN OTHERS => seg := "0001110";  -- F
        END CASE;
        RETURN seg;
    END FUNCTION;


BEGIN

    -- =========================================================================
    -- Active-high reset from KEY[0] (active-low button)
    -- =========================================================================
    reset         <= NOT KEY(0);
    training_mode <= SW(0);

    -- =========================================================================
    -- PLL instantiation
    -- =========================================================================

    -- =========================================================================
    -- VGA_SYNC instantiation
    -- NOTE: vert_sync goes to both the VGA output pin AND the bird movement
    --       process, so we route it through an internal signal first.
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
            horiz_sync_out => horiz_sync_out,
            vert_sync_out  => vert_sync,    -- internal signal
            pixel_row      => pixel_row,
            pixel_column   => pixel_column
        );

    -- Connect internal vert_sync to the board output
    VGA_VS <= vert_sync;
    VGA_HS <= horiz_sync_out;

    -- Expand 1-bit colour to 4-bit channels (all 4 bits driven identically)
    VGA_R <= (OTHERS => red_out);
    VGA_G <= (OTHERS => green_out);
    VGA_B <= (OTHERS => blue_out);

    -- =========================================================================
    -- MOUSE instantiation
    -- =========================================================================
    mouse_inst : MOUSE
        PORT MAP (
            clock_25Mhz        => clk_25,
            reset              => reset,
            mouse_data         => PS2_DAT,
            mouse_clk          => PS2_CLK,
            left_button        => left_btn,
            right_button       => right_btn,
            mouse_cursor_row   => mouse_row,
            mouse_cursor_column => mouse_col
        );

    -- =========================================================================
    -- Bird display: is the current pixel inside the bird's bounding box?
    -- The bird is a filled square.  bird_x_pos / bird_y_pos mark its CENTRE.
    -- =========================================================================
    bird_x_pos <= BIRD_X_FIXED;

    bird_on <= '1' WHEN (
            ('0' & bird_x_pos <= pixel_column + BIRD_SIZE) AND
            ('0' & pixel_column <= '0' & bird_x_pos + BIRD_SIZE) AND
            ('0' & bird_y_pos  <= pixel_row    + BIRD_SIZE) AND
            ('0' & pixel_row   <= '0' & bird_y_pos  + BIRD_SIZE)
        ) ELSE '0';

    -- Ground bar: bottom 12 pixels of the screen are green "ground"
    ground_on <= '1' WHEN pixel_row >= CONV_STD_LOGIC_VECTOR(469, 10) ELSE '0';

    -- =========================================================================
    -- Colour generation
    --   Background  : blue sky
    --   Bird        : yellow  (R=1, G=1, B=0)
    --   Ground      : green   (R=0, G=1, B=0)
    -- =========================================================================
    red_in   <= bird_on AND (NOT ground_on);
    green_in <= bird_on OR ground_on;
    blue_in  <= NOT bird_on AND NOT ground_on;

    -- =========================================================================
    -- Bird movement process
    -- Runs once per vertical sync (~60 Hz).
    --
    -- TRAINING mode (SW[0]='1'):  bird Y tracks the mouse directly.
    -- GAME mode    (SW[0]='0'):  gravity pulls the bird down each frame;
    --                             left mouse click gives an upward "flap".
    -- =========================================================================
    Move_Bird : PROCESS (vert_sync, reset)
    BEGIN
        IF reset = '1' THEN
            bird_y_pos  <= CONV_STD_LOGIC_VECTOR(240, 10);
            fall_speed  <= CONV_STD_LOGIC_VECTOR(0,   10);
            bird_falling <= '1';

        ELSIF rising_edge(vert_sync) THEN

            IF paused = '0' THEN

                IF training_mode = '1' THEN
                    -- ---- TRAINING: follow mouse exactly ----
                    bird_y_pos  <= mouse_row;
                    fall_speed  <= CONV_STD_LOGIC_VECTOR(0, 10);
                    bird_falling <= '0';

                ELSE
                    -- ---- GAME: apply gravity / flap ----

                    -- Left click = flap (jump up)
                    IF left_btn = '1' THEN
                        bird_falling <= '0';
                        fall_speed   <= CONV_STD_LOGIC_VECTOR(4, 10);

                        -- Move up, clamp to ceiling
                        IF bird_y_pos > CEILING + CONV_STD_LOGIC_VECTOR(4, 10) THEN
                            bird_y_pos <= bird_y_pos - CONV_STD_LOGIC_VECTOR(4, 10);
                        ELSE
                            bird_y_pos <= CEILING;
                        END IF;

                    ELSE
                        -- No click: gravity pulls down
                        bird_falling <= '1';

                        -- Accelerate (cap fall speed at 6 px/frame)
                        IF fall_speed < CONV_STD_LOGIC_VECTOR(6, 10) THEN
                            fall_speed <= fall_speed + 1;
                        END IF;

                        -- Move down, clamp to ground
                        IF bird_y_pos + fall_speed < GROUND THEN
                            bird_y_pos <= bird_y_pos + fall_speed;
                        ELSE
                            bird_y_pos <= GROUND;
                            fall_speed <= CONV_STD_LOGIC_VECTOR(0, 10);
                        END IF;
                    END IF;

                END IF;  -- training / game

            END IF;  -- not paused

        END IF;
    END PROCESS Move_Bird;

    -- =========================================================================
    -- Pause toggle: press KEY[1] to pause / resume
    -- We detect the falling edge (button press) using a registered copy.
    -- =========================================================================
    Pause_Toggle : PROCESS (clk_25, reset)
    BEGIN
        IF reset = '1' THEN
            paused    <= '0';
            key1_prev <= '1';
        ELSIF rising_edge(clk_25) THEN
            key1_prev <= KEY(1);
            -- Falling edge on KEY[1] means button just pressed
            IF key1_prev = '1' AND KEY(1) = '0' THEN
                paused <= NOT paused;
            END IF;
        END IF;
    END PROCESS Pause_Toggle;

    -- =========================================================================
    -- LED indicators
    -- =========================================================================
    LEDR(0)          <= left_btn;           -- left mouse button
    LEDR(1)          <= right_btn;          -- right mouse button
    LEDR(2)          <= paused;             -- pause state
    LEDR(8)          <= bird_falling;       -- bird is falling
    LEDR(9)          <= training_mode;      -- mode indicator
    LEDR(7 DOWNTO 3) <= (OTHERS => '0');

    -- =========================================================================
    -- Seven-segment displays (active LOW)
    --   HEX1:HEX0  ->  bird Y position  (10-bit shown as 3 hex digits, 2 here)
    --   HEX3:HEX2  ->  mouse column (X)
    --   HEX5:HEX4  ->  mouse row    (Y)
    -- =========================================================================
    seg_bird_y_lo    <= bird_y_pos(3  DOWNTO 0);
    seg_bird_y_hi    <= bird_y_pos(7  DOWNTO 4);
    seg_mouse_col_lo <= mouse_col(3   DOWNTO 0);
    seg_mouse_col_hi <= mouse_col(7   DOWNTO 4);
    seg_mouse_row_lo <= mouse_row(3   DOWNTO 0);
    seg_mouse_row_hi <= mouse_row(7   DOWNTO 4);

    HEX0 <= hex_to_seg(seg_bird_y_lo);
    HEX1 <= hex_to_seg(seg_bird_y_hi);
    HEX2 <= hex_to_seg(seg_mouse_col_lo);
    HEX3 <= hex_to_seg(seg_mouse_col_hi);
    HEX4 <= hex_to_seg(seg_mouse_row_lo);
    HEX5 <= hex_to_seg(seg_mouse_row_hi);

END behavior;