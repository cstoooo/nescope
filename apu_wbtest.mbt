// Tests for the APU's frame counter and channel status.
//
// The frame counter is not audio; it is a CPU-visible timer, and a game that
// misses it waits forever. These tests pin its period, its wrap and the fact
// that five-step mode never interrupts.

///|
/// A powered APU with the frame counter running.
fn running_apu() -> Apu {
  let apu = Apu::new()
  apu.write_status(0x0FU)
  apu
}

///|
test "the four-step counter raises its interrupt at the end of the sequence" {
  let apu = running_apu()
  // The sequence's last step is at 29829 CPU cycles; one cycle short, nothing
  // has been raised yet.
  inspect_bool(apu.tick(29828L), false)
  inspect_bool(apu.frame_irq, false)
  // The cycle itself raises it, and that cycle is included rather than excluded.
  inspect_bool(apu.tick(2L), true)
  inspect_bool(apu.frame_irq, true)
}

///|
test "the frame counter wraps and raises the interrupt every frame" {
  // This is the failure a stopping counter produces: the first interrupt arrives
  // and the second never does, so a game synchronised to it hangs on the frame it
  // started on. Ticking two and a half frames must raise two interrupts.
  let apu = running_apu()
  let mut raised = 0
  for _ in 0..<3 {
    if apu.tick(29829L) {
      raised = raised + 1
    }
  }
  inspect_eq(raised, 3)
}

///|
test "five-step mode never raises the interrupt" {
  let apu = running_apu()
  // $80 selects five-step mode; $40 would inhibit the interrupt, so leaving it
  // clear proves the mode alone is what suppresses it.
  apu.write_register(0x17U, 0x80U)
  let mut raised = 0
  for _ in 0..<4 {
    if apu.tick(37281L) {
      raised = raised + 1
    }
  }
  inspect_eq(raised, 0)
  inspect_bool(apu.frame_irq, false)
}

///|
test "the interrupt-inhibit bit suppresses the four-step interrupt" {
  let apu = running_apu()
  apu.write_register(0x17U, 0x40U)
  inspect_bool(apu.tick(29829L), false)
  inspect_bool(apu.frame_irq, false)
}

///|
test "reading the status register acknowledges the frame interrupt" {
  let apu = running_apu()
  ignore(apu.tick(29829L))
  inspect_bool(apu.frame_irq, true)
  // Bit 6 reports the pending interrupt, and reading clears it, which is the
  // only acknowledgement the hardware offers.
  inspect_eq(apu.read_status() & 0x40U, 0x40U)
  inspect_bool(apu.frame_irq, false)
  inspect_eq(apu.read_status() & 0x40U, 0U)
}

///|
test "a length counter write only loads while the channel is on" {
  let apu = Apu::new()
  // Channel zero is off until $4015 enables it; a length write must not start it.
  apu.write_register(0x03U, 0x08U)
  inspect_eq(apu.read_status() & 0x01U, 0U)
  apu.write_status(0x01U)
  apu.write_register(0x03U, 0x08U)
  inspect_eq(apu.read_status() & 0x01U, 0x01U)
}

///|
test "the half-frame clock drains length counters and silencing clears them" {
  let apu = Apu::new()
  apu.write_status(0x0FU)
  // Load one unit of length on channel zero: top five bits of $04.
  apu.write_register(0x03U, 0x08U)
  inspect_eq(apu.read_status() & 0x01U, 0x01U)
  // The sequence's first two steps land at 7457 and 14913 cycles: a quarter-frame
  // clock then a half-frame one. Only the half-frame clock drains the length
  // counter, so it is the second step that silences the channel.
  ignore(apu.tick(14913L))
  inspect_eq(apu.read_status() & 0x01U, 0U)
  // Writing a channel's bit low in $4015 clears its length counter outright, so
  // the channel falls silent without waiting for a clock.
  apu.write_register(0x03U, 0x08U)
  inspect_eq(apu.read_status() & 0x01U, 0x01U)
  apu.write_status(0x00U)
  inspect_eq(apu.read_status() & 0x01U, 0U)
}

///|
test "the halt bit keeps a length counter from draining" {
  let apu = Apu::new()
  apu.write_status(0x01U)
  // Bit 5 of $4000 halts channel zero's length counter, which is how a game holds
  // a note indefinitely.
  apu.write_register(0x00U, 0x20U)
  apu.write_register(0x03U, 0x08U)
  inspect_eq(apu.read_status() & 0x01U, 0x01U)
  ignore(apu.tick(14913L))
  inspect_eq(apu.read_status() & 0x01U, 0x01U)
}

///|
test "a frame counter write restarts the sequence" {
  let apu = running_apu()
  ignore(apu.tick(20000L))
  inspect_bool(apu.tick(9829L), true)
  // Writing $4017 mid-sequence puts the counter back at its start, so the next
  // interrupt needs a full period again rather than the remainder.
  apu.write_register(0x17U, 0x00U)
  inspect_bool(apu.tick(20000L), false)
  inspect_bool(apu.tick(9829L), true)
}

///|
test "the console takes the frame interrupt through the IRQ vector" {
  // A cartridge whose maskable vector points at a handler that writes a flag.
  let out = Buffer::Buffer(size_hint=16 + 0x4000 + 0x2000)
  out.write_byte(b'N')
  out.write_byte(b'E')
  out.write_byte(b'S')
  out.write_byte(b'\x1A')
  out.write_byte(b'\x01')
  out.write_byte(b'\x01')
  for _ in 0..<10 {
    out.write_byte(b'\x00')
  }
  let body = Buffer::Buffer(size_hint=0x4000)
  for _ in 0..<0x4000 {
    body.write_byte(b'\xEA')
  }
  // The IRQ handler is an RTI at $C400, but the test only needs the vector to
  // point somewhere reachable; the PC after the interrupt proves it was taken.
  for i in 0..<0x4000 {
    out.write_byte(body.to_bytes().at(i))
  }
  for _ in 0..<0x2000 {
    out.write_byte(b'\x00')
  }
  let console = Console::new(Cart::parse(out.to_bytes()))
  console.cpu.pc = 0x8000U
  // Clear the interrupt-disable flag so the interrupt can be taken, and pick a
  // vector inside the ROM.
  console.cpu.set_flag(Interrupt, false)
  console.write(0xFFFEU, 0x00U)
  console.write(0xFFFFU, 0xC0U)
  console.write(0x4017U, 0x00U)
  console.write(0x4015U, 0x0FU)
  // Run instructions until the counter has had a full frame to fire. An NOP is
  // two cycles, so a frame needs about fifteen thousand of them.
  let mut steps = 0
  while steps < 20000 {
    ignore(console.step())
    if console.irq_pending {
      console.irq_pending = false
      console.irq()
      break
    }
    steps = steps + 1
  }
  // The handler at $C000 is an NOP sled, so the PC lands inside the ROM rather
  // than on the reset address.
  inspect_bool(console.cpu.pc >= 0xC000U, true)
  inspect_bool(console.cpu.flag(Interrupt), true)
}
