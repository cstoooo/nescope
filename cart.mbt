// The cartridge: iNES parsing and memory mapping.
//
// A cartridge is two ROM chips and a wiring choice. The iNES file format puts a
// 16-byte header in front of the chips, and the header's mapper number selects
// the wiring; everything a game does to bank-switch is a write to an address
// that the mapper intercepts instead of letting it reach RAM.
//
// The ROMs are kept as they appear in the file rather than being copied into
// the address space, because a mapper switches which slice answers an address
// and copying would mean swapping bytes on every bank change.

///|
/// The four-byte magic that starts an iNES image: "NES" followed by $1A.
///
/// `$1A` is a DOS end-of-file marker, chosen by the format's author so that
/// `type file.nes` on a DOS prompt would stop there rather than printing the
/// ROM as text.
const INES_MAGIC_0 : UInt32 = 0x4E

///|
const INES_MAGIC_1 : UInt32 = 0x45

///|
const INES_MAGIC_2 : UInt32 = 0x53

///|
const INES_MAGIC_3 : UInt32 = 0x1A

///|
/// Which set of nametables the PPU sees.
///
/// The console has 2 KiB of video RAM for nametables, but the PPU can address
/// four 1 KiB tables; the cartridge decides whether the two physical ones appear
/// twice, or are replaced by extra RAM on the cartridge.
pub(all) enum Mirroring {
  /// Two tables, each visible twice, arranged to look like a screen taller than
  /// it is wide.
  Horizontal
  /// Two tables, each visible twice, arranged side by side.
  Vertical
  /// All four virtual tables map the same 1 KiB; used by single-screen games.
  SingleLow
  SingleHigh
  /// The cartridge supplies its own video RAM and the header's value is
  /// ignored.
  FourScreen
}

///|
/// A parsed cartridge.
pub(all) struct Cart {
  /// Which physical nametables answer the PPU's four virtual ones.
  mirroring : Mirroring
  /// True when the cartridge has battery-backed save RAM.
  has_battery : Bool
  /// Program ROM as stored in the file, without the header.
  prg : Bytes
  /// Character memory: ROM from the file, or zeroed RAM when the header asks for
  /// writable character memory. Held as a mutable array because a CHR-RAM
  /// cartridge writes pattern data at run time and copying the chip on every
  /// write would dominate a frame.
  chr : FixedArray[Byte]
  /// True when the header asked for writable character RAM.
  chr_ram : Bool
  /// Mapper number from the header.
  mut mapper : MapperKind
  /// 1 or 2, meaning 16 KiB or 32 KiB program banks.
  prg_banks : Int64
  /// Number of 8 KiB character banks; zero for a CHR-RAM cartridge.
  chr_banks : Int64
  /// Which 16 KiB program bank answers $8000. The upper window at $C000 is
  /// always the last bank, which is what lets a bank-switched game keep its
  /// vectors at a fixed address.
  mut prg_bank : Int64
  /// Which 16 KiB program bank answers $C000; only 32 KiB boards switch it.
  mut prg_bank_high : Int64
  /// Which 8 KiB character bank answers the PPU; only CHR-ROM boards switch it.
  mut chr_bank : Int64
  /// MMC1's five-write shift register: the value being assembled, and how many
  /// bits have arrived.
  mut shift : UInt32
  mut shift_count : UInt32
  /// MMC1's control register, which holds the mirroring bits among others.
  mut control : UInt32
  /// Set once the CPU has written to MMC1's control register, after which the
  /// header's mirroring value no longer applies.
  mut mirroring_from_mapper : Bool
  /// MMC3's eight bank registers, in the order they are written: two 2 KiB
  /// character banks, four 1 KiB character banks, then two 8 KiB program banks.
  ///
  /// They are kept as written rather than decoded into a single bank number
  /// because which window each one drives depends on a separate mode bit, and a
  /// program can flip that bit without rewriting them.
  mut bank_registers : FixedArray[Int64]
  /// MMC3's bank-select register: which of the eight the next write targets.
  mut bank_select : UInt32
  /// MMC3's program and character bank arrangement bit, which swaps the two
  /// halves of each address space.
  mut prg_mode : Bool
  mut chr_mode : Bool
  /// MMC3's scanline counter, loaded with the value a program writes and
  /// decremented on each A12 rising edge.
  mut irq_counter : UInt32
  mut irq_latch : UInt32
  /// True once the counter has reached zero and the interrupt is asserted.
  mut irq_line : Bool
  /// True when the counter reloads itself on reaching zero, which is how a game
  /// gets an interrupt on every scanline band rather than once.
  mut irq_enabled : Bool
}

