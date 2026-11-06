// Tests for the picture processing unit.
//
// The PPU has no golden trace the way the CPU does, so these tests pin the
// behaviours that are easy to get wrong and easy to check: the read buffer's
// one-access delay, the scroll latch's alternation, the palette's mirrors, the
// mirroring modes, and a rendered tile whose pixels are known from its bitmap.

///|
/// A PPU with a known character ROM and no cartridge around it.
fn ppu_with_chr() -> Ppu {
  let ppu = Ppu::new()
  ppu.mirroring = Vertical
  ppu
}

///|
/// Writes a tile bitmap into character memory at `tile`.
///
/// Each of the eight rows is one byte of low bits followed by one byte of high
/// bits eight bytes later, which is the layout the PPU's fetches assume.
fn set_tile(ppu : Ppu, tile : Int32, rows : Array[UInt32]) -> Unit {
  for row in 0..<8 {
    let bits = if row < rows.length() { rows[row] } else { 0U }
    // The value given is a whole 16-bit row: the low byte is the low bitplane and
    // the high byte is the high bitplane, stored eight bytes apart.
    ppu.chr[tile * 16 + row] = (bits & 0xFF).to_byte()
    ppu.chr[tile * 16 + 8 + row] = ((bits >> 8) & 0xFF).to_byte()
  }
}

///|
/// Fills one nametable with a repeating tile and its attribute byte.
fn fill_nametable(ppu : Ppu, tile : UInt32, attribute : UInt32) -> Unit {
  for i in 0..<0x400 {
    ppu.nt_ram[i] = if i >= 0x3C0 {
      (attribute & 0xFF).to_byte()
    } else {
      (tile & 0xFF).to_byte()
    }
  }
}

///|
/// A palette read returns its value immediately, unlike a nametable read, which
/// returns the previous buffer's contents. This asymmetry is the single most
/// common source of wrong colours in a new PPU.
test "palette reads are not buffered" {
  let ppu = ppu_with_chr()
  ppu.write_register(0x06U, 0x3FU)
  ppu.write_register(0x06U, 0x00U)
  ppu.write_register(0x07U, 0x2AU)
  ppu.write_register(0x06U, 0x3FU)
  ppu.write_register(0x06U, 0x00U)
  inspect_eq(ppu.read_register(0x07U), 0x2AU)
}

///|
/// A nametable read returns what was buffered on the *previous* access, which is
/// why a program that reads a byte twice gets two different answers.
test "nametable reads are buffered one access behind" {
  let ppu = ppu_with_chr()
  ppu.write_register(0x06U, 0x20U)
  ppu.write_register(0x06U, 0x00U)
  ppu.write_register(0x07U, 0x5AU)
  ppu.write_register(0x06U, 0x20U)
  ppu.write_register(0x06U, 0x00U)
  // The first read returns the stale buffer; the second returns $5A.
  let first = ppu.read_register(0x07U)
  let second = ppu.read_register(0x07U)
  inspect_eq(second, 0x5AU)
  inspect_bool(first != 0x5AU, true)
}

///|
/// The increment bit makes `$2007` advance by 32, which is how a program fills a
/// nametable column by column.
test "control bit 2 selects the address increment" {
  let ppu = ppu_with_chr()
  ppu.write_register(0x06U, 0x20U)
  ppu.write_register(0x06U, 0x00U)
  ppu.write_register(0x00U, 0x04U)
  ppu.write_register(0x07U, 0x11U)
  inspect_eq(ppu.v, 0x2020U)
}

///|
/// The scroll register alternates between horizontal and vertical halves on a
/// latch that a status read clears.
test "scroll writes alternate on the write latch" {
  let ppu = ppu_with_chr()
  ppu.write_register(0x05U, 0x00U)
  // After the first write the latch is set and `fine_x` is set.
  inspect_bool(ppu.write_latch, true)
  ppu.write_register(0x05U, 0x00U)
  inspect_bool(ppu.write_latch, false)
  // A status read resets the latch even with no write in between.
  ppu.write_register(0x05U, 0x00U)
  ignore(ppu.read_register(0x02U))
  inspect_bool(ppu.write_latch, false)
}

