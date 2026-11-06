// The 6502 CPU as it appears inside the NES's 2A03.
//
// The design follows one rule that makes the golden-log tests meaningful: an
// instruction is a single `step` that consumes exactly as many cycles as the
// silicon, and the cycle count is computed rather than approximated. Branch and
// page-crossing penalties are therefore modelled explicitly, because
// `nestest.log` records the cumulative cycle count on every line and a single
// missed penalty desynchronises the remaining eight thousand lines.
//
// The 2A03 differs from a stock 6502 in one way that matters: decimal mode has
// no BCD adder behind it, so the decimal flag only suppresses the carry-based
// correction rather than changing the result.

///|
/// A 6502 register file plus the memory it addresses.
///
/// Memory is the console's 64 KiB bus, not the CPU's own store: reads and writes
/// go through `Bus` so that the PPU, APU and cartridge can intercept the
/// addresses the hardware routes to them.
pub(all) struct Cpu {
  /// Accumulator.
  mut a : UInt32
  /// Index register X.
  mut x : UInt32
  /// Index register Y.
  mut y : UInt32
  /// Stack pointer; the stack lives at $0100 + this value.
  mut sp : UInt32
  /// Program counter.
  mut pc : UInt32
  /// Packed status register. Bits are read through `Cpu::flag`.
  mut p : UInt32
  /// Total cycles executed since reset. This is the number `nestest.log`
  /// records, so it counts CPU cycles only, not PPU dots.
  mut cycles : Int64
  /// Cycles of DMA still owed to the bus; the CPU does not advance while this
  /// is positive.
  mut stalled : Int64
  /// The memory location the last instruction read or wrote, for the trace
  /// column `nestest.log` renders as `= XX`.
  mut last_access : MemoryAccess?
}

///|
/// A read/write window the CPU can reach.
///
/// The real machine has no single flat memory; the CPU addresses cartridge ROM,
/// work RAM, and memory-mapped registers that all answer through the bus. Keeping
/// that indirection here is what lets the CPU be tested with a plain RAM array
/// and then dropped into the console unchanged.
pub(open) trait Bus {
  /// Reads one byte, returning 0 for addresses nothing drives.
  fn read(self : Self, address : UInt32) -> UInt32
  /// Writes one byte, ignoring addresses that are read-only.
  fn write(self : Self, address : UInt32, value : UInt32) -> Unit
}

///|
/// A flat 64 KiB of RAM, used by tests and by the CPU-only trace runner.
///
/// It is deliberately not the console's bus: `nestest` executes with the
/// cartridge mapped at $C000 and plain RAM everywhere else, which is exactly
/// what this provides.
pub(all) struct FlatRam {
  bytes : FixedArray[Byte]
}

///|
/// Allocates 64 KiB of zeroed RAM.
pub fn FlatRam::new() -> FlatRam {
  FlatRam::{ bytes: FixedArray::make(0x10000, b'\x00'), }
}

///|
/// Copies an image into RAM starting at `base`.
///
/// Used to place a test ROM's code where the real console's mapper would have
/// put it, without pulling in a cartridge.
pub fn FlatRam::load(self : FlatRam, base : UInt32, image : Bytes) -> Unit {
  for i in 0..<image.length() {
    let at = (base + i.reinterpret_as_uint()) & 0xFFFF
    self.bytes[at.reinterpret_as_int()] = image.at(i)
  }
}

///|
/// Reads a byte from RAM.
pub impl Bus for FlatRam with fn read(self, address) {
  self.bytes[(address.to_int64() & 0xFFFFL).to_int()]
  .to_int()
  .reinterpret_as_uint() &
  0xFF
}

///|
/// Writes a byte to RAM, masking both the address and the value.
pub impl Bus for FlatRam with fn write(self, address, value) {
  self.bytes[(address.to_int64() & 0xFFFFL).to_int()] = (value & 0xFF).to_byte()
}

///|
/// Reaches the `Bus` methods through the trait only, so that a bare `ram.read`
/// is not silently available.
pub extend FlatRam with Bus::{read, write}

///|
/// The mask a single status flag occupies.
const FLAG_INTERRUPT : UInt32 = 0x04

///|
const FLAG_BREAK : UInt32 = 0x10

///|
const FLAG_UNUSED : UInt32 = 0x20

///|
/// A CPU with every register zeroed and the interrupt line masked, which is the
/// state `nestest` is written to observe.
pub fn Cpu::new() -> Cpu {
  {
    a: 0,
    x: 0,
    y: 0,
    sp: 0xFD,
    pc: 0,
    p: FLAG_UNUSED | FLAG_INTERRUPT,
    cycles: 0L,
    stalled: 0L,
    last_access: None,
  }
}

