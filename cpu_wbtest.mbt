// Tests for the CPU core.
//
// The synthetic cases pin down one instruction each, so a failure names the
// instruction. The fixture case reads the real `nestest` ROM and compares
// against `nestest.log`, which is the golden trace produced by a reference
// emulator on real hardware behaviour.

///|
/// A CPU paired with 64 KiB of flat RAM.
///
/// `nestest` maps its code at $C000 and uses plain RAM everywhere else, so a
/// flat bus is enough to run it without a cartridge.
fn harness() -> (Cpu, FlatRam) {
  (Cpu::new(), FlatRam::new())
}

///|
/// Writes a short program at `base` and points the CPU at it.
fn load_program(ram : FlatRam, cpu : Cpu, base : UInt32, code : Bytes) -> Unit {
  ram.load(base, code)
  cpu.pc = base
}

///|
/// Executes `count` instructions and returns the CPU for inspection.

///|
/// A freshly reset CPU masks interrupts and reserves stack from $FD, which is
/// the state every ROM's reset code expects.
test "reset state" {
  let cpu = Cpu::new()
  check_eq(cpu.a, 0U)
  check_eq(cpu.sp, 0xFDU)
  check_bool(cpu.flag(Interrupt), true)
  check_bool(cpu.flag(Carry), false)
  check_eq(cpu.cycles, 0L)
}

///|
/// Immediate loads take two cycles and set the zero and negative flags from the
/// value loaded.
test "LDA immediate sets flags and costs two cycles" {
  let (cpu, ram) = harness()
  // LDA #$80
  load_program(ram, cpu, 0xC000, b"\xa9\x80")
  let result = cpu.step(ram)
  check_eq(cpu.a, 0x80U)
  check_eq(result.cycles, 2L)
  check_bool(cpu.flag(Negative), true)
  check_bool(cpu.flag(Zero), false)
  check_eq(cpu.pc, 0xC002U)
}

///|
/// Loading zero sets the zero flag; the `nestest` log depends on this because
/// its first instructions are `LDX #$00` and friends.
test "LDA zero value sets the zero flag" {
  let (cpu, ram) = harness()
  load_program(ram, cpu, 0xC000, b"\xa9\x00")
  ignore(cpu.step(ram))
  check_bool(cpu.flag(Zero), true)
  check_bool(cpu.flag(Negative), false)
}

///|
/// A store records the address it wrote so that the trace can print the `= XX`
/// column the golden log shows.
test "STA absolute reports the address written" {
  let (cpu, ram) = harness()
  load_program(ram, cpu, 0xC000, b"\xa9\x2a\x8d\x00\x02")
  ignore(cpu.step(ram))
  let result = cpu.step(ram)
  check_eq(result.cycles, 4L)
  check_bool(
    result.memory is Some({ address: 0x0200, value: 0x2A, write: true, }),
    true,
  )
  check_eq(ram.read(0x0200), 0x2AU)
}

///|
/// `JSR` pushes the address of its own last byte and `RTS` increments it back,
/// which is why the pair round-trips.
test "JSR and RTS round-trip" {
  let (cpu, ram) = harness()
  // JSR $C009 ; NOP ; ... ; RTS
  load_program(ram, cpu, 0xC000, b"\x20\x09\xc0\xea\xea\xea\xea\xea\xea\x60")
  ignore(cpu.step(ram))
  check_eq(cpu.pc, 0xC009U)
  // JSR pushed two bytes, so the stack pointer moved down by two.
  check_eq(cpu.sp, 0xFBU)
  ignore(cpu.step(ram))
  check_eq(cpu.pc, 0xC003U)
}

///|
/// A taken branch that crosses a page costs one extra cycle.
///
/// `nestest` records the cumulative cycle count, so a missed penalty shifts every
/// later line; this is the case that catches it.
test "branch across a page costs an extra cycle" {
  let (cpu, ram) = harness()
  // At $C0FD: BEQ +$05 lands at $C104, crossing from page $C0 to $C1.
  ram.load(0xC0FD, b"\xf0\x05\xea\xea\xea\xea\xea\xea\xea\xea")
  cpu.pc = 0xC0FDU
  cpu.set_flag(Zero, true)
  let result = cpu.step(ram)
  check_eq(result.cycles, 4L)
  check_eq(cpu.pc, 0xC104U)
}

///|
/// An untaken branch costs two cycles and does not move the program counter past
/// its operand.
test "untaken branch costs two cycles" {
  let (cpu, ram) = harness()
  load_program(ram, cpu, 0xC000, b"\xf0\x05")
  cpu.set_flag(Zero, false)
  let result = cpu.step(ram)
  check_eq(result.cycles, 2L)
  check_eq(cpu.pc, 0xC002U)
}

