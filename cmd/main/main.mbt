// The `nescope` command line tool.
//
// Today it runs a CPU-only image: it loads a flat binary, executes a chosen
// number of instructions and prints the state after each one in the layout
// `nestest.log` uses. That makes the tool useful before the PPU and cartridges
// exist, because a trace can be diffed against a reference emulator's output.

///|
/// Entry point: dispatches on the first argument.
fn main {
  let args = @env.args()
  if args.length() < 2 {
    print_usage()
    return
  }
  match args[1] {
    "--trace" => trace(args)
    "--inspect" => inspect(args)
    "--run" => run_rom(args)
    _ => {
      println("nescope: unknown command \{args[1]}")
      print_usage()
    }
  }
}

///|
/// Prints the accepted command shapes.
fn print_usage() -> Unit {
  let text =
    #|usage: nescope --inspect <rom.nes>
    #|       nescope --run <rom.nes> [--frames N] [--write-png FILE] [--write-wav FILE]
    #|       nescope --trace <binary> [--limit N] [--pc ADDR]
    #|
    #|  --inspect <rom>  parse an iNES image and report its header: mapper,
    #|                   mirroring, ROM sizes and where execution will start
    #|  --run <rom>      boot the ROM and run whole frames
    #|  --frames N       stop after N frames (default 1)
    #|  --write-png FILE write the last completed frame as a PNG
    #|  --write-wav FILE write the audio the run produced as a mono WAV
    #|  --trace <file>   load a flat binary at $C000 and print one line per
    #|                   instruction, in the layout `nestest.log` uses
    #|  --limit N        stop after N instructions (default 20)
    #|  --pc ADDR        start at this hex address instead of $C000
  println(text)
}

///|
/// Reports what the header of an iNES image says.
fn inspect(args : Array[String]) -> Unit {
  let path = match option(args, "--inspect") {
    Some(p) => p
    None => {
      println("nescope: --inspect needs a file")
      return
    }
  }
  let bytes = @fs.read_file_to_bytes(path) catch {
    e => {
      println("nescope: cannot read \{path}: \{Repr(e)}")
      return
    }
  }
  let cart = @lib.Cart::parse(bytes) catch {
    e => {
      println("nescope: \{path}: \{e.to_string()}")
      return
    }
  }
  let prg_bytes = cart.prg.length().to_int64()
  let chr_bytes = cart.chr.length().to_int64()
  println("file       \{path}")
  println("mapper     \{cart.mapper.name()}")
  println("mirroring  \{cart.mirroring.name()}")
  println(
    "program    \{cart.prg_banks} x 16 KiB (\{hex4(prg_bytes.to_int().reinterpret_as_uint())} bytes)",
  )
  if cart.chr_ram {
    println(
      "character  \{hex4(chr_bytes.to_int().reinterpret_as_uint())} bytes of RAM",
    )
  } else {
    println(
      "character  \{cart.chr_banks} x 8 KiB (\{hex4(chr_bytes.to_int().reinterpret_as_uint())} bytes)",
    )
  }
  println("battery    \{cart.has_battery}")
  let console = @lib.Console::new(cart)
  let reset = console.read(0xFFFCU) | (console.read(0xFFFDU) << 8)
  println("reset      \{hex4(reset)}")
}