///|
/// Reads a status flag.
pub fn Cpu::flag(self : Cpu, flag : Flag) -> Bool {
  (self.p & flag.mask()) != 0
}

///|
/// Sets or clears a status flag.
pub fn Cpu::set_flag(self : Cpu, flag : Flag, value : Bool) -> Unit {
  if value {
    self.p = self.p | flag.mask()
  } else {
    self.p = self.p & (flag.mask() ^ 0xFFFF_FFFFU)
  }
}

///|
/// Sets or clears the zero and negative flags from an 8-bit result.
///
/// Every instruction that produces a value calls this once, which is why the
/// two flags never drift: there is exactly one place that touches them.
pub fn Cpu::set_zn(self : Cpu, value : UInt32) -> Unit {
  self.set_flag(Zero, (value & 0xFF) == 0)
  self.set_flag(Negative, (value & 0x80) != 0)
}

///|
/// The address an interrupt pushes as its return address, which is the program
/// counter plus one for a BRK and the raw program counter for a hardware
/// interrupt.
fn Cpu::push(self : Cpu, bus : &Bus, value : UInt32) -> Unit {
  let at = 0x0100U + self.sp
  bus.write(at, value & 0xFF)
  self.sp = (self.sp - 1) & 0xFF
}

///|
/// Pops a byte from the stack and returns it.
fn Cpu::pop(self : Cpu, bus : &Bus) -> UInt32 {
  self.sp = (self.sp + 1) & 0xFF
  bus.read(0x0100U + self.sp) & 0xFF
}

///|
/// Fetches the byte at the program counter and advances it.
fn Cpu::fetch(self : Cpu, bus : &Bus) -> UInt32 {
  let value = bus.read(self.pc) & 0xFF
  self.pc = (self.pc + 1) & 0xFFFF
  value
}

///|
/// Fetches a little-endian 16-bit operand and advances the program counter by
/// two.
fn Cpu::fetch16(self : Cpu, bus : &Bus) -> UInt32 {
  let lo = self.fetch(bus)
  let hi = self.fetch(bus)
  lo | (hi << 8)
}

///|
/// Reads a 16-bit value from an arbitrary address without incrementing the
/// program counter.
///
/// Only used where an instruction reads a pointer from memory; the 6502 has a
/// famous bug in this path for `JMP ($xxFF)`, reproduced separately.
fn read16(bus : &Bus, address : UInt32) -> UInt32 {
  let lo = bus.read(address & 0xFFFF)
  let hi = bus.read((address + 1) & 0xFFFF)
  lo | (hi << 8)
}

///|
/// The result of one instruction: how many cycles it consumed and whether it
/// touched memory in a way the caller should know about.
pub(all) struct StepResult {
  /// Cycles consumed, including branch and page-crossing penalties.
  cycles : Int64
  /// The opcode that was executed.
  opcode : UInt32
  /// The address of the opcode's first byte, so a trace can print the same
  /// `PC` column the golden log does.
  at : UInt32
  /// Set when the instruction read or wrote a memory location; `address` and
  /// `value` then describe it, which is how `nestest` renders operands such as
  /// `STX $00 = 00`.
  memory : MemoryAccess?
}

///|
/// A memory location an instruction touched, with the value after the access.
pub(all) struct MemoryAccess {
  address : UInt32
  /// The value written, or the value read if the instruction only read.
  value : UInt32
  /// True when this was a write, which the trace renders with `=`.
  write : Bool
}

///|
/// Executes one instruction and returns what it did.
///
/// `bus` is mutable through its trait object: the CPU is the only component that
/// drives the address lines, so everything else observes memory through the
/// effects of this call.
pub fn Cpu::step(self : Cpu, bus : &Bus) -> StepResult raise NesError {
  // A pending DMA stalls the CPU before the next fetch, and the stall is what
  // makes sprite DMA cost 513 cycles rather than 1.
  if self.stalled > 0L {
    let waited = self.stalled
    self.stalled = 0L
    self.cycles = self.cycles + waited
    return { cycles: waited, opcode: 0xFF, at: self.pc, memory: None, }
  }
  let at = self.pc
  let opcode = self.fetch(bus)
  let result = self.execute(bus, opcode, at)
  self.cycles = self.cycles + result.cycles
  result
}

///|
/// Fetches a byte without touching memory, used by the disassembler and the
/// trace runner to render the operand bytes of an instruction that has not
/// executed yet.
pub fn peek(bus : &Bus, address : UInt32) -> UInt32 {
  bus.read(address & 0xFFFF) & 0xFF
}
