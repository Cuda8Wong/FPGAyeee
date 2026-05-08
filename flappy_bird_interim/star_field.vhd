-- =============================================================================
-- star_field.vhd
-- Manages 200 single-pixel stars that scroll right-to-left across the screen.
--
-- Each frame (vert_sync, ~60 Hz) every star moves 2 pixels left.
-- When a star's X drops below 2 it wraps to X=639 with a new pseudo-random Y.
-- A 16-bit Galois LFSR (x^16 + x^14 + x^13 + x^11 + 1) generates the random Y.
-- Stars freeze while the game is paused.
--
-- star_on is a combinatorial pixel-match output: '1' when the beam is currently
-- drawing a pixel that exactly coincides with any star's stored (X, Y) position.
-- =============================================================================

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.STD_LOGIC_ARITH.ALL;
USE IEEE.STD_LOGIC_UNSIGNED.ALL;

ENTITY star_field IS
    PORT (
        vert_sync    : IN  STD_LOGIC;                     -- ~60 Hz frame pulse
        reset        : IN  STD_LOGIC;                     -- Active-HIGH: scatter stars randomly
        paused       : IN  STD_LOGIC;                     -- '1' = freeze all star positions
        pixel_row    : IN  STD_LOGIC_VECTOR(9 DOWNTO 0);  -- Current scan row   from VGA_SYNC
        pixel_column : IN  STD_LOGIC_VECTOR(9 DOWNTO 0);  -- Current scan column from VGA_SYNC
        star_on      : OUT STD_LOGIC                      -- '1' = beam is on a star pixel
    );
END star_field;

ARCHITECTURE behavior OF star_field IS

    CONSTANT NUM_STARS : INTEGER := 200; -- Total number of stars on screen

    -- Arrays storing the (column, row) screen position of every star
    TYPE pos_array IS ARRAY(0 TO NUM_STARS-1) OF STD_LOGIC_VECTOR(9 DOWNTO 0);
    SIGNAL star_x   : pos_array; -- star_x(i) = column of star i
    SIGNAL star_y   : pos_array; -- star_y(i) = row    of star i

    -- 16-bit LFSR state, seeded with a non-zero constant to ensure it never locks
    SIGNAL lfsr_reg : STD_LOGIC_VECTOR(15 DOWNTO 0) := "1010110011010101";

BEGIN

    -- =========================================================================
    -- Star display: combinatorial pixel-match
    -- Runs every time the beam position or any star position changes.
    -- Walks through all 200 stars and sets star_on if any star sits exactly
    -- on the current pixel.  Uses a local variable so the loop resolves to a
    -- single '1'/'0' output rather than 200 concurrent driver conflicts.
    -- =========================================================================
    Star_Display : PROCESS(pixel_row, pixel_column, star_x, star_y)
        VARIABLE hit : STD_LOGIC;
    BEGIN
        hit := '0';
        FOR i IN 0 TO NUM_STARS-1 LOOP
            -- star_x stores the column; star_y stores the row
            IF pixel_column = star_x(i) AND pixel_row = star_y(i) THEN
                hit := '1';
            END IF;
        END LOOP;
        star_on <= hit;
    END PROCESS Star_Display;

    -- =========================================================================
    -- Star movement: triggered on vert_sync rising edge (~60 Hz)
    --
    -- On reset: seeds the LFSR and scatters all stars to pseudo-random
    --           initial positions spread across the screen.
    --
    -- Each frame (not paused):
    --   1. Load the saved LFSR state into a local variable for fast iteration.
    --   2. For each star:
    --        a. Advance the LFSR by one step (feedback = XOR of taps 15,13,12,10).
    --        b. If the star has scrolled off the left edge (x < 2):
    --             wrap it to the right edge (x = 639) with a new random Y.
    --        c. Otherwise: move it 2 pixels to the left.
    --   3. Save the updated LFSR state back to the register for next frame.
    -- =========================================================================
    Star_Move : PROCESS(vert_sync, reset)
        VARIABLE lv : STD_LOGIC_VECTOR(15 DOWNTO 0); -- Working copy of LFSR state
        VARIABLE fb : STD_LOGIC;                      -- LFSR feedback bit
    BEGIN
        IF reset = '1' THEN
            -- Seed LFSR and give every star a random starting position
            lv := "1010110011010101";
            FOR i IN 0 TO NUM_STARS-1 LOOP
                -- One LFSR step → random X (use all 10 bits: 0-1023, wraps on screen)
                fb        := lv(15) XOR lv(13) XOR lv(12) XOR lv(10);
                lv        := lv(14 DOWNTO 0) & fb;
                star_x(i) <= lv(9 DOWNTO 0);
                -- Second LFSR step → random Y (9 bits: 0-511, clamps to visible rows)
                fb        := lv(15) XOR lv(13) XOR lv(12) XOR lv(10);
                lv        := lv(14 DOWNTO 0) & fb;
                star_y(i) <= '0' & lv(8 DOWNTO 0); -- MSB forced 0 → rows 0-479 only
            END LOOP;
            lfsr_reg <= lv; -- Persist final LFSR state

        ELSIF rising_edge(vert_sync) THEN
            IF paused = '0' THEN
                lv := lfsr_reg; -- Load saved LFSR state for this frame's updates
                FOR i IN 0 TO NUM_STARS-1 LOOP
                    -- Advance LFSR one step to generate the next pseudo-random value
                    fb := lv(15) XOR lv(13) XOR lv(12) XOR lv(10);
                    lv := lv(14 DOWNTO 0) & fb;

                    IF star_x(i) < CONV_STD_LOGIC_VECTOR(2, 10) THEN
                        -- Star has scrolled off the left edge → wrap to right with new Y
                        star_x(i) <= CONV_STD_LOGIC_VECTOR(639, 10);
                        star_y(i) <= '0' & lv(8 DOWNTO 0); -- New random row
                    ELSE
                        -- Normal frame: move star 2 pixels to the left
                        star_x(i) <= star_x(i) - CONV_STD_LOGIC_VECTOR(2, 10);
                    END IF;
                END LOOP;
                lfsr_reg <= lv; -- Save LFSR state for next frame
            END IF;
        END IF;
    END PROCESS Star_Move;

END behavior;