///|
/// Boots a ROM and runs whole frames, reporting how far it got.
fn run_rom(args : Array[String]) -> Unit {
  let path = match option(args, "--run") {
    Some(p) => p
    None => {
      println("nescope: --run needs a file")
      return
    }
  }
  let frames = match option(args, "--frames") {
    Some(text) => parse_decimal(text)
    None => 1L
  }
  let bytes = @fs.read_file_to_bytes(path) catch {
    e => {
      println("nescope: cannot read \{path}: \{Repr(e)}")
      return
    }
  }
  let cart = @lib.Cart::parse(bytes) catch {
    e => {
      println("nescope: \{path}: \{e.to_string()}")
      return
    }
  }
  // A battery-backed cartridges's RAM lives in a file beside the ROM, named the
  // way every other NES emulator names it, so a save made here is the same save
  // another emulator would load.
  let save_path = sav_path(path)
  if cart.has_battery {
    let existing = Ok(@fs.read_file_to_bytes(save_path)) catch { _ => Err(()) }
    match existing {
      Ok(data) => {
        cart.load_save(data)
        println("loaded     \{save_path} (\{data.length()} bytes)")
      }
      Err(_) => ()
    }
  }
  let console = @lib.Console::new(cart)
  let mut ran = 0L
  let mut stopped = ""
  while ran < frames {
    let outcome = Ok(console.run_frame(29780)) catch { e => Err(e) }
    match outcome {
      Ok(_) => ()
      Err(e) => {
        stopped = e.to_string()
        break
      }
    }
    ran = ran + 1L
  }
  println("frames     \{ran}")
  println("cycles     \{console.cpu.cycles}")
  println(
    "pc         \{hex4(console.cpu.pc)}  a=\{hex2(console.cpu.a)} x=\{hex2(console.cpu.x)} y=\{hex2(console.cpu.y)} sp=\{hex2(console.cpu.sp)}",
  )
  if stopped != "" {
    println("stopped    \{stopped}")
  }
  if console.cart.has_battery {
    let data = console.cart.save_data()
    @fs.write_bytes_to_file(save_path, data) catch {
      e => println("nescope: cannot write \{save_path}: \{Repr(e)}")
    }
  }
  match option(args, "--write-wav") {
    Some(target) => {
      // The samples accumulated across every frame that ran, so the file is the
      // audio of the whole run rather than of the last frame only.
      let samples = console.apu.take_samples()
      let wav = @lib.encode_wav(samples, 44100U)
      @fs.write_bytes_to_file(target, wav) catch {
        e => println("nescope: cannot write \{target}: \{Repr(e)}")
      }
      println(
        "wrote      \{target} (\{wav.length()} bytes, \{samples.length()} samples)",
      )
    }
    None => ()
  }
  match option(args, "--write-png") {
    Some(target) => {
      // Writing the frame is what makes the renderer checkable by eye: a
      // screenshot that matches a known-good one is worth more than any
      // assertion about palette indices.
      let png = @lib.encode_png(console.ppu.frame)
      @fs.write_bytes_to_file(target, png) catch {
        e => println("nescope: cannot write \{target}: \{Repr(e)}")
      }
      println("wrote      \{target} (\{png.length()} bytes)")
    }
    None => ()
  }
}

///|
/// Runs a trace and prints it.
fn trace(args : Array[String]) -> Unit {
  let path = match option(args, "--trace") {
    Some(p) => p
    None => {
      println("nescope: --trace needs a file")
      return
    }
  }
  let limit = match option(args, "--limit") {
    Some(text) => parse_decimal(text)
    None => 20L
  }
  let start = match option(args, "--pc") {
    Some(text) => parse_hex(text)
    None => 0xC000U
  }
  let image = @fs.read_file_to_bytes(path) catch {
    e => {
      println("nescope: cannot read \{path}: \{Repr(e)}")
      return
    }
  }
  // A .nes image is a cartridge, not a flat binary: feeding one to the flat-RAM
  // loader puts the sixteen-byte header where the first instruction should be,
  // and the trace then disassembles "NES" as an instruction. Any file that
  // starts with the iNES magic goes through the cartridge path instead, which
  // also means its banking applies to the operand bytes.
  if is_ines(image) {
    let cart = @lib.Cart::parse(image) catch {
      e => {
        println("nescope: \{path}: \{e.to_string()}")
        return
      }
    }
    let console = @lib.Console::new(cart)
    run_console_trace(console, limit)
  } else {
    let ram = @lib.FlatRam::new()
    ram.load(0xC000, image)
    let cpu = @lib.Cpu::new()
    cpu.pc = start
    run_trace(cpu, ram, limit)
  }
}