///|
/// The mappers this build implements.
///
/// The set is chosen by how much of the licensed library each one unlocks per
/// line of code rather than by number: NROM is the boards with no banking at
/// all, UxROM and CNROM are single-register boards, and MMC1 is a shift register
/// that most of the early library uses.
pub(all) enum MapperKind {
  /// No banking. $8000 and $C000 see the same chip on a 16 KiB board.
  Nrom
  /// UxROM (mapper 2): one register selects the 16 KiB bank at $8000 and the
  /// last bank is fixed at $C000.
  UxRom
  /// CNROM (mapper 3): one register selects the 8 KiB character bank, and the
  /// program ROM is fixed.
  Cnrom
  /// MMC1 (mapper 1): a serial shift register loads five registers, so a program
  /// has to write one bit at a time across five stores.
  Mmc1
  /// MMC3 (mapper 4): eight bank registers selected by index, and a scanline
  /// counter driven by the PPU's A12 line that can interrupt the CPU mid-frame.
  Mmc3
  /// AxROM (mapper 7): one register selects a 32 KiB program bank and the
  /// single-screen nametable. No character banking at all.
  AxRom
  /// GxROM (mapper 66): one register, half of it a 32 KiB program bank and the
  /// other half an 8 KiB character bank.
  GxRom
  /// A mapper number this build has no wiring for; loading succeeds so the
  /// header can still be inspected, but running raises when the CPU first
  /// touches cartridge space.
  Unsupported(UInt32)
}

///|
/// Threshold beyond which a declared ROM size is rejected before allocating.
///
/// The largest licensed NES game is smaller than 4 MiB; the limit exists so that
/// a header claiming 255 banks of 16 KiB in a 40 KiB file is refused instead of
/// trusted.
const MAX_PRG_BYTES : Int64 = 4L * 1024L * 1024L

///|
const MAX_CHR_BYTES : Int64 = 4L * 1024L * 1024L

///|
/// Parses an iNES image.
///
/// The 16-byte header is validated in two stages: the magic and the declared
/// sizes must be consistent with the file, and then the mapper must be one this
/// build can wire. A bad header is an error; an unknown mapper is not, because
/// the cartridge's identity is still worth reporting.
pub fn Cart::parse(bytes : Bytes) -> Cart raise NesError {
  let length = bytes.length().to_int64()
  if length < 16L {
    raise UnexpectedEnd(offset=0L, needed=16L, available=length)
  }
  if bytes.at(0).to_int().reinterpret_as_uint() != INES_MAGIC_0 ||
    bytes.at(1).to_int().reinterpret_as_uint() != INES_MAGIC_1 ||
    bytes.at(2).to_int().reinterpret_as_uint() != INES_MAGIC_2 ||
    bytes.at(3).to_int().reinterpret_as_uint() != INES_MAGIC_3 {
    raise NotAnINes
  }
  let flags6 = flag_byte(bytes, 6)
  let flags7 = flag_byte(bytes, 7)
  let prg_banks = prg_banks_in_16k_units(bytes)
  let chr_banks = chr_banks_in_8k_units(bytes)
  let declared_prg = prg_banks.to_int64() * 16384L
  let declared_chr = chr_banks.to_int64() * 8192L
  if declared_prg > MAX_PRG_BYTES {
    raise Truncated(
      kind="program ROM",
      declared=declared_prg,
      present=MAX_PRG_BYTES,
    )
  }
  if declared_chr > MAX_CHR_BYTES {
    raise Truncated(
      kind="character ROM",
      declared=declared_chr,
      present=MAX_CHR_BYTES,
    )
  }
  let body = length - 16L
  // A trainer is 512 bytes between the header and the chips. It is preserved in
  // the file but never executed, so it only shifts where the chips start.
  let has_trainer = (flags6 & 0x04) != 0
  let trainer_bytes = if has_trainer { 512L } else { 0L }
  let available = body - trainer_bytes
  if declared_prg > available {
    raise Truncated(
      kind="program ROM",
      declared=declared_prg,
      present=available,
    )
  }
  if declared_chr > available - declared_prg {
    raise Truncated(
      kind="character ROM",
      declared=declared_chr,
      present=available - declared_prg,
    )
  }
  let prg_at = 16L + trainer_bytes
  let prg = slice_bytes(bytes, prg_at, declared_prg)
  let chr_bytes = slice_bytes(bytes, prg_at + declared_prg, declared_chr)
  // A CHR-RAM cartridge declares zero banks; it still needs 8 KiB of backing
  // store, because the PPU addresses it as if a chip were present.
  let chr_size = if chr_banks == 0 { 8192 } else { chr_bytes.length() }
  let chr : FixedArray[Byte] = FixedArray::make(chr_size, b'\x00')
  for i in 0..<chr_bytes.length() {
    chr[i] = chr_bytes.at(i)
  }
  let mapper_number = ((flags7 & 0xF0) | ((flags6 >> 4) & 0x0F)).reinterpret_as_int()
  let chr_ram = chr_banks == 0
  {
    mirroring: mirroring_of(flags6),
    has_battery: (flags6 & 0x02) != 0,
    prg,
    chr,
    chr_ram,
    mapper: mapper_of(mapper_number),
    prg_banks: prg_banks.to_int64(),
    chr_banks: chr_banks.to_int64(),
    // UxROM powers up with the second-to-last bank selected, which is $FF on a
    // board with fewer than 256 banks; the mask in the register write makes that
    // the highest bank anyway. Resetting to the last bank instead would hide a
    // program's very first bank switch behind a correct-looking screen.
    prg_bank: 0L,
    prg_bank_high: prg_banks.to_int64() - 2L,
    chr_bank: 0L,
    shift: 0U,
    shift_count: 0U,
    // $0C is the control register's power-on value: mode 3, so $C000 is fixed
    // to the last bank and reset code can bank-switch without losing itself.
    control: 0x0CU,
    mirroring_from_mapper: false,
    bank_registers: FixedArray::make(8, 0L),
    bank_select: 0U,
    prg_mode: false,
    chr_mode: false,
    irq_counter: 0U,
    irq_latch: 0U,
    irq_line: false,
    irq_enabled: false,
  }
}

