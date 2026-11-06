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
  match (self.control & 0x03U).reinterpret_as_int() {
    0 => SingleLow
    1 => SingleHigh
    2 => Vertical
    _ => Horizontal
  }
}