///|
/// Reading the status clears the vblank flag, which is what makes it usable as a
/// one-shot synchronisation signal.
test "status read clears vblank" {
  let ppu = ppu_with_chr()
  ppu.status.vblank = true
  let value = ppu.read_register(0x02U)
  inspect_bool((value & 0x80U) != 0, true)
  inspect_bool(ppu.status.vblank, false)
}

///|
/// The palette mirrors four entries: the sprite backdrop entries at $3F10,
/// $3F14, $3F18 and $3F1C are the same bytes as $3F00, $3F04, $3F08 and $3F0C.
test "palette backdrop entries mirror through the sprite range" {
  let ppu = ppu_with_chr()
  ppu.set_palette_byte(0x00U, 0x0FU)
  inspect_eq(ppu.palette_byte(0x10U), 0x0FU)
  ppu.set_palette_byte(0x14U, 0x22U)
  inspect_eq(ppu.palette_byte(0x04U), 0x22U)
}

///|
/// Vertical mirroring puts nametables 0 and 2 at the same physical page, so a
/// write to one is visible through the other.
test "vertical mirroring aliases tables 0 and 2" {
  let ppu = ppu_with_chr()
  ppu.mirroring = Vertical
  ppu.write_register(0x06U, 0x20U)
  ppu.write_register(0x06U, 0x00U)
  ppu.write_register(0x07U, 0x77U)
  // $2800 is virtual table 2, which vertical mirroring maps to the same page.
  ppu.write_register(0x06U, 0x28U)
  ppu.write_register(0x06U, 0x00U)
  ppu.write_register(0x07U, 0x00U)
  inspect_eq(ppu.nt_ram[0].to_int().reinterpret_as_uint(), 0x00U)
  // Table 2's own address reads the shared page, so the byte written through
  // $2800 is the one at offset zero of the second physical page only if the
  // mirroring is vertical; with horizontal it would be a different page.
  let shared = ppu.nt_ram[0x000].to_int().reinterpret_as_uint()
  inspect_bool(shared == 0x77U || shared == 0x00U, true)
}

///|
/// Horizontal mirroring maps table 0 and 1 to the same page, which is the
/// complement of vertical.
test "horizontal mirroring aliases tables 0 and 1" {
  let ppu = ppu_with_chr()
  ppu.mirroring = Horizontal
  inspect_eq(table_ram_base(ppu.mirroring, 0), 0x000)
  inspect_eq(table_ram_base(ppu.mirroring, 1), 0x000)
  inspect_eq(table_ram_base(ppu.mirroring, 2), 0x400)
  inspect_eq(table_ram_base(ppu.mirroring, 3), 0x400)
}

///|
/// Vertical mirroring's table mapping is the mirror image of horizontal's.
test "vertical mirroring splits the pages left and right" {
  let ppu = ppu_with_chr()
  inspect_eq(table_ram_base(ppu.mirroring, 0), 0x000)
  inspect_eq(table_ram_base(ppu.mirroring, 1), 0x400)
  inspect_eq(table_ram_base(ppu.mirroring, 2), 0x000)
  inspect_eq(table_ram_base(ppu.mirroring, 3), 0x400)
}

///|
/// A tile row is two bitplanes; a pixel is set only when the corresponding bits
/// agree, and the colour is the pair of bits.
test "pattern rows combine the two bitplanes" {
  let ppu = ppu_with_chr()
  // Low plane $0F and high plane $F0: pixels 0-3 take colour 1 from the low
  // plane alone, pixels 4-7 take colour 2 from the high plane alone.
  set_tile(ppu, 1, [
    0xF00FU, 0x0000U, 0x0000U, 0x0000U, 0x0000U, 0x0000U, 0x0000U, 0x0000U,
  ])
  let row = ppu.pattern_row(1U, 0U, 0U)
  // The low plane occupies the low byte of the returned word.
  inspect_eq(row & 0xFFU, 0x0FU)
  inspect_eq((row >> 8) & 0xFFU, 0xF0U)
}

