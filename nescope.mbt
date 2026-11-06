// nescope — a Nintendo Entertainment System emulator in pure MoonBit.
//
// This file holds the shared vocabulary: the error type, the CPU status flags,
// the button set and the small helpers every other module reads through.

///|
/// Every way a cartridge image or an emulator request can be rejected.
///
/// Loading never returns a half-filled cartridge: a malformed image surfaces as
/// one of these variants instead of an out-of-range read, and every variant
/// names the field or mapper that failed.
pub(all) suberror NesError {
  /// The buffer ended before the structure could be read completely.
  UnexpectedEnd(offset~ : Int64, needed~ : Int64, available~ : Int64)
  /// The 4-byte magic "NES\x1a" does not start the file.
  NotAnINes
  /// A header field that must take one of a small set of values holds
  /// something else.
  BadValue(field~ : String, value~ : Int64)
  /// The header declares a PRG or CHR size that the file cannot back.
  Truncated(kind~ : String, declared~ : Int64, present~ : Int64)
  /// A mapper this build does not implement.
  UnsupportedMapper(number~ : UInt32)
  /// A CPU opcode that has no handler, reported with the address that fetched
  /// it. On the 6502 this is a real class of input, not a bug: the official
  /// set has 151 of 256 opcodes, and the rest are unofficial.
  UnknownOpcode(opcode~ : UInt32, at~ : UInt32)
  /// A lockout chip (Tengen/Infrared) blocks the cartridge.
  LockoutChip
}

///|
/// Renders an error as a single line naming the field and value that failed.
pub impl Show for NesError with fn output(self, logger) {
  let text = match self {
    UnexpectedEnd(offset~, needed~, available~) =>
      "unexpected end at \{offset}: needed \{needed} bytes, \{available} available"
    NotAnINes => "not an iNES image: missing the NES\\x1a magic"
    BadValue(field~, value~) => "bad value for \{field}: \{value}"
    Truncated(kind~, declared~, present~) =>
      "\{kind} declared \{declared} bytes but the file has \{present}"
    UnsupportedMapper(number~) => "mapper \{number} is not implemented"
    UnknownOpcode(opcode~, at~) =>
      "unknown opcode $\{hex2(opcode)} at $\{hex4(at)}"
    LockoutChip => "the cartridge reports an unsupported lockout chip"
  }
  logger.write_string(text)
}

///|
/// Exposes the message as a plain string for tests and CLI output.
pub extend NesError with Show::{to_string, output}

///|
/// Formats a 32-bit value as `$` plus eight lowercase hex digits.
pub fn hex8(value : UInt32) -> String {
  "$" + hex_digits(value.to_int64(), 8)
}

///|
/// Formats a byte as `$` plus two lowercase hex digits, the width the 6502
/// disassembly column uses.
pub fn hex2(value : UInt32) -> String {
  "$" + hex_digits(value.to_int64() & 0xFFL, 2)
}

///|
/// Formats a 16-bit value as `$` plus four lowercase hex digits, the width of a
/// 6502 address.
pub fn hex4(value : UInt32) -> String {
  "$" + hex_digits(value.to_int64() & 0xFFFFL, 4)
}

///|
/// Renders a value in lowercase hex, zero-padded to `digits` characters.
///
/// Padding is done here rather than with a format specifier so that the same
/// text is produced on every backend, including wasm-gc.
fn hex_digits(value : Int64, digits : Int32) -> String {
  let text = value.to_string(radix=16)
  let pad = digits - text.length()
  if pad <= 0 {
    return text
  }
  let buf = StringBuilder(size_hint=digits)
  for _ in 0..<pad {
    buf.write_char('0')
  }
  buf.write_string(text)
  buf.to_string()
}

///|
/// The 6502 status register, one constructor per bit.
///
/// Kept as an enum rather than raw bit numbers so that the instruction
/// implementations read the way the data sheet does; the bit position is only
/// materialised when the register is pushed to or pulled from the stack.
pub(all) enum Flag {
  /// Bit 0, carry: also the "no borrow" bit after a comparison.
  Carry
  /// Bit 1, unused in most respects but pushed as one and true on real
  /// hardware.
  Zero
  /// Bit 2, IRQ disable.
  Interrupt
  /// Bit 3, decimal mode. The NES's 2A03 has no BCD adder, so this bit only
  /// suppresses it rather than changing arithmetic.
  Decimal
  /// Bit 4, break: set only in the copy of P pushed by a BRK or PHP.
  Break
  /// Bit 5, unused and always pushed as one.
  Unused
  /// Bit 6, signed overflow.
  Overflow
  /// Bit 7, negative: the sign bit latched
  Negative
}

///|
/// The bit position of a flag inside the packed status register.
pub fn Flag::bit(self : Flag) -> Int32 {
  match self {
    Carry => 0
    Zero => 1
    Interrupt => 2
    Decimal => 3
    Break => 4
    Unused => 5
    Overflow => 6
    Negative => 7
  }
}

///|
/// The mask that isolates a flag inside the packed status register.
pub fn Flag::mask(self : Flag) -> UInt32 {
  ((1UL << self.bit()) & 0xFFFF_FFFFUL).to_uint()
}

///|
/// The eight buttons a standard NES controller reports.
pub(all) enum Button {
  A
  B
  Select
  Start
  Up
  Down
  Left
  Right
}

///|
/// The position of a button in the controller's serial shift order.
///
/// The order is fixed by the hardware's shift register and is the order every
/// ROM's input code assumes: A first, then B, then the two selects, then the
/// d-pad from up to right.
pub fn Button::shift_index(self : Button) -> Int32 {
  match self {
    A => 0
    B => 1
    Select => 2
    Start => 3
    Up => 4
    Down => 5
    Left => 6
    Right => 7
  }
}

///|
/// The console region, which decides the CPU and PPU clock rates.
///
/// The rates differ enough that a PAL ROM run at NTSC speed drifts, so the rate
/// is carried in the type rather than assumed.
pub(all) enum Region {
  NTSC
  PAL
  Dendy
}

///|
/// CPU clock rate in hertz for the region.
pub fn Region::cpu_hz(self : Region) -> Int64 {
  match self {
    NTSC => 1_789_773L
    PAL => 1_662_607L
    Dendy => 1_773_448L
  }
}

///|
/// PPU dots per scanline for the region.
pub fn Region::dots_per_scanline(self : Region) -> Int32 {
  match self {
    NTSC => 341
    PAL => 341
    Dendy => 341
  }
}

///|
/// PPU scanlines per frame for the region, including the vertical blanking
/// lines the PPU does not render.
pub fn Region::scanlines_per_frame(self : Region) -> Int32 {
  match self {
    NTSC => 262
    PAL => 312
    Dendy => 312
  }
}
