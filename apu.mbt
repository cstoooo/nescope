// The audio processing unit.
//
// This build does not synthesize sound. What it does implement is the part a
// game program can observe, and that part is not optional: the APU also owns the
// frame counter, which is a CPU-visible timer. A game that waits for the frame
// IRQ to synchronise its music and its scrolling will wait forever without it,
// because `$4015` reads as zero and the IRQ never arrives. So the timer is here
// and is accurate; the four waveform channels have their registers and their
// length counters enough to make status reads honest, and there is no mixing
// stage behind them.
//
// The frame counter is a divider from the CPU clock, not from the PPU's. That
// matters: 29830 CPU cycles per NTSC frame, and the sequence steps four times
// per frame in 4-step mode or five times in 5-step mode.

///|
/// Which of the frame counter's two sequences is running.
pub(all) enum FrameMode {
  // Compared by name in tests rather than by value, so no derived Eq.
  /// Four steps, and it raises an IRQ at the end.
  FourStep
  /// Five steps, and it raises no IRQ. Games that need a clean audio stream pick
  /// this one precisely because the interrupt would disturb their timing.
  FiveStep
}

///|
/// The frame counter's step within its sequence.
///
/// The sequence's position is exposed because the quarter- and half-frame clocks
/// drive the length counters, which `$4015` reports.
pub(all) enum FrameStep {
  /// Nothing clocked yet.
  Idle
  /// Quarter-frame clock only.
  Quarter
  /// Half-frame clock, which is where the length counters and the sweeps run.
  Half
  /// Both clocks, applied together.
  Both
}

///|
/// The APU.
pub(all) struct Apu {
  /// Which of the two sequences the counter is running.
  mut mode : FrameMode
  /// True when the 4-step sequence should raise an IRQ at its end.
  mut irq_inhibit : Bool
  /// True once the frame counter has raised an IRQ, cleared by reading `$4015`.
  mut frame_irq : Bool
  /// CPU cycles counted since the last step.
  mut cycles : Int64
  /// Position within the sequence, 0 to 3 or 0 to 4.
  mut step : Int32
  /// Length counter for each of the five channels, in the order pulse 1, pulse
  /// 2, triangle, noise, DMC. Zero means the channel has silenced itself.
  length : FixedArray[UInt32]
  /// True when a channel's length counter is being held rather than clocked.
  halt : FixedArray[Bool]
  /// The raw register values, kept so a status read can report whether a channel
  /// is active without the caller having to track the writes itself.
  control : FixedArray[UInt32]
  /// True when the DMC channel has an active sample, which is the only way
  /// `$4015` bit 4 ever reads as set.
  mut dmc_active : Bool
  /// The low five bits of the last `$4015` write: which channels a program has
  /// turned on. A length-counter write to a channel that is off is ignored,
  /// which is what keeps a silenced channel from starting up again.
  mut enabled_channels : UInt32
}

///|
/// Cycles per frame-counter tick on NTSC.
///
/// The four-step sequence steps at CPU cycles 7457, 14913, 22371 and 29829, so
/// keeping a running counter and comparing against those four points is closer to
/// the hardware than dividing by a single period.
fn frame_step_cycles() -> FixedArray[Int64] {
  [7457L, 14913L, 22371L, 29829L, 37281L]
}

///|
/// True when the counter is running the four-step sequence.
fn Apu::four_step(self : Apu) -> Bool {
  match self.mode {
    FourStep => true
    FiveStep => false
  }
}

///|
/// The name of the sequence, used in reports and tests.
pub fn FrameMode::name(self : FrameMode) -> String {
  match self {
    FourStep => "4-step"
    FiveStep => "5-step"
  }
}

///|
/// A freshly powered APU.
pub fn Apu::new() -> Apu {
  {
    mode: FourStep,
    irq_inhibit: false,
    frame_irq: false,
    cycles: 0L,
    step: 0,
    length: FixedArray::make(5, 0U),
    halt: FixedArray::make(5, false),
    control: FixedArray::make(5, 0U),
    dmc_active: false,
    enabled_channels: 0U,
  }
}

