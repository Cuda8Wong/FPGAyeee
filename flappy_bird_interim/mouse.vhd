-- =============================================================================
-- MOUSE.vhd
--
-- Implements a PS/2 mouse driver using a state machine + two UARTs.
--
-- Overview of PS/2 protocol:
--   - Communication happens over two open-collector lines: CLK and DATA.
--   - The mouse drives CLK during normal operation; the host pulls CLK low
--     to inhibit the mouse before sending a command.
--   - Each byte is framed as: 1 start bit (0), 8 data bits, 1 parity bit,
--     1 stop bit (1) — transmitted LSB first, clocked on falling CLK edges.
--
-- Startup sequence:
--   1. Pull CLK low for >60 µs to stop any mouse transmission (INHIBIT_TRANS)
--   2. Send command 0xF4 "Enable Streaming" to the mouse (LOAD_COMMAND → WAIT_OUTPUT_READY)
--   3. Wait for the mouse's 0xFA acknowledgement byte (WAIT_CMD_ACK)
--   4. Receive 3-byte movement packets forever (INPUT_PACKETS)
--
-- Each 3-byte packet contains:
--   Byte 1: status flags (button bits, overflow flags, sign bits)
--   Byte 2: X (column) movement delta (signed 9-bit via sign bit in byte 1)
--   Byte 3: Y (row)    movement delta (signed 9-bit via sign bit in byte 1)
-- =============================================================================

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.all;
USE IEEE.STD_LOGIC_ARITH.all;
USE IEEE.STD_LOGIC_UNSIGNED.all;

ENTITY MOUSE IS
    PORT (
        clock_25Mhz, reset  : IN    STD_LOGIC;                     -- 25 MHz clock and active-HIGH reset
        mouse_data          : INOUT STD_LOGIC;                     -- PS/2 data line (bidirectional)
        mouse_clk           : INOUT STD_LOGIC;                     -- PS/2 clock line (bidirectional)
        left_button         : OUT   STD_LOGIC;                     -- '1' while left  button is held
        right_button        : OUT   STD_LOGIC;                     -- '1' while right button is held
        mouse_cursor_row    : OUT   STD_LOGIC_VECTOR(9 DOWNTO 0);  -- Current cursor row    (0-480)
        mouse_cursor_column : OUT   STD_LOGIC_VECTOR(9 DOWNTO 0)   -- Current cursor column (0-640)
    );
END MOUSE;


