-- =============================================================================
-- sus_bird.vhd
-- Top-level entity for Flappy Bird interim demo (COMPSYS 305)
-- DE0-CV board
--
-- Features:
--   * VGA graphics output
--   * Mouse-controlled bird movement
--   * Pause system
--   * Animated starfield background
--   * On-screen timer
--   * Title text rendering
--   * Selectable bird colours using switches
-- =============================================================================

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.STD_LOGIC_ARITH.ALL;
USE IEEE.STD_LOGIC_UNSIGNED.ALL;

ENTITY sus_bird IS
    PORT (
        CLOCK_50 : IN STD_LOGIC;
        KEY      : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
        SW       : IN STD_LOGIC_VECTOR(9 DOWNTO 0);

        VGA_R    : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
        VGA_G    : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
        VGA_B    : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
        VGA_HS   : OUT STD_LOGIC;
        VGA_VS   : OUT STD_LOGIC;

        PS2_CLK  : INOUT STD_LOGIC;
        PS2_DAT  : INOUT STD_LOGIC;

        HEX0     : OUT STD_LOGIC_VECTOR(6 DOWNTO 0);
        HEX1     : OUT STD_LOGIC_VECTOR(6 DOWNTO 0);
        HEX2     : OUT STD_LOGIC_VECTOR(6 DOWNTO 0);
        HEX3     : OUT STD_LOGIC_VECTOR(6 DOWNTO 0);
        HEX4     : OUT STD_LOGIC_VECTOR(6 DOWNTO 0);
        HEX5     : OUT STD_LOGIC_VECTOR(6 DOWNTO 0);

        LEDR     : OUT STD_LOGIC_VECTOR(9 DOWNTO 0)
    );
END sus_bird;

