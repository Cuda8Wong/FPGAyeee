-- =============================================================================
-- sus_bird.vhd
-- Top-level entity for Flappy Bird (COMPSYS 305) - DE0-CV board
--
-- Features:
--   * VGA graphics output
--   * Mouse-controlled bird (left click to flap, gravity otherwise)
--   * Scrolling red pipe obstacles with LFSR-randomised gaps
--   * Collision detection: bird hitting a pipe auto-resets the game
--   * Animated starfield background (200 stars)
--   * On-screen timer (M:SS, counts up, freezes at 9:59)
--   * "SUS BIRD" title text (SW[1] to show/hide)
--   * "PAUSED" overlay (KEY[1] to toggle)
--   * Bird colour selectable via SW[3]-SW[8]
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
    -- Component declarations
    -- =========================================================================

    COMPONENT VGA_SYNC
        PORT (
            clock_25Mhz, red, green, blue : IN STD_LOGIC;
            red_out, green_out, blue_out,
            horiz_sync_out, vert_sync_out : OUT STD_LOGIC;
            pixel_row, pixel_column : OUT STD_LOGIC_VECTOR(9 DOWNTO 0)
        );
    END COMPONENT;

    COMPONENT MOUSE
        PORT (
            clock_25Mhz, reset : IN STD_LOGIC;
            mouse_data : INOUT STD_LOGIC;
            mouse_clk  : INOUT STD_LOGIC;
            left_button, right_button : OUT STD_LOGIC;
            mouse_cursor_row    : OUT STD_LOGIC_VECTOR(9 DOWNTO 0);
            mouse_cursor_column : OUT STD_LOGIC_VECTOR(9 DOWNTO 0)
        );
    END COMPONENT;

    COMPONENT char_rom
        PORT (
            character_address : IN STD_LOGIC_VECTOR(5 DOWNTO 0);
            font_row, font_col : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
            clock : IN STD_LOGIC;
            rom_mux_output : OUT STD_LOGIC
        );
    END COMPONENT;

    COMPONENT star_field
        PORT (
            clk_25    : IN STD_LOGIC;
            vert_sync : IN STD_LOGIC;
            reset     : IN STD_LOGIC;
            paused    : IN STD_LOGIC;
            pixel_row : IN STD_LOGIC_VECTOR(9 DOWNTO 0);
            pixel_col : IN STD_LOGIC_VECTOR(9 DOWNTO 0);
            star_on   : OUT STD_LOGIC
        );
    END COMPONENT;

    COMPONENT screen_timer
        PORT (
            clk_25    : IN STD_LOGIC;
            clk_50    : IN STD_LOGIC;
            vert_sync : IN STD_LOGIC;
            reset     : IN STD_LOGIC;
            paused    : IN STD_LOGIC;
            pixel_row : IN STD_LOGIC_VECTOR(9 DOWNTO 0);
            pixel_col : IN STD_LOGIC_VECTOR(9 DOWNTO 0);
            timer_on  : OUT STD_LOGIC
        );
    END COMPONENT;

    -- =========================================================================
    -- Pipe obstacle controller
    -- Manages 3 scrolling pipe pairs with LFSR-randomised gaps
    -- =========================================================================
    COMPONENT pipes
        PORT (
            clk_25    : IN  STD_LOGIC;
            vert_sync : IN  STD_LOGIC;
            reset     : IN  STD_LOGIC;
            paused    : IN  STD_LOGIC;
            pixel_row : IN  STD_LOGIC_VECTOR(9 DOWNTO 0);
            pixel_col : IN  STD_LOGIC_VECTOR(9 DOWNTO 0);
            bird_y    : IN  STD_LOGIC_VECTOR(9 DOWNTO 0);
            pipe_on   : OUT STD_LOGIC;
            collision : OUT STD_LOGIC;
            level_out : OUT STD_LOGIC_VECTOR(3 DOWNTO 0)
        );
    END COMPONENT;

    -- =========================================================================
    -- 7-segment decode (active LOW)
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
    -- Internal signals
    -- =========================================================================

    -- Clocks / reset
    SIGNAL clk_25      : STD_LOGIC := '0';
    SIGNAL reset       : STD_LOGIC;
    SIGNAL game_reset  : STD_LOGIC; -- reset OR collision_r (auto-resets on crash)

    -- VGA
    SIGNAL pixel_row    : STD_LOGIC_VECTOR(9 DOWNTO 0);
    SIGNAL pixel_column : STD_LOGIC_VECTOR(9 DOWNTO 0);
    SIGNAL vert_sync    : STD_LOGIC;
    SIGNAL horiz_sync   : STD_LOGIC;
    SIGNAL red_in       : STD_LOGIC;
    SIGNAL green_in     : STD_LOGIC;
    SIGNAL blue_in      : STD_LOGIC;
    SIGNAL red_out      : STD_LOGIC;
    SIGNAL green_out    : STD_LOGIC;
    SIGNAL blue_out     : STD_LOGIC;

    -- Mouse
    SIGNAL mouse_row  : STD_LOGIC_VECTOR(9 DOWNTO 0);
    SIGNAL mouse_col  : STD_LOGIC_VECTOR(9 DOWNTO 0);
    SIGNAL left_btn   : STD_LOGIC;
    SIGNAL right_btn  : STD_LOGIC;

    -- Bird
    CONSTANT BIRD_X    : STD_LOGIC_VECTOR(9 DOWNTO 0)
                         := CONV_STD_LOGIC_VECTOR(100, 10);
    CONSTANT BIRD_SIZE : STD_LOGIC_VECTOR(9 DOWNTO 0)
                         := CONV_STD_LOGIC_VECTOR(12, 10);
    CONSTANT GROUND    : STD_LOGIC_VECTOR(9 DOWNTO 0)
                         := CONV_STD_LOGIC_VECTOR(468, 10);
    CONSTANT CEILING   : STD_LOGIC_VECTOR(9 DOWNTO 0)
                         := CONV_STD_LOGIC_VECTOR(12, 10);

    SIGNAL bird_on      : STD_LOGIC;
    SIGNAL bird_y_pos   : STD_LOGIC_VECTOR(9 DOWNTO 0);
    SIGNAL ground_on    : STD_LOGIC;
    SIGNAL fall_speed   : STD_LOGIC_VECTOR(9 DOWNTO 0);
    SIGNAL bird_falling : STD_LOGIC;

    -- Bird colour channels (set by SW switches)
    SIGNAL bird_r : STD_LOGIC;
    SIGNAL bird_g : STD_LOGIC;
    SIGNAL bird_b : STD_LOGIC;

    -- Pipes
    SIGNAL pipe_on    : STD_LOGIC;
    SIGNAL collision  : STD_LOGIC;
    SIGNAL collision_r : STD_LOGIC; -- collision registered 1 cycle to break loop
    SIGNAL level_sig   : STD_LOGIC_VECTOR(3 DOWNTO 0); -- current difficulty level (1-10)

    -- Pause
    SIGNAL paused    : STD_LOGIC;
    SIGNAL key1_prev : STD_LOGIC;

    -- Text overlay signals
    SIGNAL large_text_on  : STD_LOGIC;
    SIGNAL small_text_on  : STD_LOGIC;
    SIGNAL title_active   : STD_LOGIC;
    SIGNAL title_active_d : STD_LOGIC;

    SIGNAL large_char_idx  : STD_LOGIC_VECTOR(1 DOWNTO 0);
    SIGNAL small_char_idx  : STD_LOGIC_VECTOR(1 DOWNTO 0);
    SIGNAL large_char_addr : STD_LOGIC_VECTOR(5 DOWNTO 0);
    SIGNAL small_char_addr : STD_LOGIC_VECTOR(5 DOWNTO 0);

    SIGNAL large_col_off : STD_LOGIC_VECTOR(9 DOWNTO 0);
    SIGNAL small_col_off : STD_LOGIC_VECTOR(9 DOWNTO 0);

    -- PAUSED overlay
    SIGNAL paused_text_on   : STD_LOGIC;
    SIGNAL paused_active_d  : STD_LOGIC;
    SIGNAL paused_col_off   : STD_LOGIC_VECTOR(9 DOWNTO 0);
    SIGNAL paused_char_idx  : STD_LOGIC_VECTOR(2 DOWNTO 0);
    SIGNAL paused_char_addr : STD_LOGIC_VECTOR(5 DOWNTO 0);

    -- Shared char_rom signals
    SIGNAL char_addr     : STD_LOGIC_VECTOR(5 DOWNTO 0);
    SIGNAL char_font_row : STD_LOGIC_VECTOR(2 DOWNTO 0);
    SIGNAL char_font_col : STD_LOGIC_VECTOR(2 DOWNTO 0);
    SIGNAL rom_pixel     : STD_LOGIC;
    SIGNAL text_on       : STD_LOGIC;

    -- Sub-module pixel outputs
    SIGNAL star_on  : STD_LOGIC;
    SIGNAL timer_on : STD_LOGIC;

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

    reset <= NOT KEY(0);

    -- game_reset fires on hard reset OR one cycle after a collision
    -- Using a registered collision breaks any combinatorial feedback loop
    game_reset <= reset OR collision_r;

    -- =========================================================================
    -- VGA sync generator
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
    -- PS/2 mouse controller
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
    -- Character ROM (title and PAUSED text)
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
    -- Starfield background (uses hard reset only - stars persist across crashes)
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
    -- On-screen timer (resets on crash via game_reset)
    -- =========================================================================
    tmr : screen_timer
        PORT MAP (
            clk_25    => clk_25,
            clk_50    => CLOCK_50,
            vert_sync => vert_sync,
            reset     => game_reset,
            paused    => paused,
            pixel_row => pixel_row,
            pixel_col => pixel_column,
            timer_on  => timer_on
        );

    -- =========================================================================
    -- Pipe controller (resets on crash via game_reset)
    -- =========================================================================
    pipe_inst : pipes
        PORT MAP (
            clk_25    => clk_25,
            vert_sync => vert_sync,
            reset     => game_reset,
            paused    => paused,
            pixel_row => pixel_row,
            pixel_col => pixel_column,
            bird_y    => bird_y_pos,
            pipe_on   => pipe_on,
            collision => collision,
            level_out => level_sig
        );

    -- =========================================================================
    -- Collision register
    -- Delays collision by one clk_25 cycle to avoid a combinatorial loop:
    --   collision → game_reset → pipe_act resets → collision clears
    -- The 1-cycle pulse is sufficient to asynchronously reset all processes.
    -- Collision is ignored while paused.
    -- =========================================================================
    Collision_Reg : PROCESS(clk_25, reset)
    BEGIN
        IF reset = '1' THEN
            collision_r <= '0';
        ELSIF rising_edge(clk_25) THEN
            collision_r <= collision AND NOT paused;
        END IF;
    END PROCESS Collision_Reg;

    -- =========================================================================
    -- Bird bounding box display
    -- =========================================================================
    bird_on <= '1' WHEN (
        ('0' & BIRD_X    <= pixel_column + BIRD_SIZE) AND
        ('0' & pixel_column <= '0' & BIRD_X   + BIRD_SIZE) AND
        ('0' & bird_y_pos <= pixel_row   + BIRD_SIZE) AND
        ('0' & pixel_row  <= '0' & bird_y_pos + BIRD_SIZE)
    ) ELSE '0';

    ground_on <= '1' WHEN pixel_row >= CONV_STD_LOGIC_VECTOR(469, 10) ELSE '0';

    -- =========================================================================
    -- Bird colour selection (lowest active switch wins; default = white)
    -- SW(3)=Red  SW(4)=Yellow  SW(5)=Cyan  SW(6)=Green  SW(7)=Blue  SW(8)=Purple
    -- =========================================================================
    bird_r <= bird_on WHEN SW(3)='1' ELSE bird_on WHEN SW(4)='1' ELSE
              '0'     WHEN SW(5)='1' ELSE '0'     WHEN SW(6)='1' ELSE
              '0'     WHEN SW(7)='1' ELSE bird_on WHEN SW(8)='1' ELSE bird_on;

    bird_g <= '0'     WHEN SW(3)='1' ELSE bird_on WHEN SW(4)='1' ELSE
              bird_on WHEN SW(5)='1' ELSE bird_on WHEN SW(6)='1' ELSE
              '0'     WHEN SW(7)='1' ELSE '0'     WHEN SW(8)='1' ELSE bird_on;

    bird_b <= '0'     WHEN SW(3)='1' ELSE '0'     WHEN SW(4)='1' ELSE
              bird_on WHEN SW(5)='1' ELSE '0'     WHEN SW(6)='1' ELSE
              bird_on WHEN SW(7)='1' ELSE bird_on WHEN SW(8)='1' ELSE bird_on;

    -- =========================================================================
    -- Title text rendering
    --
    -- "SUS"  2x scale (16x16 px/char): cols 296-343, rows 16-31
    -- "BIRD" 1x scale (8x8   px/char): cols 304-335, rows 32-39
    -- =========================================================================
    large_text_on <= '1' WHEN pixel_column >= 296 AND pixel_column <= 343 AND
                              pixel_row    >= 16  AND pixel_row    <= 31
                     ELSE '0';

    small_text_on <= '1' WHEN pixel_column >= 304 AND pixel_column <= 335 AND
                              pixel_row    >= 32  AND pixel_row    <= 39
                     ELSE '0';

    title_active <= large_text_on OR small_text_on;

    large_col_off <= pixel_column - CONV_STD_LOGIC_VECTOR(296, 10);
    small_col_off <= pixel_column - CONV_STD_LOGIC_VECTOR(304, 10);

    large_char_idx <= large_col_off(5 DOWNTO 4); -- 16-px blocks
    small_char_idx <= small_col_off(4 DOWNTO 3); -- 8-px blocks

    -- "SUS": S=19, U=21, S=19
    WITH large_char_idx SELECT large_char_addr <=
        CONV_STD_LOGIC_VECTOR(19, 6) WHEN "00",
        CONV_STD_LOGIC_VECTOR(21, 6) WHEN "01",
        CONV_STD_LOGIC_VECTOR(19, 6) WHEN OTHERS;

    -- "BIRD": B=2, I=9, R=18, D=4
    WITH small_char_idx SELECT small_char_addr <=
        CONV_STD_LOGIC_VECTOR(2,  6) WHEN "00",
        CONV_STD_LOGIC_VECTOR(9,  6) WHEN "01",
        CONV_STD_LOGIC_VECTOR(18, 6) WHEN "10",
        CONV_STD_LOGIC_VECTOR(4,  6) WHEN OTHERS;

    -- =========================================================================
    -- "PAUSED" overlay: cols 296-343, rows 240-247 when paused
    -- =========================================================================
    paused_text_on <= '1' WHEN pixel_column >= 296 AND pixel_column <= 343 AND
                               pixel_row    >= 240 AND pixel_row    <= 247 AND
                               paused = '1'
                      ELSE '0';

    paused_col_off  <= pixel_column - CONV_STD_LOGIC_VECTOR(296, 10);
    paused_char_idx <= paused_col_off(5 DOWNTO 3);

    -- "PAUSED": P=16, A=1, U=21, S=19, E=5, D=4
    WITH paused_char_idx SELECT paused_char_addr <=
        CONV_STD_LOGIC_VECTOR(16, 6) WHEN "000",
        CONV_STD_LOGIC_VECTOR(1,  6) WHEN "001",
        CONV_STD_LOGIC_VECTOR(21, 6) WHEN "010",
        CONV_STD_LOGIC_VECTOR(19, 6) WHEN "011",
        CONV_STD_LOGIC_VECTOR(5,  6) WHEN "100",
        CONV_STD_LOGIC_VECTOR(4,  6) WHEN OTHERS;

    -- char_rom input mux: PAUSED > SUS > BIRD
    char_addr <= paused_char_addr WHEN paused_text_on = '1' ELSE
                 large_char_addr  WHEN large_text_on  = '1' ELSE
                 small_char_addr  WHEN small_text_on  = '1' ELSE
                 (OTHERS => '0');

    char_font_row <= pixel_row(3 DOWNTO 1) WHEN large_text_on = '1' ELSE
                     pixel_row(2 DOWNTO 0);

    char_font_col <= large_col_off(3 DOWNTO 1) WHEN large_text_on  = '1' ELSE
                     paused_col_off(2 DOWNTO 0) WHEN paused_text_on = '1' ELSE
                     small_col_off(2 DOWNTO 0);

    -- Pipeline delay to align active flags with ROM output latency
    Text_Pipeline : PROCESS(clk_25)
    BEGIN
        IF rising_edge(clk_25) THEN
            title_active_d  <= title_active;
            paused_active_d <= paused_text_on;
        END IF;
    END PROCESS Text_Pipeline;

    -- Title requires SW(1); PAUSED text always shows when paused
    text_on <= rom_pixel AND ((title_active_d AND SW(1)) OR paused_active_d);

    -- =========================================================================
    -- Colour generation
    --
    -- Priority (highest first):
    --   text / timer  → white  (1 1 1)
    --   pipe          → red    (1 0 0)   stars hidden behind pipes
    --   stars / bird  → white / bird colour
    --   background    → black  (0 0 0)
    -- =========================================================================
    red_in   <= (text_on OR timer_on) OR pipe_on OR
                (star_on AND NOT pipe_on) OR bird_r;

    green_in <= (text_on OR timer_on) OR
                ((star_on OR bird_g) AND NOT pipe_on);

    blue_in  <= (text_on OR timer_on) OR
                ((star_on OR bird_b) AND NOT pipe_on);

    -- =========================================================================
    -- Bird movement (game_reset resets position on crash or KEY[0])
    -- =========================================================================
    Move_Bird : PROCESS(vert_sync, game_reset)
    BEGIN
        IF game_reset = '1' THEN
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
    Pause_Toggle : PROCESS(clk_25, game_reset)
    BEGIN
        IF game_reset = '1' THEN
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
    -- LED indicators
    -- =========================================================================
    LEDR(0)          <= left_btn;
    LEDR(1)          <= right_btn;
    LEDR(2)          <= paused;
    LEDR(3)          <= collision;   -- lit while bird overlaps a pipe
    LEDR(8)          <= bird_falling;
    LEDR(9)          <= '0';
    LEDR(7 DOWNTO 4) <= (OTHERS => '0');

    -- =========================================================================
    -- Seven-segment displays
    -- HEX0-1: bird Y    HEX2-3: mouse X    HEX4-5: mouse Y
    -- =========================================================================
    HEX0 <= hex_to_seg(level_sig);              -- current level (1-10, shows as 1-A)
    HEX1 <= hex_to_seg(bird_y_pos(3  DOWNTO 0));  -- bird Y position
    HEX2 <= hex_to_seg(mouse_col(3   DOWNTO 0));
    HEX3 <= hex_to_seg(mouse_col(7   DOWNTO 4));
    HEX4 <= hex_to_seg(mouse_row(3   DOWNTO 0));
    HEX5 <= hex_to_seg(mouse_row(7   DOWNTO 4));

END behavior;
