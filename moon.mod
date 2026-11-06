// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "cstoooo/nescope"

version = "0.1.0"

readme = "README.mbt.md"

repository = "https://github.com/cstoooo/nescope"

license = "Apache-2.0"

keywords = [ "nes", "6502", "emulator", "ppu", "retro" ]

preferred_target = "wasm"

description = "A Nintendo Entertainment System emulator in pure MoonBit: 6502 CPU, PPU, frame-counter APU and the NROM/UxROM/CNROM/MMC1 mappers, verified line by line against the nestest golden trace."

import {
  "moonbitlang/x@0.5.7",
}