ARCHITECTURE behavior OF sus_bird IS

    -- =========================================================================
    -- VGA timing generator
    -- Produces sync signals and current screen pixel coordinates
    -- =========================================================================
    COMPONENT VGA_SYNC
        PORT (
            clock_25Mhz, red, green, blue : IN STD_LOGIC;
            red_out, green_out, blue_out,
            horiz_sync_out, vert_sync_out : OUT STD_LOGIC;
            pixel_row, pixel_column : OUT STD_LOGIC_VECTOR(9 DOWNTO 0)
        );
    END COMPONENT;

    -- =========================================================================
    -- PS/2 mouse controller
    -- Provides mouse position and button states
    -- =========================================================================
    COMPONENT MOUSE
        PORT (
            clock_25Mhz, reset : IN STD_LOGIC;
            mouse_data : INOUT STD_LOGIC;
            mouse_clk : INOUT STD_LOGIC;
            left_button, right_button : OUT STD_LOGIC;
            mouse_cursor_row : OUT STD_LOGIC_VECTOR(9 DOWNTO 0);
            mouse_cursor_column : OUT STD_LOGIC_VECTOR(9 DOWNTO 0)
        );
    END COMPONENT;

    -- =========================================================================
    -- Character ROM used for text rendering
    -- =========================================================================
    COMPONENT char_rom
        PORT (
            character_address : IN STD_LOGIC_VECTOR(5 DOWNTO 0);
            font_row, font_col : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
            clock : IN STD_LOGIC;
            rom_mux_output : OUT STD_LOGIC
        );
    END COMPONENT;

    -- =========================================================================
    -- Animated starfield background generator
    -- =========================================================================
    COMPONENT star_field
        PORT (
            clk_25 : IN STD_LOGIC;
            vert_sync : IN STD_LOGIC;
            reset : IN STD_LOGIC;
            paused : IN STD_LOGIC;
            pixel_row : IN STD_LOGIC_VECTOR(9 DOWNTO 0);
            pixel_col : IN STD_LOGIC_VECTOR(9 DOWNTO 0);
            star_on : OUT STD_LOGIC
        );
    END COMPONENT;

    -- =========================================================================
    -- On-screen timer renderer
    -- =========================================================================
    COMPONENT screen_timer
        PORT (
            clk_25 : IN STD_LOGIC;
            clk_50 : IN STD_LOGIC;
            vert_sync : IN STD_LOGIC;
            reset : IN STD_LOGIC;
            paused : IN STD_LOGIC;
            pixel_row : IN STD_LOGIC_VECTOR(9 DOWNTO 0);
            pixel_col : IN STD_LOGIC_VECTOR(9 DOWNTO 0);
            timer_on : OUT STD_LOGIC
        );
    END COMPONENT;

    -- =========================================================================
    -- Converts a 4-bit value into active-low 7-segment display outputs
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

    -- Clock/reset signals
    SIGNAL clk_25 : STD_LOGIC := '0';
    SIGNAL reset : STD_LOGIC;

    -- VGA signals
    SIGNAL pixel_row : STD_LOGIC_VECTOR(9 DOWNTO 0);
    SIGNAL pixel_column : STD_LOGIC_VECTOR(9 DOWNTO 0);
    SIGNAL vert_sync : STD_LOGIC;
    SIGNAL horiz_sync : STD_LOGIC;
    SIGNAL red_in : STD_LOGIC;
    SIGNAL green_in : STD_LOGIC;
    SIGNAL blue_in : STD_LOGIC;
    SIGNAL red_out : STD_LOGIC;
    SIGNAL green_out : STD_LOGIC;
    SIGNAL blue_out : STD_LOGIC;

    -- Mouse signals
    SIGNAL mouse_row : STD_LOGIC_VECTOR(9 DOWNTO 0);
    SIGNAL mouse_col : STD_LOGIC_VECTOR(9 DOWNTO 0);
    SIGNAL left_btn : STD_LOGIC;
    SIGNAL right_btn : STD_LOGIC;

    -- Bird state and movement
    CONSTANT BIRD_X : STD_LOGIC_VECTOR(9 DOWNTO 0)
        := CONV_STD_LOGIC_VECTOR(100,10);

    CONSTANT BIRD_SIZE : STD_LOGIC_VECTOR(9 DOWNTO 0)
        := CONV_STD_LOGIC_VECTOR(12,10);

    CONSTANT GROUND : STD_LOGIC_VECTOR(9 DOWNTO 0)
        := CONV_STD_LOGIC_VECTOR(468,10);

    CONSTANT CEILING : STD_LOGIC_VECTOR(9 DOWNTO 0)
        := CONV_STD_LOGIC_VECTOR(12,10);

    SIGNAL bird_on : STD_LOGIC;
    SIGNAL bird_y_pos : STD_LOGIC_VECTOR(9 DOWNTO 0);
    SIGNAL ground_on : STD_LOGIC;
    SIGNAL fall_speed : STD_LOGIC_VECTOR(9 DOWNTO 0);
    SIGNAL bird_falling : STD_LOGIC;

    -- Bird colour outputs
    SIGNAL bird_r : STD_LOGIC;
    SIGNAL bird_g : STD_LOGIC;
    SIGNAL bird_b : STD_LOGIC;

    -- Pause control
    SIGNAL paused : STD_LOGIC;
    SIGNAL key1_prev : STD_LOGIC;
    SIGNAL paused_text_on : STD_LOGIC;
    SIGNAL paused_active_d : STD_LOGIC;
    SIGNAL paused_col_off : STD_LOGIC_VECTOR(9 DOWNTO 0);
    SIGNAL paused_char_idx : STD_LOGIC_VECTOR(2 DOWNTO 0);
    SIGNAL paused_char_addr : STD_LOGIC_VECTOR(5 DOWNTO 0);

    -- Title rendering signals
    SIGNAL large_text_on : STD_LOGIC;
    SIGNAL small_text_on : STD_LOGIC;
    SIGNAL title_active : STD_LOGIC;
    SIGNAL title_active_d : STD_LOGIC;

    SIGNAL large_char_idx : STD_LOGIC_VECTOR(1 DOWNTO 0);
    SIGNAL small_char_idx : STD_LOGIC_VECTOR(1 DOWNTO 0);
    SIGNAL large_char_addr : STD_LOGIC_VECTOR(5 DOWNTO 0);
    SIGNAL small_char_addr : STD_LOGIC_VECTOR(5 DOWNTO 0);

    -- Local coordinates inside text regions
    SIGNAL large_col_off : STD_LOGIC_VECTOR(9 DOWNTO 0);
    SIGNAL small_col_off : STD_LOGIC_VECTOR(9 DOWNTO 0);

    -- Character ROM signals
    SIGNAL char_addr : STD_LOGIC_VECTOR(5 DOWNTO 0);
    SIGNAL char_font_row : STD_LOGIC_VECTOR(2 DOWNTO 0);
    SIGNAL char_font_col : STD_LOGIC_VECTOR(2 DOWNTO 0);
    SIGNAL rom_pixel : STD_LOGIC;
    SIGNAL text_on : STD_LOGIC;

    -- Sub-module outputs
    SIGNAL star_on : STD_LOGIC;
    SIGNAL timer_on : STD_LOGIC;

