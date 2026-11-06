// The 6502 addressing modes.
//
// Each mode is one function that consumes its operand bytes and returns the
// effective address. The modes that can cross a page boundary return the extra
// cycle alongside the address, because the penalty is a property of the mode,
// not of the instruction using it, and computing it in one place is what keeps
// `nestest`'s cumulative cycle column in step.

///|
/// The one-byte operand of an immediate instruction.
///
/// Returns the operand value rather than an address, since immediate operands
/// live in the instruction stream.
pub fn Cpu::immediate(self : Cpu, bus : &Bus) -> UInt32 {
  self.fetch(bus)
}

///|
/// Zero-page address, always below $0100.
pub fn Cpu::zeropage(self : Cpu, bus : &Bus) -> UInt32 {
  self.fetch(bus) & 0xFF
}

///|
/// Zero-page address plus X, wrapping inside the page.
pub fn Cpu::zeropage_x(self : Cpu, bus : &Bus) -> UInt32 {
  (self.fetch(bus) + self.x) & 0xFF
}

///|
/// Zero-page address plus Y, wrapping inside the page.
pub fn Cpu::zeropage_y(self : Cpu, bus : &Bus) -> UInt32 {
  (self.fetch(bus) + self.y) & 0xFF
}

///|
/// A 16-bit absolute address.
pub fn Cpu::absolute(self : Cpu, bus : &Bus) -> UInt32 {
  self.fetch16(bus)
}

///|
/// Absolute address plus X, without reporting a page crossing.
///
/// Used by the addressing modes that always take five cycles: a store cannot
/// profit from the crossed page being already open, so the penalty is part of
/// its fixed cost.
pub fn Cpu::absolute_x(self : Cpu, bus : &Bus) -> UInt32 {
  let base = self.fetch16(bus)
  (base + self.x) & 0xFFFF
}

///|
/// Absolute address plus Y, without reporting a page crossing.
pub fn Cpu::absolute_y(self : Cpu, bus : &Bus) -> UInt32 {
  let base = self.fetch16(bus)
  (base + self.y) & 0xFFFF
}

///|
/// Absolute address plus X, reporting one extra cycle when the addition carries
/// out of the low byte.
pub fn Cpu::absolute_x_page(self : Cpu, bus : &Bus) -> (UInt32, Int64) {
  let base = self.fetch16(bus)
  let addr = (base + self.x) & 0xFFFF
  (addr, page_penalty(base, self.x))
}

///|
/// Absolute address plus Y, reporting one extra cycle when the addition carries
/// out of the low byte.
pub fn Cpu::absolute_y_page(self : Cpu, bus : &Bus) -> (UInt32, Int64) {
  let base = self.fetch16(bus)
  let addr = (base + self.y) & 0xFFFF
  (addr, page_penalty(base, self.y))
}

///|
/// The `(zp,X)` mode: the operand is a zero-page address, X is added to it with
/// wraparound, and the two bytes there form the effective address.
///
/// The zero-page wraparound is not a bug to be fixed: `LDA ($FF,X)` reads its
/// pointer from $FF and $00.
pub fn Cpu::indexed_indirect(self : Cpu, bus : &Bus) -> UInt32 {
  let zp = (self.fetch(bus) + self.x) & 0xFF
  let lo = bus.read(zp)
  let hi = bus.read((zp + 1) & 0xFF)
  lo | (hi << 8)
}

///|
/// The `(zp),Y` mode without a page-crossing report.
pub fn Cpu::indirect_indexed(self : Cpu, bus : &Bus) -> UInt32 {
  let zp = self.fetch(bus) & 0xFF
  let lo = bus.read(zp)
  let hi = bus.read((zp + 1) & 0xFF)
  ((lo | (hi << 8)) + self.y) & 0xFFFF
}

///|
/// The `(zp),Y` mode reporting one extra cycle when Y carries out of the low
/// byte of the pointer.
pub fn Cpu::indirect_indexed_page(self : Cpu, bus : &Bus) -> (UInt32, Int64) {
  let zp = self.fetch(bus) & 0xFF
  let lo = bus.read(zp)
  let hi = bus.read((zp + 1) & 0xFF)
  let base = lo | (hi << 8)
  ((base + self.y) & 0xFFFF, page_penalty(base, self.y))
}

///|
/// One cycle when adding `index` to `base` carries out of the low byte.
fn page_penalty(base : UInt32, index : UInt32) -> Int64 {
  if (base & 0xFF) + (index & 0xFF) > 0xFF {
    1L
  } else {
    0L
  }
}
