-- videoPi - calexo programs for LZX Videomancer
-- Copyright (C) 2026 calexo
-- File: scrambler.vhd - Horizontal Line Scrambler with bad-TV glitch layer
-- License: GNU General Public License v3.0
-- https://github.com/calexocreative/videoPi
--
-- This file is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program. If not, see <https://www.gnu.org/licenses/>.
--
-- Program Name:
--   Scrambler
--
-- Author:
--   calexo
--
-- Overview:
--   Randomizes each incoming scanline's horizontal position, plus a bad-TV
--   glitch layer (static noise, chroma smear, polarity invert, dropout burst)
--   keyed by a luma matte.
--
--   - Scramble: every scanline is re-rolled a fresh horizontal shift (0 to
--     ~1023 samples) at the start of the line. The WHOLE video_stream record
--     (Y, U, V, avid, hsync_n, vsync_n, field_n) is delayed together through
--     one shared BRAM delay line, so pixel data and sync timing always stay
--     perfectly aligned -- the "wobble" IS the effect, not a bug to correct.
--   - Bad-TV bonus layer: static noise ("Snow"), a one-pole chroma low-pass
--     ("Smear"), and a polarity invert are all gated by a luma matte -- the
--     fader sets a luma threshold, and only pixels of the (already
--     scrambled) picture on the bright side of that threshold get the bonus
--     glitch treatment.
--   - Dropout: an independent whole-line "loss of tracking" burst that
--     replaces a randomly chosen line with noise/neutral chroma, overriding
--     everything else for that line.
--
-- Architecture / Pipeline:
--   Stage A (control, every clock): a free-running lfsr16 is the entropy
--     source. On every rising edge of the INCOMING data_in.hsync_n, new
--     per-line parameters are rolled: the horizontal shift amount (scaled by
--     the Scramble knob and biased by a slow free-running "Wobble" ramp), a
--     "Stutter" chance to keep the previous line's shift instead of a fresh
--     one, and a "Dropout" chance for this line.
--   Stage B (BRAM, variable latency): the packed 34-bit video_stream record
--     is delayed by the SDK's variable_delay_u module, using the per-line
--     shift as the runtime-programmable delay. variable_delay_u's own
--     latency is (programmed delay + 2) cycles; because the delay varies
--     line to line, so does the total pipeline latency -- by design.
--   Stage C (1 fixed cycle): the luma matte gate is computed from the
--     delayed luma, then Snow / Invert / Smear are applied (each gated by
--     its own toggle AND the matte), and finally Dropout is applied last,
--     overriding everything for lines where it triggers. Sync signals ride
--     through this same register stage unmodified, so they never drift
--     relative to the pixel data they describe.
--
--   Total latency: (per-line random shift + 2 [variable_delay_u] + 1
--   [effects stage]) clock cycles. This is intentionally NOT constant --
--   that's what makes the picture wobble horizontally line to line.
--
-- Register Map (see docs/abi-format.md in the SDK for the full ABI):
--   registers_in(0) rotary_potentiometer_1  "Scramble" - max horizontal shift
--   registers_in(1) rotary_potentiometer_2  "Stutter"  - chance to repeat prior line's shift
--   registers_in(2) rotary_potentiometer_3  "Snow"     - static noise amount
--   registers_in(3) rotary_potentiometer_4  "Smear"    - chroma low-pass strength
--   registers_in(4) rotary_potentiometer_5  "Dropout"  - per-line dropout-burst chance
--   registers_in(5) rotary_potentiometer_6  "Wobble"   - slow drift bias on the shift
--   registers_in(6) bit 0  toggle_switch_7  "Scramble" enable
--   registers_in(6) bit 1  toggle_switch_8  "Snow" enable
--   registers_in(6) bit 2  toggle_switch_9  "Smear" enable
--   registers_in(6) bit 3  toggle_switch_10 "Invert" enable
--   registers_in(6) bit 4  toggle_switch_11 "Dropout" enable
--   registers_in(7) linear_potentiometer_12 "Luma Matte" - key threshold (0-1023)
--
-- Submodules (from the SDK's fpga/common/rtl/dsp library):
--   lfsr16            - free-running entropy source
--   edge_detector     - once-per-line trigger from data_in.hsync_n
--   variable_delay_u  - the shared BRAM delay line driving the scramble
--   variable_filter_s (x2) - one-pole chroma low-pass for the Smear layer
--
-- Resource note:
--   The delay line is sized G_WIDTH=34 x G_DEPTH=11 (2048 x 34 bits, ~17
--   BRAMs worth of raw bits before packing overhead). Check the build's
--   reported BRAM usage against the iCE40 HX4K's 32-block budget; shrink
--   C_DELAY_DEPTH (fewer max-shift samples) if it doesn't fit.
--
-- Use Cases:
--   Horizontal glitch / tracking-error / bad-VHS look for live video.

--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.video_timing_pkg.all;
use work.video_stream_pkg.all;
use work.core_pkg.all;
use work.all;

architecture scrambler of program_top is

  ------------------------------------------------------------------------------
  -- Helper: clamp a signed value into the unsigned 10-bit video range [0,1023]
  ------------------------------------------------------------------------------
  function clamp10(x : signed) return unsigned is
  begin
    if x < 0 then
      return to_unsigned(0, 10);
    elsif x > 1023 then
      return to_unsigned(1023, 10);
    else
      return resize(unsigned(x), 10);
    end if;
  end function;

  ------------------------------------------------------------------------------
  -- Control registers
  ------------------------------------------------------------------------------
  signal s_scramble_amt : unsigned(9 downto 0);
  signal s_stutter_amt  : unsigned(9 downto 0);
  signal s_snow_amt     : unsigned(9 downto 0);
  signal s_smear_amt    : unsigned(9 downto 0);
  signal s_dropout_amt  : unsigned(9 downto 0);
  signal s_wobble_amt   : unsigned(9 downto 0);
  signal s_luma_matte   : unsigned(9 downto 0);

  signal s_en_scramble  : std_logic;
  signal s_en_snow      : std_logic;
  signal s_en_smear     : std_logic;
  signal s_en_invert    : std_logic;
  signal s_en_dropout   : std_logic;

  ------------------------------------------------------------------------------
  -- Entropy source
  ------------------------------------------------------------------------------
  signal s_lfsr_q : std_logic_vector(15 downto 0);

  ------------------------------------------------------------------------------
  -- Once-per-line control (Stage A)
  ------------------------------------------------------------------------------
  signal s_hsync_rising : std_logic;
  signal s_wobble_ctr   : unsigned(19 downto 0) := (others => '0');
  signal s_line_shift   : unsigned(10 downto 0) := (others => '0');
  signal s_line_dropout : std_logic             := '0';

  ------------------------------------------------------------------------------
  -- Packed video stream + shared delay line (Stage B)
  ------------------------------------------------------------------------------
  constant C_PACK_WIDTH  : integer := 34; -- y(10)+u(10)+v(10)+avid(1)+hsync_n(1)+vsync_n(1)+field_n(1)
  constant C_DELAY_DEPTH : integer := 11; -- 2048-sample circular buffer

  signal s_pack_in  : unsigned(C_PACK_WIDTH - 1 downto 0);
  signal s_pack_out : unsigned(C_PACK_WIDTH - 1 downto 0);
  signal s_delay_valid : std_logic;

  signal s_y0, s_u0, s_v0 : std_logic_vector(9 downto 0);
  signal s_avid0, s_hsync0, s_vsync0, s_field0 : std_logic;

  ------------------------------------------------------------------------------
  -- Chroma smear filter (Stage C input)
  ------------------------------------------------------------------------------
  signal s_smear_cutoff : unsigned(7 downto 0);
  signal s_u_lpf, s_v_lpf : signed(10 downto 0);

begin

  ------------------------------------------------------------------------------
  -- Register extraction
  ------------------------------------------------------------------------------
  s_scramble_amt <= unsigned(registers_in(0));
  s_stutter_amt  <= unsigned(registers_in(1));
  s_snow_amt     <= unsigned(registers_in(2));
  s_smear_amt    <= unsigned(registers_in(3));
  s_dropout_amt  <= unsigned(registers_in(4));
  s_wobble_amt   <= unsigned(registers_in(5));
  s_luma_matte   <= unsigned(registers_in(7));

  s_en_scramble <= registers_in(6)(0);
  s_en_snow     <= registers_in(6)(1);
  s_en_smear    <= registers_in(6)(2);
  s_en_invert   <= registers_in(6)(3);
  s_en_dropout  <= registers_in(6)(4);

  s_smear_cutoff <= s_smear_amt(9 downto 2); -- top 8 bits of the knob -> 0-255 filter cutoff

  ------------------------------------------------------------------------------
  -- Free-running entropy source (never reset -- power-on initial value only)
  ------------------------------------------------------------------------------
  entropy_lfsr : entity work.lfsr16
    port map (
      clk    => clk,
      enable => '1',
      seed   => x"ACE1",
      load   => '0',
      q      => s_lfsr_q
    );

  ------------------------------------------------------------------------------
  -- Once-per-line trigger from the incoming (pre-scramble) hsync
  ------------------------------------------------------------------------------
  hsync_edge : entity work.edge_detector
    port map (
      clk     => clk,
      a       => data_in.hsync_n,
      b       => open,
      rising  => s_hsync_rising,
      falling => open
    );

  ------------------------------------------------------------------------------
  -- Stage A: reroll the per-line horizontal shift and dropout flag
  ------------------------------------------------------------------------------
  p_line_control : process(clk)
    variable v_hold_roll     : unsigned(9 downto 0);
    variable v_dropout_roll  : unsigned(9 downto 0);
    variable v_raw_shift     : unsigned(9 downto 0);
    variable v_scaled        : unsigned(19 downto 0);
    variable v_wobble_raw    : unsigned(9 downto 0);
    variable v_wobble_scaled : unsigned(19 downto 0);
    variable v_wobble_bias   : unsigned(9 downto 0);
    variable v_new_shift     : unsigned(10 downto 0);
  begin
    if rising_edge(clk) then
      -- Slow free-running ramp used to bias the shift over time ("Wobble")
      s_wobble_ctr <= s_wobble_ctr + 1;

      if s_hsync_rising = '1' then
        if s_en_scramble = '0' then
          s_line_shift <= (others => '0');
        else
          v_hold_roll := unsigned(s_lfsr_q(9 downto 0));
          if v_hold_roll >= s_stutter_amt then
            -- Fresh roll for this line
            v_raw_shift     := unsigned(s_lfsr_q(15 downto 6));
            v_scaled        := v_raw_shift * s_scramble_amt;
            v_wobble_raw    := s_wobble_ctr(19 downto 10);
            v_wobble_scaled := v_wobble_raw * s_wobble_amt;
            v_wobble_bias   := v_wobble_scaled(19 downto 10);
            v_new_shift     := resize(v_scaled(19 downto 10), 11) + resize(v_wobble_bias, 11);
            s_line_shift <= v_new_shift;
          end if;
          -- else: "Stutter" -- keep the previous line's shift (stuck-tracking glitch)
        end if;

        if s_en_dropout = '1' then
          v_dropout_roll := unsigned(s_lfsr_q(12 downto 3));
          if v_dropout_roll < s_dropout_amt then
            s_line_dropout <= '1';
          else
            s_line_dropout <= '0';
          end if;
        else
          s_line_dropout <= '0';
        end if;
      end if;
    end if;
  end process p_line_control;

  ------------------------------------------------------------------------------
  -- Stage B: pack the whole video_stream record and run it through the
  -- shared variable-delay BRAM line. Delaying Y/U/V and every sync bit
  -- together keeps them perfectly aligned regardless of the (line-varying)
  -- delay amount.
  ------------------------------------------------------------------------------
  s_pack_in <= unsigned(data_in.y & data_in.u & data_in.v
                        & data_in.avid & data_in.hsync_n & data_in.vsync_n & data_in.field_n);

  delay_line : entity work.variable_delay_u
    generic map (
      G_WIDTH => C_PACK_WIDTH,
      G_DEPTH => C_DELAY_DEPTH
    )
    port map (
      clk    => clk,
      enable => '1',
      delay  => s_line_shift,
      a      => s_pack_in,
      result => s_pack_out,
      valid  => s_delay_valid
    );

  s_y0     <= std_logic_vector(s_pack_out(33 downto 24));
  s_u0     <= std_logic_vector(s_pack_out(23 downto 14));
  s_v0     <= std_logic_vector(s_pack_out(13 downto 4));
  s_avid0  <= s_pack_out(3);
  s_hsync0 <= s_pack_out(2);
  s_vsync0 <= s_pack_out(1);
  s_field0 <= s_pack_out(0);

  ------------------------------------------------------------------------------
  -- Chroma smear: one-pole low-pass per channel. The knob sets the filter's
  -- cutoff (deeper cutoff = slower tracking = more smear); applied to the
  -- output only where Smear is enabled and the luma matte gates it in.
  ------------------------------------------------------------------------------
  u_smear_filter : entity work.variable_filter_s
    generic map (G_WIDTH => 11)
    port map (
      clk       => clk,
      enable    => '1',
      a         => signed(resize(unsigned(s_u0), 11)),
      cutoff    => s_smear_cutoff,
      low_pass  => s_u_lpf,
      high_pass => open,
      valid     => open
    );

  v_smear_filter : entity work.variable_filter_s
    generic map (G_WIDTH => 11)
    port map (
      clk       => clk,
      enable    => '1',
      a         => signed(resize(unsigned(s_v0), 11)),
      cutoff    => s_smear_cutoff,
      low_pass  => s_v_lpf,
      high_pass => open,
      valid     => open
    );

  ------------------------------------------------------------------------------
  -- Stage C: luma matte + bad-TV glitch layer + dropout override.
  -- Fixed 1-cycle latency; sync signals ride through unmodified so they
  -- never drift relative to the pixel data they describe.
  ------------------------------------------------------------------------------
  p_effects : process(clk)
    variable v_y, v_u, v_v   : unsigned(9 downto 0);
    variable v_matte         : std_logic;
    variable v_noise9        : signed(9 downto 0);
    variable v_noise_prod    : signed(20 downto 0);
    variable v_noise_scaled  : signed(10 downto 0);
  begin
    if rising_edge(clk) then
      v_y := unsigned(s_y0);
      v_u := unsigned(s_u0);
      v_v := unsigned(s_v0);

      -- Luma matte: is this (already-scrambled) pixel above the fader's threshold?
      if v_y >= s_luma_matte then
        v_matte := '1';
      else
        v_matte := '0';
      end if;

      -- Snow: additive static noise on Y, lighter speckle on U/V
      if s_en_snow = '1' and v_matte = '1' then
        v_noise9       := signed(std_logic_vector(unsigned(s_lfsr_q(9 downto 0)) - to_unsigned(512, 10)));
        v_noise_prod   := v_noise9 * signed(resize(s_snow_amt, 11));
        v_noise_scaled := resize(shift_right(v_noise_prod, 10), 11);

        v_y := clamp10(resize(signed(resize(v_y, 11)), 12) + resize(v_noise_scaled, 12));
        v_u := clamp10(resize(signed(resize(v_u, 11)), 12) + resize(shift_right(v_noise_scaled, 2), 12));
        v_v := clamp10(resize(signed(resize(v_v, 11)), 12) + resize(shift_right(v_noise_scaled, 2), 12));
      end if;

      -- Invert: bonus polarity-flip glitch
      if s_en_invert = '1' and v_matte = '1' then
        v_y := to_unsigned(1023, 10) - v_y;
        v_u := to_unsigned(1023, 10) - v_u;
        v_v := to_unsigned(1023, 10) - v_v;
      end if;

      -- Smear: replace chroma with the low-pass filtered version
      if s_en_smear = '1' and v_matte = '1' then
        v_u := clamp10(s_u_lpf);
        v_v := clamp10(s_v_lpf);
      end if;

      -- Dropout: whole-line static burst, overrides everything above
      if s_en_dropout = '1' and s_line_dropout = '1' then
        v_y := unsigned(s_lfsr_q(9 downto 0));
        v_u := to_unsigned(512, 10);
        v_v := to_unsigned(512, 10);
      end if;

      data_out.y       <= std_logic_vector(v_y);
      data_out.u       <= std_logic_vector(v_u);
      data_out.v       <= std_logic_vector(v_v);
      data_out.avid    <= s_avid0;
      data_out.hsync_n <= s_hsync0;
      data_out.vsync_n <= s_vsync0;
      data_out.field_n <= s_field0;
    end if;
  end process p_effects;

end architecture scrambler;