///|
/// Reads one header byte as a `UInt32`.
fn flag_byte(bytes : Bytes, at : Int32) -> UInt32 {
  bytes.at(at).to_int().reinterpret_as_uint() & 0xFF
}

///|
/// The 16 KiB program-bank count the header declares.
///
/// The field is one byte, but byte 9's low nibble became the high nibble of a
/// twelve-bit count in the later revision of the format; honouring it here means
/// a large homebrew ROM reports its real size rather than sixteen banks.
fn prg_banks_in_16k_units(bytes : Bytes) -> Int32 {
  let low = flag_byte(bytes, 4).reinterpret_as_int()
  let high = flag_byte(bytes, 9).reinterpret_as_int() & 0x0F
  if high == 0x0F {
    // $F in the high nibble is the old marker for the exponent-multiplier form,
    // which this build does not decode; fall back to the plain count.
    low
  } else {
    low | (high << 8)
  }
}

///|
/// The 8 KiB character-bank count the header declares.
fn chr_banks_in_8k_units(bytes : Bytes) -> Int32 {
  let low = flag_byte(bytes, 5).reinterpret_as_int()
  let high = flag_byte(bytes, 9).reinterpret_as_int() & 0xF0
  if high == 0xF0 {
    low
  } else {
    low | high
  }
}

///|
/// Decodes the mirroring and four-screen bits.
fn mirroring_of(flags6 : UInt32) -> Mirroring {
  if (flags6 & 0x08) != 0 {
    FourScreen
  } else if (flags6 & 0x01) != 0 {
    Vertical
  } else {
    Horizontal
  }
}

///|
/// Copies a range out of the image.
fn slice_bytes(bytes : Bytes, start : Int64, count : Int64) -> Bytes {
  let out = Buffer::Buffer(size_hint=count.to_int())
  for i in 0..<count.to_int() {
    out.write_byte(bytes.at(start.to_int() + i))
  }
  out.to_bytes()
}

///|
/// Reads a program-ROM byte at a cartridge-relative offset.
///
/// Returns zero past the end rather than raising: a ROM is allowed to be smaller
/// than the address space the CPU sees, and the unpopulated region of a NROM
/// board reads back as open bus, which games treat as harmless.
pub fn Cart::prg_byte(self : Cart, offset : Int64) -> UInt32 {
  let index = offset % self.prg.length().to_int64()
  self.prg.at(index.to_int()).to_int().reinterpret_as_uint() & 0xFF
}

///|
/// Reads a character-ROM byte at a cartridge-relative offset.
///
/// A CHR-RAM cartridge hands this function an empty array; the PPU owns the RAM
/// and answers pattern fetches itself before reaching here.
pub fn Cart::chr_byte(self : Cart, offset : Int64) -> UInt32 {
  let index = offset % self.chr.length().to_int64()
  self.chr[index.to_int()].to_int().reinterpret_as_uint() & 0xFF
}

///|
/// Writes a character-ROM byte, which only a CHR-RAM cartridge accepts.
///
/// Returns true when the write landed, so the caller knows whether the PPU
/// should have handled it instead.
pub fn Cart::write_chr(self : Cart, offset : Int64, value : UInt32) -> Bool {
  if !self.chr_ram {
    return false
  }
  let index = (offset % self.chr.length().to_int64()).to_int()
  self.chr[index] = (value & 0xFF).to_byte()
  true
}

///|
/// A short name for the mapper, used in reports.
pub fn MapperKind::name(self : MapperKind) -> String {
  match self {
    Nrom => "NROM"
    UxRom => "UxROM"
    Cnrom => "CNROM"
    Mmc1 => "MMC1"
    Mmc3 => "MMC3"
    AxRom => "AxROM"
    GxRom => "GxROM"
    Unsupported(number) => "mapper \{number} (unsupported)"
  }
}

///|
/// A short name for the mirroring, used in reports.
pub fn Mirroring::name(self : Mirroring) -> String {
  match self {
    Horizontal => "horizontal"
    Vertical => "vertical"
    SingleLow => "single-screen low"
    SingleHigh => "single-screen high"
    FourScreen => "four-screen"
  }
}

///|

///|

///|

///
