// Bank switching.
//
// A mapper is not a device the CPU talks to; it is a small piece of logic on the
// board that watches the address bus and decides which ROM slice answers. The
// CPU writes to $8000-$FFFF expecting RAM, and the mapper swallows the write and
// changes its registers instead. Nothing tells the CPU this happened, which is
// why a mapper bug shows up as a game jumping into the wrong bank rather than as
// an error.
//
// Only the low bits of the written value matter, and how many bits matter comes
// from how many banks the board has: a game written for a 16-bank board still
// works on a 4-bank board because the extra bits are simply ignored, which is
// what the masks in each write handler reproduce.

///|
/// Decodes a header's mapper number into a wiring this build implements.
fn mapper_of(number : Int32) -> MapperKind {
  match number {
    0 => Nrom
    1 => Mmc1
    2 => UxRom
    3 => Cnrom
    4 => Mmc3
    _ => Unsupported(number.reinterpret_as_uint())
  }
}

///|
/// Reads a byte from the program ROM through the mapper's current bank.
///
/// `address` is a CPU address in $8000-$FFFF. Every board this build models puts
/// the last program bank at $C000 and switches only the lower window, except
/// that a 32 KiB board has enough ROM for the low window to be its own bank.
fn Cart::read_prg(self : Cart, address : UInt32) -> UInt32 {
  // The offset has to be the distance from the base of whichever 16 KiB window
  // the address falls in, not the address masked to fifteen bits: $C000 masked
  // would give $4000, which is one past the end of the bank it belongs to.
  let base = if address >= 0xC000U { 0xC000U } else { 0x8000U }
  let offset = (address - base).reinterpret_as_int().to_int64()
  let bank_bytes = 0x4000L
  let banks = self.prg.length().to_int64() / bank_bytes
  if banks <= 0L {
    return 0U
  }
  match self.mapper {
    // A board with no banking exposes its whole chip linearly: a 32 KiB NROM
    // fills both windows, and a 16 KiB one repeats in both. The window-relative
    // offset above is only right for banked boards, so the linear offset is
    // rebuilt here from the full address.
    Nrom =>
      self.prg_byte(
        (address & 0x7FFFU).reinterpret_as_int().to_int64() %
        self.prg.length().to_int64(),
      )
    // A UxROM board's low window is switchable and its high window is the last
    // bank, which is where the reset vector lives so that a bank switch cannot
    // move the code the CPU is already running.
    UxRom =>
      if address >= 0xC000U {
        self.prg_byte((banks - 1L) * bank_bytes + offset)
      } else {
        self.prg_byte(self.prg_bank * bank_bytes + offset)
      }
    // CNROM leaves the program ROM unbanked, so it decodes exactly as NROM does.
    Cnrom =>
      self.prg_byte(
        (address & 0x7FFFU).reinterpret_as_int().to_int64() %
        self.prg.length().to_int64(),
      )
    Mmc1 => {
      // Bits 2 and 3 of the control register pick one of four arrangements, and
      // the high window's behaviour is what distinguishes them: in two of them
      // it follows the register, in the other two it is pinned. Treating bit 3
      // as "16 KiB mode" alone loses the "$C000 fixed to the last bank" case
      // and leaves a game running its reset code out of the wrong bank.
      let mode = (self.control >> 2) & 0x03
      let largest = banks - 1L
      let low = self.prg_bank % banks
      let high_window = match mode {
        // 32 KiB: the register's low bit is ignored and the pair fills both
        // windows.
        0U | 1U => (low & 0xFE) + 1L
        // $8000 switched, $C000 fixed to the first bank.
        2U => 0L
        // $8000 switched, $C000 fixed to the last bank. This is the power-on
        // arrangement, which is why reset code can bank-switch itself safely.
        _ => largest
      }
      let low_window = match mode {
        0U | 1U => low & 0xFE
        _ => low
      }
      if address >= 0xC000U {
        self.prg_byte(high_window % banks * bank_bytes + offset)
      } else {
        self.prg_byte(low_window % banks * bank_bytes + offset)
      }
    }
    Mmc3 => {
      // MMC3 divides the upper half of the map into four 8 KiB windows, not two
      // 16 KiB ones, which is why this arm rebuilds its own offset instead of
      // using the 16 KiB one computed above.
      //
      // Two windows follow registers 6 and 7; the other two are pinned to the
      // last two banks. The mode bit decides which pair is which, and it is the
      // reason a game can move its own fixed code: setting the bit swaps $8000
      // with $C000 and $A000 with $E000.
      let small = 0x2000L
      let count = self.prg.length().to_int64() / small
      if count <= 0L {
        return 0U
      }
      let window = ((address - 0x8000U) >> 13).reinterpret_as_int().to_int64()
      let r6 = self.bank_registers[6] % count
      let r7 = self.bank_registers[7] % count
      let last = count - 1L
      let second_to_last = if count >= 2L { count - 2L } else { 0L }
      let bank = if self.prg_mode {
        // Swapped: the low pair is fixed and the high pair follows the
        // registers.
        match window {
          0L => second_to_last
          1L => last
          2L => r6
          _ => r7
        }
      } else {
        match window {
          0L => r6
          1L => r7
          2L => second_to_last
          _ => last
        }
      }
      let within = (address & 0x1FFFU).reinterpret_as_int().to_int64()
      self.prg_byte(bank % count * small + within)
    }
    Unsupported(_) => 0U
  }
}

