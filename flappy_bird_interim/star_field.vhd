-- =============================================================================
-- star_field.vhd
--
-- Creates a moving starfield background effect for VGA output.
--
-- Features:
--   - 200 stars total
--   - Each star is 1 pixel
--   - Stars move left by 2 pixels every screen refresh
--   - Stars respawn on the right side when leaving the screen
--   - Star Y positions are randomized using a 16-bit LFSR
--   - Animation pauses when paused = '1'
-- =============================================================================

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.STD_LOGIC_ARITH.ALL;
USE IEEE.STD_LOGIC_UNSIGNED.ALL;

-- =============================================================================
-- ENTITY
-- Defines the module inputs and outputs
-- =============================================================================

ENTITY star_field IS
    PORT (
        -- 25 MHz VGA clock
        clk_25    : IN  STD_LOGIC;

        -- Vertical sync signal
        -- Used to update stars once per frame (~60 Hz)
        vert_sync : IN  STD_LOGIC;

        -- Resets star positions
        reset     : IN  STD_LOGIC;

        -- Stops star movement when high
        paused    : IN  STD_LOGIC;

        -- Current VGA pixel row being drawn
        pixel_row : IN  STD_LOGIC_VECTOR(9 DOWNTO 0);

        -- Current VGA pixel column being drawn
        pixel_col : IN  STD_LOGIC_VECTOR(9 DOWNTO 0);

        -- '1' when current pixel contains a star
        star_on   : OUT STD_LOGIC
    );
END star_field;

-- =============================================================================
-- ARCHITECTURE
-- Contains internal signals and logic
-- =============================================================================

ARCHITECTURE behavior OF star_field IS

    -- Number of stars in the starfield
    CONSTANT NUM_STARS : INTEGER := 200;

    -- Array type used to store X or Y positions
    TYPE pos_array IS ARRAY(0 TO NUM_STARS-1)
        OF STD_LOGIC_VECTOR(9 DOWNTO 0);

    -- X positions for every star
    SIGNAL star_x : pos_array;

    -- Y positions for every star
    SIGNAL star_y : pos_array;

    -- 16-bit Linear Feedback Shift Register (LFSR)
    -- Used for pseudo-random number generation
    SIGNAL lfsr_reg : STD_LOGIC_VECTOR(15 DOWNTO 0)
        := "1010110011010101";

BEGIN

    -- =========================================================================
    -- STAR DISPLAY PROCESS
    --
    -- Checks whether the current VGA pixel matches any star position.
    -- If current pixel equals a star coordinate:
    --      star_on = '1'
    -- otherwise:
    --      star_on = '0'
    -- =========================================================================

    Star_Display : PROCESS(pixel_row, pixel_col, star_x, star_y)

        -- Stores whether a star exists at this pixel
        VARIABLE star_hit : STD_LOGIC;

    BEGIN

        -- Default: assume no star is present
        star_hit := '0';

        -- Check all stars
        FOR i IN 0 TO NUM_STARS-1 LOOP

            -- Compare current screen pixel
            -- against this star's coordinates
            IF pixel_col = star_x(i)
            AND pixel_row = star_y(i) THEN
                star_hit := '1';
            END IF;

        END LOOP;

        -- Output result
        star_on <= star_hit;

    END PROCESS Star_Display;

    -- =========================================================================
    -- STAR MOVEMENT PROCESS
    --
    -- Updates star positions once per frame using vert_sync.
    --
    -- Stars:
    --   - move left by 2 pixels each frame
    --   - respawn on right side when off-screen
    --   - get new random Y positions on respawn
    -- =========================================================================

    Star_Move : PROCESS(vert_sync, reset)

        -- Temporary working copy of LFSR
        VARIABLE lfsr_value : STD_LOGIC_VECTOR(15 DOWNTO 0);

        -- New feedback bit calculated for LFSR
        VARIABLE feedback_bit : STD_LOGIC;

    BEGIN

        -- =====================================================================
        -- RESET LOGIC
        --
        -- Initializes all star positions with pseudo-random values
        -- =====================================================================

        IF reset = '1' THEN

            -- Reset LFSR seed value
            lfsr_value := "1010110011010101";

            -- Initialize every star
            FOR i IN 0 TO NUM_STARS-1 LOOP

                -- Generate next LFSR bit
                -- XOR taps: bit 15, 13, 12, 10
                feedback_bit :=
                    lfsr_value(15) XOR
                    lfsr_value(13) XOR
                    lfsr_value(12) XOR
                    lfsr_value(10);

                -- Shift left and insert feedback bit
                lfsr_value :=
                    lfsr_value(14 DOWNTO 0) & feedback_bit;

                -- Use lower 10 bits as X position
                star_x(i) <= lfsr_value(9 DOWNTO 0);

                -- Generate another random number
                feedback_bit :=
                    lfsr_value(15) XOR
                    lfsr_value(13) XOR
                    lfsr_value(12) XOR
                    lfsr_value(10);

                -- Shift again
                lfsr_value :=
                    lfsr_value(14 DOWNTO 0) & feedback_bit;

                -- Use lower 9 bits as Y position
                -- Add leading 0 to create 10-bit value
                star_y(i) <= '0' & lfsr_value(8 DOWNTO 0);

            END LOOP;

            -- Save updated LFSR state
            lfsr_reg <= lfsr_value;

        -- =====================================================================
        -- FRAME UPDATE
        --
        -- Runs once every vertical sync rising edge (~60 Hz)
        -- =====================================================================

        ELSIF rising_edge(vert_sync) THEN

            -- Only move stars if game is not paused
            IF paused = '0' THEN

                -- Copy current LFSR state
                lfsr_value := lfsr_reg;

                -- Update every star
                FOR i IN 0 TO NUM_STARS-1 LOOP

                    -- Generate next random value
                    feedback_bit :=
                        lfsr_value(15) XOR
                        lfsr_value(13) XOR
                        lfsr_value(12) XOR
                        lfsr_value(10);

                    -- Shift LFSR
                    lfsr_value :=
                        lfsr_value(14 DOWNTO 0) & feedback_bit;

                    -- Check if star moved off left side
                    IF star_x(i) < CONV_STD_LOGIC_VECTOR(2, 10) THEN

                        -- Respawn at right edge
                        star_x(i) <= CONV_STD_LOGIC_VECTOR(639, 10);

                        -- Give star a new random Y position
                        star_y(i) <= '0' & lfsr_value(8 DOWNTO 0);
                    ELSE
                        
                        -- Move star left by 2 pixels
                        star_x(i) <=
                            star_x(i) -
                            CONV_STD_LOGIC_VECTOR(2, 10);
                    END IF;
                END LOOP;

                -- Save updated LFSR state
                lfsr_reg <= lfsr_value;
            END IF;
        END IF;
    END PROCESS Star_Move;
END behavior;
