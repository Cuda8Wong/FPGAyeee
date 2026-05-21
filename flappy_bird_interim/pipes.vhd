-- =============================================================================
-- pipes.vhd
--
-- Scrolling pipe obstacle system with progressive difficulty levels
--
-- LEVELS  (1-10)
--   Level increments every 5 seconds of active play (300 vert_sync pulses)
--   Level freezes at 10 and resets to 1 on game_reset / collision
--
-- PER-LEVEL CHANGES
--   Speed (px/frame) : 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10 → 11
--   Spawn interval   : 119 → 113 → 107 → 101 → 95 → 89 → 83 → 77 → 71 → 65
--   Gap height range :
--     Levels 1-2  : 80 + 6 LFSR bits  (range  80-143 px)
--     Levels 3-5  : 74 + 5 LFSR bits  (range  74-105 px)
--     Levels 6-10 : 66 + 4 LFSR bits  (range  66-81  px)
--   Gap top range remains 50-305 px across all levels
-- =============================================================================

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.STD_LOGIC_ARITH.ALL;
USE IEEE.STD_LOGIC_UNSIGNED.ALL;

ENTITY pipes IS
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
END pipes;

ARCHITECTURE behavior OF pipes IS

    CONSTANT NUM_PIPES   : INTEGER := 3;
    CONSTANT PIPE_WIDTH  : INTEGER := 20;
    CONSTANT GAP_TOP_MIN : INTEGER := 50;  -- min Y for gap top edge

    -- Bird bounding box (must match sus_bird.vhd)
    CONSTANT BIRD_X_C    : INTEGER := 100;
    CONSTANT BIRD_SZ     : INTEGER := 12;

    TYPE x_arr IS ARRAY(0 TO NUM_PIPES-1) OF STD_LOGIC_VECTOR(9 DOWNTO 0);
    TYPE y_arr IS ARRAY(0 TO NUM_PIPES-1) OF STD_LOGIC_VECTOR(9 DOWNTO 0);
    TYPE f_arr IS ARRAY(0 TO NUM_PIPES-1) OF STD_LOGIC;

    SIGNAL pipe_x   : x_arr;
    SIGNAL gap_top  : y_arr;
    SIGNAL gap_bot  : y_arr;
    SIGNAL pipe_act : f_arr;

    SIGNAL spawn_cnt : STD_LOGIC_VECTOR(7 DOWNTO 0);
    SIGNAL lfsr_reg  : STD_LOGIC_VECTOR(15 DOWNTO 0) := "1100101010110011";
    SIGNAL level     : STD_LOGIC_VECTOR(3 DOWNTO 0);  -- 0001-1010 (1-10)
    SIGNAL sec_cnt   : STD_LOGIC_VECTOR(8 DOWNTO 0);  -- counts vert_syncs (0-299)

