// The 6502 operations, independent of how their operands were addressed.
//
// Each function here takes the already-resolved operand and performs the
// operation, returning the cycle count for that addressing mode's fixed part.
// The addressing modes are in `addressing.mbt` and the opcode-to-mode mapping is
// in `isa.mbt`, so an operation is written once no matter how many addressing
// modes reach it.

///|
/// Loads the accumulator.
pub fn Cpu::lda(self : Cpu, value : UInt32) -> Unit {
  self.a = value & 0xFF
  self.set_zn(self.a)
}

///|
/// Loads X.
pub fn Cpu::ldx(self : Cpu, value : UInt32) -> Unit {
  self.x = value & 0xFF
  self.set_zn(self.x)
}

///|
/// Loads Y.
pub fn Cpu::ldy(self : Cpu, value : UInt32) -> Unit {
  self.y = value & 0xFF
  self.set_zn(self.y)
}

///|
/// Stores the accumulator, recording the write for the trace column.
pub fn Cpu::store(
  self : Cpu,
  bus : &Bus,
  address : UInt32,
  value : UInt32,
) -> Unit {
  let v = value & 0xFF
  bus.write(address, v)
  self.last_access = Some({ address, value: v, write: true, })
}

///|
/// `AND` with the accumulator.
pub fn Cpu::and_(self : Cpu, value : UInt32) -> Unit {
  self.a = self.a & value
  self.set_zn(self.a)
}

///|
/// `ORA` with the accumulator.
pub fn Cpu::ora(self : Cpu, value : UInt32) -> Unit {
  self.a = self.a | value
  self.set_zn(self.a)
}

///|
/// `EOR` with the accumulator.
pub fn Cpu::eor(self : Cpu, value : UInt32) -> Unit {
  self.a = self.a ^ value
  self.set_zn(self.a)
}

///|
/// `ADC`: add with carry.
///
/// The 2A03 has no decimal adder, so the decimal flag only suppresses the
/// binary result's meaning on real hardware; the arithmetic performed is always
/// binary. The overflow flag is set from the sign bits of the operands rather
/// than from the result's carry, because carries out of bit 6 and bit 7 disagree
/// in the overflow case.
pub fn Cpu::adc(self : Cpu, value : UInt32) -> Unit {
  let a = self.a & 0xFF
  let m = value & 0xFF
  let carry = if self.flag(Carry) { 1U } else { 0U }
  let sum = a + m + carry
  let result = sum & 0xFF
  self.set_flag(Carry, sum > 0xFF)
  self.set_flag(Overflow, ((a ^ result) & (m ^ result) & 0x80) != 0)
  self.a = result
  self.set_zn(result)
}

///|
/// `SBC`: subtract with borrow, which on the 6502 is `ADC` of the complement.
pub fn Cpu::sbc(self : Cpu, value : UInt32) -> Unit {
  let a = self.a & 0xFF
  let m = value & 0xFF
  let borrow = if self.flag(Carry) { 0U } else { 1U }
  let diff = a - m - borrow
  let result = diff & 0xFF
  self.set_flag(Carry, diff < 0x100 && a >= m + borrow)
  self.set_flag(Overflow, ((a ^ result) & (0xFF ^ m ^ result) & 0x80) != 0)
  self.a = result
  self.set_zn(result)
}

///|
/// Compares a register with a value, setting carry when the register is at
/// least the value.
pub fn Cpu::compare(self : Cpu, register : UInt32, value : UInt32) -> Unit {
  let r = register & 0xFF
  let v = value & 0xFF
  self.set_flag(Carry, r >= v)
  self.set_zn((r - v) & 0xFF)
}

///|
/// Increments a value without touching memory.
pub fn Cpu::inc(self : Cpu, value : UInt32) -> UInt32 {
  let v = (value + 1) & 0xFF
  self.set_zn(v)
  v
}

///|
/// Decrements a value without touching memory.
pub fn Cpu::dec(self : Cpu, value : UInt32) -> UInt32 {
  let v = (value - 1) & 0xFF
  self.set_zn(v)
  v
}