BEGIN

    -- =========================================================================
    -- Divide 50 MHz clock into 25 MHz VGA clock
    -- =========================================================================
    clk_div : PROCESS(CLOCK_50)
    BEGIN
        IF rising_edge(CLOCK_50) THEN
            clk_25 <= NOT clk_25;
        END IF;
    END PROCESS clk_div;

    -- KEY(0) is active-low reset
    reset <= NOT KEY(0);

    -- =========================================================================
    -- VGA controller instance
    -- =========================================================================
    vga_inst : VGA_SYNC
        PORT MAP (
            clock_25Mhz => clk_25,
            red => red_in,
            green => green_in,
            blue => blue_in,
            red_out => red_out,
            green_out => green_out,
            blue_out => blue_out,
            horiz_sync_out => horiz_sync,
            vert_sync_out => vert_sync,
            pixel_row => pixel_row,
            pixel_column => pixel_column
        );

    -- Output VGA signals
    VGA_HS <= horiz_sync;
    VGA_VS <= vert_sync;
    VGA_R <= (OTHERS => red_out);
    VGA_G <= (OTHERS => green_out);
    VGA_B <= (OTHERS => blue_out);

    -- =========================================================================
    -- Mouse controller instance
    -- =========================================================================
    mouse_inst : MOUSE
        PORT MAP (
            clock_25Mhz => clk_25,
            reset => reset,
            mouse_data => PS2_DAT,
            mouse_clk => PS2_CLK,
            left_button => left_btn,
            right_button => right_btn,
            mouse_cursor_row => mouse_row,
            mouse_cursor_column => mouse_col
        );

    -- =========================================================================
    -- Character ROM instance
    -- =========================================================================
    char_rom_inst : char_rom
        PORT MAP (
            character_address => char_addr,
            font_row => char_font_row,
            font_col => char_font_col,
            clock => clk_25,
            rom_mux_output => rom_pixel
        );

    -- =========================================================================
    -- Starfield background instance
    -- =========================================================================
    stars : star_field
        PORT MAP (
            clk_25 => clk_25,
            vert_sync => vert_sync,
            reset => reset,
            paused => paused,
            pixel_row => pixel_row,
            pixel_col => pixel_column,
            star_on => star_on
        );

    -- =========================================================================
    -- Timer instance
    -- =========================================================================
    tmr : screen_timer
        PORT MAP (
            clk_25 => clk_25,
            clk_50 => CLOCK_50,
            vert_sync => vert_sync,
            reset => reset,
            paused => paused,
            pixel_row => pixel_row,
            pixel_col => pixel_column,
            timer_on => timer_on
        );

    -- =========================================================================
    -- Bird collision box
    -- Draws the bird when the current VGA pixel lies inside
    -- the bird boundaries
    -- =========================================================================
    bird_on <= '1' WHEN (
        ('0' & BIRD_X <= pixel_column + BIRD_SIZE) AND
        ('0' & pixel_column <= '0' & BIRD_X + BIRD_SIZE) AND
        ('0' & bird_y_pos <= pixel_row + BIRD_SIZE) AND
        ('0' & pixel_row <= '0' & bird_y_pos + BIRD_SIZE)
    ) ELSE '0';

    -- Ground region
    ground_on <= '1' WHEN pixel_row >= CONV_STD_LOGIC_VECTOR(469,10) ELSE '0';

    -- =========================================================================
    -- Bird colour selection
    -- SW(3)=red
    -- SW(4)=orange
    -- SW(5)=yellow
    -- SW(6)=green
    -- SW(7)=blue
    -- SW(8)=purple
    --
    -- Lowest active switch has priority.
    -- Default colour is white.
    -- =========================================================================
    bird_r <= bird_on WHEN SW(3) = '1' ELSE
        bird_on WHEN SW(4) = '1' ELSE
        '0' WHEN SW(5) = '1' ELSE
        '0' WHEN SW(6) = '1' ELSE
        '0' WHEN SW(7) = '1' ELSE
        bird_on WHEN SW(8) = '1' ELSE
        bird_on;

    bird_g <= '0' WHEN SW(3) = '1' ELSE
        bird_on WHEN SW(4) = '1' ELSE
        bird_on WHEN SW(5) = '1' ELSE
        bird_on WHEN SW(6) = '1' ELSE
        '0' WHEN SW(7) = '1' ELSE
        '0' WHEN SW(8) = '1' ELSE
        bird_on;

    bird_b <= '0' WHEN SW(3) = '1' ELSE
        '0' WHEN SW(4) = '1' ELSE
        bird_on WHEN SW(5) = '1' ELSE
        '0' WHEN SW(6) = '1' ELSE
        bird_on WHEN SW(7) = '1' ELSE
        bird_on WHEN SW(8) = '1' ELSE
        bird_on;

    -- =========================================================================
    -- Title text regions
    --
    -- "SUS" uses 2x scaling
    -- "BIRD" uses normal scaling
    -- =========================================================================

    -- "SUS" region
    large_text_on <= '1' WHEN pixel_column >= 296 AND pixel_column <= 343 AND
                              pixel_row >= 16 AND pixel_row <= 31
                    ELSE '0';

    -- "BIRD" region
    small_text_on <= '1' WHEN pixel_column >= 304 AND pixel_column <= 335 AND
                              pixel_row >= 32 AND pixel_row <= 39
                    ELSE '0';

    -- Enable title rendering when either region is active
    title_active <= large_text_on OR small_text_on;

    -- Convert screen coordinates into local coordinates
    -- inside each text region
    large_col_off <= pixel_column - CONV_STD_LOGIC_VECTOR(296,10);
    small_col_off <= pixel_column - CONV_STD_LOGIC_VECTOR(304,10);

    -- Divide by 16 to determine which enlarged character
    -- is currently being drawn
    large_char_idx <= large_col_off(5 DOWNTO 4);

    -- Character selection for "SUS"
    WITH large_char_idx SELECT large_char_addr <=
        CONV_STD_LOGIC_VECTOR(19,6) WHEN "00",   -- S
        CONV_STD_LOGIC_VECTOR(21,6) WHEN "01",   -- U
        CONV_STD_LOGIC_VECTOR(19,6) WHEN OTHERS; -- S

    -- Divide by 8 to determine which normal-sized character
    -- is currently being drawn
    small_char_idx <= small_col_off(4 DOWNTO 3);

    -- Character selection for "BIRD"
    WITH small_char_idx SELECT small_char_addr <=
        CONV_STD_LOGIC_VECTOR(2,6) WHEN "00",    -- B
        CONV_STD_LOGIC_VECTOR(9,6) WHEN "01",    -- I
        CONV_STD_LOGIC_VECTOR(18,6) WHEN "10",   -- R
        CONV_STD_LOGIC_VECTOR(4,6) WHEN OTHERS;  -- D

    -- =========================================================================
    -- "PAUSED" text overlay
    -- Draws centered pause text when game is paused
    -- =========================================================================
    paused_text_on <= '1' WHEN pixel_column >= 296 AND pixel_column <= 343 AND
                               pixel_row >= 240 AND pixel_row <= 247 AND
                               paused = '1'
                      ELSE '0';

    -- Convert screen coordinates into local text coordinates
    paused_col_off <= pixel_column - CONV_STD_LOGIC_VECTOR(296,10);

    -- Divide by 8 to determine current character
    paused_char_idx <= paused_col_off(5 DOWNTO 3);

    -- Character selection for "PAUSED"
    WITH paused_char_idx SELECT paused_char_addr <=
        CONV_STD_LOGIC_VECTOR(16,6) WHEN "000",  -- P
        CONV_STD_LOGIC_VECTOR(1,6) WHEN "001",   -- A
        CONV_STD_LOGIC_VECTOR(21,6) WHEN "010",  -- U
        CONV_STD_LOGIC_VECTOR(19,6) WHEN "011",  -- S
        CONV_STD_LOGIC_VECTOR(5,6) WHEN "100",   -- E
        CONV_STD_LOGIC_VECTOR(4,6) WHEN OTHERS;  -- D

    -- Select which character should be rendered
    char_addr <= paused_char_addr WHEN paused_text_on = '1' ELSE
                 large_char_addr WHEN large_text_on = '1' ELSE
                 small_char_addr WHEN small_text_on = '1' ELSE
                 (OTHERS => '0');

    -- 2x-scaled text repeats font rows twice
    char_font_row <= pixel_row(3 DOWNTO 1) WHEN large_text_on = '1' ELSE
                     pixel_row(2 DOWNTO 0);

    -- 2x-scaled text repeats font columns twice
    char_font_col <= large_col_off(3 DOWNTO 1) WHEN large_text_on = '1' ELSE
                     paused_col_off(2 DOWNTO 0) WHEN paused_text_on = '1' ELSE
                     small_col_off(2 DOWNTO 0);

    -- Delay text enable signals so they stay aligned
    -- with character ROM output timing
    Text_Pipeline : PROCESS(clk_25)
    BEGIN
        IF rising_edge(clk_25) THEN
            title_active_d <= title_active;
            paused_active_d <= paused_text_on;
        END IF;
    END PROCESS Text_Pipeline;

    -- Title text only appears when SW(1) is enabled
    -- Pause text always appears when paused
    text_on <= rom_pixel AND ((title_active_d AND SW(1)) OR paused_active_d);

    -- =========================================================================
    -- Final colour generation
    --
    -- Text, timer, and stars are white.
    -- Bird colour is controlled separately.
    -- =========================================================================
    red_in <= (text_on OR star_on OR timer_on) OR bird_r;
    green_in <= (text_on OR star_on OR timer_on) OR bird_g;
    blue_in <= (text_on OR star_on OR timer_on) OR bird_b;

    -- =========================================================================
    -- Bird movement system
    --
    -- Left mouse button moves bird upward.
    -- Gravity increases downward speed over time.
    -- =========================================================================
    Move_Bird : PROCESS(vert_sync,reset)
    BEGIN
        IF reset = '1' THEN

            -- Reset bird position and movement
            bird_y_pos <= CONV_STD_LOGIC_VECTOR(240,10);
            fall_speed <= CONV_STD_LOGIC_VECTOR(0,10);
            bird_falling <= '1';

        ELSIF rising_edge(vert_sync) THEN

            -- Only update movement when not paused
            IF paused = '0' THEN

                -- Mouse button held: move bird upward
                IF left_btn = '1' THEN

                    bird_falling <= '0';

                    -- Reset upward movement speed
                    fall_speed <= CONV_STD_LOGIC_VECTOR(4,10);

                    -- Prevent bird from moving above ceiling
                    IF bird_y_pos > CEILING + CONV_STD_LOGIC_VECTOR(4,10) THEN
                        bird_y_pos <= bird_y_pos - CONV_STD_LOGIC_VECTOR(4,10);
                    ELSE
                        bird_y_pos <= CEILING;
                    END IF;

                ELSE

                    -- Apply gravity
                    bird_falling <= '1';

                    -- Increase downward velocity until terminal speed
                    IF fall_speed < CONV_STD_LOGIC_VECTOR(6,10) THEN
                        fall_speed <= fall_speed + 1;
                    END IF;

                    -- Prevent bird from falling below ground
                    IF bird_y_pos + fall_speed < GROUND THEN
                        bird_y_pos <= bird_y_pos + fall_speed;
                    ELSE
                        bird_y_pos <= GROUND;
                        fall_speed <= CONV_STD_LOGIC_VECTOR(0,10);
                    END IF;

                END IF;

            END IF;

        END IF;

    END PROCESS Move_Bird;

    -- =========================================================================
    -- Pause toggle system
    --
    -- Detects falling edge of KEY(1) to prevent
    -- repeated toggles while button is held
    -- =========================================================================
    Pause_Toggle : PROCESS(clk_25,reset)
    BEGIN
        IF reset = '1' THEN

            paused <= '0';
            key1_prev <= '1';

        ELSIF rising_edge(clk_25) THEN

            -- Store previous button state
            key1_prev <= KEY(1);

            -- Toggle pause on button press
            IF key1_prev = '1' AND KEY(1) = '0' THEN
                paused <= NOT paused;
            END IF;

        END IF;

    END PROCESS Pause_Toggle;

    -- =========================================================================
    -- LED debug outputs
    -- =========================================================================
    LEDR(0) <= left_btn;
    LEDR(1) <= right_btn;
    LEDR(2) <= paused;
    LEDR(8) <= bird_falling;
    LEDR(9) <= '0';
    LEDR(7 DOWNTO 3) <= (OTHERS => '0');

    -- =========================================================================
    -- Seven-segment debug displays
    --
    -- HEX0-1 : bird Y position
    -- HEX2-3 : mouse X position
    -- HEX4-5 : mouse Y position
    -- =========================================================================
    HEX0 <= hex_to_seg(bird_y_pos(3 DOWNTO 0));
    HEX1 <= hex_to_seg(bird_y_pos(7 DOWNTO 4));

    HEX2 <= hex_to_seg(mouse_col(3 DOWNTO 0));
    HEX3 <= hex_to_seg(mouse_col(7 DOWNTO 4));

    HEX4 <= hex_to_seg(mouse_row(3 DOWNTO 0));
    HEX5 <= hex_to_seg(mouse_row(7 DOWNTO 4));

END behavior;