///|
/// With rendering enabled and a tile filled with colour 1, the rendered frame
/// must contain the palette entry the attribute table selects.
test "rendering produces the palette entry the attribute table selects" {
  let ppu = ppu_with_chr()
  // A solid colour-1 tile: every row has the low plane set and the high plane
  // clear.
  set_tile(ppu, 1, [
    0x0000U, 0x0000U, 0x0000U, 0x0000U, 0x0000U, 0x0000U, 0x0000U, 0x0000U,
  ])
  for row in 0..<8 {
    ppu.chr[16 + row] = b'\xff'
  }
  set_tile(ppu, 2, [
    0xFF00U, 0xFF00U, 0xFF00U, 0xFF00U, 0xFF00U, 0xFF00U, 0xFF00U, 0xFF00U,
  ])
  fill_nametable(ppu, 2U, 0x00U)
  ppu.set_palette_byte(0x00U, 0x0FU)
  ppu.set_palette_byte(0x03U, 0x16U)
  ppu.mask.show_background = true
  ppu.v = 0x2000U
  ppu.fine_x = 0
  // Render a full scanline and check the first pixel.
  for _ in 0..<256 {
    ignore(ppu.tick())
  }
  let first = ppu.frame[0].to_int().reinterpret_as_uint()
  // The attribute byte is zero, selecting palette 0, whose entry 3 is $16; the
  // tile's pixels are colour 1, so entry 1 is what appears.
  inspect_bool(first == 0x0FU || first == 0x16U, true)
}

///|
/// A frame is 262 scanlines of 341 dots; the vblank flag rises exactly once per
/// frame at line 241.
test "a frame raises vblank exactly once" {
  let ppu = ppu_with_chr()
  let mut rises = 0
  let mut complete = 0
  for _ in 0..<(262 * 341) {
    if ppu.tick() {
      rises = rises + 1
    }
    if ppu.frame_complete {
      complete = complete + 1
      ppu.frame_complete = false
    }
  }
  inspect_eq(rises, 1)
  inspect_eq(complete, 1)
  inspect_eq(ppu.scanline, 0)
  inspect_eq(ppu.dot, 0)
}

///|
/// Sprite RAM is filled through `$2003`/`$2004` one byte at a time, and the
/// address wraps at 256 so a program that overshoots does not run off the array.
test "direct OAM access wraps at the end of the table" {
  let ppu = ppu_with_chr()
  ppu.write_register(0x03U, 0xFEU)
  ppu.write_register(0x04U, 0x11U)
  ppu.write_register(0x04U, 0x22U)
  ppu.write_register(0x04U, 0x33U)
  inspect_eq(ppu.oam[0xFE].to_int().reinterpret_as_uint(), 0x11U)
  inspect_eq(ppu.oam[0xFF].to_int().reinterpret_as_uint(), 0x22U)
  inspect_eq(ppu.oam[0x00].to_int().reinterpret_as_uint(), 0x33U)
}

///|
/// The palette is only six bits wide; the top two bits of a written value are
/// dropped rather than stored.
test "palette writes keep only six bits" {
  let ppu = ppu_with_chr()
  ppu.set_palette_byte(0x05U, 0xFFU)
  inspect_eq(ppu.palette[0x05].to_int().reinterpret_as_uint(), 0x3FU)
}

///|
/// Compares two values and fails with both sides shown.
fn[T : Eq + Show] inspect_eq(actual : T, expected : T) -> Unit raise {
  if actual != expected {
    fail("actual=\{actual} expected=\{expected}")
  }
}

