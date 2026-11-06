// The console's address bus.
//
// The CPU and the PPU each see their own address space, and the cartridge sits
// between them: the CPU's $4020-$FFFF is the cartridge's ROM, and the PPU's
// pattern tables are the cartridge's character memory. This file wires the three
// together and owns the two things that belong to neither: work RAM and the
// controller shift registers.
//
// The mirroring here is not an implementation detail to be tidied up. Work RAM is
// 2 KiB but answers across 8 KiB of the CPU's map, and the PPU registers repeat
// every eight bytes across 32. A program that writes $0800 and reads $0000 must
// see the same byte, and games rely on it.

///|
/// The whole console: CPU, PPU, cartridge and the memories they share.
pub(all) struct Console {
  /// The processor.
  mut cpu : Cpu
  /// The picture unit.
  mut ppu : Ppu
  /// The cartridge, which answers $4020 and up for the CPU and supplies the
  /// PPU's pattern tables.
  mut cart : Cart
  /// 2 KiB of work RAM, mirrored across $0000-$1FFF.
  ram : FixedArray[Byte]
  /// Controller state for both ports; the low eight bits are the buttons, one
  /// per `Button::shift_index`.
  mut controllers : (UInt32, UInt32)
  /// How many bits each controller has shifted out since the strobe went low.
  mut controller_shift : (Int32, Int32)
  /// True while the CPU is stalled waiting for sprite DMA.
  mut dma_cycles : Int64
  /// The audio unit. It does not synthesize sound here, but it owns the frame
  /// counter, which is a CPU-visible timer.
  mut apu : Apu
  /// True when the APU's frame counter has raised an interrupt that the CPU has
  /// not taken yet.
  mut irq_pending : Bool
}

///|
/// A console with a freshly reset CPU and PPU and the given cartridge.
pub fn Console::new(cart : Cart) -> Console {
  let cpu = Cpu::new()
  let ppu = Ppu::new()
  ppu.mirroring = cart.current_mirroring()
  // The CHR array is shared by reference: a CHR-RAM cartridge writes through the
  // PPU's data port and the cartridge must see the same bytes when it answers a
  // pattern fetch.
  let chr = cart.chr
  ppu.chr = chr
  ppu.chr_ram = cart.chr_ram
  ppu.chr_bank = cart.chr_bank
  ppu.chr_pages = cart.chr_pages()
  {
    cpu,
    ppu,
    cart,
    ram: FixedArray::make(0x800, b'\x00'),
    controllers: (0U, 0U),
    controller_shift: (0, 0),
    dma_cycles: 0L,
    apu: Apu::new(),
    irq_pending: false,
  }.boot()
}

///|
/// Boots a freshly built console the way the hardware does.
///
/// `Cpu::new` leaves the program counter at zero, which is fine for a unit test
/// that sets it itself and wrong for every other caller: zero is the first byte
/// of work RAM, so a console that is never reset starts executing a zero-filled
/// page of RAM and runs whatever the zeros decode to. Booting here rather than
/// asking callers to remember `reset()` makes the common path correct.
fn Console::boot(self : Console) -> Console {
  self.reset()
  self
}

///|
/// Reads a byte from the CPU's address space.
///
/// Each region is handled explicitly rather than by subtraction from a base,
/// because the regions do not share a stride: work RAM repeats every 2 KiB while
/// the PPU registers repeat every 8 bytes, and a single formula would have to
/// special-case one of them anyway.
pub fn Console::read(self : Console, address : UInt32) -> UInt32 {
  let at = address & 0xFFFFU
  let offset = at.reinterpret_as_int()
  if offset < 0x2000 {
    self.ram[offset % 0x800].to_int().reinterpret_as_uint() & 0xFF
  } else if offset < 0x4000 {
    self.ppu.read_register((offset - 0x2000).reinterpret_as_uint() & 0x07U)
  } else if offset >= 0x4000 && offset <= 0x4013 {
    // The channel registers read back as open bus on the real hardware, which is
    // effectively zero here.
    0U
  } else if offset == 0x4015 {
    self.apu.read_status()
  } else if offset == 0x4016 {
    self.read_controller(0)
  } else if offset == 0x4017 {
    self.read_controller(1)
  } else if offset >= 0x4020 {
    self.cart_read(at)
  } else {
    0U
  }
}

