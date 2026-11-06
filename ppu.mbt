// The picture processing unit.
//
// The PPU is a dot-driven machine: it emits one pixel per dot, 341 dots per
// scanline, 262 scanlines per frame on NTSC. Everything it renders comes from
// two memories — 8 KiB of character ROM holding the tile bitmaps, and 2 KiB of
// video RAM holding which tile goes where.
//
// The central modelling decision here is that rendering is done per pixel from
// the PPU's current scroll and address state, rather than by copying a completed
// nametable into a frame buffer at the start of each frame. The per-pixel model
// is what makes mid-frame scroll changes — which every side-scroller relies on —
// work without a special case.

///|
/// The width of the visible picture in pixels.
pub const SCREEN_WIDTH : Int32 = 256

///|
/// The height of the visible picture in pixels.
pub const SCREEN_HEIGHT : Int32 = 240

///|
/// Dots per scanline. The visible picture is the first 256; the remaining 85 are
/// the horizontal blanking interval, and they are where the CPU gets its chance
/// to write to PPU registers.
const DOTS_PER_SCANLINE : Int32 = 341

///|
/// The first scanline of the vertical blanking interval on NTSC.
const VBLANK_START : Int32 = 241

///|
/// A palette entry: six bits selecting one of the console's 64 colours, plus the
/// emphasis bits that tint the whole screen.
pub type PaletteIndex = UInt32

///|
/// The PPU's control register at $2000.
///
/// Held as named fields rather than a raw byte so that a test can set the
/// nametable select without also having to know which bits the other fields use.
pub(all) struct Ctrl {
  /// Base nametable selected for rendering; also the high bit of the scroll
  /// address during a scroll write.
  mut nametable : UInt32
  /// Add 32 to the address after each CPU read or write, for column-major fills.
  mut increment32 : Bool
  /// Where sprite bitmaps are fetched from: 0 for $0000, 1 for $1000.
  mut sprite_pattern : UInt32
  /// Where background bitmaps are fetched from.
  mut background_pattern : UInt32
  /// Sprites are 8x16 rather than 8x8.
  mut tall_sprites : Bool
  /// Generate an NMI at the start of each vertical blank.
  mut nmi_enabled : Bool
}

///|
/// The PPU's mask register at $2001.
pub(all) struct Mask {
  /// Show the background in the leftmost 8 pixels.
  mut show_background_left : Bool
  /// Show sprites in the leftmost 8 pixels.
  mut show_sprites_left : Bool
  /// Enable background rendering at all.
  mut show_background : Bool
  /// Enable sprite rendering.
  mut show_sprites : Bool
  /// Tint the picture toward red.
  mut emphasize_red : Bool
  /// Tint it toward green.
  mut emphasize_green : Bool
  /// Tint it toward blue.
  mut emphasize_blue : Bool
  /// Greyscale: collapse the palette to its luminance ramp.
  mut greyscale : Bool
}

///|
/// The PPU's status register at $2002.
pub(all) struct Status {
  /// Set during vertical blank; cleared by reading this register.
  mut vblank : Bool
  /// Set when a sprite has hit the sprite-0 pixel; cleared by reading this
  /// register.
  mut sprite_zero_hit : Bool
  /// Set when more than eight sprites share a scanline.
  ///
  /// The hardware's evaluator also has a bug that corrupts the index when an
  /// eighth sprite is found, which games use as a detection signature. This
  /// build raises the flag at the honest moment and does not reproduce the
  /// bug, so the flag is right but a game relying on the corruption will not
  /// see it.
  mut overflow : Bool
}

