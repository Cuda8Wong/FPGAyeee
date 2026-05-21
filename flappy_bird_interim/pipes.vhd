-- =============================================================================
-- pipes.vhd
--
-- Scrolling pipe obstacle system for Flappy Bird (COMPSYS 305)
--
-- Features:
--   - 3 pipe slots managed concurrently
--   - Pipes spawn on the right edge every 120 frames (~2 seconds at 60 Hz)
--   - Pipes scroll left at 2 pixels per frame (slow)
--   - Gap Y position randomised using 16-bit LFSR (range 50-305 px from top)
--   - Gap height randomised using LFSR          (range 80-143 px)
--   - Collision detection against bird bounding box
--   - Animation and spawning freeze when paused
--   - Pipes are drawn as solid regions above and below the gap
-- =============================================================================

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.STD_LOGIC_ARITH.ALL;
USE IEEE.STD_LOGIC_UNSIGNED.ALL;

ENTITY pipes IS
    PORT (
        clk_25    : IN  STD_LOGIC;              -- 25 MHz pixel clock
        vert_sync : IN  STD_LOGIC;              -- vertical sync (~60 Hz)
        reset     : IN  STD_LOGIC;              -- active high
        paused    : IN  STD_LOGIC;              -- freeze when high
        pixel_row : IN  STD_LOGIC_VECTOR(9 DOWNTO 0);
        pixel_col : IN  STD_LOGIC_VECTOR(9 DOWNTO 0);
        bird_y    : IN  STD_LOGIC_VECTOR(9 DOWNTO 0); -- bird centre Y
        pipe_on   : OUT STD_LOGIC;              -- current pixel is a pipe pixel
        collision : OUT STD_LOGIC               -- bird overlaps a pipe
    );
END pipes;

ARCHITECTURE behavior OF pipes IS

    -- =========================================================================
    -- Pipe parameters
    -- =========================================================================
    CONSTANT NUM_PIPES   : INTEGER := 3;    -- pipe slots on screen at once
    CONSTANT PIPE_WIDTH  : INTEGER := 20;   -- pipe width in pixels
    CONSTANT PIPE_SPEED  : INTEGER := 2;    -- pixels moved left per frame
    CONSTANT SPAWN_INT   : INTEGER := 120;  -- frames between spawns (2 s @ 60 Hz)

    -- Bird bounding box - must match BIRD_X and BIRD_SIZE in sus_bird.vhd
    CONSTANT BIRD_X_C    : INTEGER := 100;
    CONSTANT BIRD_SZ     : INTEGER := 12;

    -- Gap position/size constraints
    CONSTANT GAP_TOP_MIN : INTEGER := 50;   -- min row for gap top edge
    CONSTANT GAP_H_MIN   : INTEGER := 80;   -- min gap height in pixels
    --   gap_top = 50  + LFSR[7:0]  → range  50-305
    --   gap_h   = 80  + LFSR[5:0]  → range  80-143
    --   gap_bot = gap_top + gap_h   → max   448  (< ground at 469) ✓

    -- =========================================================================
    -- Array types for pipe state
    -- =========================================================================
    TYPE x_arr IS ARRAY(0 TO NUM_PIPES-1) OF STD_LOGIC_VECTOR(9 DOWNTO 0);
    TYPE y_arr IS ARRAY(0 TO NUM_PIPES-1) OF STD_LOGIC_VECTOR(9 DOWNTO 0);
    TYPE f_arr IS ARRAY(0 TO NUM_PIPES-1) OF STD_LOGIC;

    SIGNAL pipe_x   : x_arr;   -- left edge X of each pipe
    SIGNAL gap_top  : y_arr;   -- top Y of the gap (first open row)
    SIGNAL gap_bot  : y_arr;   -- bottom Y of the gap (first solid row below)
    SIGNAL pipe_act : f_arr;   -- '1' when pipe slot is in use

    SIGNAL spawn_cnt : STD_LOGIC_VECTOR(7 DOWNTO 0);
    SIGNAL lfsr_reg  : STD_LOGIC_VECTOR(15 DOWNTO 0) := "1100101010110011";