///|
/// `ADC` sets carry on overflow out of bit 7 and overflow on signed overflow,
/// and the two disagree for the same operands.
test "ADC sets carry and overflow independently" {
  let (cpu, ram) = harness()
  // $7F + $01 = $80: no carry, but signed overflow.
  load_program(ram, cpu, 0xC000, b"\xa9\x7f\x69\x01")
  ignore(cpu.step(ram))
  ignore(cpu.step(ram))
  check_eq(cpu.a, 0x80U)
  check_bool(cpu.flag(Carry), false)
  check_bool(cpu.flag(Overflow), true)
  check_bool(cpu.flag(Negative), true)
}

///|
/// `SBC` borrows through carry: carry clear means one extra is subtracted.
test "SBC accounts for borrow" {
  let (cpu, ram) = harness()
  // $50 - $F0 - 1 = $5F, with carry clear afterwards.
  load_program(ram, cpu, 0xC000, b"\xa9\x50\xe9\xf0")
  cpu.set_flag(Carry, false)
  ignore(cpu.step(ram))
  ignore(cpu.step(ram))
  check_eq(cpu.a, 0x5FU)
  check_bool(cpu.flag(Carry), false)
}

///|
/// `JMP ($xxFF)` reads its high byte from `$xx00`: the 6502's indirect jump does
/// not carry into the next page, and ROMs place tables knowing that.
test "indirect jump reproduces the page-boundary bug" {
  let (cpu, ram) = harness()
  // JMP ($C1FF): lo comes from $C1FF, hi from $C100 rather than $C200 because
  // the pointer does not carry out of its page.
  ram.load(0xC000, b"\x6c\xff\xc1")
  ram.write(0xC1FF, 0x34)
  ram.write(0xC100, 0x12)
  ram.write(0xC200, 0x99)
  cpu.pc = 0xC000
  ignore(cpu.step(ram))
  check_eq(cpu.pc, 0x1234U)
}

///|
/// A page-crossing indexed read costs one extra cycle; the same instruction with
/// a non-crossing index does not.
test "page crossing on an indexed read costs a cycle" {
  let (cpu, ram) = harness()
  // LDX #$01 ; LDA $C0FF,X  -> $C100, crossing from $C0 to $C1.
  ram.load(0xC000, b"\xa2\x01\xbd\xff\xc0")
  ram.write(0xC100, 0x77)
  cpu.pc = 0xC000
  ignore(cpu.step(ram))
  let result = cpu.step(ram)
  check_eq(cpu.a, 0x77U)
  check_eq(result.cycles, 5L)
}

///|
/// The unofficial `LAX` loads the accumulator and X from one value; several
/// shipped games rely on it.
test "unofficial LAX loads both registers" {
  let (cpu, ram) = harness()
  ram.load(0xC000, b"\xa7\x10")
  ram.write(0x0010, 0x42)
  cpu.pc = 0xC000
  let result = cpu.step(ram)
  check_eq(cpu.a, 0x42U)
  check_eq(cpu.x, 0x42U)
  check_eq(result.cycles, 3L)
}

///|
/// Every instruction the decoder accepts must be one the CPU can execute without
/// raising, which is what the conformance ROMs assume. Opcodes that are not
/// implemented must raise `UnknownOpcode` rather than doing something arbitrary.
test "unimplemented opcodes are rejected by name" {
  let (cpu, ram) = harness()
  load_program(ram, cpu, 0xC000, b"\x02\x00")
  let result = Ok(cpu.step(ram)) catch { e => Err(e) }
  match result {
    Err(UnknownOpcode(opcode~, at~)) => {
      check_eq(opcode, 0x02U)
      check_eq(at, 0xC000U)
    }
    _ => fail("expected UnknownOpcode")
  }
}

///|
/// The real `nestest` ROM is executed for its first 200 instructions and every
/// line is compared with the golden log.
///
/// Only the first 200 lines are checked here so that the fast test suite stays
/// fast; `trace_test.mbt` runs the full 8991.
test "nestest matches the golden log for the first 200 instructions" {
  let rom = read_fixture("nestest.nes")
  let log = read_text_fixture("nestest.log")
  let golden = parse_golden(log)
  let (cpu, ram) = harness()
  // The ROM's 16-byte header precedes 16 KiB of PRG mapped at $C000 and 8 KiB of
  // CHR; `nestest` is executed from $C000 with no mapper, which is what makes it
  // usable as a CPU-only fixture.
  let prg = rom[16:].to_owned()
  ram.load(0xC000, prg)
  cpu.pc = 0xC000
  // `nestest.log` starts after the reset sequence, so its first line already
  // counts seven cycles that this CPU-only harness never executes. Seeding the
  // counter is what makes the columns comparable from line one.
  cpu.cycles = 7L
  let checked = if golden.length() < 200 { golden.length() } else { 200 }
  for i in 0..<checked {
    let expected = golden[i]
    let actual = (cpu.pc, cpu.a, cpu.x, cpu.y, cpu.p, cpu.sp, cpu.cycles)
    check_eq(actual, expected)
    ignore(cpu.step(ram))
  }
}