///|
/// A complete PPU.
///
/// The two 16-bit address latches are the source of most of the PPU's
/// awkwardness:
///
/// - `v` is the address the PPU renders from; it walks across the nametable as
///   dots are emitted.
/// - `t` is the address a scroll write stages a value into.
/// - `fine_x` is the sub-tile horizontal scroll, which cannot be represented in
///   `t` and so is kept separately.
///
/// The `$2006`/`$2005` write protocol is what moves values into and out of them,
/// and getting it wrong produces a picture that is subtly shifted rather than
/// obviously broken.
pub(all) struct Ppu {
  /// The control register.
  ctrl : Ctrl
  /// The mask register.
  mask : Mask
  /// The status register.
  status : Status
  /// Current rendering address.
  mut v : UInt32
  /// Staging address for scroll and address writes.
  mut t : UInt32
  /// Fine horizontal scroll, 0 to 7.
  mut fine_x : UInt32
  /// True while the next write to `$2005` or `$2006` sets the low byte.
  mut write_latch : Bool
  /// Nametable RAM: two 1 KiB tables, mirrored according to the cartridge.
  nt_ram : FixedArray[Byte]
  /// Palette RAM: 32 bytes, with the sprite entries mirrored down to 16.
  palette : FixedArray[Byte]
  /// Object attribute memory: 64 sprites of 4 bytes each.
  oam : FixedArray[Byte]
  /// The byte most recently read into the PPU's internal read buffer.
  ///
  /// A read from any VRAM address returns the previous buffer's contents and
  /// then refills it, which is why a program that reads a nametable byte twice
  /// gets two different answers.
  mut read_buffer : UInt32
  /// Which scanline the raster is on.
  mut scanline : Int32
  /// Which dot within that scanline.
  mut dot : Int32
  /// The decoded picture, one palette index per pixel.
  frame : FixedArray[Byte]
  /// Set when the frame has been fully drawn and the host should present it.
  mut frame_complete : Bool
  /// Which physical nametables answer the four virtual ones.
  ///
  /// Copying the cartridge's mirroring in at reset rather than reading it from
  /// the cartridge on every fetch matters because a single scanline touches the
  /// nametable hundreds of times; four-way mirroring additionally needs its own
  /// RAM, so the PPU owns it either way.
  mut mirroring : Mirroring
  /// Character memory, owned by the cartridge but read through here.
  mut chr : FixedArray[Byte]
  /// True when the cartridge's character memory is RAM and accepts writes.
  mut chr_ram : Bool
  /// How many scanlines the raster has completed since the counter was last
  /// read.
  ///
  /// The board's scanline counter watches the PPU's A12 line and cannot see the
  /// raster directly, so the console reports edges rather than lines; counting
  /// completed scanlines here is the same signal with less plumbing.
  mut scanlines : UInt32
  /// Which 8 KiB character bank the mapper currently has selected.
  ///
  /// Kept here rather than read from the cartridge on every fetch because a
  /// background row alone is eight pattern reads, and a pattern fetch happens
  /// hundreds of times per scanline; the console refreshes this whenever a
  /// mapper write changes it.
  mut chr_bank : Int64
  /// Per-1 KiB page numbers for the eight pages of the 8 KiB pattern space.
  ///
  /// Coarse boards fill this with the one bank they have selected; MMC3 fills it
  /// page by page from its six character registers. The PPU uses it whenever it
  /// is present, because a pattern fetch is the hottest path in the whole
  /// emulator and resolving a mapper's register layout per fetch would cost more
  /// than the fetch.
  mut chr_pages : FixedArray[Int64]?
  /// The offset `$2003` last wrote, used by direct OAM access.
  mut oam_addr : UInt32
}

///|
/// A PPU with every register at its power-on value.
///
/// `ctrl` starts at zero, which selects nametable 0 and 8x8 sprites; `mask`
/// starts at zero, so nothing renders until a game enables it. That is what makes
/// a game's first frame black rather than random.
pub fn Ppu::new() -> Ppu {
  {
    ctrl: {
      nametable: 0,
      increment32: false,
      sprite_pattern: 0,
      background_pattern: 0,
      tall_sprites: false,
      nmi_enabled: false,
    },
    mask: {
      show_background_left: false,
      show_sprites_left: false,
      show_background: false,
      show_sprites: false,
      emphasize_red: false,
      emphasize_green: false,
      emphasize_blue: false,
      greyscale: false,
    },
    status: { vblank: false, sprite_zero_hit: false, overflow: false, },
    v: 0,
    t: 0,
    fine_x: 0,
    write_latch: false,
    // Four KiB, not two: four-screen mirroring gives each virtual table its own
    // page, and the extra pages live on the cartridge rather than in the PPU.
    // Allocating only two would make table 2 and 3 read past the end of the array.
    nt_ram: FixedArray::make(0x1000, b'\x00'),
    palette: FixedArray::make(32, b'\x00'),
    oam: FixedArray::make(256, b'\x00'),
    read_buffer: 0,
    scanline: 0,
    dot: 0,
    frame: FixedArray::make(SCREEN_WIDTH * SCREEN_HEIGHT, b'\x00'),
    frame_complete: false,
    mirroring: Horizontal,
    chr: FixedArray::make(0x2000, b'\x00'),
    chr_ram: false,
    chr_bank: 0L,
    chr_pages: None,
    scanlines: 0U,
    oam_addr: 0,
  }
}

