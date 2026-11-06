// Shared test helpers.
//
// The golden-log parser and the fixture reader are used by both the CPU tests and
// the console tests, so they live here rather than being copied into each. A copy
// would be worse than duplication: the two suites assert against the same trace,
// and a parser that drifted between them would make one of them pass for the
// wrong reason.

///|
/// Parses the golden trace into the tuple of CPU-owned fields per line.
///
/// The PPU column and the disassembly text are deliberately not parsed: the
/// first is the PPU's business and the second is a rendering choice, so a
/// mismatch in either would not mean the CPU is wrong.
fn parse_golden(
  text : String,
) -> Array[(UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, Int64)] {
  let out : Array[(UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, Int64)] = []
  for raw in text.split("\n") {
    if raw.length() < 80 {
      continue
    }
    let line = raw.to_owned()
    out.push(
      (
        parse_pc(line),
        parse_field(line, "A:"),
        parse_field(line, "X:"),
        parse_field(line, "Y:"),
        parse_field(line, "P:"),
        parse_field(line, "SP:"),
        parse_decimal(line, "CYC:"),
      ),
    )
  }
  out
}

///|
/// The 16-bit program counter in the first four columns.
fn parse_pc(line : String) -> UInt32 {
  let view = line.exact_view(start=0, end=line.length())
  let mut value = 0U
  for i in 0..<4 {
    value = (value << 4) | hex_value(view.unsafe_get(i).unsafe_to_char())
  }
  value
}

///|
/// Reads the hex digits following a `LABEL:` marker, skipping the left padding
/// the log uses to keep its columns aligned.
fn parse_field(line : String, label : String) -> UInt32 {
  let view = line.exact_view(start=0, end=line.length())
  let at = match view.find(label) {
    Some(i) => i
    None => return 0
  }
  let mut start = at + label.length()
  while start < view.length() {
    let c = view.unsafe_get(start).unsafe_to_char()
    if c == ' ' {
      start = start + 1
    } else {
      break
    }
  }
  let mut value = 0U
  let mut i = start
  while i < view.length() {
    let c = view.unsafe_get(i).unsafe_to_char()
    if c == ' ' || c == ',' {
      break
    }
    value = (value << 4) | hex_value(c)
    i = i + 1
  }
  value
}

///|
/// Reads the decimal digits following a `LABEL:` marker.
///
/// `CYC:` is decimal in the golden log while every register is hex, which is the
/// one place the format is inconsistent; reading it as hex would desynchronise
/// the cycle column from the third line onward.
fn parse_decimal(line : String, label : String) -> Int64 {
  let view = line.exact_view(start=0, end=line.length())
  let at = match view.find(label) {
    Some(i) => i
    None => return 0L
  }
  let mut start = at + label.length()
  while start < view.length() {
    let c = view.unsafe_get(start).unsafe_to_char()
    if c == ' ' {
      start = start + 1
    } else {
      break
    }
  }
  let mut value = 0L
  let mut i = start
  while i < view.length() {
    let c = view.unsafe_get(i).unsafe_to_char()
    if c == ' ' || c == ',' {
      break
    }
    let code = c.to_int()
    if code >= 48 && code <= 57 {
      value = value * 10L + (code - 48).to_int64()
    } else {
      break
    }
    i = i + 1
  }
  value
}

///|
/// The value of one hex digit, or zero for anything else.
fn hex_value(unit : Char) -> UInt32 {
  let code = unit.to_int()
  if code >= 48 && code <= 57 {
    (code - 48).reinterpret_as_uint()
  } else if code >= 97 && code <= 102 {
    (code - 87).reinterpret_as_uint()
  } else if code >= 65 && code <= 70 {
    (code - 55).reinterpret_as_uint()
  } else {
    0U
  }
}

///|
/// Reads a checked-in binary fixture.
fn read_fixture(name : String) -> Bytes raise {
  let dir = @env.current_dir().unwrap()
  @fs.read_file_to_bytes(dir + "/internal/fixtures/" + name)
}

///|
/// Reads a checked-in text fixture as one string.
fn read_text_fixture(name : String) -> String raise {
  let bytes = read_fixture(name)
  @utf8.decode(bytes)
}

///|
/// Fails with both sides shown when two values differ.
///
/// A helper rather than a macro because the runner's snapshot facility keys on
/// the call site, and a snapshot taken inside a helper would report the
/// helper's line for every test that used it.
fn[T : Eq] check_eq(actual : T, expected : T) -> Unit raise {
  if actual != expected {
    inspect("mismatch")
    fail("values differ")
  }
}

///|
/// Compares two values whose `Show` is only wanted for a failure message.
///
/// Marked separately so that the deprecated `Show`-for-debugging path is used in
/// exactly one place rather than at every assertion.

///|
/// Fails when a boolean is not the expected value.
fn check_bool(actual : Bool, expected : Bool) -> Unit raise {
  check_eq(actual, expected)
}