ARCHITECTURE behavior OF MOUSE IS

    -- =========================================================================
    -- State machine states for the startup + receive sequencer
    -- =========================================================================
    TYPE STATE_TYPE IS (
        INHIBIT_TRANS,      -- Pull CLK low to stop mouse; wait >60 µs
        LOAD_COMMAND,       -- Assert SEND_DATA to start the TX UART
        LOAD_COMMAND2,      -- Hold SEND_DATA for one extra cycle (pipeline fill)
        WAIT_OUTPUT_READY,  -- Wait for TX UART to finish shifting out all bits
        WAIT_CMD_ACK,       -- Wait for mouse to send 0xFA acknowledge byte
        INPUT_PACKETS       -- Receive 3-byte movement packets indefinitely
    );
    SIGNAL mouse_state : state_type;

    -- -------------------------------------------------------------------------
    -- Counter used in INHIBIT_TRANS to time the >60 µs CLK-low period.
    -- At 25 MHz, 1 clock = 40 ns.  2^12 = 4096 clocks × 40 ns ≈ 164 µs.
    -- The state exits when bits [11:10] = "11" (i.e. count ≥ 3072 = 123 µs).
    -- -------------------------------------------------------------------------
    SIGNAL inhibit_wait_count : STD_LOGIC_VECTOR(11 DOWNTO 0);

    -- -------------------------------------------------------------------------
    -- Serial byte registers
    --   CHARIN  : byte being assembled by the RX UART
    --   CHAROUT : byte to be sent by the TX UART (loaded with 0xF4 command)
    -- -------------------------------------------------------------------------
    SIGNAL CHARIN, CHAROUT : STD_LOGIC_VECTOR(7 DOWNTO 0);

    -- -------------------------------------------------------------------------
    -- Computed next cursor position (updated when a full 3-byte packet arrives)
    -- These are held separately from cursor_row/column so the current position
    -- is only committed once a complete packet has been validated.
    -- -------------------------------------------------------------------------
    SIGNAL new_cursor_row, new_cursor_column : STD_LOGIC_VECTOR(9 DOWNTO 0);
    SIGNAL cursor_row, cursor_column         : STD_LOGIC_VECTOR(9 DOWNTO 0);

    -- -------------------------------------------------------------------------
    -- Bit counters for the TX and RX UARTs
    --   INCNT  : counts received bits  (0-9, 10 data bits excluding start)
    --   OUTCNT : counts transmitted bits (0-10, 11 total frame bits)
    --   mSB_OUT: unused legacy signal
    -- -------------------------------------------------------------------------
    SIGNAL INCNT, OUTCNT, mSB_OUT : STD_LOGIC_VECTOR(3 DOWNTO 0);

    -- Counts which of the 3 bytes in a packet we are currently receiving (0-3).
    -- 0 = ACK from init command; 1 = status; 2 = X delta; 3 = Y delta.
    SIGNAL PACKET_COUNT : STD_LOGIC_VECTOR(1 DOWNTO 0);

    -- -------------------------------------------------------------------------
    -- Shift registers
    --   SHIFTIN  : 9-bit shift register for receiving bits from the mouse
    --              (the start bit is consumed before shifting begins, so 9 bits
    --               hold the 8 data bits + 1 parity bit)
    --   SHIFTOUT : 11-bit shift register for transmitting to the mouse
    --              (start + 8 data + parity + stop = 11 bits)
    -- -------------------------------------------------------------------------
    SIGNAL SHIFTIN  : STD_LOGIC_VECTOR(8 DOWNTO 0);
    SIGNAL SHIFTOUT : STD_LOGIC_VECTOR(10 DOWNTO 0);

    -- Stored bytes from each position in the 3-byte packet
    SIGNAL PACKET_CHAR1 : STD_LOGIC_VECTOR(7 DOWNTO 0); -- Byte 1: status / button flags
    SIGNAL PACKET_CHAR2 : STD_LOGIC_VECTOR(7 DOWNTO 0); -- Byte 2: X (column) movement delta
    SIGNAL PACKET_CHAR3 : STD_LOGIC_VECTOR(7 DOWNTO 0); -- Byte 3: Y (row)    movement delta

    -- -------------------------------------------------------------------------
    -- Handshake / status signals between the state machine and UARTs
    -- -------------------------------------------------------------------------
    SIGNAL MOUSE_CLK_BUF  : STD_LOGIC; -- Value driven onto CLK line when host controls it
    SIGNAL DATA_READY      : STD_LOGIC; -- (legacy, not used externally)
    SIGNAL READ_CHAR       : STD_LOGIC; -- '1' while RX UART is actively receiving a byte
    SIGNAL iready_set      : STD_LOGIC; -- Pulses '1' for one CLK after a byte is fully received
    SIGNAL break           : STD_LOGIC; -- (unused)
    SIGNAL toggle_next     : STD_LOGIC; -- (unused)
    SIGNAL output_ready    : STD_LOGIC; -- Pulses '1' when TX UART finishes sending all 11 bits
    SIGNAL send_char       : STD_LOGIC; -- '1' while TX UART is shifting out bits
    SIGNAL send_data       : STD_LOGIC; -- Strobe: '1' tells TX UART to load and start sending

    -- -------------------------------------------------------------------------
    -- Tri-state control signals for the bidirectional PS/2 lines
    --   DIR = '1' → FPGA drives the line  (output)
    --   DIR = '0' → Mouse drives the line (input / high-Z)
    -- -------------------------------------------------------------------------
    SIGNAL MOUSE_DATA_DIR  : STD_LOGIC; -- Data line direction control
    SIGNAL MOUSE_DATA_OUT  : STD_LOGIC; -- (unused legacy)
    SIGNAL MOUSE_DATA_BUF  : STD_LOGIC; -- Value driven onto DATA when FPGA controls it
    SIGNAL MOUSE_CLK_DIR   : STD_LOGIC; -- Clock line direction control

    -- -------------------------------------------------------------------------
    -- PS/2 clock filter: smooths glitches on the incoming clock line.
    -- The mouse CLK line is an open-collector signal that can be noisy.
    -- An 8-sample majority filter ensures that a '1' or '0' is only accepted
    -- if all 8 consecutive samples agree.
    -- -------------------------------------------------------------------------
    SIGNAL MOUSE_CLK_FILTER : STD_LOGIC;              -- Filtered (debounced) mouse clock
    SIGNAL filter            : STD_LOGIC_VECTOR(7 DOWNTO 0); -- Shift register of the last 8 CLK samples

    SIGNAL i : INTEGER; -- Loop variable (legacy, not used in current code)