///|
/// What the background layer contributes at one position.
///
/// `opaque` is separate from the colour because a background pixel can resolve
/// to the backdrop colour and still count as opaque for sprite-zero purposes;
/// conflating the two is what makes a status-bar split fire at the wrong line.
priv struct BackgroundPixel {
  /// The palette entry, or the backdrop colour when nothing was drawn.
  colour : UInt32
  /// True when a tile pixel covered this position, whatever its colour.
  covered : Bool
}

///|
/// Computes the background layer at one position from the current scroll state.
///
/// Kept as one function so that rendering and sprite-zero detection agree by
/// construction rather than by two copies of the same arithmetic.
///
/// The vertical position comes from `v`, not from the scanline: a game that
/// rewrites the scroll register mid-frame is telling the PPU to draw a different
/// part of the nametable from here on, and reading the scanline instead would
/// ignore that.
fn Ppu::background_pixel(self : Ppu, x : Int32, _y : Int32) -> BackgroundPixel {
  let backdrop = self.palette_byte(0) & 0x3F
  let hidden = if x < 8 && !self.mask.show_background_left {
    true
  } else {
    !self.mask.show_background
  }
  if hidden {
    return { colour: backdrop, covered: false, }
  }
  // `v` already encodes the whole position: coarse X, coarse Y, the fine Y scroll
  // and both nametable-select bits. Rebuilding a pixel offset from them and then
  // re-adding the base nametable double-counts the table select, because the base
  // is already folded into bit 10 and bit 11 of `v`.
  let table_x = (self.v >> 10) & 0x03
  let name_x = (self.v & 0x1F).reinterpret_as_int()
  let name_y = ((self.v >> 5) & 0x1F).reinterpret_as_int()
  let tile = self.nametable_byte(table_x, name_x, name_y)
  let fine_y = ((self.v >> 12) & 0x07).reinterpret_as_int()
  let row = self.pattern_row(
    tile,
    fine_y.reinterpret_as_uint(),
    self.ctrl.background_pattern,
  )
  let bit = 7 - self.fine_x.reinterpret_as_int()
  // A background pixel is one bit from the low plane: its colour is always 0 or 1,
  // never 2 or 3. Reading the joined word without masking would pick up the high
  // plane's bit and produce colours the background layer cannot show.
  let low = row & 0xFF
  let pixel = (low >> bit) & 1
  if pixel == 0 {
    return { colour: backdrop, covered: false, }
  }
  let attr = self.attribute_byte(table_x, name_x, name_y)
  let high_bits : Int32 = name_y % 4 / 2 * 2 + name_x % 4 / 2
  let palette_index = (attr >> (high_bits * 2)) & 0x03U
  {
    // The palette's first entry is the backdrop, so a tile pixel of colour 1 maps
    // to entry 1 of its group rather than to entry 0. Adding one for the backdrop
    // as well would shift every background colour by one group.
    colour: self.palette_byte(palette_index * 4 + pixel) & 0x3F,
    covered: true,
  }
}

