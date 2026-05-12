-- =============================================================================
-- star_field.vhd
-- Scrolling starfield: 40 stars, 1 px each, move left 2 px/frame (~60 Hz).
-- 16-bit LFSR for pseudo-random Y on star respawn.
-- Freezes when paused = '1'.
-- =============================================================================
LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.STD_LOGIC_ARITH.ALL;
USE IEEE.STD_LOGIC_UNSIGNED.ALL;

ENTITY star_field IS
    PORT (
        clk_25      : IN  STD_LOGIC;
        vert_sync   : IN  STD_LOGIC;
        reset       : IN  STD_LOGIC;
        paused      : IN  STD_LOGIC;
        pixel_row   : IN  STD_LOGIC_VECTOR(9 DOWNTO 0);
        pixel_col   : IN  STD_LOGIC_VECTOR(9 DOWNTO 0);
        star_on     : OUT STD_LOGIC
    );
END star_field;

ARCHITECTURE behavior OF star_field IS

    CONSTANT NUM_STARS : INTEGER := 200;
    TYPE pos_array IS ARRAY(0 TO NUM_STARS-1) OF STD_LOGIC_VECTOR(9 DOWNTO 0);
    SIGNAL star_x   : pos_array;
    SIGNAL star_y   : pos_array;
    SIGNAL lfsr_reg : STD_LOGIC_VECTOR(15 DOWNTO 0) := "1010110011010101";

BEGIN

    -- -------------------------------------------------------------------------
    -- Display: check current pixel against all star positions
    -- -------------------------------------------------------------------------
    Star_Display : PROCESS(pixel_row, pixel_col, star_x, star_y)
        VARIABLE hit : STD_LOGIC;
    BEGIN
        hit := '0';
        FOR i IN 0 TO NUM_STARS-1 LOOP
            IF pixel_col = star_x(i) AND pixel_row = star_y(i) THEN
                hit := '1';
            END IF;
        END LOOP;
        star_on <= hit;
    END PROCESS Star_Display;

    -- -------------------------------------------------------------------------
    -- Movement: ~60 Hz on vert_sync rising edge
    -- -------------------------------------------------------------------------
    Star_Move : PROCESS(vert_sync, reset)
        VARIABLE lv : STD_LOGIC_VECTOR(15 DOWNTO 0);
        VARIABLE fb : STD_LOGIC;
    BEGIN
        IF reset = '1' THEN
            lv := "1010110011010101";
            FOR i IN 0 TO NUM_STARS-1 LOOP
                fb := lv(15) XOR lv(13) XOR lv(12) XOR lv(10);
                lv := lv(14 DOWNTO 0) & fb;
                star_x(i) <= lv(9 DOWNTO 0);
                fb := lv(15) XOR lv(13) XOR lv(12) XOR lv(10);
                lv := lv(14 DOWNTO 0) & fb;
                star_y(i) <= '0' & lv(8 DOWNTO 0);
            END LOOP;
            lfsr_reg <= lv;

        ELSIF rising_edge(vert_sync) THEN
            IF paused = '0' THEN
                lv := lfsr_reg;
                FOR i IN 0 TO NUM_STARS-1 LOOP
                    fb := lv(15) XOR lv(13) XOR lv(12) XOR lv(10);
                    lv := lv(14 DOWNTO 0) & fb;
                    IF star_x(i) < CONV_STD_LOGIC_VECTOR(2, 10) THEN
                        star_x(i) <= CONV_STD_LOGIC_VECTOR(639, 10);
                        star_y(i) <= '0' & lv(8 DOWNTO 0);
                    ELSE
                        star_x(i) <= star_x(i) - CONV_STD_LOGIC_VECTOR(2, 10);
                    END IF;
                END LOOP;
                lfsr_reg <= lv;
            END IF;
        END IF;
    END PROCESS Star_Move;

END behavior;