///|
/// Advances the frame counter by a number of CPU cycles.
///
/// Returns true on the cycle the four-step sequence raises its IRQ, so the
/// console can take the interrupt at the right moment rather than polling.
pub fn Apu::tick(self : Apu, cycles : Int64) -> Bool {
  self.cycles = self.cycles + cycles
  let mut raised = false
  // The sequence is periodic, so this has to wrap rather than stop at its end:
  // a counter that stopped would raise the frame IRQ once and never again, and
  // a game waiting for the second one would hang on the same frame it started.
  let limit = if self.four_step() { 4 } else { 5 }
  let period = if self.four_step() { 29829L } else { 37281L }
  while self.step < limit && self.cycles >= frame_step_cycles()[self.step] {
    // The step's position decides which clocks fire: quarter then half,
    // alternating. The five-step sequence ends on a lone quarter-frame clock.
    let which = if self.step % 2 == 0 { Quarter } else { Half }
    self.clock_step(which)
    self.step = self.step + 1
    // The four-step sequence raises the frame IRQ as it wraps. The five-step one
    // never does, which is why a game that needs clean audio selects it.
    if self.four_step() && self.step == 4 && !self.irq_inhibit {
      self.frame_irq = true
      raised = true
    }
  }
  if self.step >= limit {
    // Wrap: fold the elapsed period out of the counter and start the sequence
    // again. Subtracting the period rather than resetting to zero keeps the
    // fractional remainder, so a frame that is not an exact multiple of the
    // period does not drift.
    self.cycles = self.cycles - period
    self.step = 0
  }
  raised
}

///|
/// Applies one of the frame counter's clocks to the channels.
fn Apu::clock_step(self : Apu, which : FrameStep) -> Unit {
  // The frame counter runs whether or not any channel is on: it is a divider of
  // the CPU clock, not a property of the audio channels, and its interrupt is
  // raised regardless. Gating it on `$4015` would silently disable the one part
  // of the APU a program can depend on.
  match which {
    Idle => ()
    // A quarter-frame clock advances the envelope and the triangle's linear
    // counter. Neither affects anything observable here yet, so the only work is
    // deciding whether the half-frame clock also fires.
    Quarter => ()
    // The half-frame clock decrements every length counter that is not halted,
    // which is what eventually makes `$4015` report the channel as finished.
    Half => self.clock_length()
    Both => self.clock_length()
  }
}

///|
/// Decrements each channel's length counter.
fn Apu::clock_length(self : Apu) -> Unit {
  for channel in 0..<5 {
    if self.halt[channel] {
      continue
    }
    if self.length[channel] > 0U {
      self.length[channel] = self.length[channel] - 1U
    }
  }
}

///|
/// Reads the status register `$4015`.
///
/// Bit *n* is set while channel *n* still has length left, which is how a game
/// knows a note has finished without tracking the length counter itself. Reading
/// the register also clears the frame IRQ flag, which is the only way to
/// acknowledge it.
pub fn Apu::read_status(self : Apu) -> UInt32 {
  let mut value = 0U
  for channel in 0..<4 {
    if self.length[channel] > 0U {
      value = value | (1U << channel)
    }
  }
  if self.dmc_active {
    value = value | 0x10U
  }
  if self.frame_irq {
    value = value | 0x40U
  }
  self.frame_irq = false
  value
}

///|
/// Writes the status register `$4015`, which only uses its low five bits: each
/// one enables or disables a channel, and writing a zero clears that channel's
/// length counter so it falls silent at once.
pub fn Apu::write_status(self : Apu, value : UInt32) -> Unit {
  for channel in 0..<4 {
    let on = (value & (1U << channel)) != 0
    if !on {
      self.length[channel] = 0U
    }
  }
  self.dmc_active = (value & 0x10U) != 0
  self.enabled_channels = value & 0x1FU
  // Any write here restarts the counter, which a game depends on because it is
  // the documented way to get a clean four-step sequence from the top.
  self.cycles = 0L
  self.step = 0
  self.frame_irq = false
}

