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
fn synth_rom(
  mapper : Int32,
  prg_banks : Int32,
  chr_banks : Int32,
  battery~ : Bool = false,
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
  let battery_bit = if battery { 0x02 } else { 0x00 }
  out.write_byte(
    (((mapper & 0x0F) << 4) | battery_bit).reinterpret_as_uint().to_byte(),
  )
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

///|
/// Builds a cartridge whose character ROM is filled with the 1 KiB page number,
/// so a fetch says exactly which page answered. MMC3 is the first board here
/// whose character banking is finer than 8 KiB, and a page-numbered ROM is the
/// only way to see that the fine banking actually works.
fn synth_mmc3(chr_pages : Int32) -> Bytes {
  let out = Buffer::Buffer(size_hint=16 + 0x2000 * 8 + chr_pages * 0x400)
  out.write_byte(b'N')
  out.write_byte(b'E')
  out.write_byte(b'S')
  out.write_byte(b'\x1A')
  // The header counts 16 KiB program banks; eight of them is 64 KiB, which MMC3
  // addresses as sixteen 8 KiB windows.
  out.write_byte(b'\x04')
  // The header counts 8 KiB character banks, not 1 KiB pages, so a page count
  // has to be divided before it is written.
  out.write_byte((chr_pages / 8).reinterpret_as_uint().to_byte())
  out.write_byte(b'\x40')
  out.write_byte(b'\x00')
  for _ in 0..<8 {
    out.write_byte(b'\x00')
  }
  // Each 8 KiB window is filled with its own window number, so a read says
  // exactly which window answered rather than requiring the test to know the
  // ROM's contents.
  for window in 0..<8 {
    for _ in 0..<0x2000 {
      out.write_byte(window.reinterpret_as_uint().to_byte())
    }
  }
  for page in 0..<chr_pages {
    for _ in 0..<0x400 {
      out.write_byte(page.reinterpret_as_uint().to_byte())
    }
  }
  out.to_bytes()
}

///|
test "MMC3 switches the two 8 KiB program windows independently" {
  let console = Console::new(Cart::parse(synth_mmc3(8)))
  inspect_eq(console.cart.mapper.name(), "MMC3")
  // Register 6 drives $8000 and register 7 drives $A000; $C000 and $E000 are
  // pinned to the last two banks. Each program bank here is 8 KiB, and every
  // byte of it holds the bank number, so the read says which answered.
  console.write(0x8000U, 0x06U)
  console.write(0x8001U, 0x03U)
  inspect_eq(console.read(0x8000U), 3U)
  console.write(0x8000U, 0x07U)
  console.write(0x8001U, 0x05U)
  inspect_eq(console.read(0xA000U), 5U)
  // The pinned windows are the last two of the eight: windows 6 and 7.
  inspect_eq(console.read(0xC000U), 6U)
  inspect_eq(console.read(0xE000U), 7U)
}

///|
test "MMC3's mode bit swaps the program windows" {
  let console = Console::new(Cart::parse(synth_mmc3(8)))
  console.write(0x8000U, 0x06U)
  console.write(0x8001U, 0x02U)
  inspect_eq(console.read(0x8000U), 2U)
  inspect_eq(console.read(0xC000U), 6U)
  // Setting bit 6 of the bank-select register swaps which pair follows the
  // registers, which is how a game moves its own fixed code.
  console.write(0x8000U, 0x46U)
  inspect_eq(console.read(0x8000U), 6U)
  inspect_eq(console.read(0xC000U), 2U)
}

///|
test "MMC3 selects character banks at 1 KiB granularity" {
  let console = Console::new(Cart::parse(synth_mmc3(8)))
  // In the default arrangement the first 4 KiB of the pattern space is driven by
  // registers 0 and 1 as 2 KiB windows, and only the second 4 KiB is driven by
  // the four 1 KiB registers. Register 2 therefore covers $1000, not $0000.
  console.write(0x8000U, 0x02U)
  console.write(0x8001U, 0x05U)
  // The data port is buffered, so two reads are needed to see the fetched byte.
  console.ppu.v = 0x1000U
  ignore(console.ppu.read_register(0x07U))
  inspect_eq(console.ppu.read_register(0x07U), 5U)
  // Changing register 2 must change that byte, which proves the page table is
  // being refreshed on a mapper write rather than cached at construction.
  console.write(0x8001U, 0x06U)
  console.ppu.v = 0x1000U
  ignore(console.ppu.read_register(0x07U))
  inspect_eq(console.ppu.read_register(0x07U), 6U)
  // Flipping the mode bit swaps the halves, so register 2 now covers $0000.
  console.write(0x8000U, 0x80U)
  console.ppu.v = 0x0000U
  ignore(console.ppu.read_register(0x07U))
  inspect_eq(console.ppu.read_register(0x07U), 6U)
}

///|
test "MMC3's scanline counter interrupts after the latched number of lines" {
  let console = Console::new(Cart::parse(synth_mmc3(8)))
  // Latch a count, clear the counter, then arm it. The order matters: $C001
  // clears without reloading, so the first interval is the latch rather than
  // zero, which is what a game relies on to get its first split in the right
  // place.
  console.write(0xC000U, 3U)
  console.write(0xC001U, 0U)
  console.write(0xE001U, 0U)
  inspect_bool(console.cart.irq_enabled, true)
  // Three edges must not have fired yet; the fourth is where the counter hits
  // zero.
  for _ in 0..<3 {
    console.cart.clock_scanline()
  }
  inspect_bool(console.cart.irq_line, false)
  console.cart.clock_scanline()
  inspect_bool(console.cart.irq_line, true)
  // Disarming clears the pending line, which is how a game stops the interrupt
  // once it has finished the split.
  console.write(0xE000U, 0U)
  inspect_bool(console.cart.irq_line, false)
}

///|
test "MMC3's mirroring register switches between the single-screen modes" {
  let console = Console::new(Cart::parse(synth_mmc3(8)))
  // Bit 0 of a write to $A000 picks which page both nametables show.
  console.write(0xA000U, 0x00U)
  inspect_eq(console.cart.current_mirroring().name(), "single-screen low")
  console.write(0xA000U, 0x01U)
  inspect_eq(console.cart.current_mirroring().name(), "single-screen high")
}

///|
/// Builds a cartridge whose program ROM is divided into 32 KiB banks, each filled
/// with its own bank number.
fn synth_32k_rom(mapper : Int32, banks : Int32, chr_banks : Int32) -> Bytes {
  let out = Buffer::Buffer(size_hint=16 + banks * 0x8000 + chr_banks * 0x2000)
  out.write_byte(b'N')
  out.write_byte(b'E')
  out.write_byte(b'S')
  out.write_byte(b'\x1A')
  out.write_byte((banks * 2).reinterpret_as_uint().to_byte())
  out.write_byte(chr_banks.reinterpret_as_uint().to_byte())
  out.write_byte(((mapper & 0x0F) << 4).reinterpret_as_uint().to_byte())
  out.write_byte((mapper & 0xF0).reinterpret_as_uint().to_byte())
  for _ in 0..<8 {
    out.write_byte(b'\x00')
  }
  for bank in 0..<banks {
    for _ in 0..<0x8000 {
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
test "AxROM switches the whole 32 KiB window and the single-screen nametable" {
  let console = Console::new(Cart::parse(synth_32k_rom(7, 4, 1)))
  inspect_eq(console.cart.mapper.name(), "AxROM")
  // Every address in the upper half follows the one register, because the board
  // has no fixed window at all.
  inspect_eq(console.read(0x8000U), 0U)
  console.write(0x8000U, 2U)
  inspect_eq(console.read(0x8000U), 2U)
  inspect_eq(console.read(0xC000U), 2U)
  inspect_eq(console.read(0xFFFCU), 2U)
  // Bit 4 picks which of the two nametables both virtual tables show. A game
  // flips it mid-frame to double its background space.
  inspect_eq(console.cart.current_mirroring().name(), "single-screen low")
  console.write(0x8000U, 0x12U)
  inspect_eq(console.cart.current_mirroring().name(), "single-screen high")
  // The program bank is still two, because the nametable bit is not part of it.
  inspect_eq(console.read(0x8000U), 2U)
}

///|
test "GxROM splits its one register between program and character banks" {
  let console = Console::new(Cart::parse(synth_32k_rom(66, 4, 4)))
  inspect_eq(console.cart.mapper.name(), "GxROM")
  inspect_eq(console.read(0x8000U), 0U)
  // The high nibble is the 32 KiB program bank and the low two bits the 8 KiB
  // character bank, so a write of $21 selects program bank two and character
  // bank one.
  console.write(0x8000U, 0x21U)
  inspect_eq(console.read(0x8000U), 2U)
  inspect_eq(console.read(0xC000U), 2U)
  inspect_eq(console.cart.chr_bank, 1L)
  // Character bank one holds the value two, because this builder numbers banks
  // from one.
  console.ppu.v = 0x0000U
  ignore(console.ppu.read_register(0x07U))
  inspect_eq(console.ppu.read_register(0x07U), 2U)
}

///|
/// Cartridge RAM at $6000 is readable and writable, which is what a game with a
/// save battery stores its progress in.
test "work RAM answers at $6000 and holds what is written" {
  let cart = Cart::parse(synth_rom(0, 1, 1, battery=true)) catch {
    _ => fail("parse")
  }
  let console = Console::new(cart)
  inspect_eq(console.read(0x6000U), 0U)
  console.write(0x6000U, 0x5AU)
  console.write(0x7FFFU, 0xA5U)
  inspect_eq(console.read(0x6000U), 0x5AU)
  inspect_eq(console.read(0x7FFFU), 0xA5U)
  // The two ends are distinct addresses, not one mirror.
  inspect_eq(console.read(0x7FFEU), 0U)
}

///|
/// A board with a battery hands its RAM back as a save file of exactly the RAM's
/// size, and loading that file restores every byte.
test "a battery board round-trips its save file" {
  let cart = Cart::parse(synth_rom(0, 1, 1, battery=true)) catch {
    _ => fail("parse")
  }
  let console = Console::new(cart)
  console.write(0x6000U, 0x12U)
  console.write(0x6123U, 0x34U)
  let saved = console.cart.save_data()
  inspect_eq(saved.length(), 0x2000)
  let fresh_cart = Cart::parse(synth_rom(0, 1, 1, battery=true)) catch {
    _ => fail("parse")
  }
  let fresh = Console::new(fresh_cart)
  inspect_eq(fresh.read(0x6000U), 0U)
  fresh.cart.load_save(saved)
  inspect_eq(fresh.read(0x6000U), 0x12U)
  inspect_eq(fresh.read(0x6123U), 0x34U)
}

///|
/// A board without a battery writes no save at all, so a stray `.srm` beside the
/// ROM cannot be clobbered by a cartridge that never had one.
test "a board without a battery produces no save data" {
  let cart = Cart::parse(synth_rom(0, 1, 1)) catch { _ => fail("parse") }
  let console = Console::new(cart)
  console.write(0x6000U, 0x99U)
  inspect_eq(console.cart.save_data().length(), 0)
}

///|
/// A short save file fills what it can and leaves the rest zeroed, and a long one
/// is truncated rather than overflowing the RAM array.
test "save loading tolerates files of the wrong size" {
  let cart = Cart::parse(synth_rom(0, 1, 1, battery=true)) catch {
    _ => fail("parse")
  }
  let console = Console::new(cart)
  console.cart.load_save(Bytes::from_array([b'\x01', b'\x02']))
  inspect_eq(console.read(0x6000U), 0x01U)
  inspect_eq(console.read(0x6001U), 0x02U)
  inspect_eq(console.read(0x6002U), 0x00U)
  let big = Bytes::make(0x4000, b'\x7F')
  console.cart.load_save(big)
  inspect_eq(console.read(0x6000U), 0x7FU)
  inspect_eq(console.read(0x7FFFU), 0x7FU)
}