///|
/// Applies a write the CPU made into cartridge space.
///
/// Returns true when a mapper consumed the write. Returning false means the
/// board has no register there, which for the boards modelled here is the same
/// as the write disappearing into nothing.
fn Cart::write_mapper(self : Cart, address : UInt32, value : UInt32) -> Bool {
  let value = value & 0xFFU
  match self.mapper {
    Nrom => false
    UxRom => {
      // One register, anywhere in $8000-$FFFF. The mask picks the low bits the
      // board actually has; the upper-bit difference is why cheap UxROM boards
      // need 74HC161 counters to bank correctly.
      let banks = self.prg.length().to_int64() / 0x4000L
      if banks > 0L {
        self.prg_bank = (value & 0x0FU).reinterpret_as_int().to_int64() % banks
      }
      true
    }
    Cnrom => {
      let banks = self.chr.length().to_int64() / 0x2000L
      if banks > 0L {
        self.chr_bank = (value & 0x03U).reinterpret_as_int().to_int64() % banks
      }
      true
    }
    Mmc1 => {
      // MMC1 takes its registers one bit at a time, least significant bit first.
      // Five writes of one bit each assemble a byte; the sixth write would start
      // over, and a write with bit 7 set resets the register instead of
      // contributing a bit. Games depend on that reset, because it is the only
      // way to recover from a partial write.
      if (value & 0x80U) != 0 {
        self.shift = 0U
        self.shift_count = 0U
        self.control = self.control | 0x0CU
        return true
      }
      self.shift = self.shift |
        ((value & 0x01U) << self.shift_count.reinterpret_as_int())
      self.shift_count = self.shift_count + 1U
      if self.shift_count == 5U {
        let latched = self.shift & 0x1FU
        self.shift = 0U
        self.shift_count = 0U
        // The destination register is chosen by the top two address bits, which
        // is why a game writes the same address five times in a row.
        let target = (address >> 13) & 0x03U
        match target {
          0U => {
            self.control = latched
            self.mirroring_from_mapper = true
          }
          1U => {
            let banks = self.chr.length().to_int64() / 0x1000L
            if banks > 0L {
              self.chr_bank = (latched & 0x1FU).reinterpret_as_int().to_int64() %
                banks
            }
          }
          2U => {
            let banks = self.chr.length().to_int64() / 0x1000L
            if banks > 0L {
              self.chr_bank = self.chr_bank +
                (latched & 0x1FU).reinterpret_as_int().to_int64() %
                banks *
                0x1000L
            }
          }
          _ => {
            let banks = self.prg.length().to_int64() / 0x4000L
            if banks > 0L {
              self.prg_bank = (latched & 0x0FU).reinterpret_as_int().to_int64() %
                banks
            }
          }
        }
      }
      true
    }
    Mmc3 => {
      // MMC3 is even/odd addressed: each 8 KiB block in $8000-$FFFF holds two
      // registers, one at an even address and one at the odd address next to it.
      // A write's address alone decides which register it reaches, and the same
      // block means different things on reads and writes, so getting this wrong
      // is silent — both are "somewhere in the upper half".
      let even = (address & 0x01U) == 0U
      match (address >> 13) & 0x03U {
        // $8000: even selects the bank register, odd writes it.
        0U =>
          if even {
            self.bank_select = value & 0x07U
            self.prg_mode = (value & 0x40U) != 0
            self.chr_mode = (value & 0x80U) != 0
          } else {
            let index = self.bank_select.reinterpret_as_int()
            self.bank_registers[index] = value.reinterpret_as_int().to_int64()
            // A character bank register holds an even or odd 1 KiB index
            // depending on which of the pair it is, and the mode bit swaps the
            // two halves, so the effective bank is computed on read instead.
            self.chr_bank = self.effective_chr_bank()
          }
        // $A000: even sets the nametable arrangement, odd is the (unused) PRG
        // RAM protect register.
        1U =>
          if even {
            // Four-screen boards ignore this: their extra RAM wins over the
            // header's mirroring bits.
            if !self.four_screen() {
              self.write_mirroring(value & 0x01U)
            }
          }
        // $C000 loads the counter's reload value; $C001 clears the counter
        // without reloading it, which is what gives a program a short first
        // interval rather than a full latch's worth.
        2U =>
          if even {
            self.irq_latch = value
          } else {
            self.irq_counter = 0U
            self.irq_line = false
          }
        // $E000 disarms the counter; $E001 arms it.
        _ =>
          if even {
            self.irq_enabled = false
            self.irq_line = false
          } else {
            self.irq_enabled = true
          }
      }
      true
    }
    Unsupported(_) => false
  }
}