///|
/// The save file that belongs beside a ROM: same path, `.srm` extension.
fn sav_path(rom : String) -> String {
  // Strip a trailing ".nes" if there is one, then append. A ROM whose name does
  // not end that way keeps its whole name, so two files called "a.nes" and "a"
  // do not share a save.
  let suffix = ".nes"
  if rom.length() > suffix.length() {
    let tail = rom.exact_view(
      start=rom.length() - suffix.length(),
      end=rom.length(),
    )
    if tail == suffix {
      let stem = rom.exact_view(start=0, end=rom.length() - suffix.length())
      return stem.to_owned() + ".srm"
    }
  }
  rom + ".srm"
}

///|
/// True when a file starts with the iNES magic.
fn is_ines(image : Bytes) -> Bool {
  image.length() >= 4 &&
  image.at(0).to_int() == 0x4E &&
  image.at(1).to_int() == 0x45 &&
  image.at(2).to_int() == 0x53 &&
  image.at(3).to_int() == 0x1A
}

///|
/// Executes up to `limit` instructions of a cartridge, printing the state before
/// each one.
fn run_console_trace(console : @lib.Console, limit : Int64) -> Unit {
  let mut n = 0L
  while n < limit {
    println(format_line(console.cpu, console, console.cpu.pc))
    let outcome = Ok(console.step()) catch { e => Err(e) }
    match outcome {
      Ok(_) => ()
      Err(e) => {
        println("stopped: \{e.to_string()}")
        return
      }
    }
    n = n + 1L
  }
}

///|
/// Executes up to `limit` instructions, printing the state before each one.
fn run_trace(cpu : @lib.Cpu, ram : @lib.FlatRam, limit : Int64) -> Unit {
  let mut n = 0L
  while n < limit {
    println(format_line(cpu, ram, cpu.pc))
    let outcome = Ok(cpu.step(ram)) catch { e => Err(e) }
    match outcome {
      Ok(_) => ()
      Err(e) => {
        println("stopped: \{e.to_string()}")
        return
      }
    }
    n = n + 1L
  }
}

///|
/// Renders one trace line: program counter, the instruction's bytes, its
/// disassembly and the register columns.
///
/// The layout matches the reference logs so that a line-by-line diff points at a
/// state difference rather than at formatting. That also means the operand bytes
/// have to be shown even when the opcode is undocumented and has no mnemonic: an
/// unnamed instruction still has a known length, and leaving its bytes blank
/// would shift every following column.
fn format_line(cpu : @lib.Cpu, bus : &@lib.Bus, address : UInt32) -> String {
  let opcode = @lib.peek(bus, address)
  let decoded = @lib.decode(opcode)
  // The operand bytes, read through the bus so a cartridge's banking applies,
  // and the target a branch reaches.
  let operand = match decoded {
    Some(d) =>
      match d.mode.operand_bytes() {
        0 => 0U
        1 => @lib.peek(bus, address + 1U)
        _ => @lib.peek(bus, address + 1U) | (@lib.peek(bus, address + 2U) << 8)
      }
    None => 0U
  }
  let text = match decoded {
    Some(d) =>
      if d.mode is Relative {
        // A branch's operand is a signed displacement from the byte after the
        // instruction, so the address shown is where it actually goes.
        let displacement = if operand >= 0x80U {
          operand.reinterpret_as_int() - 256
        } else {
          operand.reinterpret_as_int()
        }
        // The target is relative to the byte after the instruction, and the
        // result is masked to sixteen bits because a branch can wrap.
        let target = (address.reinterpret_as_int() + 2 + displacement) & 0xFFFF
        @lib.render(d, target.reinterpret_as_uint())
      } else {
        @lib.render(d, operand)
      }
    None => "(undocumented)"
  }
  let bytes = match decoded {
    Some(d) =>
      match d.mode.operand_bytes() {
        0 => hex2(opcode)
        1 => hex2(opcode) + " " + hex2(@lib.peek(bus, address + 1U))
        _ =>
          hex2(opcode) +
          " " +
          hex2(@lib.peek(bus, address + 1U)) +
          " " +
          hex2(@lib.peek(bus, address + 2U))
      }
    None => hex2(opcode)
  }
  let pc = hex4(address)
  let a = hex_pad(cpu.a, 2).to_upper()
  let x = hex_pad(cpu.x, 2).to_upper()
  let y = hex_pad(cpu.y, 2).to_upper()
  let p = hex_pad(cpu.p, 2).to_upper()
  let sp = hex_pad(cpu.sp, 2).to_upper()
  let cyc = cpu.cycles
  "\{pc}  \{trailing(bytes, 9)} \{trailing(text, 32)} A:\{a} X:\{x} Y:\{y} P:\{p} SP:\{sp} CYC:\{cyc}"
}