///|
/// Advances the raster by one dot and renders the pixel it lands on.
///
/// Returns true on the dot that starts vertical blank, so that the caller can
/// raise an NMI without polling. The scanline counters follow the roster the
/// hardware uses: an NTSC frame is 262 lines of 341 dots, and the visible
/// picture ends at line 240.
pub fn Ppu::tick(self : Ppu) -> Bool {
  if self.scanline < VBLANK_START {
    if self.dot < SCREEN_WIDTH {
      self.render_pixel()
    }
  }
  let mut started_vblank = false
  self.dot = self.dot + 1
  // `v` walks across the nametable as dots are emitted: every eighth dot it moves
  // to the next tile column, and at the end of a scanline it moves to the next
  // row. Without this the whole screen is one tile, which is what a static `v`
  // produces and it looks like a rendering bug rather than a missing one.
  if self.rendering_enabled() {
    if self.dot == 256 {
      self.increment_y()
    } else if self.dot == 257 {
      self.copy_horizontal()
    } else if self.dot % 8 == 0 && self.dot < 256 {
      self.increment_x()
    }
  }
  if self.dot >= DOTS_PER_SCANLINE {
    self.dot = 0
    self.scanline = self.scanline + 1
    // A scanline is one A12 rising edge for a board that counts them: the fetch
    // pattern is the same on every line, so the line boundary is a faithful
    // stand-in and costs one increment instead of tracking the bus.
    self.scanlines = self.scanlines + 1U
    if self.scanline == VBLANK_START {
      self.status.vblank = true
      started_vblank = true
      // The vertical blank hands the rest of the frame back to the CPU, and the
      // next frame starts from the top of the picture.
      self.copy_vertical()
    } else if self.scanline >= 262 {
      self.scanline = 0
      self.frame_complete = true
      // The vblank flag is cleared at the start of the next frame, because the
      // hardware clears it when the pre-render line finishes rather than when
      // the CPU reads $2002.
      self.status.vblank = false
      self.copy_vertical()
    }
  }
  started_vblank
}

///|
/// True when either layer is on, which is when the hardware advances the
/// rendering address.
pub fn Ppu::rendering_enabled(self : Ppu) -> Bool {
  self.mask.show_background || self.mask.show_sprites
}

///|
/// Advances the coarse horizontal scroll by one tile, wrapping into the next
/// nametable at the end of a row.
fn Ppu::increment_x(self : Ppu) -> Unit {
  if (self.v & 0x001F) == 0x1F {
    self.v = self.v & 0x7FE0
    // Bit 10 selects which of the two horizontal nametables the row continues
    // into; toggling it is how the PPU walks past the right edge.
    self.v = self.v ^ 0x0400
  } else {
    self.v = self.v + 1
  }
}

///|
/// Advances to the next row of tiles, wrapping into the next vertical nametable
/// after the twenty-ninth row.
///
/// The wrap compares against 29 rather than 31 because the bottom two rows of a
/// nametable are the attribute table, not tiles.
fn Ppu::increment_y(self : Ppu) -> Unit {
  if (self.v & 0x7000) != 0x7000 {
    self.v = self.v + 0x1000
  } else {
    self.v = self.v & 0x0FFF
    let mut coarse_y = (self.v & 0x03E0) >> 5
    if coarse_y == 29 {
      coarse_y = 0
      self.v = self.v ^ 0x0800
    } else if coarse_y == 31 {
      coarse_y = 0
    } else {
      coarse_y = coarse_y + 1
    }
    self.v = (self.v & 0x7C1FU) | (coarse_y << 5)
  }
}

///|
/// Copies the horizontal scroll bits from the staging register into the rendering
/// address, which the hardware does at dot 257 of every scanline.
fn Ppu::copy_horizontal(self : Ppu) -> Unit {
  self.v = (self.v & 0x7BE0U) | (self.t & 0x041FU)
}

///|
/// Copies the vertical scroll bits from the staging register, which the hardware
/// does during the pre-render line and at the start of vertical blank.
fn Ppu::copy_vertical(self : Ppu) -> Unit {
  self.v = (self.v & 0x041FU) | (self.t & 0x7BE0U)
}

///|
/// Writes the palette index for the pixel at the raster's current position.
///
/// Rendering reads the nametable through `v`, whose low bits select the tile
/// column and row; `fine_x` shifts the tile bitmap horizontally within the eight
/// pixels a tile covers. The coarse scroll is already folded into `v` by the
/// scroll registers, which is why a split-screen effect only needs the game to
/// rewrite `$2006` mid-frame.
fn Ppu::render_pixel(self : Ppu) -> Unit {
  let x = self.dot
  let y = self.scanline
  let background = self.background_pixel(x, y)
  let mut index = background.colour
  if self.mask.show_sprites {
    let sprite = self.sprite_pixel(x, y)
    match sprite {
      Some(pixel) => {
        // Sprite zero hit is raised only when an opaque sprite pixel overlaps an
        // opaque background pixel. Raising it whenever sprite zero covers this
        // scanline is the usual shortcut and it breaks every game that splits the
        // screen at a status bar, because the hit arrives a whole scanline early.
        if pixel.is_zero && background.covered {
          self.status.sprite_zero_hit = true
        }
        index = pixel.colour
      }
      None => ()
    }
  }
  if self.mask.greyscale {
    index = index & 0x30
  }
  if y < SCREEN_HEIGHT {
    self.frame[y * SCREEN_WIDTH + x] = (index & 0x3F).to_byte()
  }
}

