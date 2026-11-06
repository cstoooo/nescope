// Tests for the console as a whole: cartridge loading, address decoding and the
// full `nestest` run through the real bus.

///|
/// Loads a fixture cartridge.
fn fixture_cart(name : String) -> Cart raise {
  let bytes = read_fixture(name)
  Cart::parse(bytes)
}

///|
/// The iNES header of `nestest` declares one 16 KiB program bank, one 8 KiB
/// character bank and no mapper, and the parser must agree byte for byte.
test "cart parses the nestest header" {
  let cart = fixture_cart("nestest.nes")
  same(cart.prg.length(), 0x4000)
  same(cart.chr.length(), 0x2000)
  same(cart.prg_banks, 1L)
  same(cart.chr_banks, 1L)
  same(cart.mapper.name(), "NROM")
  same(cart.mirroring.name(), "horizontal")
  same_bool(cart.has_battery, false)
  same_bool(cart.chr_ram, false)
}

///|
/// A file that does not start with the magic must be rejected by name, not by
/// reading garbage.
test "cart rejects a file without the magic" {
  // A full 16-byte header whose fourth magic byte is wrong, so the magic check
  // is what fails rather than the length check.
  let bytes = Bytes::from_array([
    b'N', b'E', b'S', b'\x00', b'\x01', b'\x01', b'\x00', b'\x00', b'\x00', b'\x00',
    b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00',
  ])
  let result = Ok(Cart::parse(bytes)) catch { e => Err(e) }
  match result {
    Err(NotAnINes) => ()
    Err(_) => fail("expected NotAnINes, got a different error")
    Ok(_) => fail("expected NotAnINes")
  }
}

///|
/// A header that declares more program ROM than the file holds must name the
/// shortfall rather than reading past the end.
test "cart rejects a truncated program ROM" {
  // One 16 KiB bank declared, no bytes present.
  let bytes = Bytes::from_array([
    b'N', b'E', b'S', b'\x1a', b'\x01', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00',
    b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00',
  ])
  let result = Ok(Cart::parse(bytes)) catch { e => Err(e) }
  match result {
    Err(Truncated(kind~, declared~, ..)) => {
      same(kind, "program ROM")
      same(declared, 0x4000L)
    }
    _ => fail("expected Truncated")
  }
}

///|
/// Work RAM is 2 KiB but answers across 8 KiB, so a write at $0000 must be
/// visible at $0800. Games rely on this and a decoder that forgets it breaks
/// subtly rather than loudly.
test "work RAM mirrors every 2 KiB" {
  let cart = fixture_cart("nestest.nes")
  let console = Console::new(cart)
  console.write(0x0000U, 0x5AU)
  same(console.read(0x0800U), 0x5AU)
  same(console.read(0x1000U), 0x5AU)
  same(console.read(0x1800U), 0x5AU)
  console.write(0x1FFFU, 0xA5U)
  same(console.read(0x07FFU), 0xA5U)
}

///|
/// The PPU registers repeat every eight bytes across the $2000-$3FFF window.
test "PPU registers mirror every eight bytes" {
  let cart = fixture_cart("nestest.nes")
  let console = Console::new(cart)
  // $2002 is the one register that reads back meaningfully, so the mirror is
  // checked by setting vblank and reading through $200A rather than through a
  // write-only register.
  console.ppu.status.vblank = true
  same(console.read(0x200AU) & 0x80U, 0x80U)
  // Reading through the mirror must clear the same flag the real address owns.
  same_bool(console.ppu.status.vblank, false)
}

///|
/// The NROM board answers $8000 and $C000 with the same 16 KiB chip when the ROM
/// is that small, so the vector at $FFFC must be readable through the chip's
/// offset $3FFC.
test "a 16 KiB NROM mirrors into both halves of the upper map" {
  let cart = fixture_cart("nestest.nes")
  let console = Console::new(cart)
  let from_low = console.read(0x8000U)
  let from_high = console.read(0xC000U)
  same(from_low, from_high)
}