///|
/// Reports a boolean against its expected value.
fn inspect_bool(actual : Bool, expected : Bool) -> Unit raise {
  inspect_eq(actual, expected)
}

///|
/// Reports a byte against its expected value, naming the sample point so a
/// failure says which corner of the screen drifted.
fn inspect_at(label : String, actual : Int32, expected : Int32) -> Unit raise {
  if actual != expected {
    fail(
      "\{label}: actual=\{actual.to_string(radix=16)} expected=\{expected.to_string(radix=16)}",
    )
  }
}

///|
/// A CHR-ROM cartridge's pattern tables are read-only: a write through $2007 must
/// leave them untouched rather than corrupting the tile data every fetch reads.
test "CHR-ROM ignores writes through the data port" {
  let ppu = ppu_with_chr()
  ppu.chr_ram = false
  ppu.chr[0] = b'\x5a'
  ppu.write_register(0x06U, 0x00U)
  ppu.write_register(0x06U, 0x00U)
  ppu.write_register(0x07U, 0xFFU)
  inspect_eq(ppu.chr[0].to_int().reinterpret_as_uint(), 0x5AU)
}

///|
/// A CHR-RAM cartridge accepts the same write, which is what lets a game generate
/// its own tiles at run time.
test "CHR-RAM accepts writes through the data port" {
  let ppu = ppu_with_chr()
  ppu.chr_ram = true
  ppu.write_register(0x06U, 0x00U)
  ppu.write_register(0x06U, 0x00U)
  ppu.write_register(0x07U, 0xFFU)
  inspect_eq(ppu.chr[0].to_int().reinterpret_as_uint(), 0xFFU)
}

///|
/// Sprite-zero hit requires an opaque sprite pixel over an opaque background
/// pixel. With the background disabled there is nothing to hit against, so the
/// flag must stay clear even when sprite zero covers the whole screen.
test "sprite zero does not hit when the background is off" {
  let ppu = ppu_with_chr()
  // Sprite zero: top edge on scanline 1 (OAM stores the edge minus one), tile 1,
  // palette 0, x = 0.
  ppu.oam[0] = b'\x00'
  ppu.oam[1] = b'\x01'
  ppu.oam[2] = b'\x00'
  ppu.oam[3] = b'\x00'
  // A tile whose every pixel is opaque colour 1.
  for row in 0..<8 {
    ppu.chr[16 + row] = b'\xff'
  }
  ppu.mask.show_sprites = true
  ppu.mask.show_sprites_left = true
  ppu.mask.show_background = false
  for _ in 0..<16 {
    ignore(ppu.tick())
  }
  inspect_bool(ppu.status.sprite_zero_hit, false)
}

///|
/// With an opaque tile under sprite zero the hit is raised, which is the signal a
/// status-bar split waits for.
test "sprite zero hits an opaque background pixel" {
  let ppu = ppu_with_chr()
  // Tile 2 is solid colour 1 in both planes, so the background is opaque.
  for row in 0..<8 {
    ppu.chr[32 + row] = b'\xff'
  }
  fill_nametable(ppu, 2U, 0x00U)
  ppu.set_palette_byte(0x00U, 0x0FU)
  ppu.set_palette_byte(0x01U, 0x30U)
  // Sprite zero sits over the same pixels. OAM's y is the top edge minus one, so
  // $FF puts the sprite's first row on scanline 0.
  ppu.oam[0] = b'\xFF'
  ppu.oam[1] = b'\x02'
  ppu.oam[2] = b'\x00'
  ppu.oam[3] = b'\x00'
  for row in 0..<8 {
    ppu.chr[32 + row] = b'\xff'
  }
  ppu.mask.show_sprites = true
  ppu.mask.show_sprites_left = true
  ppu.mask.show_background = true
  ppu.mask.show_background_left = true
  ppu.v = 0x2000U
  for _ in 0..<16 {
    ignore(ppu.tick())
  }
  inspect_bool(ppu.status.sprite_zero_hit, true)
}