///|
/// Reads one byte of palette RAM.
///
/// The palette is 32 bytes but only 16 are addressable at a time: the sprite
/// half mirrors $3F10-$3F1F down onto $3F00-$3F0F, and every fourth byte is a
/// mirror of the backdrop colour rather than a real entry. Reproducing both
/// mirrors matters because games write the backdrop through the sprite alias.
fn Ppu::palette_byte(self : Ppu, index : UInt32) -> UInt32 {
  let mut at = index.reinterpret_as_int() & 0x1F
  if at >= 0x10 && at % 4 == 0 {
    at = at - 0x10
  }
  self.palette[at].to_int().reinterpret_as_uint() & 0x3F
}

///|
/// Writes one byte of palette RAM through the same mirrors.
pub fn Ppu::set_palette_byte(
  self : Ppu,
  index : UInt32,
  value : UInt32,
) -> Unit {
  let mut at = index.reinterpret_as_int() & 0x1F
  if at >= 0x10 && at % 4 == 0 {
    at = at - 0x10
  }
  self.palette[at] = (value & 0x3F).to_byte()
}

///|
/// Reads a nametable byte for a virtual table, tile column and tile row.
///
/// `table` selects one of the four virtual tables the PPU can address; the
/// cartridge's mirroring decides which of the two physical 1 KiB pages answers.
fn Ppu::nametable_byte(
  self : Ppu,
  table : UInt32,
  column : Int32,
  row : Int32,
) -> UInt32 {
  let physical = table_ram_base(self.mirroring, table.reinterpret_as_int())
  let at = physical + row * 32 + column
  self.nt_ram[at].to_int().reinterpret_as_uint() & 0xFF
}

///|
/// Reads the attribute-table byte governing a tile.
///
/// The attribute table occupies the last 64 bytes of each nametable and packs
/// four 2-bit palette selections per byte, so a tile's byte is found by dividing
/// its coordinates by four and its field by taking the low or high nibble.
fn Ppu::attribute_byte(
  self : Ppu,
  table : UInt32,
  column : Int32,
  row : Int32,
) -> UInt32 {
  let physical = table_ram_base(self.mirroring, table.reinterpret_as_int())
  let at = physical + 0x3C0 + row / 4 * 8 + column / 4
  self.nt_ram[at].to_int().reinterpret_as_uint() & 0xFF
}

///|
/// Fetches one row of a tile bitmap as two bitplanes joined into one byte.
///
/// A tile's bitmap is stored as two 8-byte planes: the low bits of every pixel
/// in one plane and the high bits in the next. Pixel *n* of the row is
/// `(plane0 >> (7-n) & 1) | ((plane1 >> (7-n) & 1) << 1)`.
fn Ppu::pattern_row(
  self : Ppu,
  tile : UInt32,
  row : UInt32,
  base : UInt32,
) -> UInt32 {
  let offset = base.reinterpret_as_int() +
    tile.reinterpret_as_int() * 16 +
    (row.reinterpret_as_int() & 7)
  let low = self.chr_byte(offset)
  let high = self.chr_byte(offset + 8)
  low | (high << 8)
}

///|
/// The offset into the PPU's 2 KiB of video RAM that a virtual nametable maps to.
///
/// The four virtual tables select among two physical pages, and the cartridge's
/// mirroring decides which page each virtual one sees. Getting this wrong is
/// visible immediately: a horizontally mirrored cartridge run with vertical
/// mirroring scrolls the wrong axis through the level.
fn table_ram_base(mirroring : Mirroring, table : Int32) -> Int32 {
  let selector = table & 0x03
  match mirroring {
    // Vertical mirroring puts the two pages side by side: table 0 and 2 are the
    // left page, 1 and 3 the right.
    Vertical => if selector % 2 == 0 { 0x000 } else { 0x400 }
    // Horizontal mirroring stacks them: 0 and 1 are the top, 2 and 3 the bottom.
    Horizontal => if selector / 2 == 0 { 0x000 } else { 0x400 }
    SingleLow => 0x000
    SingleHigh => 0x400
    // Four-screen mirroring gives each virtual table its own page, which needs
    // 4 KiB; the PPU allocates the extra two pages beyond its nominal 2 KiB.
    FourScreen => selector * 0x400
  }
}

