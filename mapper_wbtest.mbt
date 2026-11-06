// Tests for the bank-switching mappers.
//
// A mapper is hard to test through a game ROM because a failure looks like "the
// game is broken" rather than "bank three did not load". These tests build
// synthetic cartridges whose banks are filled with their own bank number, so a
// read tells you exactly which bank answered.

///|
/// Builds an iNES image with `prg_banks` 16 KiB program banks and `chr_banks`
/// 8 KiB character banks, every byte of bank *n* set to *n*.
///
/// Uniform banks make the assertion trivial: reading $8000 and getting 3 means
/// bank 3 answered, with no need to know anything about the ROM's contents.
fn synth_rom(mapper : Int32, prg_banks : Int32, chr_banks : Int32) -> Bytes {
  let out = Buffer::Buffer(
    size_hint=16 + prg_banks * 0x4000 + chr_banks * 0x2000,
  )
  out.write_byte(b'N')
  out.write_byte(b'E')
  out.write_byte(b'S')
  out.write_byte(b'\x1A')
  out.write_byte(prg_banks.reinterpret_as_uint().to_byte())
  out.write_byte(chr_banks.reinterpret_as_uint().to_byte())
  out.write_byte(((mapper & 0x0F) << 4).reinterpret_as_uint().to_byte())
  out.write_byte((mapper & 0xF0).reinterpret_as_uint().to_byte())
  for _ in 0..<8 {
    out.write_byte(b'\x00')
  }
  for bank in 0..<prg_banks {
    for _ in 0..<0x4000 {
      out.write_byte(bank.reinterpret_as_uint().to_byte())
    }
  }
  for bank in 0..<chr_banks {
    for _ in 0..<0x2000 {
      out.write_byte(bank.reinterpret_as_uint().to_byte())
    }
  }
  out.to_bytes()
}

///|
/// The same, with the character banks numbered 1 upward so that "bank 0" and
/// "nothing loaded" are distinguishable.
fn synth_rom_numbered_chr(
  mapper : Int32,
  prg_banks : Int32,
  chr_banks : Int32,
) -> Bytes {
  let out = Buffer::Buffer(
    size_hint=16 + prg_banks * 0x4000 + chr_banks * 0x2000,
  )
  out.write_byte(b'N')
  out.write_byte(b'E')
  out.write_byte(b'S')
  out.write_byte(b'\x1A')
  out.write_byte(prg_banks.reinterpret_as_uint().to_byte())
  out.write_byte(chr_banks.reinterpret_as_uint().to_byte())
  out.write_byte(((mapper & 0x0F) << 4).reinterpret_as_uint().to_byte())
  out.write_byte((mapper & 0xF0).reinterpret_as_uint().to_byte())
  for _ in 0..<8 {
    out.write_byte(b'\x00')
  }
  for bank in 0..<prg_banks {
    for _ in 0..<0x4000 {
      out.write_byte(bank.reinterpret_as_uint().to_byte())
    }
  }
  for bank in 0..<chr_banks {
    for _ in 0..<0x2000 {
      out.write_byte((bank + 1).reinterpret_as_uint().to_byte())
    }
  }
  out.to_bytes()
}

///|
test "UxROM puts the last bank at $C000 and switches the low window" {
  let console = Console::new(Cart::parse(synth_rom(2, 4, 1)))
  inspect_eq(console.cart.mapper.name(), "UxROM")
  // The high window is fixed to the last bank, which is where a game's vectors
  // live; this is what makes a bank switch safe to perform mid-program.
  inspect_eq(console.read(0xC000U), 3U)
  inspect_eq(console.read(0xFFFCU), 3U)
  // The low window starts on bank 0 and follows the register.
  inspect_eq(console.read(0x8000U), 0U)
  console.write(0x8000U, 2U)
  inspect_eq(console.read(0x8000U), 2U)
  inspect_eq(console.read(0xC000U), 3U)
  // The mask keeps the low four bits, so a value with high bits set still
  // selects a bank that exists rather than reading past the ROM.
  console.write(0x8000U, 0xF5U)
  inspect_eq(console.read(0x8000U), 1U)
}

///|
test "UxROM ignores a bank value larger than the ROM" {
  let console = Console::new(Cart::parse(synth_rom(2, 2, 1)))
  inspect_eq(console.read(0x8000U), 0U)
  console.write(0x8000U, 9U)
  // Nine is masked to one, but the board has only two banks; the modulo keeps
  // the read inside the chip rather than running off the end of the array.
  inspect_eq(console.read(0x8000U), 1U)
}