///|
/// The mirroring the cartridge currently asks the PPU for.
///
/// MMC1 can change it at run time, which a game does when it switches between a
/// horizontally scrolling level and a vertically scrolling one. The header's
/// value is a starting point, not a constant.
fn Cart::current_mirroring(self : Cart) -> Mirroring {
  if !self.mirroring_from_mapper {
    return self.mirroring
  }
  // MMC3 keeps its mirroring in a single bit rather than MMC1's two, and four-
  // screen boards ignore the register entirely because their extra RAM is
  // already wired to all four tables.
  match self.mapper {
    Mmc3 => if (self.control & 0x01U) == 0U { SingleLow } else { SingleHigh }
    Mmc1 =>
      match (self.control & 0x03U).reinterpret_as_int() {
        0 => SingleLow
        1 => SingleHigh
        2 => Vertical
        _ => Horizontal
      }
    _ => self.mirroring
  }
}

///|
/// True when the cartridge supplies its own four nametables.
fn Cart::four_screen(self : Cart) -> Bool {
  match self.mirroring {
    FourScreen => true
    _ => false
  }
}

///|
/// Switches between the two single-screen arrangements.
///
/// MMC3 has a single bit for this rather than a full enum: zero means both
/// nametables show the first page, one means both show the second. A game that
/// switches mid-frame to draw a status bar uses it.
fn Cart::write_mirroring(self : Cart, bit : UInt32) -> Unit {
  match (self.mirroring, bit) {
    // The enum is not mutable on `Cart`, so the chosen arrangement is recorded
    // through the control field the console already reads. Keeping one place
    // that answers "what mirroring is active" matters more than which field it
    // is stored in.
    _ => {
      self.mirroring_from_mapper = true
      self.control = bit
    }
  }
}

