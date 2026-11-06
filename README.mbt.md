# nescope

A Nintendo Entertainment System emulator in pure MoonBit.

The console runs: CPU, PPU, cartridge and the bus that joins them. The whole
`nestest` ROM executes from a real cartridge image and every one of its 8991
instruction traces is compared against `nestest.log`, the reference trace that
ships with the ROM.

## Why it is structured this way

A 6502's cost is a property of its addressing mode, not of its operation:
`LDA $1234` takes 4 cycles and `LDA ($12),Y` takes 5, and either grows by one
when the effective address crosses a page. Putting the cycle count next to the
operation is the obvious thing to do and it is wrong — the first version of this
code did exactly that and produced a trace that drifted from the golden log by
the third line.

So the module is split three ways:

```
addressing.mbt   operand decoding; page-crossing penalties are computed here
ops.mbt          what an instruction does to registers and flags
isa.mbt          the opcode table; each arm fixes the addressing mode and the cost
```

An operation is written once no matter how many modes reach it, and the cycle
count is written once per opcode, next to the data-sheet entry it came from.

## Quick start

```sh
moon test
```

Read a real cartridge's header:

```sh
moon run cmd/main -- --inspect internal/fixtures/nestest.nes
```

```
file       internal/fixtures/nestest.nes
mapper     NROM
mirroring  horizontal
program    1 x 16 KiB (4000 bytes)
character  1 x 8 KiB (2000 bytes)
battery    false
reset      C004
```

Boot it and run a frame:

```sh
moon run cmd/main -- --run internal/fixtures/nestest.nes --frames 2 --write-png frame.png
```

```
frames     2
cycles     59567
pc         C5F4  a=00 x=00 y=00 sp=FA
wrote      frame.png (184638 bytes)
```

`nestest` renders nothing but its backdrop, so that frame is a single flat grey.
The point of the flag is that any ROM's frame becomes a file you can look at,
which is the only way to check rendering without a window system.

`--trace` still exists for flat binaries: it loads an image at `$C000` and prints
one line per instruction in the layout `nestest.log` uses. Its `(?)` column is
the mnemonic, which this build does not disassemble yet. It is left visibly
empty rather than filled with a guess so that a column that disagrees with a
reference trace is known to be a state difference and not a formatting one.

## What works today

| Capability | Status |
|---|---|
| All 151 official 6502 opcodes with data-sheet cycle counts | done |
| Unofficial opcodes: LAX, SAX, SLO, RLA, SRE, RRA, DCP, ISC, ANC, ALR, ARR, SBX, multi-byte NOPs | done |
| Page-crossing penalties on `abs,X` / `abs,Y` / `(zp),Y` reads | done |
| Branch penalties including the page-crossing extra | done |
| The `JMP ($xxFF)` page-boundary bug | done |
| `BRK` / `RTI` / `JSR` / `RTS` stack behaviour | done |
| `BIT` as a two-bit branch on one memory read | done |
| Golden-log trace comparison against `nestest.log` | all 8991 lines |
| iNES header parsing, including the twelve-bit bank counts | done |
| NROM cartridge, 16 KiB mirroring into both halves of the map | done |
| UxROM (mapper 2): switchable low window, last bank fixed at `$C000` | done |
| CNROM (mapper 3): switchable character bank | done |
| MMC1 (mapper 1): serial shift register, four bank arrangements, run-time mirroring | done |
| MMC3 (mapper 4): two switchable 8 KiB windows, 1 KiB character banking, scanline IRQ | done |
| PPU registers, read buffer, scroll latch, palette mirrors | done |
| PPU: per-pixel background and sprite rendering | done |
| Sprite DMA through `$4014` with the odd-cycle stall | done |
| Controller shift registers in hardware order | done |
| Four-screen mirroring with its own 4 KiB of nametable RAM | done |
| Sprite-zero hit: opaque sprite pixel over opaque background pixel | done |
| Mappers: MMC5, VRC, and the discrete boards (AxROM, GxROM, MMC2) | planned |
| APU frame counter: 4-step and 5-step sequences, frame IRQ | done |
| APU channel status and length counters, as `$4015` reports them | done |
| APU: waveform synthesis and mixing | planned |
| Sprite overflow flag | approximate |
| PNG output of a finished frame, written out without a dependency | done |

## How it is tested

Three kinds of test:

- **Synthetic.** Each test builds a few bytes of program in flat RAM and pins one
  instruction: the cycle count, the flags set, the address written, or the
  program counter afterwards. A failure names the instruction.
- **Banking.** `mapper_wbtest.mbt` builds synthetic cartridges whose program
  banks are filled with their own bank number, so a read says which bank
  answered. That is the only way to tell "bank three loaded" from "bank zero
  loaded and happened to contain the right bytes".
- **Differential.** The real `nestest` ROM is executed and every line compared
  with `nestest.log` — program counter, accumulator, X, Y, status, stack pointer
  and cumulative cycle count. The log is decimal in its `CYC:` column and hex
  everywhere else, which cost a debugging round to notice.

The fixtures in `internal/fixtures` are `nestest.nes` and `nestest.log` from
[christopherpow/nes-test-roms](https://github.com/christopherpow/nes-test-roms).
The planned PPU and APU work will use
[Gekkio/mooneye-test-suite](https://github.com/Gekkio/mooneye-test-suite) and
[pinobatch/240p-test-mini](https://github.com/pinobatch/240p-test-mini).

## Source layout

```
nescope.mbt      errors, status flags, buttons, region timings
cpu.mbt          register file, bus trait, fetch/step, stack
addressing.mbt   the addressing modes and their page penalties
ops.mbt          operations: loads, ALU, shifts, compare, branch, jump
isa.mbt          the opcode table
cart.mbt         iNES parsing and the cartridge's memories
mapper.mbt       bank switching: NROM, UxROM, CNROM, MMC1
ppu.mbt          registers, rendering, sprites, palette and mirroring
png.mbt          palette to RGB, and a dependency-free PNG writer
apu.mbt          the frame counter and channel status registers
bus.mbt          the console: address decoding, DMA, controllers
cmd/main/        the CLI
```

## License

Apache-2.0.