LIBRARY ieee;
USE ieee.std_logic_1164.all;
USE IEEE.STD_LOGIC_ARITH.all;
USE IEEE.STD_LOGIC_UNSIGNED.all;

-- Altera megafunction library needed to instantiate altsyncram (the on-chip ROM block)
LIBRARY altera_mf;
USE altera_mf.all;

-- ============================================================================
-- char_rom
-- Looks up a single pixel from a character font stored in on-chip ROM.
--
-- How it works:
--   The ROM holds 64 characters (addresses 0-63), each 8 rows tall.
--   Every row is stored as 8 bits — one bit per pixel column.
--   To find a pixel:
--     1. Concatenate character_address (6 bits) + font_row (3 bits)
--        to form a 9-bit ROM address → selects one 8-bit row of the character.
--     2. Index into that byte using font_col to extract the single pixel bit.
-- ============================================================================
ENTITY char_rom IS
    PORT (
        character_address : IN  STD_LOGIC_VECTOR(5 DOWNTO 0); -- Which character (0-63)
        font_row          : IN  STD_LOGIC_VECTOR(2 DOWNTO 0); -- Which row within the char (0-7)
        font_col          : IN  STD_LOGIC_VECTOR(2 DOWNTO 0); -- Which column within the row (0-7)
        clock             : IN  STD_LOGIC;                     -- 25 MHz pixel clock
        rom_mux_output    : OUT STD_LOGIC                      -- Single pixel: '1'=lit, '0'=dark
    );
END char_rom;


ARCHITECTURE SYN OF char_rom IS

    -- rom_data holds the 8-bit row fetched from the ROM (one bit per pixel column)
    SIGNAL rom_data    : STD_LOGIC_VECTOR(7 DOWNTO 0);

    -- rom_address is the 9-bit address sent to the ROM = {character_address, font_row}
    SIGNAL rom_address : STD_LOGIC_VECTOR(8 DOWNTO 0);

    -- -------------------------------------------------------------------------
    -- altsyncram: Altera megafunction for synchronous single-port ROM.
    -- The actual font pixel data is loaded at synthesis time from the .mif file.
    -- -------------------------------------------------------------------------
    COMPONENT altsyncram
        GENERIC (
            address_aclr_a          : STRING;  -- Async clear on address register (unused)
            clock_enable_input_a    : STRING;  -- Clock-enable mode for input registers
            clock_enable_output_a   : STRING;  -- Clock-enable mode for output registers
            init_file               : STRING;  -- Memory Initialisation File with font bitmap data
            intended_device_family  : STRING;  -- Target FPGA family (affects RAM block choice)
            lpm_hint                : STRING;  -- Extra options (runtime modification disabled)
            lpm_type                : STRING;  -- Identifies this as an altsyncram instance
            numwords_a              : NATURAL; -- Total number of addressable words (512 = 64 chars × 8 rows)
            operation_mode          : STRING;  -- "ROM" = read-only, no write port
            outdata_aclr_a          : STRING;  -- Async clear on output register (unused)
            outdata_reg_a           : STRING;  -- "UNREGISTERED" = output combinatorially driven (no extra cycle)
            widthad_a               : NATURAL; -- Address bus width (9 bits → 512 locations)
            width_a                 : NATURAL; -- Data bus width (8 bits per row)
            width_byteena_a         : NATURAL  -- Byte-enable width (1 = not used)
        );
        PORT (
            clock0    : IN  STD_LOGIC;                     -- Read clock
            address_a : IN  STD_LOGIC_VECTOR(8 DOWNTO 0); -- ROM address input
            q_a       : OUT STD_LOGIC_VECTOR(7 DOWNTO 0)  -- ROM data output (one font row)
        );
    END COMPONENT;

BEGIN

    -- -------------------------------------------------------------------------
    -- Instantiate the synchronous ROM with the font bitmap (.mif) file.
    -- All generic settings match the Quartus-generated defaults for a 512×8 ROM
    -- on a Cyclone III/IV device.
    -- -------------------------------------------------------------------------
    altsyncram_component : altsyncram
        GENERIC MAP (
            address_aclr_a          => "NONE",          -- No async clear on address
            clock_enable_input_a    => "BYPASS",        -- Always enabled (no CE pin needed)
            clock_enable_output_a   => "BYPASS",        -- Always enabled
            init_file               => "tcgrom.mif",    -- Font data file (64 chars, 8 rows each)
            intended_device_family  => "Cyclone III",
            lpm_hint                => "ENABLE_RUNTIME_MOD=NO", -- Prevent in-system memory editing
            lpm_type                => "altsyncram",
            numwords_a              => 512,             -- 64 characters × 8 rows = 512 words
            operation_mode          => "ROM",           -- Read-only memory
            outdata_aclr_a          => "NONE",
            outdata_reg_a           => "UNREGISTERED",  -- No output pipeline register
            widthad_a               => 9,               -- 9-bit address (2^9 = 512)
            width_a                 => 8,               -- 8-bit wide data (one pixel row)
            width_byteena_a         => 1
        )
        PORT MAP (
            clock0    => clock,       -- Clocked on 25 MHz pixel clock
            address_a => rom_address, -- 9-bit address from char + row
            q_a       => rom_data     -- 8-bit row bitmap output
        );

    -- -------------------------------------------------------------------------
    -- Build the 9-bit ROM address by concatenating:
    --   character_address (bits 8..3) — selects which character (0-63)
    --   font_row          (bits 2..0) — selects which of the 8 rows within that char
    -- Each character therefore occupies 8 consecutive ROM locations.
    -- -------------------------------------------------------------------------
    rom_address <= character_address & font_row;

    -- -------------------------------------------------------------------------
    -- Extract a single pixel bit from the 8-bit row returned by the ROM.
    --
    -- font_col ranges 0-7, where 0 = leftmost pixel.
    -- The ROM stores pixels with bit 7 = leftmost, bit 0 = rightmost,
    -- so we invert font_col to map column 0 → bit 7, column 7 → bit 0.
    --
    -- CONV_INTEGER converts the inverted 3-bit column index to an integer
    -- so it can be used as a dynamic bit-select index into rom_data.
    -- -------------------------------------------------------------------------
    rom_mux_output <= rom_data(CONV_INTEGER(NOT font_col(2 DOWNTO 0)));

END SYN;