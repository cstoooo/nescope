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
    #|       nescope --run <rom.nes> [--frames N] [--write-png FILE]
    #|       nescope --trace <binary> [--limit N] [--pc ADDR]
    #|
    #|  --inspect <rom>  parse an iNES image and report its header: mapper,
    #|                   mirroring, ROM sizes and where execution will start
    #|  --run <rom>      boot the ROM and run whole frames
    #|  --frames N       stop after N frames (default 1)
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
  let ram = @lib.FlatRam::new()
  ram.load(0xC000, image)
  let cpu = @lib.Cpu::new()
  cpu.pc = start
  run_trace(cpu, ram, limit)
}

///|
/// Executes up to `limit` instructions, printing the state before each one.
fn run_trace(cpu : @lib.Cpu, ram : @lib.FlatRam, limit : Int64) -> Unit {
  let mut n = 0L
  while n < limit {
    let opcode = @lib.peek(ram, cpu.pc)
    println(format_line(cpu, opcode))
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
/// Renders one trace line: program counter, opcode byte, mnemonic placeholder and
/// the register columns.
///
/// The operand bytes and mnemonic are not yet decoded: this build reports the
/// opcode byte alone rather than inventing a disassembly, so that a column that
/// disagrees with a reference log is known to be a state difference and not a
/// formatting difference.
fn format_line(cpu : @lib.Cpu, opcode : UInt32) -> String {
  let pc = hex4(cpu.pc)
  let op = hex2(opcode)
  let a = hex_pad(cpu.a, 2).to_upper()
  let x = hex_pad(cpu.x, 2).to_upper()
  let y = hex_pad(cpu.y, 2).to_upper()
  let p = hex_pad(cpu.p, 2).to_upper()
  let sp = hex_pad(cpu.sp, 2).to_upper()
  let cyc = cpu.cycles
  "\{pc}  \{op}        (?)                         A:\{a} X:\{x} Y:\{y} P:\{p} SP:\{sp} PPU:  0,  0 CYC:\{cyc}"
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