///|
/// Arithmetic shift left: bit 7 moves into carry, bit 0 becomes zero.
pub fn Cpu::asl(self : Cpu, value : UInt32) -> (UInt32, UInt32) {
  let v = value & 0xFF
  self.set_flag(Carry, (v & 0x80) != 0)
  let result = (v << 1) & 0xFF
  self.set_zn(result)
  (result, result)
}

///|
/// Logical shift right: bit 0 moves into carry, bit 7 becomes zero.
pub fn Cpu::lsr(self : Cpu, value : UInt32) -> (UInt32, UInt32) {
  let v = value & 0xFF
  self.set_flag(Carry, (v & 0x01) != 0)
  let result = (v >> 1) & 0xFF
  self.set_zn(result)
  (result, result)
}

///|
/// Rotate left through carry.
pub fn Cpu::rol(self : Cpu, value : UInt32) -> (UInt32, UInt32) {
  let v = value & 0xFF
  let carry_in = if self.flag(Carry) { 1U } else { 0U }
  self.set_flag(Carry, (v & 0x80) != 0)
  let result = ((v << 1) | carry_in) & 0xFF
  self.set_zn(result)
  (result, result)
}

///|
/// Rotate right through carry.
pub fn Cpu::ror(self : Cpu, value : UInt32) -> (UInt32, UInt32) {
  let v = value & 0xFF
  let carry_in = if self.flag(Carry) { 0x80U } else { 0U }
  self.set_flag(Carry, (v & 0x01) != 0)
  let result = ((v >> 1) | carry_in) & 0xFF
  self.set_zn(result)
  (result, result)
}

///|
/// A taken branch: adds the signed displacement and one cycle, plus another when
/// the branch crosses into a new page.
pub fn Cpu::branch(self : Cpu, bus : &Bus, taken : Bool) -> Int64 {
  let displacement = self.fetch(bus)
  if !taken {
    return 2L
  }
  let offset = if (displacement & 0x80) != 0 {
    displacement.to_int64() - 0x100L
  } else {
    displacement.to_int64()
  }
  let from = self.pc
  let target = ((self.pc.to_int64() + offset) & 0xFFFFL)
    .to_int()
    .reinterpret_as_uint()
  self.pc = target
  let penalty = if (from & 0xFF00) != (target & 0xFF00) { 1L } else { 0L }
  3L + penalty
}

///|
/// `JMP ($addr)`: the 6502's indirect jump does not carry into the high byte of
/// the pointer, so a pointer at `$xxFF` reads its high byte from `$xx00`.
///
/// Reproducing the bug matters because real ROMs jump through tables placed to
/// avoid it, and because `nestest` checks it.
pub fn Cpu::jmp_indirect(self : Cpu, bus : &Bus) -> Int64 {
  let pointer = self.fetch16(bus)
  let lo = bus.read(pointer)
  let hi_addr = (pointer & 0xFF00) | ((pointer + 1) & 0xFF)
  let hi = bus.read(hi_addr)
  self.pc = lo | (hi << 8)
  5L
}

///|
/// `BRK`: pushes the return address plus two, the break flag and the status,
/// then vectors through the IRQ vector with the interrupt mask set.
pub fn Cpu::brk(self : Cpu, bus : &Bus) -> Int64 {
  let ret = (self.pc + 1) & 0xFFFF
  self.push(bus, (ret >> 8) & 0xFF)
  self.push(bus, ret & 0xFF)
  self.push(bus, self.p | FLAG_BREAK | FLAG_UNUSED)
  self.set_flag(Interrupt, true)
  let vector = read16(bus, 0xFFFE)
  self.pc = vector
  7L
}

///|
/// `BIT`: tests bits of a memory value against the accumulator.
///
/// The zero flag is set from the AND, but the negative and overflow flags are
/// copied straight from bits 7 and 6 of the operand, which is why `BIT` can be
/// used as a two-bit branch on a single memory read.
pub fn Cpu::bit(self : Cpu, value : UInt32) -> Unit {
  let v = value & 0xFF
  self.set_flag(Zero, (self.a & v) == 0)
  self.set_flag(Negative, (v & 0x80) != 0)
  self.set_flag(Overflow, (v & 0x40) != 0)
}
