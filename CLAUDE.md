# CLAUDE.md

Guidance for AI assistants (and humans) working in this repository.

## What this repo is

This repo (`videoPi`, owner `calexocreative`) holds **custom video effects
("programs") for the [LZX Videomancer](https://lzxindustries.net/products/videomancer)** —
a standalone, real-time video-effects console.

The goal of the project is to author, simulate, and package original Videomancer
effects (color processing, glitch, keying, patterns, feedback, displacement,
etc.) that load onto the hardware as signed `.vmprog` packages.

> Status: the repo is being bootstrapped. Effect source lives under
> `programs/<author>/<name>/` (see [Repository layout](#repository-layout)).
> The actual toolchain lives in the upstream
> [`videomancer-sdk`](https://github.com/lzxindustries/videomancer-sdk); this
> repo contains the *programs*, not the SDK.

## The platform you are targeting (read this first)

Getting the mental model right matters — Videomancer is **not** a GPU/shader or
software-plugin environment.

- **FPGA, not GPU.** Effects are compiled logic that runs directly on
  Field-Programmable Gate Array hardware. Latency is measured in
  **microseconds, not frames**. There is no framebuffer you can index into and
  no general-purpose CPU running your effect per-frame — you describe a
  **streaming pixel pipeline** in hardware.
- **Language is VHDL.** Every effect is VHDL that implements the fixed
  `program_top` entity (below). Think in terms of clocked logic operating on a
  pixel stream, not imperative loops over an image.
- **Raspberry Pi is the control brain, not the video engine.** On the device, a
  Raspberry Pi manages the USB ports (firmware updates, program upload, control)
  while the FPGA does all video processing. Do not expect to run effects on the
  Pi's CPU/GPU.
- **Video format:** 10-bit YUV 4:4:4 internally (each channel 0–1023). I/O
  covers HDMI, composite, component YPbPr/RGB, and 1V DC RGB; formats NTSC/PAL,
  240p/288p/480p/576p/720p/1080i/1080p.
- **Controls are physical and finite:** six rotary knobs, five toggle switches,
  one linear fader, plus four audio/CV inputs. Every effect parameter maps to
  one of these via registers.

## The program interface (the contract every effect implements)

Each effect provides an architecture of the `program_top` entity with this
exact port signature:

```vhdl
entity program_top is
    port (
        clk          : in  std_logic;                    -- 74.25 MHz (HD) / 13.5 MHz (SD) pixel clock
        registers_in : in  t_spi_ram;                    -- 9 control registers
        data_in      : in  t_video_stream_yuv444_30b;    -- incoming pixel stream (10b Y, 10b U, 10b V)
        data_out     : out t_video_stream_yuv444_30b     -- outgoing pixel stream
    );
end entity program_top;
```

- `registers_in(0..7)` — the eight **parameter registers**, each a 10-bit
  unsigned value (0–1023). Front-panel controls (rotaries, fader, toggles) are
  mapped onto these in the program's `.toml`.
- `registers_in(8)` — video **timing ID** (`registers_in(8)(3 downto 0)`); use
  it to branch behavior between SD/HD timings when needed.
- `data_in` / `data_out` carry the YUV channels **and** sync signals
  (`hsync_n`, `vsync_n`, `field_n`, `avid`). Passthrough programs must forward
  syncs unchanged; only transform active-video pixels.

Typical register extraction inside the architecture:

```vhdl
s_param1    <= unsigned(registers_in(0));        -- e.g. rotary_potentiometer_1
s_enable    <= registers_in(1)(0);               -- a toggle switch (single bit)
s_timing_id <= registers_in(8)(3 downto 0);      -- video timing ID
```

**When creating a new effect, start from the SDK's `passthru` program as a
template** — it is the canonical minimal, syntactically-correct starting point
and correctly forwards syncs.

## Files that make up one effect

A program directory (`programs/<author>/<name>/`) contains:

| File | Required | Purpose |
| --- | --- | --- |
| `<name>.vhd` | yes | Main VHDL — implements the `program_top` architecture |
| `<name>.toml` | yes | Metadata + register/control mapping (knobs → registers, labels, ranges) |
| `<name>.py` | optional | Python 3 build/preprocessing hook run during the build |
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
matching the `calexocreative` owner. Mirror the upstream
`programs/<author>/<program>/` convention so effects can be dropped into the SDK
or the community-programs repo cleanly.

## Development workflow

The build/simulate/package tools are **not vendored here** — they come from the
[`videomancer-sdk`](https://github.com/lzxindustries/videomancer-sdk).
Prerequisites: **Python 3.10+**, ~2 GB disk, and Linux / Windows (WSL2) /
macOS+Homebrew.

1. **Get the SDK** (once, alongside this repo):
   ```bash
   git clone https://github.com/lzxindustries/videomancer-sdk.git
   cd videomancer-sdk
   bash scripts/setup.sh
   ```
2. **Author an effect** in this repo under `programs/calexo/<name>/`, starting
   from the SDK's `passthru` as a template. Point the SDK at these programs with
   `--programs-dir <path-to-this-repo>/programs` or the
   `LZX_VIT_PROGRAMS_DIR` environment variable.
3. **Simulate on a still image (no hardware needed)** using the GHDL-backed VHDL
   Image Tester:
   ```bash
   # CLI / headless
   lzx-vhdl-cli list
   lzx-vhdl-cli simulate <name> --image test.png --output result.png
   lzx-vhdl-cli simulate <name> --image test.png \
       --set rotary_potentiometer_1=750 --output result.png

   # capture / replay register state
   lzx-vhdl-cli export-regs <name> --output regs.json
   lzx-vhdl-cli simulate <name> --image photo.png --import-regs regs.json
   ```
   A GUI mode also exists: `cd tools/vhdl-image-tester && ./run.sh --install`
   (first run) then `./run.sh`.
4. **Validate metadata / convert TOML:**
   `tools/toml-validator/` checks the `.toml`; `tools/toml-converter/` converts
   it to the binary form; `tools/toml-editor/` is a visual editor.
5. **Build to `.vmprog`:**
   ```bash
   bash build_programs.sh                 # build everything
   bash build_programs.sh calexo          # build one vendor/author
   bash build_programs.sh calexo <name>   # build one program
   bash clean_programs.sh                 # remove build artifacts
   ```
   Output lands in `out/<hardware>/<program>.vmprog` (organized by hardware
   revision and vendor).
6. **Package & sign:** `tools/vmprog-packer/` produces the signed `.vmprog`
   (Ed25519 signing). The signed package is what loads onto the device.
7. **Deploy:** transfer the `.vmprog` to the Videomancer over USB (Pi-managed)
   and test on real hardware — simulation approximates but does not fully
   replace on-device verification, especially for timing/feedback behavior.

## Conventions & rules of thumb

- **Iterate in simulation first.** GHDL image-testing is the fast loop; keep
  effects sim-verifiable before touching hardware.
- **Preserve syncs.** Always forward `hsync_n`/`vsync_n`/`field_n`/`avid`
  faithfully; corrupting them breaks the output signal, not just the look.
- **Parameters are 10-bit registers (0–1023).** Design control ranges and
  scaling around that; document each knob/toggle mapping in the `.toml`.
- **Respect the pipeline latency budget.** This is real-time hardware — avoid
  logic that assumes random-access to a full frame; think line/pixel streaming.
- **One effect per directory**, `snake_case` names, `programs/calexo/<name>/`.
- **Licensing:** the upstream SDK and community programs are **GPL-3.0-only**.
  Effects intended for the community repo should be GPL-3.0-compatible; confirm
  the license before publishing.
- **Contributing upstream:** to share an effect, follow the community repo's
  `CONTRIBUTING.md`, place it under `programs/<yourname>/<program>/`, test on
  hardware, and open a PR to
  [`videomancer-community-programs`](https://github.com/lzxindustries/videomancer-community-programs).

## Hardware / firmware notes

- **Firmware baseline:** the Videomancer firmware updater is downloaded and the
  device is running a **mid-April** firmware build. VHDL ABI, register layout,
  and `.vmprog` format can change across firmware — if a built program fails to
  load or behaves unexpectedly, first confirm the SDK version matches this
  firmware, and re-check the ABI/`VMPROG Format` docs in the SDK before
  debugging the effect itself.
- Keep an eye on which SDK commit/tag corresponds to the installed firmware;
  pin or note it when things work so builds stay reproducible.

## Git workflow for this repo

- Active development branch for AI-assisted work: **`claude/claude-md-docs-np92a5`**.
- Push with `git push -u origin <branch>`; do not push to other branches without
  explicit permission. Do not open a PR unless asked.

## Reference links

- Product: https://lzxindustries.net/products/videomancer
- Technical manual: https://docs.lzxindustries.net/docs/instruments/videomancer
- SDK: https://github.com/lzxindustries/videomancer-sdk
- Community programs: https://github.com/lzxindustries/videomancer-community-programs
