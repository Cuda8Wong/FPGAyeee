-- ============================================================
-- DE0-CV Top-Level Entity
-- Connects bouncy_ball → VGA_SYNC → board pins
-- Just enough to see output on the VGA display for the interim.
-- ============================================================
LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.STD_LOGIC_ARITH.ALL;
USE IEEE.STD_LOGIC_UNSIGNED.ALL;

ENTITY sus_bird IS
    PORT (
        -- 50 MHz board clock
        CLOCK_50    : IN  STD_LOGIC;

        -- Push-buttons (active-low on DE0-CV)
        KEY         : IN  STD_LOGIC_VECTOR(3 DOWNTO 0);

        -- VGA outputs  (4 bits per channel on DE0-CV)
        VGA_R       : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
        VGA_G       : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
        VGA_B       : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
        VGA_HS      : OUT STD_LOGIC;
        VGA_VS      : OUT STD_LOGIC
    );
END sus_bird;

ARCHITECTURE behavior OF sus_bird IS

    -- --------------------------------------------------------
    -- Internal signals
    -- --------------------------------------------------------
    SIGNAL clock_25MHz              : STD_LOGIC := '0';

    SIGNAL red_sig, green_sig,
           blue_sig                 : STD_LOGIC;          -- ball → sync
    SIGNAL red_out, green_out,
           blue_out                 : STD_LOGIC;          -- sync → VGA pins
    SIGNAL vert_sync_sig            : STD_LOGIC;
    SIGNAL pixel_row, pixel_column  : STD_LOGIC_VECTOR(9 DOWNTO 0);

    -- --------------------------------------------------------
    -- Component declarations (must match the source files)
    -- --------------------------------------------------------
    COMPONENT bouncy_ball
        PORT (
            pb1, pb2, clk, vert_sync : IN  STD_LOGIC;
            pixel_row, pixel_column  : IN  STD_LOGIC_VECTOR(9 DOWNTO 0);
            red, green, blue         : OUT STD_LOGIC
        );
    END COMPONENT;

    COMPONENT VGA_SYNC
        PORT (
            clock_25Mhz, red, green, blue           : IN  STD_LOGIC;
            red_out, green_out, blue_out,
            horiz_sync_out, vert_sync_out            : OUT STD_LOGIC;
            pixel_row, pixel_column                  : OUT STD_LOGIC_VECTOR(9 DOWNTO 0)
        );
    END COMPONENT;

BEGIN

    -- --------------------------------------------------------
    -- Clock divider  50 MHz → 25 MHz
    -- (Toggle every rising edge = divide by 2)
    -- --------------------------------------------------------
    clk_div : PROCESS (CLOCK_50)
    BEGIN
        IF rising_edge(CLOCK_50) THEN
            clock_25MHz <= NOT clock_25MHz;
        END IF;
    END PROCESS clk_div;

    -- --------------------------------------------------------
    -- VGA sync generator
    -- --------------------------------------------------------
    u_vga : VGA_SYNC
        PORT MAP (
            clock_25Mhz    => clock_25MHz,
            red            => red_sig,
            green          => green_sig,
            blue           => blue_sig,
            red_out        => red_out,
            green_out      => green_out,
            blue_out       => blue_out,
            horiz_sync_out => VGA_HS,
            vert_sync_out  => vert_sync_sig,
            pixel_row      => pixel_row,
            pixel_column   => pixel_column
        );

    -- Feed vert_sync back to the ball and out to the board pin
    VGA_VS <= vert_sync_sig;

    -- --------------------------------------------------------
    -- Bouncy ball
    -- KEY is active-low; invert so '1' = button pressed
    -- --------------------------------------------------------
    u_ball : bouncy_ball
        PORT MAP (
            pb1          => NOT KEY(0),
            pb2          => NOT KEY(1),
            clk          => clock_25MHz,
            vert_sync    => vert_sync_sig,
            pixel_row    => pixel_row,
            pixel_column => pixel_column,
            red          => red_sig,
            green        => green_sig,
            blue         => blue_sig
        );

    -- --------------------------------------------------------
    -- Drive all 4 colour bits from the single-bit sync output
    -- (all bits same → full-brightness colour when on)
    -- --------------------------------------------------------
    VGA_R <= (OTHERS => red_out);
    VGA_G <= (OTHERS => green_out);
    VGA_B <= (OTHERS => blue_out);

END behavior;