BEGIN

    level_out <= level;

    -- =========================================================================
    -- PIPE DISPLAY
    -- =========================================================================
    Pipe_Display : PROCESS(pixel_row, pixel_col, pipe_x, gap_top, gap_bot, pipe_act)
        VARIABLE hit : STD_LOGIC;
    BEGIN
        hit := '0';
        FOR i IN 0 TO NUM_PIPES-1 LOOP
            IF pipe_act(i) = '1' THEN
                IF pixel_col >= pipe_x(i) AND
                   pixel_col <  pipe_x(i) + CONV_STD_LOGIC_VECTOR(PIPE_WIDTH, 10) THEN
                    IF pixel_row < CONV_STD_LOGIC_VECTOR(469, 10) THEN
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
    -- =========================================================================
    Collision_Check : PROCESS(bird_y, pipe_x, gap_top, gap_bot, pipe_act)
        VARIABLE col : STD_LOGIC;
    BEGIN
        col := '0';
        FOR i IN 0 TO NUM_PIPES-1 LOOP
            IF pipe_act(i) = '1' THEN
                IF pipe_x(i) <= CONV_STD_LOGIC_VECTOR(BIRD_X_C + BIRD_SZ, 10) AND
                   pipe_x(i) + CONV_STD_LOGIC_VECTOR(PIPE_WIDTH, 10) >
                                CONV_STD_LOGIC_VECTOR(BIRD_X_C - BIRD_SZ, 10) THEN
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
    -- PIPE MOVEMENT, SPAWNING AND LEVEL PROGRESSION
    -- =========================================================================
    Pipe_Update : PROCESS(vert_sync, reset)
        VARIABLE lv          : STD_LOGIC_VECTOR(15 DOWNTO 0);
        VARIABLE fb          : STD_LOGIC;
        VARIABLE gt          : STD_LOGIC_VECTOR(9 DOWNTO 0);
        VARIABLE gs          : STD_LOGIC_VECTOR(9 DOWNTO 0);
        VARIABLE sp          : STD_LOGIC;
        VARIABLE curr_speed  : INTEGER;           -- px/frame this level
        VARIABLE curr_spawn  : STD_LOGIC_VECTOR(7 DOWNTO 0); -- spawn threshold
    BEGIN
        IF reset = '1' THEN
            FOR i IN 0 TO NUM_PIPES-1 LOOP
                pipe_act(i) <= '0';
                pipe_x(i)   <= CONV_STD_LOGIC_VECTOR(700, 10);
                gap_top(i)  <= CONV_STD_LOGIC_VECTOR(150, 10);
                gap_bot(i)  <= CONV_STD_LOGIC_VECTOR(300, 10);
            END LOOP;
            spawn_cnt <= (OTHERS => '0');
            lfsr_reg  <= "1100101010110011";
            level     <= "0001";                  -- start at level 1
            sec_cnt   <= (OTHERS => '0');

        ELSIF rising_edge(vert_sync) THEN
            IF paused = '0' THEN
                lv := lfsr_reg;

                -- ----------------------------------------------------------------
                -- Resolve level-dependent parameters for this frame
                -- Speed rises by 1 px/frame each level (2 at L1, 11 at L10)
                -- Spawn interval shrinks by 6 frames each level (119 at L1, 65 at L10)
                -- ----------------------------------------------------------------
                CASE level IS
                    WHEN "0001" => curr_speed := 2;  curr_spawn := CONV_STD_LOGIC_VECTOR(119, 8);
                    WHEN "0010" => curr_speed := 3;  curr_spawn := CONV_STD_LOGIC_VECTOR(113, 8);
                    WHEN "0011" => curr_speed := 4;  curr_spawn := CONV_STD_LOGIC_VECTOR(107, 8);
                    WHEN "0100" => curr_speed := 5;  curr_spawn := CONV_STD_LOGIC_VECTOR(101, 8);
                    WHEN "0101" => curr_speed := 6;  curr_spawn := CONV_STD_LOGIC_VECTOR(95,  8);
                    WHEN "0110" => curr_speed := 7;  curr_spawn := CONV_STD_LOGIC_VECTOR(89,  8);
                    WHEN "0111" => curr_speed := 8;  curr_spawn := CONV_STD_LOGIC_VECTOR(83,  8);
                    WHEN "1000" => curr_speed := 9;  curr_spawn := CONV_STD_LOGIC_VECTOR(77,  8);
                    WHEN "1001" => curr_speed := 10; curr_spawn := CONV_STD_LOGIC_VECTOR(71,  8);
                    WHEN OTHERS => curr_speed := 11; curr_spawn := CONV_STD_LOGIC_VECTOR(65,  8);
                END CASE;

                -- ----------------------------------------------------------------
                -- Level progression: increment level every 300 vert_syncs (~5 s)
                -- ----------------------------------------------------------------
                IF sec_cnt >= CONV_STD_LOGIC_VECTOR(299, 9) THEN
                    sec_cnt <= (OTHERS => '0');
                    IF level < "1010" THEN        -- cap at level 10
                        level <= level + 1;
                    END IF;
                ELSE
                    sec_cnt <= sec_cnt + 1;
                END IF;

                -- ----------------------------------------------------------------
                -- Move active pipes left at the current speed
                -- ----------------------------------------------------------------
                FOR i IN 0 TO NUM_PIPES-1 LOOP
                    IF pipe_act(i) = '1' THEN
                        IF pipe_x(i) < CONV_STD_LOGIC_VECTOR(curr_speed, 10) THEN
                            pipe_act(i) <= '0';
                        ELSE
                            pipe_x(i) <= pipe_x(i) -
                                         CONV_STD_LOGIC_VECTOR(curr_speed, 10);
                        END IF;
                    END IF;
                END LOOP;

                -- ----------------------------------------------------------------
                -- Spawn a new pipe when the counter fires
                -- ----------------------------------------------------------------
                IF spawn_cnt >= curr_spawn THEN
                    spawn_cnt <= (OTHERS => '0');
                    sp := '0';
                    FOR i IN 0 TO NUM_PIPES-1 LOOP
                        IF pipe_act(i) = '0' AND sp = '0' THEN

                            -- Random gap top: 50 + 8 LFSR bits → range 50-305
                            fb := lv(15) XOR lv(13) XOR lv(12) XOR lv(10);
                            lv := lv(14 DOWNTO 0) & fb;
                            gt := CONV_STD_LOGIC_VECTOR(GAP_TOP_MIN, 10) +
                                  ("00" & lv(7 DOWNTO 0));

                            -- Random gap height: range narrows as level increases
                            fb := lv(15) XOR lv(13) XOR lv(12) XOR lv(10);
                            lv := lv(14 DOWNTO 0) & fb;

                            CASE level IS
                                -- Levels 1-2: wide gap  80-143 px (6 random bits)
                                WHEN "0001" | "0010" =>
                                    gs := CONV_STD_LOGIC_VECTOR(80, 10) +
                                          ("0000" & lv(5 DOWNTO 0));
                                -- Levels 3-5: medium gap  74-105 px (5 random bits)
                                WHEN "0011" | "0100" | "0101" =>
                                    gs := CONV_STD_LOGIC_VECTOR(74, 10) +
                                          ("00000" & lv(4 DOWNTO 0));
                                -- Levels 6-10: narrow gap  66-81 px (4 random bits)
                                WHEN OTHERS =>
                                    gs := CONV_STD_LOGIC_VECTOR(66, 10) +
                                          ("000000" & lv(3 DOWNTO 0));
                            END CASE;

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