BEGIN

    -- =========================================================================
    -- PIPE DISPLAY
    -- Sets pipe_on = '1' when the current VGA pixel falls inside the solid
    -- region of any active pipe (above or below its gap, above the ground bar)
    -- =========================================================================
    Pipe_Display : PROCESS(pixel_row, pixel_col, pipe_x, gap_top, gap_bot, pipe_act)
        VARIABLE hit : STD_LOGIC;
    BEGIN
        hit := '0';
        FOR i IN 0 TO NUM_PIPES-1 LOOP
            IF pipe_act(i) = '1' THEN
                -- Within this pipe's horizontal band?
                IF pixel_col >= pipe_x(i) AND
                   pixel_col <  pipe_x(i) + CONV_STD_LOGIC_VECTOR(PIPE_WIDTH, 10) THEN
                    -- Within visible rows (stop at ground bar)?
                    IF pixel_row < CONV_STD_LOGIC_VECTOR(469, 10) THEN
                        -- Solid region: above gap OR below gap
                        IF pixel_row < gap_top(i) OR pixel_row >= gap_bot(i) THEN
                            hit := '1';
                        END IF;
                    END IF;
                END IF;
            END IF;
        END LOOP;
        pipe_on <= hit;
    END PROCESS Pipe_Display;

    -- =========================================================================
    -- COLLISION DETECTION
    -- Checks whether the bird's bounding box overlaps the solid region of
    -- any active pipe.  Uses the centre coordinates of the bird:
    --   bird X range : [BIRD_X_C - BIRD_SZ, BIRD_X_C + BIRD_SZ] = [88, 112]
    --   bird Y range : [bird_y  - BIRD_SZ,  bird_y  + BIRD_SZ ]
    -- =========================================================================
    Collision_Check : PROCESS(bird_y, pipe_x, gap_top, gap_bot, pipe_act)
        VARIABLE col : STD_LOGIC;
    BEGIN
        col := '0';
        FOR i IN 0 TO NUM_PIPES-1 LOOP
            IF pipe_act(i) = '1' THEN
                -- X overlap: bird right >= pipe left  AND  bird left < pipe right
                IF pipe_x(i) <= CONV_STD_LOGIC_VECTOR(BIRD_X_C + BIRD_SZ, 10) AND
                   pipe_x(i) +  CONV_STD_LOGIC_VECTOR(PIPE_WIDTH, 10) >
                                 CONV_STD_LOGIC_VECTOR(BIRD_X_C - BIRD_SZ, 10) THEN
                    -- Y overlap: bird enters top pipe OR bottom pipe
                    IF bird_y < gap_top(i) + CONV_STD_LOGIC_VECTOR(BIRD_SZ, 10) OR
                       bird_y + CONV_STD_LOGIC_VECTOR(BIRD_SZ, 10) >= gap_bot(i) THEN
                        col := '1';
                    END IF;
                END IF;
            END IF;
        END LOOP;
        collision <= col;
    END PROCESS Collision_Check;

    -- =========================================================================
    -- PIPE MOVEMENT AND SPAWNING
    -- Runs once per frame on the rising edge of vert_sync.
    --   1. Move all active pipes left by PIPE_SPEED pixels
    --   2. Deactivate any pipe that has scrolled off the left edge
    --   3. Increment spawn counter; when it reaches SPAWN_INT, activate the
    --      first free slot with a new pipe at X=639 and an LFSR-random gap
    -- =========================================================================
    Pipe_Update : PROCESS(vert_sync, reset)
        VARIABLE lv : STD_LOGIC_VECTOR(15 DOWNTO 0); -- working LFSR copy
        VARIABLE fb : STD_LOGIC;                      -- LFSR feedback bit
        VARIABLE gt : STD_LOGIC_VECTOR(9 DOWNTO 0);  -- computed gap top
        VARIABLE gs : STD_LOGIC_VECTOR(9 DOWNTO 0);  -- computed gap size
        VARIABLE sp : STD_LOGIC;                      -- spawned-this-frame flag
    BEGIN
        IF reset = '1' THEN
            -- Deactivate all pipes and park them off-screen
            FOR i IN 0 TO NUM_PIPES-1 LOOP
                pipe_act(i) <= '0';
                pipe_x(i)   <= CONV_STD_LOGIC_VECTOR(700, 10);
                gap_top(i)  <= CONV_STD_LOGIC_VECTOR(150, 10);
                gap_bot(i)  <= CONV_STD_LOGIC_VECTOR(300, 10);
            END LOOP;
            spawn_cnt <= (OTHERS => '0');
            lfsr_reg  <= "1100101010110011";

        ELSIF rising_edge(vert_sync) THEN
            IF paused = '0' THEN
                lv := lfsr_reg;

                -- Move active pipes left; deactivate if off screen
                FOR i IN 0 TO NUM_PIPES-1 LOOP
                    IF pipe_act(i) = '1' THEN
                        IF pipe_x(i) < CONV_STD_LOGIC_VECTOR(PIPE_SPEED, 10) THEN
                            pipe_act(i) <= '0';
                        ELSE
                            pipe_x(i) <= pipe_x(i) -
                                         CONV_STD_LOGIC_VECTOR(PIPE_SPEED, 10);
                        END IF;
                    END IF;
                END LOOP;

                -- Spawn logic
                IF spawn_cnt >= CONV_STD_LOGIC_VECTOR(SPAWN_INT - 1, 8) THEN
                    spawn_cnt <= (OTHERS => '0');

                    -- Activate the first free slot
                    sp := '0';
                    FOR i IN 0 TO NUM_PIPES-1 LOOP
                        IF pipe_act(i) = '0' AND sp = '0' THEN

                            -- Random gap top: 50 + 8 LFSR bits → range 50-305
                            fb := lv(15) XOR lv(13) XOR lv(12) XOR lv(10);
                            lv := lv(14 DOWNTO 0) & fb;
                            gt := CONV_STD_LOGIC_VECTOR(GAP_TOP_MIN, 10) +
                                  ("00" & lv(7 DOWNTO 0));

                            -- Random gap height: 80 + 6 LFSR bits → range 80-143
                            fb := lv(15) XOR lv(13) XOR lv(12) XOR lv(10);
                            lv := lv(14 DOWNTO 0) & fb;
                            gs := CONV_STD_LOGIC_VECTOR(GAP_H_MIN, 10) +
                                  ("0000" & lv(5 DOWNTO 0));

                            pipe_x(i)   <= CONV_STD_LOGIC_VECTOR(639, 10);
                            gap_top(i)  <= gt;
                            gap_bot(i)  <= gt + gs;
                            pipe_act(i) <= '1';
                            sp := '1';
                        END IF;
                    END LOOP;
                ELSE
                    spawn_cnt <= spawn_cnt + 1;
                END IF;

                lfsr_reg <= lv;
            END IF;
        END IF;
    END PROCESS Pipe_Update;

END behavior;