///|
/// Reset reads the program counter from $FFFC, which for `nestest` is $C000.
test "reset takes the program counter from the vector" {
  let cart = fixture_cart("nestest.nes")
  let console = Console::new(cart)
  console.reset()
  // `nestest`'s reset vector is $C004; the golden log starts at $C000, which is
  // where the reference emulator was pointed rather than where the hardware
  // would have landed.
  same(console.cpu.pc, 0xC004U)
  same(console.cpu.sp, 0xFDU)
}

///|
/// The controller shifts out A first and then B, select, start and the d-pad,
/// and returns 1 after the eighth bit.
test "controllers shift out in hardware order" {
  let cart = fixture_cart("nestest.nes")
  let console = Console::new(cart)
  console.set_buttons(0, [A, Start])
  // Strobe high then low to latch.
  console.write(0x4016U, 1U)
  console.write(0x4016U, 0U)
  // Bit 0 is A, bit 1 is B (not pressed), bit 2 is Select (not pressed), bit 3 is
  // Start.
  let bits : Array[UInt32] = []
  for _ in 0..<10 {
    bits.push(console.read(0x4016U))
  }
  same(bits[0], 1U)
  same(bits[1], 0U)
  same(bits[2], 0U)
  same(bits[3], 1U)
  same(bits[8], 1U)
  same(bits[9], 1U)
}

///|
/// The whole point of the bus: run the real `nestest` ROM from reset and compare
/// every instruction against the golden trace.
///
/// `nestest` begins with a jump into the same $C000 routine the CPU-only test
/// uses, so this exercises cartridge decoding, the PPU's registers and the
/// work-RAM mirrors on the way. All 8991 lines are checked.
test "nestest runs through the console bus for the whole log" {
  let cart = fixture_cart("nestest.nes")
  let console = Console::new(cart)
  let log = read_text_fixture("nestest.log")
  let golden = parse_golden(log)
  console.reset()
  // The golden log is a CPU-only trace: it starts at $C000 rather than at the
  // cartridge's reset vector ($C004) and its first line already counts seven
  // cycles. Starting the program counter where the log does is what the
  // reference tooling does, and it is the only way to compare against a trace
  // that was never meant to include the reset routine.
  console.cpu.pc = 0xC000U
  console.cpu.cycles = 7L
  for i in 0..<golden.length() {
    let expected = golden[i]
    let actual = (
      console.cpu.pc,
      console.cpu.a,
      console.cpu.x,
      console.cpu.y,
      console.cpu.p,
      console.cpu.sp,
      console.cpu.cycles,
    )
    if actual != expected {
      fail(
        "line \{i + 1} differs: actual=\{inspect_tuple(actual)} expected=\{inspect_tuple(expected)}",
      )
    }
    ignore(console.cpu.step(console))
  }
}

///|
/// Renders a trace tuple as text for a failure message.
fn inspect_tuple(
  value : (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, Int64),
) -> String {
  let (pc, a, x, y, p, sp, cycles) = value
  let buf = StringBuilder()
  buf.write_string("pc=")
  buf.write_string(pc.to_string())
  buf.write_string(" a=")
  buf.write_string(a.to_string())
  buf.write_string(" x=")
  buf.write_string(x.to_string())
  buf.write_string(" y=")
  buf.write_string(y.to_string())
  buf.write_string(" p=")
  buf.write_string(p.to_string())
  buf.write_string(" sp=")
  buf.write_string(sp.to_string())
  buf.write_string(" cycles=")
  buf.write_string(cycles.to_string())
  buf.to_string()
}

///|
/// Compares two values and fails with both sides shown.
fn[T : Eq + Show] same(actual : T, expected : T) -> Unit raise {
  if actual != expected {
    fail("actual=\{actual} expected=\{expected}")
  }
}

///|
/// Reports a boolean against its expected value.
fn same_bool(actual : Bool, expected : Bool) -> Unit raise {
  same(actual, expected)
}
