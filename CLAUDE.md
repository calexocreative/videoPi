# CLAUDE.md

Guidance for AI assistants (and humans) working in this repository.

## What this repo is

This repo (`videoPi`, owner `calexocreative`) holds **custom video effects
("programs") for the [LZX Videomancer](https://lzxindustries.net/products/videomancer)** —
a standalone, real-time video-effects console.

The goal of the project is to author, simulate, and package original Videomancer
effects (color processing, glitch, keying, patterns, feedback, displacement,
etc.) that load onto the hardware as `.vmprog` packages.

> Status: the repo is being bootstrapped. Effect source lives under
> `programs/<author>/<name>/` (see [Repository layout](#repository-layout)).
> The actual toolchain lives in the upstream
> [`videomancer-sdk`](https://github.com/lzxindustries/videomancer-sdk); this
> repo contains the *programs*, not the SDK.
>
> This file was written against the SDK's `main` branch as of **2026-07-07**
> (commit `5d7ca29`, one commit ahead of tag `0.5.0`). See
> [Hardware / firmware notes](#hardware--firmware-notes) — the device was
> updated via LZX Connect on **2026-07-10** to firmware **1.0 (rc.30)**
> (`videomancer/1.0.0-rc.30` in the `videomancer-firmware` repo), well past
> the `0.5.0`-vintage build this file was originally checked against. That
> should resolve the "may be ahead of firmware" caution below for most
> programs, but it hasn't been independently re-verified against a specific
> SDK commit — confirm anything schema-related by sideloading.

## The platform you are targeting (read this first)

Getting the mental model right matters — Videomancer is **not** a GPU/shader or
software-plugin environment.

- **FPGA, not GPU.** Effects are compiled logic that runs directly on an
  iCE40 HX4K Field-Programmable Gate Array. Latency is measured in
  **microseconds, not frames**. There is no framebuffer you can index into and
  no general-purpose CPU running your effect per-frame — you describe a
  **streaming pixel pipeline** in hardware. Budget your design against the
  chip's real resources: **7,680 logic cells, 32 block RAMs (4 Kbit each)**.
- **Language is VHDL.** Every effect is VHDL that implements the fixed
  `program_top` entity (below). Think in terms of clocked logic operating on a
  pixel stream, not imperative loops over an image. No `wait`/`after`, and no
  explicit resets in processes — the iCE40 has no global reset, so state must
  come from a synchronous `rising_edge(clk)` process with an initial value.
- **The control side is an RP2040 microcontroller, not a Linux SBC.** Per the
  SDK's ABI spec, front-panel controls and USB/host communication are handled
  by an **RP2040 MCU** (the chip family behind Raspberry Pi Pico) that talks to
  the FPGA over a simple write-only SPI protocol (see
  [Control & register map](#control--register-map)). There is no Raspberry Pi
  single-board computer or Linux userspace running effects here — despite this
  repo's name, don't design around Pi-side compute.
- **Video format:** 10-bit per channel internally, in one of two selectable
  core architectures — YUV 4:4:4 (`yuv444_30b`, the default) or YUV 4:2:2
  (`yuv422_20b`) — chosen per-program via the TOML `core` field. I/O covers
  HDMI, composite, component YPbPr/RGB, and 1V DC RGB; timings NTSC/PAL/
  480p/576p/720p/1080i/1080p (15 timing IDs total, see below).
- **Controls are physical and finite:** six rotary knobs, five toggle
  switches, one linear fader — these map 1:1 onto named hardware registers
  (not just numbered ones; see below).

## The program interface (the contract every effect implements)

Each effect provides an architecture of the `program_top` entity. The exact
port signature depends on the core architecture (`core` in the TOML):

```vhdl
-- yuv444_30b (default core)
entity program_top is
    port (
        clk          : in  std_logic;                    -- pixel clock, see timing table below
        registers_in : in  t_spi_ram;                     -- control registers (32-slot array)
        data_in      : in  t_video_stream_yuv444_30b;     -- incoming pixel stream (10b Y, 10b U, 10b V)
        data_out     : out t_video_stream_yuv444_30b      -- outgoing pixel stream
    );
end entity program_top;
```

The `yuv422_20b` core is identical except `data_in`/`data_out` are
`t_video_stream_yuv422_20b` (10b Y + 10b C, no separate U/V).

- `data_in` / `data_out` carry the pixel channels **and** sync signals
  (`hsync_n`, `vsync_n`, `field_n`, `avid`). Passthrough programs must forward
  syncs unchanged; only transform active-video pixels. Any pipeline stage you
  add must delay the sync signals by the exact same number of clocks as the
  pixel data (a shift-register delay line — see the Program Development
  Guide's pattern).
- `registers_in` is a `t_spi_ram` array (32 slots, addresses `0x00`–`0x1F`),
  each a `std_logic_vector(9 downto 0)`. Only addresses `0x00`–`0x08` are
  currently defined — see the register map below. `0x09`–`0x1F` are reserved;
  don't rely on their contents.

**When creating a new effect, start from the SDK's `programs/passthru/`
program as a template** — it is the canonical minimal, syntactically-correct
starting point (1 clock cycle latency, forwards everything unchanged).

## Control & register map

Front-panel controls map onto SPI registers with **fixed, named identifiers**
— this is the real ABI, not an arbitrary numbered array:

| Address | Field | Bits | Notes |
| --- | --- | --- | --- |
| `0x00`–`0x05` | `rotary_potentiometer_1` … `_6` | `[9:0]` | 10-bit, 0–1023, one per knob |
| `0x06` | `toggle_switch_7` … `_11` | bits `[0]`…`[4]` | one bit per toggle switch, packed into a single register |
| `0x07` | `linear_potentiometer_12` | `[9:0]` | the fader, 10-bit, 0–1023 |
| `0x08` | `video_timing_id` | `[3:0]` | active video timing, written at load and on format change |
| `0x09`–`0x1F` | — | — | reserved |

All registers are **write-only** — the FPGA never reads back to the MCU.

```vhdl
-- Typical register extraction inside the architecture:
s_param1    <= unsigned(registers_in(0));        -- rotary_potentiometer_1
s_toggle7   <= registers_in(6)(0);               -- toggle_switch_7 (bit 0 of reg 6)
s_fader     <= unsigned(registers_in(7));        -- linear_potentiometer_12
s_timing_id <= registers_in(8)(3 downto 0);       -- video_timing_id
```

### Video timing IDs and clocks

`registers_in(8)(3 downto 0)` tells you the active format. Most programs
don't need this — only use it if your algorithm must scale buffer/delay sizes
to frame dimensions. Constants live in
`fpga/common/rtl/video_timing/video_timing_pkg.vhd`.

| ID | Constant | Standard | Frame | Interlaced | Pixel clock |
| --- | --- | --- | --- | --- | --- |
| 0x0 | `C_NTSC` | 480i 59.94 Hz | 720×486 | yes | 13.5 MHz |
| 0x8 | `C_PAL` | 576i 50 Hz | 720×576 | yes | 13.5 MHz |
| 0x4 | `C_480P` | 480p 59.94 Hz | 720×480 | no | 27 MHz |
| 0xC | `C_576P` | 576p 50 Hz | 720×576 | no | 27 MHz |
| 0x1–0x3, 0x5–0x7, 0x9–0xE | various | 720p/1080i/1080p | up to 1920×1080 | mixed | 74.25 MHz |

**Don't hardcode "13.5 MHz for SD"** — NTSC/PAL run at 13.5 MHz but the
progressive SD modes (480p/576p) are double-rate at 27 MHz. All HD modes run
at 74.25 MHz. Full table: [`docs/abi-format.md`](https://github.com/lzxindustries/videomancer-sdk/blob/main/docs/abi-format.md#video-timing-id-0x08)
in the SDK.

## TOML configuration

Each program's `.toml` declares metadata and its parameter-to-control mapping.
Required `[program]` fields: `program_id` (reverse-DNS, e.g.
`com.calexo.my_effect`), `program_name`, `program_version` (SemVer),
`abi_version` (range, e.g. `">=1.0,<2.0"`), `hardware_compatibility`
(`["rev_a"]` and/or `["rev_b"]`), and `program_type` — `"processing"`
(transforms `data_in`) or `"synthesis"` (generates output from scratch,
ignoring `data_in`).

Optional: `core` (`"yuv444_30b"` default, or `"yuv422_20b"`), `author`,
`license`, `description`, `url`, `categories` (array of up to 8 tags from the
fixed list in [`docs/program-categories.md`](https://github.com/lzxindustries/videomancer-sdk/blob/main/docs/program-categories.md)
— e.g. `Color`, `Glitch`, `Pattern`, `Feedback`, `Temporal`, `Warp`), and
`supported_timings` (restrict to a subset of the 15 timing names; omit to
support all of them).

Each `[[parameter]]` binds to one physical control via `parameter_id`
(`rotary_potentiometer_1`–`_6`, `toggle_switch_7`–`_11`, or
`linear_potentiometer_12`) — max 12 parameters, one per control, no reuse.
Two mutually-exclusive modes:

- **Numeric** — set `control_mode` (`linear`, `linear_half/quarter/double`,
  `boolean`, `steps_4/8/…/256`, `polar_degs_90/180/360/720/1440/2880`, or an
  easing curve like `quad_in_out`), plus `min_value`/`max_value`/
  `initial_value` (0–1023 hardware range) and optional `display_min_value`/
  `display_max_value`/`display_float_digits`/`suffix_label` for the on-screen
  readout.
- **Label** — set `value_labels` (2–16 strings, e.g.
  `["Off", "Low", "Medium", "High"]`) and `initial_value_label`; the hardware
  range is divided evenly across the labels. Don't combine with numeric-mode
  fields.

Validate before building:

```bash
python3 tools/toml-validator/toml_schema_validator.py programs/calexo/<name>/<name>.toml
```

Or use the visual editor: `open tools/toml-editor/toml-editor.html` (fully
offline, schema-aware, catches mode conflicts and length limits live).

## Files that make up one effect

A program directory (`programs/<author>/<name>/`) contains:

| File | Required | Purpose |
| --- | --- | --- |
| `<name>.vhd` | yes | Main VHDL — implements the `program_top` architecture |
| `<name>.toml` | yes | Metadata + parameter/control mapping (see above) |
| `<name>.py` | optional | Python 3 build hook, runs once before synthesis (lookup tables, validation, codegen) |
| `component*.vhd` | optional | Additional VHDL modules the main file instantiates |
| `.lzx-status.toml` | generated | Build/deployment status tracking (do not hand-edit) |

Naming: lowercase, `snake_case`, directory name == program name == entity
config name. Keep one effect per directory.

## Repository layout

```
videoPi/
├── CLAUDE.md                 # this file
├── README.md                 # human-facing intro
├── .gitignore
└── programs/
    └── calexo/               # our author namespace
        └── <effect_name>/    # one directory per effect (see table above)
```

Author namespace for this project: **`calexo`** (i.e. `programs/calexo/...`),
matching the `calexocreative` owner. This mirrors the
[`videomancer-community-programs`](https://github.com/lzxindustries/videomancer-community-programs)
convention (`programs/<vendor>/<program>/`) exactly, so effects can be dropped
into either repo's `programs/` tree without restructuring. Note the SDK's own
*bundled example* programs (`passthru`, `yuv_amplifier`, etc.) live flat under
`programs/<name>/` with no vendor folder — that flat layout is only for the
SDK's own references, not the convention to follow here.

## Authoring effects with AI assistance

This repo is meant to be developed largely by AI assistants, and the SDK ships
a dedicated guide for exactly that:
[`docs/ai-program-generation-guide.md`](https://github.com/lzxindustries/videomancer-sdk/blob/main/docs/ai-program-generation-guide.md).
Read it before generating a new effect. The short version:

**Before writing VHDL, read from an SDK checkout (in priority order):**
1. `fpga/core/<core>/rtl/program_top.vhd` — the entity you must implement
2. `fpga/common/rtl/video_stream/video_stream_pkg.vhd` — stream/record types
3. `fpga/common/rtl/video_timing/video_timing_pkg.vhd` — timing constants
4. `docs/toml-config-guide.md` — full TOML field reference
5. One or two existing `programs/*` (VHD + TOML) similar to what you're building

**Reusable DSP modules** (`fpga/common/rtl/dsp/`) — reach for these before
writing bespoke arithmetic:

| Module | Purpose | Latency |
| --- | --- | --- |
| `interpolator` | Linear crossfade: `a + (b-a) × t` | 4 cycles |
| `proc_amp` | Contrast & brightness | ~9 cycles |
| `multiplier_s` | Signed fixed-point multiply | ~8 cycles |
| `diff_multiplier_s` | 4-quadrant differential multiply | ~10 cycles |
| `variable_delay_u` | BRAM delay line, programmable offset | 2 + delay cycles |
| `variable_filter_s` | 1st-order IIR low/high-pass (no multiplier) | 1 cycle/sample |
| `frequency_doubler` | Ramp → triangle (fold at midpoint) | 2 cycles |
| `sin_cos_full_lut_10x10` | 10-bit angle → sin & cos | combinational |
| `lfsr16` / `lfsr` | PRNG | 1 cycle/sample |
| `edge_detector` | Rising/falling edge detect | 1 cycle |

**Before calling a draft done, check:**
- Architecture is `of program_top`, not a custom entity
- Toggle switches are extracted from `registers_in(6)` as individual bits
- Every process is `if rising_edge(clk) then` — no `wait`, `after`, or resets
- Sync signals are delayed by exactly the pipeline's latency in clocks
- `data_out` is assigned in every case — no undriven signals
- Design fits the iCE40 HX4K budget (7,680 LCs / 32 BRAMs)
- Pipeline depth and register mapping are documented in the file header

## Development workflow

The build/simulate/package tools are **not vendored here** — they come from
the [`videomancer-sdk`](https://github.com/lzxindustries/videomancer-sdk).
Prerequisites: **Python 3.10+**, GHDL ≥3.0 (via OSS CAD Suite, installed by
`scripts/setup.sh`), ~2 GB disk, and Linux / Windows (WSL2) / macOS+Homebrew.

1. **Get the SDK** (once, alongside this repo):
   ```bash
   git clone https://github.com/lzxindustries/videomancer-sdk.git
   cd videomancer-sdk
   bash scripts/setup.sh
   ```
2. **Author an effect** in this repo under `programs/calexo/<name>/`, starting
   from the SDK's `passthru` as a template. Point the SDK's tools at these
   programs with `--programs-dir <path-to-this-repo>/programs` or the
   `LZX_VIT_PROGRAMS_DIR` environment variable.
3. **Simulate on a still image (no hardware needed)** using the GHDL-backed
   VHDL Image Tester — this is an authentic GHDL simulation of the real SDK
   source tree, not an approximation:
   ```bash
   # CLI / headless
   lzx-vhdl-cli list
   lzx-vhdl-cli info <name>                    # show the parameter table
   lzx-vhdl-cli simulate <name> --image test.png --output result.png
   lzx-vhdl-cli simulate <name> --image test.png \
       --set rotary_potentiometer_1=750 --output result.png

   # capture / replay register state
   lzx-vhdl-cli export-regs <name> --output regs.json
   lzx-vhdl-cli simulate <name> --image photo.png --import-regs regs.json
   ```
   A GUI mode also exists: `cd tools/vhdl-image-tester && ./run.sh --install`
   (first run) then `./run.sh`. Test images ship in
   `lfs/library/stock/test-images/`.
4. **Validate metadata / convert TOML:**
   `tools/toml-validator/` checks the `.toml`; `tools/toml-converter/`
   converts it to the binary form; `tools/toml-editor/` is a visual editor.
5. **Build to `.vmprog`:**
   ```bash
   bash build_programs.sh                 # build everything
   bash build_programs.sh calexo          # build one vendor/author
   bash build_programs.sh calexo <name>   # build one program
   bash clean_programs.sh                 # remove build artifacts
   ```
   Output lands in `out/<hardware>/<program>.vmprog`. The build reports
   synthesized `Fmax` and iCE40 resource usage (LCs/IOs/RAMs/PLLs) — check
   these against the budget above.
6. **Package & sign (optional for dev use):** `tools/vmprog-packer/` (Ed25519,
   self-generated keypair via `bash scripts/setup_ed25519_signing.sh`) can
   produce a signed or `--no-sign` unsigned package. Signing here is purely
   integrity/provenance for your own packages — it is not an LZX approval
   gate, and it's separate from the "signed release" that happens when a
   program is merged into the community-programs library.
7. **Deploy for iterative testing — sideload with LZX Connect:** the fast
   loop is **not** microSD-card copying. Install
   [LZX Connect](https://lzxindustries.net/connect), connect via the
   device's **USB-C "Device"** port (not the Host port used for
   keyboards/controllers — that's the RP2040's USB link, unrelated to any
   Raspberry Pi), and click **Load VMPROG File**. This streams the `.vmprog`
   straight to the FPGA in seconds, accepts unsigned dev builds by design, and
   requires no reboot — but it is **not persistent**: it's gone on the next
   program switch or power cycle, which is exactly what you want while
   iterating. Confirm behavior on real hardware — simulation approximates but
   doesn't fully replace on-device verification, especially for
   timing/feedback effects.
8. **Publishing a finished effect:** a *permanent*, menu-visible install goes
   through the official **Program Library** — submit a PR to
   [`videomancer-community-programs`](https://github.com/lzxindustries/videomancer-community-programs)
   (`programs/calexo/<name>/`, per its `CONTRIBUTING.md`); accepted programs
   are officially signed and ship in the library that LZX Connect installs to
   the SD card.

## Conventions & rules of thumb

- **Iterate in simulation first.** GHDL image-testing is the fast loop; keep
  effects sim-verifiable before touching hardware.
- **Preserve syncs.** Always forward `hsync_n`/`vsync_n`/`field_n`/`avid`
  faithfully, delayed to match your pipeline latency exactly; corrupting them
  breaks the output signal, not just the look.
- **Parameters are 10-bit registers (0–1023).** Design control ranges and
  scaling around that; document each control's mapping in the `.toml`.
- **Respect the pipeline latency and resource budget.** This is real-time
  hardware — avoid logic that assumes random-access to a full frame (think
  line/pixel streaming), and keep designs within the iCE40 HX4K's 7,680 LCs /
  32 BRAMs.
- **No resets, no `wait`/`after`.** The iCE40 has no global reset and these
  constructs don't synthesize — rely on `rising_edge(clk)` processes and
  signal initial values.
- **One effect per directory**, `snake_case` names, `programs/calexo/<name>/`.
- **Licensing:** the upstream SDK and community programs are **GPL-3.0-only**.
  Effects intended for the community repo should be GPL-3.0-compatible;
  confirm the license before publishing.
- **Contributing upstream:** to share an effect, follow
  `videomancer-community-programs`'s `CONTRIBUTING.md`, keep it under
  `programs/calexo/<program>/`, test on hardware via LZX Connect sideload
  first, then open a PR.

## Hardware / firmware notes

- **Firmware baseline (current):** updated via LZX Connect on **2026-07-10**
  to **Videomancer firmware 1.0 (rc.30)** — tag `videomancer/1.0.0-rc.30` in
  the `videomancer-firmware` repo. This supersedes the mid-April 2026,
  `0.5.0`-vintage build this file was originally written against.
- **Firmware and SDK are versioned independently**, and there's no published
  mapping from a firmware release to a specific SDK commit/ABI feature set —
  the `videomancer-firmware` repo is just a binary (`.uf2`) archive with no
  changelog tying releases to SDK state. The SDK's own latest tag is still
  `0.5.0`; `main` (commit `5d7ca29`, what this file is written against) sits
  one commit past it with **`[Unreleased]`** changes: the `core_id`/`core`
  field (multi-core support), the `categories` array + required
  `program_type` field (replacing the older singular `category` string —
  still seen in some existing community programs), and an expanded parameter
  control-curve range.
- Firmware 1.0 being a major-version jump past the `0.5.0` baseline makes it
  *likely* those newer TOML fields are now understood, but **this hasn't been
  independently confirmed** — verify empirically rather than assuming.
  Concretely: sideload a `.vmprog` built with `categories`/`program_type`/
  `core` set (e.g. `programs/calexo/scrambler/`) via LZX Connect and confirm
  it loads without a `timing_not_supported` or config-parsing error. **If a
  program using these newer fields fails to load or behaves oddly, that's
  still the first thing to suspect.**
- Keep a note of which SDK commit/tag corresponds to the installed firmware
  when things work, so builds stay reproducible.

## Git workflow for this repo

- Active development branch for AI-assisted work: **`claude/claude-md-docs-np92a5`**.
- Push with `git push -u origin <branch>`; do not push to other branches without
  explicit permission. Do not open a PR unless asked.

## Reference links

- Product: https://lzxindustries.net/products/videomancer
- Technical manual: https://docs.lzxindustries.net/docs/instruments/videomancer
- SDK: https://github.com/lzxindustries/videomancer-sdk
  - Program Development Guide: `docs/program-development-guide.md`
  - AI Program Generation Guide: `docs/ai-program-generation-guide.md`
  - TOML Configuration Guide: `docs/toml-config-guide.md`
  - ABI Format: `docs/abi-format.md`
  - VMPROG Format: `docs/vmprog-format.md`
  - Package Signing Guide: `docs/package-signing-guide.md`
  - Program Categories: `docs/program-categories.md`
- Community programs: https://github.com/lzxindustries/videomancer-community-programs
  - Newcomer's Guide (full walkthrough incl. LZX Connect sideloading):
    `docs/newcomer-guide.md`
- LZX Connect (desktop app for USB sideload / firmware update / library install):
  https://lzxindustries.net/connect