///|
/// Reads a byte of character memory.
fn Ppu::chr_byte(self : Ppu, offset : Int32) -> UInt32 {
  let size = self.chr.length()
  if size <= 0 {
    return 0U
  }
  // A board with 1 KiB granularity hands over a page table; using it here keeps
  // the mapper's register layout out of the fetch path.
  match self.chr_pages {
    Some(pages) => {
      let page = offset % 0x2000 / 0x400
      let bank = pages[page].to_int()
      let within = offset % 0x400
      return self.chr[(bank * 0x400 + within) % size]
        .to_int()
        .reinterpret_as_uint() &
        0xFF
    }
    None => ()
  }
  // Pattern tables are 8 KiB, and a board with more than one of them answers a
  // fetch from whichever bank its register currently selects. Adding the bank
  // base before the mask matters: masking first would pin every fetch to bank
  // zero, which renders banks 1..n as a copy of the first.
  let banks = size / 0x2000
  let bank = if banks <= 0 { 0 } else { self.chr_bank.to_int() % banks }
  let at = (bank * 0x2000 + offset % 0x2000) % size
  self.chr[at].to_int().reinterpret_as_uint() & 0xFF
}

///|
/// Renders the sprite layer for one pixel, returning the palette index when a
/// sprite is opaque there.
///
/// Sprites are drawn in OAM order and the first opaque pixel wins, except that
/// sprite 0 hitting an opaque background pixel raises the sprite-zero flag,
/// which is the only way a game can synchronise to the raster.

///|
/// An opaque sprite pixel together with which sprite it came from.
///
/// The index is carried out because sprite zero's hit flag depends on the sprite's
/// position in OAM, and OAM is the only fixed point a game can rely on to know
/// when the raster has reached a particular line.
priv struct SpritePixel {
  /// The palette entry to draw.
  colour : UInt32
  /// True when this came from the sprite at OAM index zero.
  is_zero : Bool
}

///|
/// Finds the frontmost opaque sprite pixel at a position.
///
/// Sprites are drawn in OAM order and the first opaque pixel wins, so a sprite
/// with a higher index that overlaps a lower one is hidden behind it. That is the
/// opposite of the background layer, where nothing overlaps, and it is what makes
/// hardware-sprite multiplexing possible.
fn Ppu::sprite_pixel(self : Ppu, x : Int32, y : Int32) -> SpritePixel? {
  if x < 8 && !self.mask.show_sprites_left {
    return None
  }
  let height = if self.ctrl.tall_sprites { 16 } else { 8 }
  let mut drawn = 0
  for i in 0..<64 {
    let at = i * 4
    let sprite_y = self.oam[at].to_int().reinterpret_as_uint()
    let tile_index = self.oam[at + 1].to_int().reinterpret_as_uint()
    let attributes = self.oam[at + 2].to_int().reinterpret_as_uint()
    let sprite_x = self.oam[at + 3].to_int().reinterpret_as_uint()
    // OAM stores the sprite's top edge minus one, so $FF means the sprite starts
    // on scanline 0. The addition wraps inside eight bits rather than going
    // negative, which is why $FF is the top of the screen rather than above it.
    let top = ((sprite_y + 1U) & 0xFFU).reinterpret_as_int()
    let row = y - top
    // A negative difference means the scanline is above the sprite; a distance at
    // least the sprite's height means it is below.
    if row < 0 || row >= height {
      continue
    }
    if x < sprite_x.reinterpret_as_int() ||
      x >= sprite_x.reinterpret_as_int() + 8 {
      continue
    }
    drawn = drawn + 1
    if drawn > 8 {
      self.status.overflow = true
      break
    }
    let mut row = row
    if (attributes & 0x80) != 0 {
      row = height - 1 - row
    }
    let mut column = x - sprite_x.reinterpret_as_int()
    if (attributes & 0x40) != 0 {
      column = 7 - column
    }
    let palette = attributes & 0x03
    let tile = if self.ctrl.tall_sprites {
      // A tall sprite's index selects a 16-pixel pair: the low bit is forced to
      // zero and the row selects which of the two 8x8 tiles to use.
      let base = (tile_index & 0xFE) | (row / 8).reinterpret_as_uint()
      base
    } else {
      tile_index
    }
    let row_in_tile = (row % 8).reinterpret_as_uint()
    let bitmap = self.pattern_row(tile, row_in_tile, self.ctrl.sprite_pattern)
    let bit = 7 - column
    let pixel = (bitmap >> bit) & 3
    if pixel != 0 {
      return Some({
        colour: self.palette_byte(0x10 + palette * 4 + pixel) & 0x3F,
        is_zero: i == 0,
      })
    }
  }
  None
}

