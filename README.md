# videoPi — LZX Videomancer effects

Custom real-time video effects ("programs") for the
[LZX Videomancer](https://lzxindustries.net/products/videomancer).

Videomancer effects are **VHDL** compiled to signed `.vmprog` packages that run
on the device's FPGA (a Raspberry Pi handles USB/control). This repo holds the
effect *sources*; the build/simulate/package toolchain lives in the upstream
[`videomancer-sdk`](https://github.com/lzxindustries/videomancer-sdk).

## Layout

```
programs/calexo/<effect_name>/   # one directory per effect
  <effect_name>.vhd              # implements the program_top entity
  <effect_name>.toml             # metadata + control/register mapping
  <effect_name>.py               # optional build hook
```

## Quick start

```bash
# 1. get the SDK (separate checkout)
git clone https://github.com/lzxindustries/videomancer-sdk.git
cd videomancer-sdk && bash scripts/setup.sh

# 2. simulate an effect from this repo on a still image (no hardware)
lzx-vhdl-cli simulate <effect_name> --image test.png --output result.png \
    --programs-dir /path/to/videoPi/programs

# 3. build a signed .vmprog
bash build_programs.sh calexo <effect_name>
```

See [`CLAUDE.md`](./CLAUDE.md) for the full platform model, the `program_top`
VHDL interface, conventions, and the end-to-end workflow.
