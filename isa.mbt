// The opcode decoder.
//
// One match arm per official opcode, plus the unofficial ones that shipped games
// and the conformance ROMs execute. Cycle counts live here rather than in the
// operations, because a 6502's cost is a property of the addressing mode:
// `LDA $1234` and `LDA ($12),Y` reach the same operation with different prices,
// and page-crossing penalties only apply to the modes that can cross at all.
//
// The single-opcode arms follow the data sheet line by line, which makes a wrong
// count easy to see against the entry it came from.

///|
/// A read-modify-write operation applied to a memory location.
priv enum RmwOp {
  Inc
  Dec
  Asl
  Lsr
  Rol
  Ror
}

///|
/// A two-step operation that modifies memory and then combines it into a
/// register, the shape of six unofficial instructions.
priv enum CombinedOp {
  SlO
  Rla
  Sre
  Rra
  Dcp
  Isc
}

///|
/// Executes one already-fetched opcode and returns what it did.
fn Cpu::execute(
  self : Cpu,
  bus : &Bus,
  opcode : UInt32,
  at : UInt32,
) -> StepResult raise NesError {
  // Cleared first so that "no memory touched" is the default state.
  self.last_access = None
  let cycles = match opcode {
    0x01 => {
      let addr = self.indexed_indirect(bus)
      self.ora(self.read_operand(bus, addr))
      6L
    }
    0x05 => {
      let addr = self.zeropage(bus)
      self.ora(self.read_operand(bus, addr))
      3L
    }
    0x09 => {
      self.ora(self.immediate(bus))
      2L
    }
    0x0D => {
      let addr = self.absolute(bus)
      self.ora(self.read_operand(bus, addr))
      4L
    }
    0x11 => {
      let (addr, page) = self.indirect_indexed_page(bus)
      self.ora(self.read_operand(bus, addr))
      5L + page
    }
    0x15 => {
      let addr = self.zeropage_x(bus)
      self.ora(self.read_operand(bus, addr))
      4L
    }
    0x19 => {
      let (addr, page) = self.absolute_y_page(bus)
      self.ora(self.read_operand(bus, addr))
      4L + page
    }
    0x1D => {
      let (addr, page) = self.absolute_x_page(bus)
      self.ora(self.read_operand(bus, addr))
      4L + page
    }
    0x21 => {
      let addr = self.indexed_indirect(bus)
      self.and_(self.read_operand(bus, addr))
      6L
    }
    0x25 => {
      let addr = self.zeropage(bus)
      self.and_(self.read_operand(bus, addr))
      3L
    }
    0x29 => {
      self.and_(self.immediate(bus))
      2L
    }
    0x2D => {
      let addr = self.absolute(bus)
      self.and_(self.read_operand(bus, addr))
      4L
    }
    0x31 => {
      let (addr, page) = self.indirect_indexed_page(bus)
      self.and_(self.read_operand(bus, addr))
      5L + page
    }
    0x35 => {
      let addr = self.zeropage_x(bus)
      self.and_(self.read_operand(bus, addr))
      4L
    }
    0x39 => {
      let (addr, page) = self.absolute_y_page(bus)
      self.and_(self.read_operand(bus, addr))
      4L + page
    }
    0x3D => {
      let (addr, page) = self.absolute_x_page(bus)
      self.and_(self.read_operand(bus, addr))
      4L + page
    }
    0x41 => {
      let addr = self.indexed_indirect(bus)
      self.eor(self.read_operand(bus, addr))
      6L
    }
    0x45 => {
      let addr = self.zeropage(bus)
      self.eor(self.read_operand(bus, addr))
      3L
    }
    0x49 => {
      self.eor(self.immediate(bus))
      2L
    }
    0x4D => {
      let addr = self.absolute(bus)
      self.eor(self.read_operand(bus, addr))
      4L
    }
    0x51 => {
      let (addr, page) = self.indirect_indexed_page(bus)
      self.eor(self.read_operand(bus, addr))
      5L + page
    }
    0x55 => {
      let addr = self.zeropage_x(bus)
      self.eor(self.read_operand(bus, addr))
      4L
    }
    0x59 => {
      let (addr, page) = self.absolute_y_page(bus)
      self.eor(self.read_operand(bus, addr))
      4L + page
    }
    0x5D => {
      let (addr, page) = self.absolute_x_page(bus)
      self.eor(self.read_operand(bus, addr))
      4L + page
    }
    0x61 => {
      let addr = self.indexed_indirect(bus)
      self.adc(self.read_operand(bus, addr))
      6L
    }
    0x65 => {
      let addr = self.zeropage(bus)
      self.adc(self.read_operand(bus, addr))
      3L
    }
    0x69 => {
      self.adc(self.immediate(bus))
      2L
    }
    0x6D => {
      let addr = self.absolute(bus)
      self.adc(self.read_operand(bus, addr))
      4L
    }
    0x71 => {
      let (addr, page) = self.indirect_indexed_page(bus)
      self.adc(self.read_operand(bus, addr))
      5L + page
    }
    0x75 => {
      let addr = self.zeropage_x(bus)
      self.adc(self.read_operand(bus, addr))
      4L
    }
    0x79 => {
      let (addr, page) = self.absolute_y_page(bus)
      self.adc(self.read_operand(bus, addr))
      4L + page
    }
    0x7D => {
      let (addr, page) = self.absolute_x_page(bus)
      self.adc(self.read_operand(bus, addr))
      4L + page
    }
    0x81 => {
      let addr = self.indexed_indirect(bus)
      self.store(bus, addr, self.a)
      6L
    }
    0x84 => {
      let addr = self.zeropage(bus)
      self.store(bus, addr, self.y)
      3L
    }
    0x85 => {
      let addr = self.zeropage(bus)
      self.store(bus, addr, self.a)
      3L
    }
    0x86 => {
      let addr = self.zeropage(bus)
      self.store(bus, addr, self.x)
      3L
    }
    0x8C => {
      let addr = self.absolute(bus)
      self.store(bus, addr, self.y)
      4L
    }
    0x8D => {
      let addr = self.absolute(bus)
      self.store(bus, addr, self.a)
      4L
    }
    0x8E => {
      let addr = self.absolute(bus)
      self.store(bus, addr, self.x)
      4L
    }
    0x91 => {
      let addr = self.indirect_indexed(bus)
      self.store(bus, addr, self.a)
      5L
    }
    0x94 => {
      let addr = self.zeropage_x(bus)
      self.store(bus, addr, self.y)
      4L
    }
    0x95 => {
      let addr = self.zeropage_x(bus)
      self.store(bus, addr, self.a)
      4L
    }
    0x96 => {
      let addr = self.zeropage_y(bus)
      self.store(bus, addr, self.x)
      4L
    }
    0x99 => {
      let addr = self.absolute_y(bus)
      self.store(bus, addr, self.a)
      4L
    }
    0x9D => {
      let addr = self.absolute_x(bus)
      self.store(bus, addr, self.a)
      4L
    }
    0xA0 => {
      self.ldy(self.immediate(bus))
      2L
    }
    0xA1 => {
      let addr = self.indexed_indirect(bus)
      self.lda(self.read_operand(bus, addr))
      6L
    }
    0xA2 => {
      self.ldx(self.immediate(bus))
      2L
    }
    0xA4 => {
      let addr = self.zeropage(bus)
      self.ldy(self.read_operand(bus, addr))
      3L
    }
    0xA5 => {
      let addr = self.zeropage(bus)
      self.lda(self.read_operand(bus, addr))
      3L
    }
    0xA6 => {
      let addr = self.zeropage(bus)
      self.ldx(self.read_operand(bus, addr))
      3L
    }
    0xA9 => {
      self.lda(self.immediate(bus))
      2L
    }
    0xAC => {
      let addr = self.absolute(bus)
      self.ldy(self.read_operand(bus, addr))
      4L
    }
    0xAD => {
      let addr = self.absolute(bus)
      self.lda(self.read_operand(bus, addr))
      4L
    }
    0xAE => {
      let addr = self.absolute(bus)
      self.ldx(self.read_operand(bus, addr))
      4L
    }
    0xB1 => {
      let (addr, page) = self.indirect_indexed_page(bus)
      self.lda(self.read_operand(bus, addr))
      5L + page
    }
    0xB4 => {
      let addr = self.zeropage_x(bus)
      self.ldy(self.read_operand(bus, addr))
      4L
    }
    0xB5 => {
      let addr = self.zeropage_x(bus)
      self.lda(self.read_operand(bus, addr))
      4L
    }
    0xB6 => {
      let addr = self.zeropage_y(bus)
      self.ldx(self.read_operand(bus, addr))
      4L
    }
    0xB9 => {
      let (addr, page) = self.absolute_y_page(bus)
      self.lda(self.read_operand(bus, addr))
      4L + page
    }
    0xBC => {
      let (addr, page) = self.absolute_x_page(bus)
      self.ldy(self.read_operand(bus, addr))
      4L + page
    }
    0xBD => {
      let (addr, page) = self.absolute_x_page(bus)
      self.lda(self.read_operand(bus, addr))
      4L + page
    }
    0xBE => {
      let (addr, page) = self.absolute_y_page(bus)
      self.ldx(self.read_operand(bus, addr))
      4L + page
    }
    0xC0 => {
      self.compare(self.y, self.immediate(bus))
      2L
    }
    0xC1 => {
      let addr = self.indexed_indirect(bus)
      self.compare(self.a, self.read_operand(bus, addr))
      6L
    }
    0xC4 => {
      let addr = self.zeropage(bus)
      self.compare(self.y, self.read_operand(bus, addr))
      3L
    }
    0xC5 => {
      let addr = self.zeropage(bus)
      self.compare(self.a, self.read_operand(bus, addr))
      3L
    }
    0xC9 => {
      self.compare(self.a, self.immediate(bus))
      2L
    }
    0xCC => {
      let addr = self.absolute(bus)
      self.compare(self.y, self.read_operand(bus, addr))
      4L
    }
    0xCD => {
      let addr = self.absolute(bus)
      self.compare(self.a, self.read_operand(bus, addr))
      4L
    }
    0xD1 => {
      let (addr, page) = self.indirect_indexed_page(bus)
      self.compare(self.a, self.read_operand(bus, addr))
      5L + page
    }
    0xD5 => {
      let addr = self.zeropage_x(bus)
      self.compare(self.a, self.read_operand(bus, addr))
      4L
    }
    0xD9 => {
      let (addr, page) = self.absolute_y_page(bus)
      self.compare(self.a, self.read_operand(bus, addr))
      4L + page
    }
    0xDD => {
      let (addr, page) = self.absolute_x_page(bus)
      self.compare(self.a, self.read_operand(bus, addr))
      4L + page
    }
    0xE0 => {
      self.compare(self.x, self.immediate(bus))
      2L
    }
    0xE1 => {
      let addr = self.indexed_indirect(bus)
      self.sbc(self.read_operand(bus, addr))
      6L
    }
    0xE4 => {
      let addr = self.zeropage(bus)
      self.compare(self.x, self.read_operand(bus, addr))
      3L
    }
    0xE5 => {
      let addr = self.zeropage(bus)
      self.sbc(self.read_operand(bus, addr))
      3L
    }
    0xE9 => {
      self.sbc(self.immediate(bus))
      2L
    }
    0xEB => {
      self.sbc(self.immediate(bus))
      2L
    }
    0xEC => {
      let addr = self.absolute(bus)
      self.compare(self.x, self.read_operand(bus, addr))
      4L
    }
    0xED => {
      let addr = self.absolute(bus)
      self.sbc(self.read_operand(bus, addr))
      4L
    }
    0xF1 => {
      let (addr, page) = self.indirect_indexed_page(bus)
      self.sbc(self.read_operand(bus, addr))
      5L + page
    }
    0xF5 => {
      let addr = self.zeropage_x(bus)
      self.sbc(self.read_operand(bus, addr))
      4L
    }
    0xF9 => {
      let (addr, page) = self.absolute_y_page(bus)
      self.sbc(self.read_operand(bus, addr))
      4L + page
    }
    0xFD => {
      let (addr, page) = self.absolute_x_page(bus)
      self.sbc(self.read_operand(bus, addr))
      4L + page
    }
    // ---- BIT ----
    0x24 => {
      let addr = self.zeropage(bus)
      self.bit(self.read_operand(bus, addr))
      3L
    }
    0x2C => {
      let addr = self.absolute(bus)
      self.bit(self.read_operand(bus, addr))
      4L
    }
    // ---- Transfers ----
    0xAA => {
      self.x = self.a
      self.set_zn(self.x)
      2L
    }
    0xA8 => {
      self.y = self.a
      self.set_zn(self.y)
      2L
    }
    0x8A => {
      self.a = self.x
      self.set_zn(self.a)
      2L
    }
    0x98 => {
      self.a = self.y
      self.set_zn(self.a)
      2L
    }
    0xBA => {
      self.x = self.sp
      self.set_zn(self.x)
      2L
    }
    0x9A => {
      self.sp = self.x
      2L
    }
    // ---- Stack ----
    0x48 => {
      self.push(bus, self.a)
      3L
    }
    0x68 => {
      self.a = self.pop(bus)
      self.set_zn(self.a)
      4L
    }
    0x08 => {
      self.push(bus, self.p | FLAG_BREAK | FLAG_UNUSED)
      3L
    }
    0x28 => {
      self.p = (self.pop(bus) | FLAG_UNUSED) & (FLAG_BREAK ^ 0xFFFF_FFFFU)
      4L
    }
    // ---- Register increments ----
    0xE8 => {
      self.x = self.inc(self.x)
      2L
    }
    0xC8 => {
      self.y = self.inc(self.y)
      2L
    }
    0xCA => {
      self.x = self.dec(self.x)
      2L
    }
    0x88 => {
      self.y = self.dec(self.y)
      2L
    }
    // ---- Shifts on the accumulator ----
    0x0A => {
      self.a = self.asl(self.a).0
      2L
    }
    0x4A => {
      self.a = self.lsr(self.a).0
      2L
    }
    0x2A => {
      self.a = self.rol(self.a).0
      2L
    }
    0x6A => {
      self.a = self.ror(self.a).0
      2L
    }
    // ---- Read-modify-write ----
    0xE6 => {
      let addr = self.zeropage(bus)
      self.rmw(bus, addr, Inc, 5L)
    }
    0xF6 => {
      let addr = self.zeropage_x(bus)
      self.rmw(bus, addr, Inc, 6L)
    }
    0xEE => {
      let addr = self.absolute(bus)
      self.rmw(bus, addr, Inc, 6L)
    }
    0xFE => {
      let addr = self.absolute_x(bus)
      self.rmw(bus, addr, Inc, 7L)
    }
    0xC6 => {
      let addr = self.zeropage(bus)
      self.rmw(bus, addr, Dec, 5L)
    }
    0xD6 => {
      let addr = self.zeropage_x(bus)
      self.rmw(bus, addr, Dec, 6L)
    }
    0xCE => {
      let addr = self.absolute(bus)
      self.rmw(bus, addr, Dec, 6L)
    }
    0xDE => {
      let addr = self.absolute_x(bus)
      self.rmw(bus, addr, Dec, 7L)
    }
    0x06 => {
      let addr = self.zeropage(bus)
      self.rmw(bus, addr, Asl, 5L)
    }
    0x16 => {
      let addr = self.zeropage_x(bus)
      self.rmw(bus, addr, Asl, 6L)
    }
    0x0E => {
      let addr = self.absolute(bus)
      self.rmw(bus, addr, Asl, 6L)
    }
    0x1E => {
      let addr = self.absolute_x(bus)
      self.rmw(bus, addr, Asl, 7L)
    }
    0x46 => {
      let addr = self.zeropage(bus)
      self.rmw(bus, addr, Lsr, 5L)
    }
    0x56 => {
      let addr = self.zeropage_x(bus)
      self.rmw(bus, addr, Lsr, 6L)
    }
    0x4E => {
      let addr = self.absolute(bus)
      self.rmw(bus, addr, Lsr, 6L)
    }
    0x5E => {
      let addr = self.absolute_x(bus)
      self.rmw(bus, addr, Lsr, 7L)
    }
    0x26 => {
      let addr = self.zeropage(bus)
      self.rmw(bus, addr, Rol, 5L)
    }
    0x36 => {
      let addr = self.zeropage_x(bus)
      self.rmw(bus, addr, Rol, 6L)
    }
    0x2E => {
      let addr = self.absolute(bus)
      self.rmw(bus, addr, Rol, 6L)
    }
    0x3E => {
      let addr = self.absolute_x(bus)
      self.rmw(bus, addr, Rol, 7L)
    }
    0x66 => {
      let addr = self.zeropage(bus)
      self.rmw(bus, addr, Ror, 5L)
    }
    0x76 => {
      let addr = self.zeropage_x(bus)
      self.rmw(bus, addr, Ror, 6L)
    }
    0x6E => {
      let addr = self.absolute(bus)
      self.rmw(bus, addr, Ror, 6L)
    }
    0x7E => {
      let addr = self.absolute_x(bus)
      self.rmw(bus, addr, Ror, 7L)
    }
    // ---- Control flow ----
    0x4C => {
      self.pc = self.fetch16(bus)
      3L
    }
    0x6C => self.jmp_indirect(bus)
    0x20 => {
      // JSR pushes its own last byte, so RTS's increment lands on the next
      // instruction.
      let target = self.fetch16(bus)
      let ret = (self.pc - 1) & 0xFFFF
      self.push(bus, (ret >> 8) & 0xFF)
      self.push(bus, ret & 0xFF)
      self.pc = target
      6L
    }
    0x60 => {
      let lo = self.pop(bus)
      let hi = self.pop(bus)
      self.pc = (((hi << 8) | lo) + 1) & 0xFFFF
      6L
    }
    0x40 => {
      let status = self.pop(bus)
      self.p = (status | FLAG_UNUSED) & (FLAG_BREAK ^ 0xFFFF_FFFFU)
      let lo = self.pop(bus)
      let hi = self.pop(bus)
      self.pc = (((hi << 8) | lo) + 1) & 0xFFFF
      6L
    }
    0x00 => self.brk(bus)
    0x10 => self.branch(bus, !self.flag(Negative))
    0x30 => self.branch(bus, self.flag(Negative))
    0x50 => self.branch(bus, !self.flag(Overflow))
    0x70 => self.branch(bus, self.flag(Overflow))
    0x90 => self.branch(bus, !self.flag(Carry))
    0xB0 => self.branch(bus, self.flag(Carry))
    0xD0 => self.branch(bus, !self.flag(Zero))
    0xF0 => self.branch(bus, self.flag(Zero))
    // ---- Flag operations ----
    0x18 => {
      self.set_flag(Carry, false)
      2L
    }
    0x38 => {
      self.set_flag(Carry, true)
      2L
    }
    0x58 => {
      self.set_flag(Interrupt, false)
      2L
    }
    0x78 => {
      self.set_flag(Interrupt, true)
      2L
    }
    0xB8 => {
      self.set_flag(Overflow, false)
      2L
    }
    0xD8 => {
      self.set_flag(Decimal, false)
      2L
    }
    0xF8 => {
      self.set_flag(Decimal, true)
      2L
    }
    0xEA => 2L
    // ---- Unofficial ----
    0x1A | 0x3A | 0x5A | 0x7A | 0xDA | 0xFA => 2L
    0x80 | 0x82 | 0x89 | 0xC2 | 0xE2 => {
      ignore(self.fetch(bus))
      2L
    }
    0x04 | 0x44 | 0x64 => {
      ignore(self.zeropage(bus))
      3L
    }
    0x14 | 0x34 | 0x54 | 0x74 | 0xD4 | 0xF4 => {
      ignore(self.zeropage_x(bus))
      4L
    }
    0x0C => {
      ignore(self.absolute(bus))
      4L
    }
    0x1C | 0x3C | 0x5C | 0x7C | 0xDC | 0xFC => {
      ignore(self.absolute_x(bus))
      4L
    }
    0xA7 => self.lax(bus, self.zeropage(bus), 3L)
    0xB7 => self.lax(bus, self.zeropage_y(bus), 4L)
    0xAF => self.lax(bus, self.absolute(bus), 4L)
    0xBF => {
      let (addr, page) = self.absolute_y_page(bus)
      self.lax(bus, addr, 4L) + page
    }
    0xA3 => self.lax(bus, self.indexed_indirect(bus), 6L)
    0xB3 => {
      let (addr, page) = self.indirect_indexed_page(bus)
      self.lax(bus, addr, 5L) + page
    }
    0x87 => {
      let addr = self.zeropage(bus)
      self.store(bus, addr, self.a & self.x)
      3L
    }
    0x97 => {
      let addr = self.zeropage_y(bus)
      self.store(bus, addr, self.a & self.x)
      4L
    }
    0x8F => {
      let addr = self.absolute(bus)
      self.store(bus, addr, self.a & self.x)
      4L
    }
    0x83 => {
      let addr = self.indexed_indirect(bus)
      self.store(bus, addr, self.a & self.x)
      6L
    }
    0x07 => self.combined(bus, self.zeropage(bus), SlO, 5L)
    0x17 => self.combined(bus, self.zeropage_x(bus), SlO, 6L)
    0x0F => self.combined(bus, self.absolute(bus), SlO, 6L)
    0x1F => self.combined(bus, self.absolute_x(bus), SlO, 7L)
    0x1B => self.combined(bus, self.absolute_y(bus), SlO, 7L)
    0x03 => self.combined(bus, self.indexed_indirect(bus), SlO, 8L)
    0x13 => self.combined(bus, self.indirect_indexed(bus), SlO, 8L)
    0x27 => self.combined(bus, self.zeropage(bus), Rla, 5L)
    0x37 => self.combined(bus, self.zeropage_x(bus), Rla, 6L)
    0x2F => self.combined(bus, self.absolute(bus), Rla, 6L)
    0x3F => self.combined(bus, self.absolute_x(bus), Rla, 7L)
    0x3B => self.combined(bus, self.absolute_y(bus), Rla, 7L)
    0x23 => self.combined(bus, self.indexed_indirect(bus), Rla, 8L)
    0x33 => self.combined(bus, self.indirect_indexed(bus), Rla, 8L)
    0x47 => self.combined(bus, self.zeropage(bus), Sre, 5L)
    0x57 => self.combined(bus, self.zeropage_x(bus), Sre, 6L)
    0x4F => self.combined(bus, self.absolute(bus), Sre, 6L)
    0x5F => self.combined(bus, self.absolute_x(bus), Sre, 7L)
    0x5B => self.combined(bus, self.absolute_y(bus), Sre, 7L)
    0x43 => self.combined(bus, self.indexed_indirect(bus), Sre, 8L)
    0x53 => self.combined(bus, self.indirect_indexed(bus), Sre, 8L)
    0x67 => self.combined(bus, self.zeropage(bus), Rra, 5L)
    0x77 => self.combined(bus, self.zeropage_x(bus), Rra, 6L)
    0x6F => self.combined(bus, self.absolute(bus), Rra, 6L)
    0x7F => self.combined(bus, self.absolute_x(bus), Rra, 7L)
    0x7B => self.combined(bus, self.absolute_y(bus), Rra, 7L)
    0x63 => self.combined(bus, self.indexed_indirect(bus), Rra, 8L)
    0x73 => self.combined(bus, self.indirect_indexed(bus), Rra, 8L)
    0xC7 => self.combined(bus, self.zeropage(bus), Dcp, 5L)
    0xD7 => self.combined(bus, self.zeropage_x(bus), Dcp, 6L)
    0xCF => self.combined(bus, self.absolute(bus), Dcp, 6L)
    0xDF => self.combined(bus, self.absolute_x(bus), Dcp, 7L)
    0xDB => self.combined(bus, self.absolute_y(bus), Dcp, 7L)
    0xC3 => self.combined(bus, self.indexed_indirect(bus), Dcp, 8L)
    0xD3 => self.combined(bus, self.indirect_indexed(bus), Dcp, 8L)
    0xE7 => self.combined(bus, self.zeropage(bus), Isc, 5L)
    0xF7 => self.combined(bus, self.zeropage_x(bus), Isc, 6L)
    0xEF => self.combined(bus, self.absolute(bus), Isc, 6L)
    0xFF => self.combined(bus, self.absolute_x(bus), Isc, 7L)
    0xFB => self.combined(bus, self.absolute_y(bus), Isc, 7L)
    0xE3 => self.combined(bus, self.indexed_indirect(bus), Isc, 8L)
    0xF3 => self.combined(bus, self.indirect_indexed(bus), Isc, 8L)
    0x0B | 0x2B => {
      self.a = self.a & self.fetch(bus)
      self.set_zn(self.a)
      self.set_flag(Carry, (self.a & 0x80) != 0)
      2L
    }
    0x4B => {
      self.a = (self.a >> 1) & self.fetch(bus)
      self.set_zn(self.a)
      2L
    }
    0x6B => {
      let v = self.a & self.fetch(bus)
      let carry = if self.flag(Carry) { 1U } else { 0U }
      self.a = ((v >> 1) | (carry << 7)) & 0xFF
      self.set_zn(self.a)
      self.set_flag(Carry, (self.a & 0x40) != 0)
      self.set_flag(Overflow, ((self.a >> 6) & 1) != ((self.a >> 5) & 1))
      2L
    }
    0xCB => {
      let v = self.a & self.fetch(bus)
      let result = (v - self.x) & 0xFF
      self.set_flag(Carry, v >= self.x)
      self.x = result
      self.set_zn(result)
      2L
    }
    0x8B => {
      let v = self.a & self.x & self.fetch(bus)
      let addr = self.zeropage(bus)
      self.store(bus, addr, v)
      2L
    }
    0x9F | 0x9B => {
      let (addr, _) = self.absolute_y_page(bus)
      let v = self.a & self.x & ((addr >> 8) & 0xFF)
      self.store(bus, addr, v)
      5L
    }
    0x93 => {
      let (addr, _) = self.indirect_indexed_page(bus)
      let v = self.a & self.x & ((addr >> 8) & 0xFF)
      self.store(bus, addr, v)
      6L
    }
    0x9C => {
      let (addr, _) = self.absolute_x_page(bus)
      let v = self.y & (((addr >> 8) + 1) & 0xFF)
      self.store(bus, addr, v)
      5L
    }
    0x9E => {
      let (addr, _) = self.absolute_y_page(bus)
      let v = self.x & (((addr >> 8) + 1) & 0xFF)
      self.store(bus, addr, v)
      5L
    }
    0xBB => {
      let (addr, page) = self.absolute_y_page(bus)
      let v = self.read_operand(bus, addr) & self.x & 0xFF
      self.sp = v
      self.a = v
      self.x = v
      self.set_zn(v)
      4L + page
    }
    _ => raise UnknownOpcode(opcode~, at~)
  }
  { cycles, opcode, at, memory: self.last_access, }
}