///|
/// Writes a byte to the CPU's address space.
pub fn Console::write(self : Console, address : UInt32, value : UInt32) -> Unit {
  let at = address & 0xFFFFU
  let offset = at.reinterpret_as_int()
  if offset < 0x2000 {
    self.ram[offset % 0x800] = (value & 0xFF).to_byte()
  } else if offset < 0x4000 {
    self.ppu.write_register(
      (offset - 0x2000).reinterpret_as_uint() & 0x07U,
      value,
    )
  } else if offset == 0x4014 {
    // Sprite DMA: the CPU stalls for 513 or 514 cycles while 256 bytes are copied
    // from a page of memory into OAM. The extra cycle occurs when the source page
    // starts on an odd cycle, which this build does not model yet.
    self.sprite_dma(value)
  } else if offset >= 0x4000 && offset <= 0x4013 {
    self.apu.write_register((offset - 0x4000).reinterpret_as_uint(), value)
  } else if offset == 0x4017 {
    self.apu.write_register(0x17U, value)
  } else if offset == 0x4016 {
    self.strobe_controllers()
  } else if offset >= 0x4020 {
    // Program RAM, save RAM and the mapper's own registers share this range. The
    // boards modelled here have no save RAM in this window, so a write either
    // lands in a mapper register or disappears; either way the CPU cannot tell.
    // A mapper write can also change the character bank or the mirroring, so the
    // PPU's cached copies have to be refreshed afterwards.
    if self.cart.write_mapper(at, value) {
      self.ppu.chr_bank = self.cart.chr_bank
      self.ppu.chr_pages = self.cart.chr_pages()
      self.ppu.mirroring = self.cart.current_mirroring()
      // MMC3's scanline counter is armed and disarmed by the same writes that
      // change its banks, so the console has to re-read the line state after
      // every mapper write rather than only after the PPU advances.
      self.irq_pending = self.irq_pending || self.cart.irq_line
    }
  }
}

///|
/// Reads a byte from the cartridge through the mapper's current banking.
///
/// The address decode itself lives in `Cart::read_prg` because which slice of
/// ROM answers is the board's decision, not the console's: a 16 KiB NROM board
/// mirrors one chip into both windows, while a UxROM board puts the last bank in
/// the high window and a switchable one in the low window.
fn Console::cart_read(self : Console, address : UInt32) -> UInt32 {
  self.cart.read_prg(address)
}

///|
/// Copies 256 bytes from a page of memory into OAM and stalls the CPU.
fn Console::sprite_dma(self : Console, page : UInt32) -> Unit {
  let base = page.to_int64() * 256L
  for i in 0..<256 {
    let value = self.read(
      (base + i.to_int64()).to_int().reinterpret_as_uint() & 0xFFFFU,
    )
    self.ppu.oam[i] = (value & 0xFF).to_byte()
  }
  // 513 cycles on an even starting cycle, 514 on an odd one. The parity depends on
  // the CPU's cycle counter, which is what the extra cycle is for.
  let extra = if self.cpu.cycles % 2L == 0L { 513L } else { 514L }
  self.dma_cycles = extra
  self.cpu.stalled = extra
}

///|
/// Latches the controller state while the strobe is held high.
///
/// Writing $4016 with the low bit set holds both controllers' shift registers in a
/// loop; clearing it starts the serial read. Games pulse it high then low once
/// per frame.
fn Console::strobe_controllers(self : Console) -> Unit {
  self.controller_shift = (0, 0)
}

///|
/// Shifts one bit out of a controller.
///
/// After the eighth shift the register returns 1 forever, which is how a game
/// tells a standard pad from a device that sends more bits.
fn Console::read_controller(self : Console, port : Int32) -> UInt32 {
  let state = if port == 0 { self.controllers.0 } else { self.controllers.1 }
  let shifted = if port == 0 {
    self.controller_shift.0
  } else {
    self.controller_shift.1
  }
  let bit = if shifted < 8 { (state >> shifted) & 1U } else { 1U }
  if port == 0 {
    self.controller_shift = (shifted + 1, self.controller_shift.1)
  } else {
    self.controller_shift = (self.controller_shift.0, shifted + 1)
  }
  bit
}

///|
/// Sets the buttons held on a controller.
pub fn Console::set_buttons(
  self : Console,
  port : Int32,
  buttons : Array[Button],
) -> Unit {
  let mut bits = 0U
  for button in buttons {
    bits = bits | (1UL << button.shift_index()).to_uint()
  }
  if port == 0 {
    self.controllers = (bits, self.controllers.1)
  } else {
    self.controllers = (self.controllers.0, bits)
  }
}

