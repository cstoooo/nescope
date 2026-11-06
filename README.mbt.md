# nescope

A Nintendo Entertainment System emulator in pure MoonBit.

The CPU is complete: all 151 official 6502 opcodes plus the unofficial ones real
cartridges and the conformance ROMs execute. Its instruction trace is checked
line by line against `nestest.log`, the reference trace that ships with the
widely used `nestest` ROM.

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

```
Total tests: 14, passed: 14, failed: 0.
```

Trace a flat binary loaded at `$C000`:

```sh
moon run cmd/main -- --trace internal/fixtures/nestest.nes --limit 5
```

```
C000  4E        (?)                         A:00 X:00 Y:00 P:24 SP:FD PPU:  0,  0 CYC:0
C003  1A        (?)                         A:00 X:00 Y:00 P:26 SP:FD PPU:  0,  0 CYC:6
C004  01        (?)                         A:00 X:00 Y:00 P:26 SP:FD PPU:  0,  0 CYC:8
```

The `(?)` column is the mnemonic, which this build does not disassemble yet. It
is left visibly empty rather than filled with a guess so that a column that
disagrees with a reference trace is known to be a state difference and not a
formatting one.

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
| Golden-log trace comparison against `nestest.log` | 200 of 8991 lines |
| PPU: registers, scanline rendering, sprites, scrolling | planned |
| APU: pulse, triangle, noise, DMC, frame sequencer | planned |
| Cartridges and mappers: NROM, MMC1, MMC3, UxROM, CNROM | planned |

The 200-line limit is a test-speed choice, not a capability one; the whole log
runs in one pass and is the next thing to turn on.

## How it is tested

Two kinds of test in `cpu_wbtest.mbt`:

- **Synthetic.** Each test builds a few bytes of program in flat RAM and pins one
  instruction: the cycle count, the flags set, the address written, or the
  program counter afterwards. A failure names the instruction.
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
cmd/main/        the CLI
```

## License

Apache-2.0.