///|
/// Reads one of the PPU's eight registers.
///
/// Only `$2002` returns a value directly; the others either return the read
/// buffer's contents or return nothing a program should rely on. Register reads
/// also have side effects — reading the status clears the vblank flag and the
/// write latch — which is why they cannot be modelled as pure getters.
pub fn Ppu::read_register(self : Ppu, address : UInt32) -> UInt32 {
  match address & 0x07U {
    0x02U => {
      let mut value = 0U
      if self.status.vblank {
        value = value | 0x80U
      }
      if self.status.sprite_zero_hit {
        value = value | 0x40U
      }
      if self.status.overflow {
        value = value | 0x20U
      }
      // Reading status clears vblank and the write latch. It does not clear
      // sprite-zero hit until the pre-render line, which is what makes the flag
      // usable as a timing signal: a game polls it once and the next frame's
      // poll would otherwise see a stale set.
      self.status.vblank = false
      self.write_latch = false
      value
    }
    0x04U =>
      self.oam[self.oam_addr.reinterpret_as_int()]
      .to_int()
      .reinterpret_as_uint() &
      0xFF
    0x07U => self.read_vram()
    _ => 0U
  }
}

///|
/// Writes one of the PPU's eight registers.
pub fn Ppu::write_register(
  self : Ppu,
  address : UInt32,
  value : UInt32,
) -> Unit {
  match address & 0x07U {
    0x00U => {
      self.ctrl.nametable = value & 0x03U
      self.ctrl.increment32 = (value & 0x04) != 0
      self.ctrl.sprite_pattern = (value >> 3) & 0x01
      self.ctrl.background_pattern = (value >> 4) & 0x01
      self.ctrl.tall_sprites = (value & 0x20) != 0
      self.ctrl.nmi_enabled = (value & 0x80) != 0
      // The nametable bits live in both the control register and the scroll
      // latch; writing here updates the staged address too.
      self.t = (self.t & 0x73FF) | ((value & 0x03) << 10)
    }
    0x01U => {
      self.mask.greyscale = (value & 0x01) != 0
      self.mask.show_background_left = (value & 0x02) != 0
      self.mask.show_sprites_left = (value & 0x04) != 0
      self.mask.show_background = (value & 0x08) != 0
      self.mask.show_sprites = (value & 0x10) != 0
      self.mask.emphasize_red = (value & 0x20) != 0
      self.mask.emphasize_green = (value & 0x40) != 0
      self.mask.emphasize_blue = (value & 0x80) != 0
    }
    // $2003 sets the OAM address; it does not write OAM.
    0x03U => self.oam_addr = value & 0xFFU
    0x04U => self.write_oam(value)
    0x05U => self.write_scroll(value)
    0x06U => self.write_address(value)
    0x07U => self.write_vram(value)
    _ => ()
  }
}

///|
/// Writes a byte of OAM at the current address and advances it.
///
/// OAM is normally filled through `$4014`'s DMA rather than byte by byte, so this
/// only has to be correct for the direct-access path that a few games use.
fn Ppu::write_oam(self : Ppu, value : UInt32) -> Unit {
  let at = self.oam_addr.reinterpret_as_int() & 0xFF
  self.oam[at] = (value & 0xFF).to_byte()
  self.oam_addr = (self.oam_addr + 1U) & 0xFFU
}

