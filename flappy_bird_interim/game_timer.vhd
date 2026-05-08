-- =============================================================================
-- game_timer.vhd
-- Counts elapsed game time in MM:SS and outputs each digit as a 4-bit BCD
-- value (0-9) for use by the top-level rendering logic.
--
-- Timing:
--   vert_sync pulses at ~60 Hz (one pulse per displayed frame).
--   60 pulses = 1 second.  60 seconds = 1 minute.
--   The counter stops while the game is paused.
--   Max displayable time: 99:59 (≈ 100 minutes).
-- =============================================================================

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.STD_LOGIC_ARITH.ALL;
USE IEEE.STD_LOGIC_UNSIGNED.ALL;

ENTITY game_timer IS
    PORT (
        vert_sync  : IN  STD_LOGIC;                    -- ~60 Hz frame pulse from VGA
        reset      : IN  STD_LOGIC;                    -- Active-HIGH: clears timer to 00:00
        paused     : IN  STD_LOGIC;                    -- '1' = freeze timer
        min_tens   : OUT STD_LOGIC_VECTOR(3 DOWNTO 0); -- Minutes tens digit  (0-9)
        min_ones   : OUT STD_LOGIC_VECTOR(3 DOWNTO 0); -- Minutes ones digit  (0-9)
        sec_tens   : OUT STD_LOGIC_VECTOR(3 DOWNTO 0); -- Seconds tens digit  (0-5)
        sec_ones   : OUT STD_LOGIC_VECTOR(3 DOWNTO 0)  -- Seconds ones digit  (0-9)
    );
END game_timer;

ARCHITECTURE behavior OF game_timer IS

    -- Counts vert_sync pulses within the current second (0-59)
    SIGNAL frame_count : STD_LOGIC_VECTOR(5 DOWNTO 0);

    -- Internal BCD digit registers (driven out via the output ports)
    SIGNAL i_sec_ones  : STD_LOGIC_VECTOR(3 DOWNTO 0);
    SIGNAL i_sec_tens  : STD_LOGIC_VECTOR(3 DOWNTO 0);
    SIGNAL i_min_ones  : STD_LOGIC_VECTOR(3 DOWNTO 0);
    SIGNAL i_min_tens  : STD_LOGIC_VECTOR(3 DOWNTO 0);

BEGIN

    -- Drive outputs from internal registers
    min_tens <= i_min_tens;
    min_ones <= i_min_ones;
    sec_tens <= i_sec_tens;
    sec_ones <= i_sec_ones;

    -- =========================================================================
    -- Timer counter process
    -- Triggered on every vert_sync rising edge (~60 Hz).
    -- Increments a frame counter; when it hits 59 (completing a full second),
    -- it resets and carries the increment through the BCD digit chain.
    -- =========================================================================
    Timer_Count : PROCESS(vert_sync, reset)
    BEGIN
        IF reset = '1' THEN
            -- Clear everything back to 00:00
            frame_count <= (OTHERS => '0');
            i_sec_ones  <= (OTHERS => '0');
            i_sec_tens  <= (OTHERS => '0');
            i_min_ones  <= (OTHERS => '0');
            i_min_tens  <= (OTHERS => '0');

        ELSIF rising_edge(vert_sync) THEN
            IF paused = '0' THEN

                IF frame_count = 59 THEN
                    -- ---- One full second has elapsed ----
                    frame_count <= (OTHERS => '0');

                    -- Increment seconds ones digit; carry if it hits 10
                    IF i_sec_ones = 9 THEN
                        i_sec_ones <= (OTHERS => '0');

                        -- Increment seconds tens digit; carry at 6 (max SS = 59)
                        IF i_sec_tens = 5 THEN
                            i_sec_tens <= (OTHERS => '0');

                            -- Increment minutes ones digit; carry at 10
                            IF i_min_ones = 9 THEN
                                i_min_ones <= (OTHERS => '0');

                                -- Increment minutes tens digit; saturate at 9
                                -- (timer wraps at 99:59 back to 00:00)
                                IF i_min_tens = 9 THEN
                                    i_min_tens <= (OTHERS => '0');
                                ELSE
                                    i_min_tens <= i_min_tens + 1;
                                END IF;

                            ELSE
                                i_min_ones <= i_min_ones + 1;
                            END IF;

                        ELSE
                            i_sec_tens <= i_sec_tens + 1;
                        END IF;

                    ELSE
                        i_sec_ones <= i_sec_ones + 1;
                    END IF;

                ELSE
                    -- Not yet a full second — just advance the frame counter
                    frame_count <= frame_count + 1;
                END IF;

            END IF; -- paused = '0'
        END IF;
    END PROCESS Timer_Count;

END behavior;