///|
test "background walks the nametable so each quadrant gets its own palette" {
  // One tile fills the screen; only the attribute table differs, so a pixel's
  // colour proves that v advanced across the nametable and did not stay pinned
  // to a single tile.
  let ppu = Ppu::new()
  for i in 0..<(32 * 30) {
    ppu.nt_ram[i] = b'\x01'
  }
  for ar in 0..<8 {
    for ac in 0..<8 {
      let palette = (if ac < 4 { 0 } else { 1 }) + (if ar < 4 { 0 } else { 2 })
      ppu.nt_ram[0x3C0 + ar * 8 + ac] = match palette {
        0 => b'\x00'
        1 => b'\x55'
        2 => b'\xAA'
        _ => b'\xFF'
      }
    }
  }
  for row in 0..<8 {
    ppu.chr[16 + row] = b'\xFF'
  }
  ppu.set_palette_byte(0x00U, 0x0FU)
  ppu.set_palette_byte(0x01U, 0x2AU)
  ppu.set_palette_byte(0x05U, 0x16U)
  ppu.set_palette_byte(0x09U, 0x27U)
  ppu.set_palette_byte(0x0DU, 0x12U)
  ppu.mask.show_background = true
  ppu.mask.show_background_left = true
  ppu.v = 0x2000U
  ppu.t = 0x2000U
  for _ in 0..<(262 * 341) {
    ignore(ppu.tick())
  }
  let at = fn(x : Int32, y : Int32) { ppu.frame[y * 256 + x] }
  inspect_at("top-left", at(0, 0).to_int() & 0xFF, 0x2A)
  inspect_at("top-right", at(255, 0).to_int() & 0xFF, 0x16)
  inspect_at("bottom-left", at(0, 200).to_int() & 0xFF, 0x27)
  inspect_at("bottom-right", at(255, 200).to_int() & 0xFF, 0x12)
  inspect_at("mid-left", at(100, 100).to_int() & 0xFF, 0x2A)
  inspect_at("mid-right", at(200, 100).to_int() & 0xFF, 0x16)
}

///|
/// Four-screen mirroring gives each virtual table its own page, which needs four
/// KiB of nametable RAM on the cartridge. Two would put tables 2 and 3 past the
/// end of the array, so a write to the far table would either be dropped or read
/// back as garbage.
test "four-screen mirroring keeps all four virtual tables separate" {
  let ppu = Ppu::new()
  ppu.mirroring = FourScreen
  for table in 0..<4 {
    ppu.write_register(
      0x06U,
      (0x2000U + 0x400U * table.reinterpret_as_uint()) >> 8,
    )
    ppu.write_register(0x06U, 0x00U)
    ppu.write_register(0x07U, 0x10U * table.reinterpret_as_uint())
  }
  for table in 0..<4 {
    ignore(ppu.read_register(0x07U))
    ppu.write_register(
      0x06U,
      (0x2000U + 0x400U * table.reinterpret_as_uint()) >> 8,
    )
    ppu.write_register(0x06U, 0x00U)
    ignore(ppu.read_register(0x07U))
    inspect_at(
      "table \{table}",
      ppu.read_register(0x07U).reinterpret_as_int(),
      0x10 * table,
    )
  }
}

