library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.STD_LOGIC_ARITH.all;
use IEEE.STD_LOGIC_UNSIGNED.all;

-- ============================================================================
-- VGA_SYNC
-- Generates standard 640×480 @ 60 Hz VGA timing signals and outputs RGB pixel
-- data gated by the active-video window.
--
-- Timing overview (pixel clock = 25.175 MHz, approximated by 25 MHz):
--
--   Horizontal (per line):   800 total clocks
--     0–639   : active video  (640 pixels)
--     640–658 : front porch
--     659–755 : sync pulse (horiz_sync LOW)
--     756–799 : back porch
--
--   Vertical (per frame):    525 total lines
--     0–479   : active video  (480 lines)
--     480–492 : front porch
--     493–494 : sync pulse (vert_sync LOW)
--     495–524 : back porch
-- ============================================================================
ENTITY VGA_SYNC IS
    PORT (
        clock_25Mhz                                  : IN  STD_LOGIC; -- 25 MHz pixel clock
        red, green, blue                             : IN  STD_LOGIC; -- Pixel colour inputs from game logic
        red_out, green_out, blue_out                 : OUT STD_LOGIC; -- Colour outputs to VGA DAC (blanked outside active area)
        horiz_sync_out, vert_sync_out                : OUT STD_LOGIC; -- Sync outputs to VGA connector
        pixel_row, pixel_column                      : OUT STD_LOGIC_VECTOR(9 DOWNTO 0) -- Current active pixel coordinates
    );
END VGA_SYNC;


ARCHITECTURE a OF VGA_SYNC IS

    -- Internal sync signals built by this process, then registered to outputs
    SIGNAL horiz_sync, vert_sync           : STD_LOGIC;

    -- video_on_h: high while h_count is within the 640-pixel active window
    -- video_on_v: high while v_count is within the 480-line active window
    -- video_on:   combined gate — only high when both are active
    SIGNAL video_on, video_on_v, video_on_h : STD_LOGIC;

    -- h_count: horizontal pixel counter, 0–799
    -- v_count: vertical line counter,    0–524
    SIGNAL h_count, v_count : STD_LOGIC_VECTOR(9 DOWNTO 0);

BEGIN

    -- video_on is the AND of horizontal and vertical active-window flags.
    -- It is used to blank (force to black) all pixels outside the 640×480 area.
    video_on <= video_on_H AND video_on_V;


    PROCESS
    BEGIN
        -- All logic below is clocked on the rising edge of the 25 MHz pixel clock
        WAIT UNTIL (clock_25Mhz'EVENT) AND (clock_25Mhz = '1');

        -- =================================================================
        -- HORIZONTAL COUNTER (h_count)
        -- Counts 0 to 799 then wraps — one count per pixel clock.
        -- 800 clocks × 40 ns ≈ 31.78 µs per scan line (≈ 31.47 kHz line rate)
        -- =================================================================
        IF (h_count = 799) THEN
            h_count <= "0000000000"; -- End of line: reset counter
        ELSE
            h_count <= h_count + 1;  -- Advance one pixel
        END IF;

        -- =================================================================
        -- HORIZONTAL SYNC PULSE
        -- The VGA spec requires a negative-polarity sync pulse.
        -- horiz_sync goes LOW between h_count 659 and 755 (96 clocks ≈ 3.84 µs),
        -- which sits in the horizontal blanking interval after the active pixels.
        -- =================================================================
        IF (h_count <= 755) AND (h_count >= 659) THEN
            horiz_sync <= '0'; -- Inside sync pulse: pull LOW
        ELSE
            horiz_sync <= '1'; -- Outside sync pulse: HIGH
        END IF;

        -- =================================================================
        -- VERTICAL COUNTER (v_count)
        -- Increments once per complete scan line (every 800 h_count clocks).
        -- Counts 0 to 524 then wraps — giving 525 lines per frame (≈ 59.94 Hz).
        --
        -- The reset condition checks both v_count and h_count together so
        -- the vertical counter only resets at the correct point within a line.
        -- =================================================================
        IF (v_count >= 524) AND (h_count >= 699) THEN
            v_count <= "0000000000"; -- End of frame: reset line counter
        ELSIF (h_count = 699) THEN
            v_count <= v_count + 1;  -- End of each line: advance line counter
        END IF;

        -- =================================================================
        -- VERTICAL SYNC PULSE
        -- vert_sync goes LOW for lines 493–494 (2 lines ≈ 63.6 µs),
        -- which sits in the vertical blanking interval after all active lines.
        -- =================================================================
        IF (v_count <= 494) AND (v_count >= 493) THEN
            vert_sync <= '0'; -- Inside sync pulse: pull LOW
        ELSE
            vert_sync <= '1'; -- Outside sync pulse: HIGH
        END IF;

        -- =================================================================
        -- HORIZONTAL ACTIVE WINDOW
        -- The first 640 counts are the visible pixel columns.
        -- pixel_column is updated here so downstream logic always has the
        -- correct column index registered on the same clock edge.
        -- =================================================================
        IF (h_count <= 639) THEN
            video_on_h   <= '1';       -- We are inside the active horizontal window
            pixel_column <= h_count;   -- Export current column coordinate
        ELSE
            video_on_h <= '0';         -- Horizontal blanking: no pixel data
        END IF;

        -- =================================================================
        -- VERTICAL ACTIVE WINDOW
        -- The first 480 lines are the visible pixel rows.
        -- pixel_row is updated here for the same reason as pixel_column above.
        -- =================================================================
        IF (v_count <= 479) THEN
            video_on_v <= '1';     -- We are inside the active vertical window
            pixel_row  <= v_count; -- Export current row coordinate
        ELSE
            video_on_v <= '0';     -- Vertical blanking: no pixel data
        END IF;

        -- =================================================================
        -- OUTPUT STAGE — registered (DFF) to remove combinatorial glitches
        -- that would otherwise appear as blurry or noisy edges on screen.
        --
        -- RGB outputs are gated by video_on:
        --   - During active video: pass through the colour inputs unchanged
        --   - During blanking periods: force outputs to '0' (black)
        --
        -- Sync signals are passed through directly (no gating needed).
        -- =================================================================
        red_out        <= red   AND video_on; -- Blank red outside active area
        green_out      <= green AND video_on; -- Blank green outside active area
        blue_out       <= blue  AND video_on; -- Blank blue outside active area
        horiz_sync_out <= horiz_sync;         -- Pass horizontal sync to VGA connector
        vert_sync_out  <= vert_sync;          -- Pass vertical sync to VGA connector

    END PROCESS;
END a;