///|
/// Runs one instruction, advancing the PPU by the three dots per CPU cycle the
/// hardware uses.
///
/// Returns true when the instruction's final cycle raised the PPU's vblank and the
/// control register has NMI enabled, so the caller can service the interrupt.
pub fn Console::step(self : Console) -> Bool raise NesError {
  let result = self.cpu.step(self)
  let mut cycles = result.cycles
  if self.dma_cycles > 0L {
    cycles = cycles + self.dma_cycles
    self.dma_cycles = 0L
  }
  // The CPU and PPU run at a 3:1 ratio on NTSC, which is why one CPU cycle is
  // three dots and a frame is 29780 cycles.
  let mut started_vblank = false
  for _ in 0..<(cycles * 3L).to_int() {
    if self.ppu.tick() {
      started_vblank = true
    }
  }
  // The board's scanline counter watches the same line boundaries the PPU just
  // crossed, so edges are delivered after the dots rather than polled from the
  // mapper every cycle.
  let mut edges = self.ppu.scanlines
  self.ppu.scanlines = 0U
  while edges > 0U {
    self.cart.clock_scanline()
    if self.cart.irq_line {
      self.irq_pending = true
    }
    edges = edges - 1U
  }
  // The APU counts CPU cycles, not dots, so it advances once per instruction
  // rather than in the loop above.
  let frame_interrupt = self.apu.tick(cycles)
  if frame_interrupt {
    self.irq_pending = true
  }
  started_vblank && self.ppu.ctrl.nmi_enabled
}

///|
/// Resets the console as the hardware does: the CPU reads its program counter from
/// the vector at $FFFC and the stack pointer starts at $FD.
pub fn Console::reset(self : Console) -> Unit {
  self.cpu = Cpu::new()
  let low = self.cart_read(0xFFFCU)
  let high = self.cart_read(0xFFFDU)
  self.cpu.pc = low | (high << 8)
  self.cpu.sp = 0xFDU
  self.cpu.p = FLAG_UNUSED | FLAG_INTERRUPT
}

///|
/// Services an NMI by pushing the return address and status and vectoring through
/// $FFFA, which is what the hardware does when the PPU raises the line.
pub fn Console::nmi(self : Console) -> Unit {
  let ret = self.cpu.pc
  self.cpu.push(self, (ret >> 8) & 0xFF)
  self.cpu.push(self, ret & 0xFF)
  // The pushed status has the break bit clear, which distinguishes an NMI from a
  // BRK when the handler inspects the stack.
  self.cpu.push(self, (self.cpu.p | FLAG_UNUSED) & (FLAG_BREAK ^ 0xFFFF_FFFFU))
  self.cpu.set_flag(Interrupt, true)
  let low = self.cart_read(0xFFFAU)
  let high = self.cart_read(0xFFFBU)
  self.cpu.pc = low | (high << 8)
}

///|
/// Takes a maskable interrupt through the vector at `$FFFE`.
///
/// The difference from `NMI` is more than the vector. Panning the pushed status:
/// the hardware clears the break bit for both, but a maskable interrupt is also
/// suppressed while the interrupt-disable flag is set, and an NMI is not. That
/// distinction is what makes `SEI` a usable critical section.
pub fn Console::irq(self : Console) -> Unit {
  if self.cpu.flag(Interrupt) {
    return
  }
  let ret = self.cpu.pc
  self.cpu.push(self, (ret >> 8) & 0xFF)
  self.cpu.push(self, ret & 0xFF)
  self.cpu.push(self, (self.cpu.p | FLAG_UNUSED) & (FLAG_BREAK ^ 0xFFFF_FFFFU))
  self.cpu.set_flag(Interrupt, true)
  let low = self.cart_read(0xFFFEU)
  let high = self.cart_read(0xFFFFU)
  self.cpu.pc = low | (high << 8)
}

///|
/// Runs until the PPU completes a frame, returning the number of CPU instructions
/// executed.
///
/// Bounded so that a ROM stuck in a loop cannot hang a test: the limit is a few
/// frames' worth of instructions, and hitting it returns the count rather than
/// spinning forever.
pub fn Console::run_frame(
  self : Console,
  limit : Int32,
) -> Int32 raise NesError {
  self.ppu.frame_complete = false
  let mut executed = 0
  while !self.ppu.frame_complete && executed < limit {
    let interrupt = self.step()
    if interrupt {
      self.nmi()
    }
    // The frame counter's interrupt is maskable, so it is checked after the
    // instruction rather than delivered as part of it: a program that has run
    // SEI must not be interrupted no matter how overdue the counter is.
    if self.irq_pending {
      self.irq_pending = false
      self.irq()
    }
    executed = executed + 1
  }
  executed
}

///|
/// Reaches the console's bus through the trait the CPU is written against.
pub impl Bus for Console with fn read(self, address) {
  self.read(address)
}

///|
/// Writes through the console's bus.
pub impl Bus for Console with fn write(self, address, value) {
  self.write(address, value)
}
