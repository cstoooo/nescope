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
}

///|
/// A console with a freshly reset CPU and PPU and the given cartridge.
pub fn Console::new(cart : Cart) -> Console {
  let cpu = Cpu::new()
  let ppu = Ppu::new()
  ppu.mirroring = cart.mirroring
  // The CHR array is shared by reference: a CHR-RAM cartridge writes through the
  // PPU's data port and the cartridge must see the same bytes when it answers a
  // pattern fetch.
  let chr = cart.chr
  ppu.chr = chr
  ppu.chr_ram = cart.chr_ram
  {
    cpu,
    ppu,
    cart,
    ram: FixedArray::make(0x800, b'\x00'),
    controllers: (0U, 0U),
    controller_shift: (0, 0),
    dma_cycles: 0L,
  }
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
  } else if offset == 0x4015 {
    // The APU status register; no audio yet, so it reads as zero rather than
    // returning open bus, which some games would misread as a pending channel.
    0U
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
  } else if offset == 0x4016 {
    self.strobe_controllers()
  } else if offset >= 0x4020 {
    // Mapper writes are intercepted here; NROM has no banks to switch, so a
    // write into cartridge space is ignored rather than treated as an error.
    ()
  }
}

///|
/// Reads a byte from the cartridge, which answers the whole upper half of the
/// map for NROM.
///
/// A 16 KiB NROM cartridge is wired to answer both $8000 and $C000 with the same
/// chip, which is why a game smaller than 32 KiB can place its vectors at $FFFA
/// and its code at $8000 without any banking.
fn Console::cart_read(self : Console, address : UInt32) -> UInt32 {
  if address >= 0xC000U {
    let offset = (address - 0xC000U).reinterpret_as_int().to_int64()
    if self.cart.prg.length() <= 0x4000 {
      // The smaller board mirrors one 16 KiB chip into both halves.
      self.cart.prg_byte(offset % 0x4000L)
    } else {
      // A 32 KiB chip fills both halves; subtracting the bank base would be a
      // no-op here and is left out.
      self.cart.prg_byte(offset + 0x4000L)
    }
  } else {
    let offset = (address - 0x8000U).reinterpret_as_int().to_int64()
    self.cart.prg_byte(offset % 0x4000L)
  }
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