BEGIN

    -- Wire cursor position registers out to the entity ports
    mouse_cursor_row    <= cursor_row;
    mouse_cursor_column <= cursor_column;

    -- =========================================================================
    -- PS/2 line tri-state buffers
    -- When the FPGA drives the line (DIR='1'), the buffer output is connected.
    -- When the mouse drives the line (DIR='0'), the port is set to 'Z' (high-Z)
    -- so the open-collector pull-up lets the mouse pull the line low freely.
    -- =========================================================================
    MOUSE_DATA <= 'Z'            WHEN MOUSE_DATA_DIR = '0' ELSE MOUSE_DATA_BUF;
    MOUSE_CLK  <= 'Z'            WHEN MOUSE_CLK_DIR  = '0' ELSE MOUSE_CLK_BUF;

    -- =========================================================================
    -- Main state machine: startup sequencer
    -- Controls the initialisation handshake with the mouse.
    -- =========================================================================
    PROCESS (reset, clock_25Mhz)
    BEGIN
        IF reset = '1' THEN
            mouse_state       <= INHIBIT_TRANS;
            inhibit_wait_count <= CONV_STD_LOGIC_VECTOR(0, 12);
            SEND_DATA          <= '0';

        ELSIF clock_25Mhz'EVENT AND clock_25Mhz = '1' THEN
            CASE mouse_state IS

                -- ---- Step 1: hold CLK low to inhibit mouse transmission ----
                -- Count up to ~123 µs so any in-progress mouse packet is aborted.
                -- Meanwhile pre-load CHAROUT with the F4 "Enable Streaming" command.
                WHEN INHIBIT_TRANS =>
                    inhibit_wait_count <= inhibit_wait_count + 1;
                    IF inhibit_wait_count(11 DOWNTO 10) = "11" THEN
                        mouse_state <= LOAD_COMMAND; -- Inhibit period done
                    END IF;
                    charout <= "11110100"; -- 0xF4 = Enable Streaming Mode command

                -- ---- Step 2: assert SEND_DATA to trigger the TX UART ----
                WHEN LOAD_COMMAND =>
                    SEND_DATA   <= '1';
                    mouse_state <= LOAD_COMMAND2;

                -- ---- Step 3: hold SEND_DATA for one more cycle ----
                -- (The TX UART samples SEND_DATA asynchronously; the extra cycle
                --  ensures SHIFTOUT is fully loaded before CLK is released.)
                WHEN LOAD_COMMAND2 =>
                    SEND_DATA   <= '1';
                    mouse_state <= WAIT_OUTPUT_READY;

                -- ---- Step 4: release SEND_DATA and wait for TX to finish ----
                -- OUTPUT_READY pulses '1' when the TX UART has shifted out all 11 bits.
                WHEN WAIT_OUTPUT_READY =>
                    SEND_DATA <= '0';
                    IF OUTPUT_READY = '1' THEN
                        mouse_state <= WAIT_CMD_ACK;
                    ELSE
                        mouse_state <= WAIT_OUTPUT_READY;
                    END IF;

                -- ---- Step 5: wait for mouse to send 0xFA acknowledgement ----
                -- IREADY_SET pulses '1' when the RX UART receives a complete byte.
                WHEN WAIT_CMD_ACK =>
                    SEND_DATA <= '0';
                    IF IREADY_SET = '1' THEN
                        mouse_state <= INPUT_PACKETS; -- ACK received, start receiving data
                    END IF;

                -- ---- Step 6: receive 3-byte movement packets forever ----
                -- All actual data handling is done in the RECV_UART process below.
                WHEN INPUT_PACKETS =>
                    mouse_state <= INPUT_PACKETS;

            END CASE;
        END IF;
    END PROCESS;

    -- =========================================================================
    -- Tri-state direction control: decoded from current state
    -- DATA_DIR: '1' = FPGA drives DATA (during command send), '0' = mouse drives
    -- CLK_DIR:  '1' = FPGA drives CLK  (during inhibit),     '0' = mouse drives
    -- =========================================================================
    WITH mouse_state SELECT
        MOUSE_DATA_DIR <= '0' WHEN INHIBIT_TRANS,
                          '0' WHEN LOAD_COMMAND,
                          '0' WHEN LOAD_COMMAND2,
                          '1' WHEN WAIT_OUTPUT_READY,  -- FPGA sends command byte
                          '0' WHEN WAIT_CMD_ACK,
                          '0' WHEN INPUT_PACKETS;

    WITH mouse_state SELECT
        MOUSE_CLK_DIR  <= '1' WHEN INHIBIT_TRANS,      -- FPGA holds CLK low
                          '1' WHEN LOAD_COMMAND,
                          '1' WHEN LOAD_COMMAND2,
                          '0' WHEN WAIT_OUTPUT_READY,  -- Release CLK to mouse
                          '0' WHEN WAIT_CMD_ACK,
                          '0' WHEN INPUT_PACKETS;

    -- Value driven onto CLK when FPGA is in control:
    --   '0' during inhibit (pulls CLK low to stop mouse)
    --   '1' during command send (idles high, mouse clocks the bits)
    WITH mouse_state SELECT
        MOUSE_CLK_BUF  <= '0' WHEN INHIBIT_TRANS,
                          '1' WHEN LOAD_COMMAND,
                          '1' WHEN LOAD_COMMAND2,
                          '1' WHEN WAIT_OUTPUT_READY,
                          '1' WHEN WAIT_CMD_ACK,
                          '1' WHEN INPUT_PACKETS;

    -- =========================================================================
    -- PS/2 clock glitch filter
    -- Samples the raw MOUSE_CLK line every 25 MHz clock cycle into an 8-bit
    -- shift register. Only updates MOUSE_CLK_FILTER when all 8 samples agree:
    --   "11111111" → filtered output = '1'
    --   "00000000" → filtered output = '0'
    -- Intermediate values leave MOUSE_CLK_FILTER unchanged (hysteresis).
    -- This prevents noise spikes from triggering false bit shifts.
    -- =========================================================================
    PROCESS
    BEGIN
        WAIT UNTIL clock_25Mhz'event AND clock_25Mhz = '1';
        filter(7 DOWNTO 1) <= filter(6 DOWNTO 0); -- Shift previous samples up
        filter(0)          <= MOUSE_CLK;           -- Insert newest raw sample
        IF filter = "11111111" THEN
            MOUSE_CLK_FILTER <= '1'; -- All samples high → clean '1'
        ELSIF filter = "00000000" THEN
            MOUSE_CLK_FILTER <= '0'; -- All samples low  → clean '0'
        END IF;
    END PROCESS;

    -- =========================================================================
    -- TX UART: SEND_UART
    -- Sends one byte (CHAROUT = 0xF4) to the mouse over the PS/2 DATA line.
    --
    -- The PS/2 host-to-device protocol:
    --   1. Pull DATA low (start bit) while CLK is still held low by FPGA.
    --   2. Release CLK — the mouse takes over and pulses CLK to clock in bits.
    --   3. On each falling edge of mouse CLK, shift out the next bit.
    --   4. After 10 bits (start + 8 data + parity), mouse sends an ACK bit
    --      by pulling DATA low on its 11th CLK pulse.
    --
    -- SHIFTOUT bit layout: [10]=stop(1), [9]=parity, [8:1]=data, [0]=start(0)
    -- =========================================================================
    SEND_UART : PROCESS (send_data, Mouse_clK_filter)
    BEGIN
        IF SEND_DATA = '1' THEN
            -- ---- Initialise TX UART ----
            OUTCNT       <= "0000";
            SEND_CHAR    <= '1';        -- Mark transmitter as active
            OUTPUT_READY <= '0';
            -- Load shift register: start(0) | data(8 bits) | parity | stop(1)
            SHIFTOUT(8 DOWNTO 1) <= CHAROUT;      -- Data byte in positions [8:1]
            SHIFTOUT(0)          <= '0';           -- Start bit
            -- Odd parity: '1' if even number of '1's in data byte
            SHIFTOUT(9) <= NOT (charout(7) XOR charout(6) XOR charout(5) XOR