///|
/// Two lowercase hex digits for a register value.
fn hex_pad(value : UInt32, digits : Int32) -> String {
  let text = (value & 0xFF).to_string(radix=16)
  padded(text, digits)
}

///|
/// Returns the value following `flag` on the command line.
fn option(args : Array[String], flag : String) -> String? {
  for i in 0..<args.length() {
    if args[i] == flag && i + 1 < args.length() {
      return Some(args[i + 1])
    }
  }
  None
}

///|
/// Parses a decimal string, returning zero for anything unparseable.
fn parse_decimal(text : String) -> Int64 {
  let mut value = 0L
  for i in 0..<text.length() {
    let c = text.code_unit_at(i).unsafe_to_char()
    let code = c.to_int()
    if code >= 48 && code <= 57 {
      value = value * 10L + (code - 48).to_int64()
    } else {
      break
    }
  }
  value
}

///|
/// Parses a `$`-prefixed or bare hex address.
fn parse_hex(text : String) -> UInt32 {
  let mut value = 0U
  for i in 0..<text.length() {
    let c = text.code_unit_at(i).unsafe_to_char()
    let code = c.to_int()
    let digit = if code >= 48 && code <= 57 {
      code - 48
    } else if code >= 97 && code <= 102 {
      code - 87
    } else if code >= 65 && code <= 70 {
      code - 55
    } else {
      continue
    }
    value = (value << 4) | digit.reinterpret_as_uint()
  }
  value
}

///|
/// Renders a 16-bit address the way the golden log does: four uppercase hex
/// digits with no prefix.
fn hex4(value : UInt32) -> String {
  padded((value & 0xFFFF).to_string(radix=16).to_upper(), 4)
}

///|
/// Renders a byte the way the golden log does: two uppercase hex digits.
fn hex2(value : UInt32) -> String {
  padded((value & 0xFF).to_string(radix=16).to_upper(), 2)
}

///|
/// Pads `text` on the right with spaces, which is what a column that holds
/// variable-length text needs. `padded` fills with zeroes on the left because it
/// is for numbers, and using it here would render `LSR` as `000000LSR`.
fn trailing(text : String, width : Int32) -> String {
  let pad = width - text.length()
  if pad <= 0 {
    return text
  }
  let buf = StringBuilder(size_hint=width)
  buf.write_string(text)
  for _ in 0..<pad {
    buf.write_char(' ')
  }
  buf.to_string()
}

///|
/// Left-pads `text` with zeroes to `width` characters, leaving longer text
/// alone.
fn padded(text : String, width : Int32) -> String {
  let pad = width - text.length()
  if pad <= 0 {
    return text
  }
  let buf = StringBuilder(size_hint=width)
  for _ in 0..<pad {
    buf.write_char('0')
  }
  buf.write_string(text)
  buf.to_string()
}