///|
/// Parses the golden trace into the tuple of CPU-owned fields per line.
///
/// The PPU column and the disassembly text are deliberately not parsed: the
/// first is the PPU's business and the second is a rendering choice, so a
/// mismatch in either would not mean the CPU is wrong.
fn parse_golden(
  text : String,
) -> Array[(UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, Int64)] {
  let out : Array[(UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, Int64)] = []
  for raw in text.split("\n") {
    if raw.length() < 80 {
      continue
    }
    let line = raw.to_owned()
    out.push(
      (
        parse_pc(line),
        parse_field(line, "A:"),
        parse_field(line, "X:"),
        parse_field(line, "Y:"),
        parse_field(line, "P:"),
        parse_field(line, "SP:"),
        parse_decimal(line, "CYC:"),
      ),
    )
  }
  out
}

///|
/// The 16-bit program counter in the first four columns.
fn parse_pc(line : String) -> UInt32 {
  let view = line.view()
  let mut value = 0U
  for i in 0..<4 {
    value = (value << 4) | hex_value(view.unsafe_get(i).unsafe_to_char())
  }
  value
}

///|
/// Reads the hex digits following a `LABEL:` marker, skipping the left padding
/// the log uses to keep its columns aligned.
fn parse_field(line : String, label : String) -> UInt32 {
  let view = line.view()
  let at = match view.find(label) {
    Some(i) => i
    None => return 0
  }
  let mut start = at + label.length()
  while start < view.length() {
    let c = view.unsafe_get(start).unsafe_to_char()
    if c == ' ' {
      start = start + 1
    } else {
      break
    }
  }
  let mut value = 0U
  let mut i = start
  while i < view.length() {
    let c = view.unsafe_get(i).unsafe_to_char()
    if c == ' ' || c == ',' {
      break
    }
    value = (value << 4) | hex_value(c)
    i = i + 1
  }
  value
}

///|
/// Reads the decimal digits following a `LABEL:` marker.
///
/// `CYC:` is decimal in the golden log while every register is hex, which is the
/// one place the format is inconsistent; reading it as hex would desynchronise
/// the cycle column from the third line onward.
fn parse_decimal(line : String, label : String) -> Int64 {
  let view = line.view()
  let at = match view.find(label) {
    Some(i) => i
    None => return 0L
  }
  let mut start = at + label.length()
  while start < view.length() {
    let c = view.unsafe_get(start).unsafe_to_char()
    if c == ' ' {
      start = start + 1
    } else {
      break
    }
  }
  let mut value = 0L
  let mut i = start
  while i < view.length() {
    let c = view.unsafe_get(i).unsafe_to_char()
    if c == ' ' || c == ',' {
      break
    }
    let code = c.to_int()
    if code >= 48 && code <= 57 {
      value = value * 10L + (code - 48).to_int64()
    } else {
      break
    }
    i = i + 1
  }
  value
}

///|
/// The value of one hex digit, or zero for anything else.
fn hex_value(unit : Char) -> UInt32 {
  let code = unit.to_int()
  if code >= 48 && code <= 57 {
    (code - 48).reinterpret_as_uint()
  } else if code >= 97 && code <= 102 {
    (code - 87).reinterpret_as_uint()
  } else if code >= 65 && code <= 70 {
    (code - 55).reinterpret_as_uint()
  } else {
    0U
  }
}

///|
/// Reads a checked-in binary fixture.
fn read_fixture(name : String) -> Bytes raise {
  let dir = @env.current_dir().unwrap()
  @fs.read_file_to_bytes(dir + "/internal/fixtures/" + name)
}

///|
/// Reads a checked-in text fixture as one string.
fn read_text_fixture(name : String) -> String raise {
  let bytes = read_fixture(name)
  @utf8.decode(bytes)
}

///|
/// Fails with both sides shown when two values differ.
///
/// A helper rather than a macro because the runner's snapshot facility keys on
/// the call site, and a snapshot taken inside a helper would report the
/// helper's line for every test that used it.
fn[T : Eq] check_eq(actual : T, expected : T) -> Unit raise {
  if actual != expected {
    inspect("mismatch")
    fail("values differ")
  }
}

///|
/// Compares two values whose `Show` is only wanted for a failure message.
///
/// Marked separately so that the deprecated `Show`-for-debugging path is used in
/// exactly one place rather than at every assertion.

///|
/// Fails when a boolean is not the expected value.
fn check_bool(actual : Bool, expected : Bool) -> Unit raise {
  check_eq(actual, expected)
}