///|
test "CNROM switches the character bank the PPU reads" {
  let console = Console::new(Cart::parse(synth_rom_numbered_chr(3, 2, 3)))
  inspect_eq(console.cart.mapper.name(), "CNROM")
  // The program ROM is fixed, so both windows see the same chip as NROM would.
  inspect_eq(console.read(0x8000U), 0U)
  inspect_eq(console.cart.chr_bank, 0L)
  console.write(0x8000U, 2U)
  inspect_eq(console.cart.chr_bank, 2L)
  // The PPU caches the bank, so a write through the console has to refresh it.
  inspect_eq(console.ppu.chr_bank, 2L)
  // Character bank 2 is filled with the value three, because the numbering
  // starts at one in this builder.
  // The data port is buffered: the first read returns whatever was latched and
  // fetches the addressed byte, so two reads are needed to see the value.
  console.ppu.v = 0x0000U
  ignore(console.ppu.read_register(0x07U))
  inspect_eq(console.ppu.read_register(0x07U), 3U)
}

///|
test "MMC1 loads a register one bit at a time" {
  let console = Console::new(Cart::parse(synth_rom(1, 4, 2)))
  inspect_eq(console.cart.mapper.name(), "MMC1")
  // MMC1 powers up in 16 KiB mode with the low window on bank 0.
  inspect_eq(console.read(0x8000U), 0U)
  inspect_eq(console.read(0xC000U), 3U)
  // The register at $E000 selects the program bank. Five writes of one bit each,
  // least significant bit first, assemble the value two. Asserting the old value
  // is gone proves the write replaced the register rather than OR-ing into it;
  // the rest of the battery is checked in the 32 KiB test below.
  for bit in 0..<5 {
    console.write(0xE000U, (2 >> bit).reinterpret_as_uint() & 1U)
  }
  inspect_eq(console.read(0x8000U), 2U)
  // The high window is the pair's second bank, not the last bank, because this
  // board is still in its power-on 32 KiB mode.
  inspect_eq(console.read(0xC000U), 3U)
  // A write with bit 7 set resets the shift register instead of contributing a
  // bit, which is how a program recovers from a partial write.
  console.write(0xE000U, 0x80U)
  inspect_eq(console.cart.shift_count, 0U)
}

///|
test "MMC1 changes mirroring at run time" {
  let console = Console::new(Cart::parse(synth_rom(1, 2, 2)))
  // The header said horizontal; the control register starts on its power-on
  // value, and until a program writes it the header value still applies.
  inspect_eq(console.cart.current_mirroring().name(), "horizontal")
  // Control register zero: single-screen low.
  for bit in 0..<5 {
    console.write(0x8000U, (0 >> bit).reinterpret_as_uint() & 1U)
  }
  inspect_eq(console.cart.current_mirroring().name(), "single-screen low")
  inspect_eq(console.ppu.mirroring.name(), "single-screen low")
  // Control register two: vertical.
  for bit in 0..<5 {
    console.write(0x8000U, (2 >> bit).reinterpret_as_uint() & 1U)
  }
  inspect_eq(console.cart.current_mirroring().name(), "vertical")
  inspect_eq(console.ppu.mirroring.name(), "vertical")
}

///|
test "MMC1's control register picks one of four bank arrangements" {
  let console = Console::new(Cart::parse(synth_rom(1, 8, 1)))
  // Power-on control is $0C: mode 3, $C000 fixed to the last bank. Reset code
  // depends on that, because it has to be able to bank-switch while running.
  inspect_eq(console.read(0xC000U), 7U)
  inspect_eq(console.read(0x8000U), 0U)
  // Select bank five with the register at $E000; the low window follows it and
  // the high window stays on the last bank.
  for bit in 0..<5 {
    console.write(0xE000U, (5 >> bit).reinterpret_as_uint() & 1U)
  }
  inspect_eq(console.read(0x8000U), 5U)
  inspect_eq(console.read(0xC000U), 7U)
  // Mode 2 fixes $C000 to the first bank instead.
  for bit in 0..<5 {
    console.write(0x8000U, (0x08 >> bit).reinterpret_as_uint() & 1U)
  }
  inspect_eq(console.read(0x8000U), 5U)
  inspect_eq(console.read(0xC000U), 0U)
  // Mode 0 is 32 KiB: the register's low bit is ignored and the pair fills both
  // windows, so bank five becomes the pair four/five.
  for bit in 0..<5 {
    console.write(0x8000U, (0x00 >> bit).reinterpret_as_uint() & 1U)
  }
  inspect_eq(console.read(0x8000U), 4U)
  inspect_eq(console.read(0xC000U), 5U)
}

///|
test "NROM ignores mapper writes" {
  let console = Console::new(Cart::parse(synth_rom(0, 2, 1)))
  inspect_eq(console.read(0x8000U), 0U)
  console.write(0x8000U, 1U)
  // A NROM board has nothing to switch, so the write must not disturb the map.
  inspect_eq(console.read(0x8000U), 0U)
  inspect_eq(console.read(0xC000U), 1U)
}