///|
/// Reads an operand, recording it so that the trace can render `LDA $00 = 01`.
fn Cpu::read_operand(self : Cpu, bus : &Bus, address : UInt32) -> UInt32 {
  let value = bus.read(address & 0xFFFF) & 0xFF
  self.last_access = Some({ address, value, write: false, })
  value
}

///|
/// Applies a read-modify-write operation to a memory address.
///
/// The 6502 writes the unmodified value back before the modified one; nothing a
/// ROM can observe depends on that, so only the final value is written while the
/// passed cycle count carries the cost of both writes.
fn Cpu::rmw(
  self : Cpu,
  bus : &Bus,
  address : UInt32,
  op : RmwOp,
  cycles : Int64,
) -> Int64 {
  let current = bus.read(address & 0xFFFF) & 0xFF
  let result = match op {
    Inc => self.inc(current)
    Dec => self.dec(current)
    Asl => self.asl(current).0
    Lsr => self.lsr(current).0
    Rol => self.rol(current).0
    Ror => self.ror(current).0
  }
  bus.write(address & 0xFFFF, result)
  self.last_access = Some({ address, value: result, write: true, })
  cycles
}

///|
/// `LAX`: loads both the accumulator and X from one value.
fn Cpu::lax(self : Cpu, bus : &Bus, address : UInt32, cycles : Int64) -> Int64 {
  let value = self.read_operand(bus, address)
  self.a = value
  self.x = value
  self.set_zn(value)
  cycles
}

///|
/// The unofficial read-modify-write-then-combine instructions.
fn Cpu::combined(
  self : Cpu,
  bus : &Bus,
  address : UInt32,
  op : CombinedOp,
  cycles : Int64,
) -> Int64 {
  let current = bus.read(address & 0xFFFF) & 0xFF
  let modified = match op {
    SlO => self.asl(current).0
    Rla => self.rol(current).0
    Sre => self.lsr(current).0
    Rra => self.ror(current).0
    Dcp => self.dec(current)
    Isc => self.inc(current)
  }
  bus.write(address & 0xFFFF, modified)
  self.last_access = Some({ address, value: modified, write: true, })
  match op {
    SlO => {
      self.a = self.a | modified
      self.set_zn(self.a)
    }
    Rla => {
      self.a = self.a & modified
      self.set_zn(self.a)
    }
    Sre => {
      self.a = self.a ^ modified
      self.set_zn(self.a)
    }
    Rra => self.adc(modified)
    Dcp => self.compare(self.a, modified)
    Isc => self.sbc(modified)
  }
  cycles
}