///|
/// The character bank the current MMC3 registers select for the window at
/// $0000.
///
/// MMC3 splits the 8 KiB character space into two 4 KiB halves, each of which is
/// built from one 2 KiB register and two 1 KiB registers. The mode bit swaps
/// which half is which, so the same registers drive different windows depending
/// on it. The PPU asks for one flat bank number, so this collapses the four
/// registers of the requested half into one.
fn Cart::effective_chr_bank(self : Cart) -> Int64 {
  // The PPU's flat bank covers 8 KiB, but MMC3's finest granularity is 1 KiB, so
  // the real selection has to happen per fetch. What is stored here is the base
  // of the half the PPU's two windows share; `chr_bank_offset` refines it.
  let banks = self.chr.length().to_int64() / 0x2000L
  if banks <= 0L {
    return 0L
  }
  let first = self.bank_registers[if self.chr_mode { 2 } else { 0 }]
  (first & 0xFEU.reinterpret_as_int().to_int64()) % banks
}

///|
/// The eight 1 KiB character banks the current mapper registers select.
///
/// The PPU fetches one byte at a time and cannot afford to consult a mapper's
/// register layout on every fetch, so the mapping is resolved once here whenever
/// a register changes and handed over as a small table. Boards coarser than 8 KiB
/// return `None`, and the PPU falls back to its single bank number.
///
/// MMC3's arrangement is the reason this is not just a multiply: it splits the
/// 8 KiB into two 4 KiB halves, each made of one 2 KiB and two 1 KiB windows, and
/// a mode bit decides which half the registers drive. Registers 0 and 1 are the
/// 2 KiB windows and supply two adjacent pages each; registers 2 to 5 are the
/// four 1 KiB pages.
fn Cart::chr_pages(self : Cart) -> FixedArray[Int64]? {
  match self.mapper {
    Mmc3 => {
      let count = self.chr.length().to_int64() / 0x400L
      if count <= 0L {
        return None
      }
      let pages : FixedArray[Int64] = FixedArray::make(8, 0L)
      // Registers 0 and 1 are 2 KiB windows, so each supplies two consecutive
      // 1 KiB pages; their low bit is ignored, which is why they are masked even.
      let r0 = self.bank_registers[0] & 0xFEU.reinterpret_as_int().to_int64()
      let r1 = self.bank_registers[1] & 0xFEU.reinterpret_as_int().to_int64()
      // The first half of the pattern space is [R0, R0+1, R1, R1+1]; the second
      // is the four 1 KiB registers in order.
      let first_half : Array[Int64] = [r0, r0 + 1L, r1, r1 + 1L]
      let second_half : Array[Int64] = [
        self.bank_registers[2],
        self.bank_registers[3],
        self.bank_registers[4],
        self.bank_registers[5],
      ]
      for page in 0..<8 {
        // The mode bit swaps which half of the pattern space the registers drive,
        // which is how a game keeps its background tiles in one half while
        // switching sprite tiles per scanline in the other.
        let value = if self.chr_mode {
          if page < 4 {
            second_half[page]
          } else {
            first_half[page - 4]
          }
        } else if page < 4 {
          first_half[page]
        } else {
          second_half[page - 4]
        }
        pages[page] = value % count
      }
      Some(pages)
    }
    _ => None
  }
}

///|
/// Advances MMC3's scanline counter by one A12 rising edge.
///
/// The counter is the board's only view of the raster, and it is deliberately
/// coarse: it watches bit 12 of the PPU's address bus, which goes high when the
/// PPU fetches sprite pattern data and low again during the background fetches.
/// One complete scanline is therefore one rising edge. Games use it to change
/// banks at an exact scanline, which is how a status bar stays fixed while the
/// playfield scrolls.
///
/// The counter reloads on reaching zero rather than on the next edge, and the
/// reload value is used immediately, so a latch of zero means "interrupt every
/// scanline" rather than "interrupt on the second one".
fn Cart::clock_scanline(self : Cart) -> Unit {
  match self.mapper {
    Mmc3 =>
      if self.irq_counter == 0U {
        self.irq_counter = self.irq_latch
        if self.irq_enabled && self.irq_latch == 0U {
          self.irq_line = true
        }
      } else {
        self.irq_counter = self.irq_counter - 1U
        if self.irq_counter == 0U && self.irq_enabled {
          self.irq_line = true
        }
      }
    _ => ()
  }
}