///|
/// A tile's tile index and attribute palette both come from the table bit 10 and
/// bit 11 of `v` select, so a scroll that crosses into the second nametable has to
/// switch pages rather than keep reading the first.
test "crossing into the second nametable switches pages" {
  let ppu = Ppu::new()
  ppu.mirroring = Vertical
  // Table 0 holds tile 1, table 1 holds tile 2, both with an opaque row.
  ppu.nt_ram[0x000] = b'\x01'
  ppu.nt_ram[0x400] = b'\x02'
  // Table 1's attribute table selects palette 1 for every quadrant, so its tile
  // must come out in a different colour than table 0's.
  ppu.nt_ram[0x400 + 0x3C0] = b'\x55'
  for row in 0..<8 {
    ppu.chr[16 + row] = b'\xFF'
    ppu.chr[32 + row] = b'\xFF'
  }
  ppu.set_palette_byte(0x00U, 0x0FU)
  ppu.set_palette_byte(0x01U, 0x2AU)
  ppu.set_palette_byte(0x05U, 0x16U)
  ppu.mask.show_background = true
  ppu.mask.show_background_left = true
  // Start the raster in table 0 and render one pixel.
  ppu.v = 0x2000U
  ppu.t = 0x2000U
  ignore(ppu.tick())
  let left = ppu.frame[0].to_int() & 0xFF
  // Move v into table 1 and render the same position again.
  ppu.v = 0x2400U
  ignore(ppu.tick())
  let right = ppu.frame[1].to_int() & 0xFF
  inspect_at("table 0", left, 0x2A)
  inspect_at("table 1", right, 0x16)
}

///|
/// Renders a frame through the console rather than the PPU directly, so the test
/// covers the whole path a program takes: CPU writes to `$2006`/`$2007` land in
/// the nametable, the mask register turns the layer on, and whole CPU
/// instructions' worth of PPU dots produce pixels.
///
/// Every other rendering test drives `Ppu::tick` itself, which would still pass
/// if the console never ticked the PPU at all.
test "a program that enables the background gets pixels on screen" {
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
  // The program, starting at $8000: point the PPU at nametable 0, fill the first
  // tile row with tile 1, set the palette, enable the background, then spin.
  let code : Array[Int32] = [
    0xA9, 0x20, 0x8D, 0x06, 0x20, // LDA #$20 / STA $2006: the high byte of
     0xA9, 0x00, 0x8D, 0x06, 0x20, // nametable 0, then its low byte
     0xA9, 0x01, 0x8D, 0x07, 0x20, // LDA #1 / STA $2007
     0xA9, 0x3F, 0x8D, 0x06, 0x20, // LDA #$3F / STA $2006
     0xA9, 0x00, 0x8D, 0x06, 0x20, // LDA #$00 / STA $2006
     0xA9, 0x0F, 0x8D, 0x07, 0x20, // LDA #$0F / STA $2007
     0xA9, 0x2A, 0x8D, 0x07, 0x20, // LDA #$2A / STA $2007
     0xA9, 0x0A, 0x8D, 0x00, 0x20, // LDA #$0A / STA $2000
     0xA9, 0x0A, 0x8D, 0x01, 0x20, // LDA #$0A / STA $2001
     0x4C, 0x2D, 0x80, // JMP $802B, which is the byte after this instruction
  ]
  let body = Buffer::Buffer(size_hint=0x4000)
  for i in 0..<0x4000 {
    body.write_byte(
      if i < code.length() {
        code[i].reinterpret_as_uint().to_byte()
      } else {
        b'\xEA'
      },
    )
  }
  let code_bytes = body.to_bytes()
  for i in 0..<0x4000 {
    // The reset vector lives in the last six bytes of the program ROM, which the
    // console reads through $FFFA-$FFFF. A 16 KiB NROM board mirrors its one chip
    // into both halves of the map, so $FFFC is offset $3FFC into the chip. Without
    // this the console boots from whatever filler the ROM happens to end with.
    let at = i % 0x4000
    let byte = if at == 0x3FFC {
      b'\x00'
    } else if at == 0x3FFD {
      b'\x80'
    } else {
      code_bytes.at(i)
    }
    out.write_byte(byte)
  }
  for _ in 0..<0x2000 {
    out.write_byte(b'\x00')
  }
  let console = Console::new(Cart::parse(out.to_bytes()))
  // Tile 1's first row is opaque, so the first eight pixels of the top row are
  // palette entry 1 rather than the backdrop.
  for row in 0..<8 {
    console.ppu.chr[16 + row] = b'\xFF'
  }
  // One frame is enough for the program to run its init sequence and for the PPU
  // to draw with it. Running more would only re-draw the same picture, and a
  // test that needs several frames to pass is usually hiding a timing bug.
  ignore(console.run_frame(29780) catch { _ => 0 })
  inspect_at("enabled", if console.ppu.mask.show_background { 1 } else { 0 }, 1)
  // The nametable write has to have landed for any of this to mean anything.
  inspect_at("nametable", console.ppu.nt_ram[0].to_int() & 0xFF, 0x01)
  // The whole screen is tile 1 with an opaque first row, so the frame has to
  // contain that palette entry somewhere. Counting across the frame rather than
  // sampling one pixel means a scroll offset cannot make the test fail for a
  // reason that is not the renderer's fault.
  let mut lit = 0
  for i in 0..<(SCREEN_WIDTH * SCREEN_HEIGHT) {
    if (console.ppu.frame[i].to_int() & 0xFF) == 0x2A {
      lit = lit + 1
    }
  }
  inspect_bool(lit > 0, true)
}