///|
/// Handles a write to the scroll register `$2005`.
///
/// The first write sets the coarse and fine horizontal scroll, the second the
/// vertical. The split is invisible to the caller — it depends on a latch that
/// the status register read also clears — which is why `write_latch` is PPU state
/// and not a parameter.
fn Ppu::write_scroll(self : Ppu, value : UInt32) -> Unit {
  if !self.write_latch {
    self.t = (self.t & 0x7FE0) | ((value >> 3) & 0x1F) | ((value & 0x07) << 12)
    self.fine_x = value & 0x07
    self.write_latch = true
  } else {
    let coarse_y = (value >> 3) & 0x1F
    let fine_y = value & 0x07
    self.t = (self.t & 0x0C1F) | (coarse_y << 5) | (fine_y << 12)
    self.write_latch = false
  }
}

///|
/// Handles a write to the address register `$2006`.
fn Ppu::write_address(self : Ppu, value : UInt32) -> Unit {
  if !self.write_latch {
    self.t = (self.t & 0x00FF) | ((value & 0x3F) << 8)
    self.write_latch = true
  } else {
    self.t = (self.t & 0x7F00) | (value & 0xFF)
    self.v = self.t
    self.write_latch = false
  }
}

///|
/// Reads from the data port `$2007`.
///
/// The returned value is whatever the previous access buffered, except for
/// palette reads, which return immediately because the palette sits on the PPU's
/// own die and needs no buffering.
fn Ppu::read_vram(self : Ppu) -> UInt32 {
  let address = self.v & 0x3FFFU
  let result = if address >= 0x3F00U {
    // A palette read returns the byte immediately but still refills the buffer
    // from the mirrored nametable address beneath it.
    let mirrored = address - 0x1000U
    self.read_buffer = self.vram_read(mirrored)
    self.palette_byte(address & 0x1FU)
  } else {
    let buffered = self.read_buffer
    self.read_buffer = self.vram_read(address)
    buffered
  }
  self.v = (self.v + self.increment()) & 0x7FFFU
  result
}

///|
/// Writes to the data port `$2007`.
fn Ppu::write_vram(self : Ppu, value : UInt32) -> Unit {
  let address = self.v & 0x3FFFU
  if address >= 0x3F00U {
    self.set_palette_byte(address & 0x1FU, value)
  } else if address >= 0x2000U {
    let at = table_ram_offset(
      self.mirroring,
      (address - 0x2000U).reinterpret_as_int(),
    )
    self.nt_ram[at] = (value & 0xFF).to_byte()
  } else if self.chr_ram {
    // Only a CHR-RAM cartridge accepts writes here. On a CHR-ROM board the
    // pattern tables are read-only, and silently writing would corrupt the tile
    // bitmaps that every sprite and background fetch reads back.
    let size = self.chr.length()
    let banks = size / 0x2000
    let bank = if banks <= 0 { 0 } else { self.chr_bank.to_int() % banks }
    let at = (bank * 0x2000 + address.reinterpret_as_int() % 0x2000) % size
    self.chr[at] = (value & 0xFF).to_byte()
  }
  self.v = (self.v + self.increment()) & 0x7FFFU
}

///|
/// How far `$2007` advances the address after each access.
fn Ppu::increment(self : Ppu) -> UInt32 {
  if self.ctrl.increment32 {
    32U
  } else {
    1U
  }
}

///|
/// Reads a PPU address that is not the palette.
fn Ppu::vram_read(self : Ppu, address : UInt32) -> UInt32 {
  if address >= 0x2000U {
    let at = table_ram_offset(
      self.mirroring,
      (address - 0x2000U).reinterpret_as_int(),
    )
    self.nt_ram[at].to_int().reinterpret_as_uint() & 0xFF
  } else {
    self.chr_byte(address.reinterpret_as_int())
  }
}

///|
/// Maps a PPU address in the $2000-$3EFF range to an offset in the PPU's
/// nametable RAM.
///
/// The range is 8 KiB wide but only 2 KiB exist; the address is folded first so
/// that the cartridge's mirroring is applied to the table index, not the raw
/// offset.
fn table_ram_offset(mirroring : Mirroring, address : Int32) -> Int32 {
  let folded = address % 0x1000
  let table = folded / 0x400
  let within = folded % 0x400
  table_ram_base(mirroring, table) + within
}