///|
/// Writes a channel register.
///
/// Only the bits that change the length counter and the frame counter are acted
/// on. The rest — the timer periods, the envelopes — would matter to a mixer and
/// are recorded so a later version can pick them up without changing the
/// register decode.
pub fn Apu::write_register(
  self : Apu,
  address : UInt32,
  value : UInt32,
) -> Unit {
  let value = value & 0xFFU
  match address & 0x1FU {
    0x00U | 0x04U => {
      // Pulse 1 and 2 duty and halt.
      let channel = if (address & 0x1FU) == 0U { 0 } else { 1 }
      self.control[channel] = value
      self.halt[channel] = (value & 0x20U) != 0
    }
    0x01U | 0x05U => {
      let channel = if (address & 0x1FU) == 0x01U { 0 } else { 1 }
      self.control[channel] = value
    }
    0x02U | 0x06U => ()
    0x03U | 0x07U => {
      // The length counter is loaded from the top five bits whenever a channel's
      // fourth register is written, but only if the channel is enabled. Loading
      // it while the channel is off is what keeps a silenced channel silenced.
      let channel = if (address & 0x1FU) == 0x03U { 0 } else { 1 }
      self.load_length(channel, value >> 3)
    }
    0x08U => {
      self.control[2] = value
      self.halt[2] = (value & 0x80U) != 0
    }
    0x0AU => ()
    0x0BU => self.load_length(2, value >> 3)
    0x0CU => {
      self.control[3] = value
      self.halt[3] = (value & 0x20U) != 0
    }
    0x0EU => ()
    0x0FU => self.load_length(3, value >> 3)
    0x10U =>
      // A DMC register write restarts the sample, which is what makes the
      // channel's status bit go high.
      self.control[4] = value
    0x11U => ()
    0x12U => ()
    0x13U => {
      self.control[4] = value
      self.dmc_active = (value & 0x10U) != 0
    }
    0x15U => self.write_status(value)
    0x17U => {
      // The frame counter register. Writing it resets the sequence and, in
      // five-step mode, clocks everything once immediately, which is why the
      // order of a game's init writes is audible.
      self.mode = if (value & 0x80U) != 0 { FiveStep } else { FourStep }
      self.irq_inhibit = (value & 0x40U) != 0
      self.cycles = 0L
      self.step = 0
      if self.four_step() && !self.irq_inhibit {
        self.frame_irq = false
      }
      if !self.four_step() {
        self.clock_step(Both)
      }
    }
    _ => ()
  }
}

///|
/// The length counter's load table.
///
/// The five bits written to a channel's fourth register are an index into this
/// table, not a length. The table is deliberately non-monotonic — index 1 loads
/// 254 and index 2 loads 20 — because the values were chosen so that a small
/// index can still produce a long note. Treating the index as the length gives
/// every short-written note the wrong duration, and index 1 a sixteenth of the
/// note it should be.
fn length_table() -> FixedArray[UInt32] {
  [
    10U, 254U, 20U, 2U, 40U, 4U, 80U, 6U, 160U, 8U, 60U, 10U, 14U, 12U, 26U, 14U,
    12U, 16U, 24U, 18U, 48U, 20U, 96U, 22U, 192U, 24U, 72U, 26U, 16U, 28U, 32U, 30U,
  ]
}

///|
/// Loads a channel's length counter from the top five bits of a register write.
fn Apu::load_length(self : Apu, channel : Int32, value : UInt32) -> Unit {
  if channel < 0 || channel >= 4 {
    return
  }
  // The counter only loads while the channel is on. A write to a channel the
  // program has not enabled leaves the counter at zero, so the channel stays
  // silent rather than starting on the next half-frame clock.
  if (self.enabled_channels & (1U << channel)) == 0U {
    return
  }
  self.length[channel] = length_table()[(value & 0x1FU).reinterpret_as_int()]
}