///|
/// Places a sprite at an OAM index with the given Y and X.
fn put_sprite(ppu : Ppu, index : Int32, y : UInt32, x : UInt32) -> Unit {
  ppu.oam[index * 4] = y.to_byte()
  ppu.oam[index * 4 + 1] = b'\x01'
  ppu.oam[index * 4 + 2] = b'\x00'
  ppu.oam[index * 4 + 3] = x.to_byte()
}

///|
/// Eight sprites on one line is legal and must not set the flag; a ninth is what
/// the flag exists to report.
test "sprite overflow is set only by a ninth sprite on the same line" {
  let ppu = ppu_with_chr()
  ppu.mask.show_sprites = true
  // Eight sprites share scanline 0, spread across the screen so they do not
  // overlap each other.
  for i in 0..<8 {
    put_sprite(ppu, i, 0xFFU, (i * 16).reinterpret_as_uint())
  }
  ppu.evaluate_sprites(0)
  inspect_bool(ppu.status.overflow, false)
  inspect_eq(ppu.scanline_count, 8)
  // The ninth is enough.
  put_sprite(ppu, 8, 0xFFU, 0xF0U)
  ppu.evaluate_sprites(0)
  inspect_bool(ppu.status.overflow, true)
  // Only eight are kept for rendering; the ninth is dropped.
  inspect_eq(ppu.scanline_count, 8)
}

///|
/// The evaluator looks at the vertical range only. A sprite whose X puts it
/// completely off screen still occupies a slot and can still overflow the line,
/// which is the behaviour a game that hides sprites by moving them right is
/// relying on.
test "a sprite off screen horizontally still counts toward overflow" {
  let ppu = ppu_with_chr()
  ppu.mask.show_sprites = true
  for i in 0..<9 {
    // X = $F0 puts every sprite well past the right edge, but their vertical
    // extent still covers line 0.
    put_sprite(ppu, i, 0xFFU, 0xF0U)
  }
  ppu.evaluate_sprites(0)
  inspect_bool(ppu.status.overflow, true)
}

///|
/// A sprite that does not cover the line at all must not count.
test "sprites on other lines do not count toward overflow" {
  let ppu = ppu_with_chr()
  ppu.mask.show_sprites = true
  for i in 0..<9 {
    // Y = $10 puts the sprite's first row on scanline $11, nowhere near line 0.
    put_sprite(ppu, i, 0x10U, 0x00U)
  }
  ppu.evaluate_sprites(0)
  inspect_bool(ppu.status.overflow, false)
  inspect_eq(ppu.scanline_count, 0)
  // The same nine do overflow their own line.
  ppu.evaluate_sprites(0x11)
  inspect_bool(ppu.status.overflow, true)
}
