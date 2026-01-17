const std = @import("std");
const regs = @import("registers.zig");

const Writer = std.Io.Writer;

const clk_freq = 8_000_000;
const timer_prescalar = 8;
const timer_freq = @divFloor(clk_freq, timer_prescalar);
pub const std_options = std.Options{
    .log_level = .debug,
    .logFn = log,
};

// Global State
var serial_initialised = false;

fn assert(cond: bool, comptime msg: []const u8, args: anytype) void {
    if (!cond) {
        std.debug.panic(msg, args);
    }
}

fn log(comptime message_level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
    const level_txt = comptime message_level.asText();
    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
    var buffer: [512]u8 = undefined;
    const uart = UARTWriter(.USART1).init(&buffer);
    var uart_writer = uart.writer;
    if (serial_initialised) {
        uart_writer.print(level_txt ++ prefix2 ++ format ++ "\r\n", args) catch return;
        uart_writer.flush() catch return;
    }
}

pub fn panic(
    msg: []const u8,
    trace: ?*std.builtin.StackTrace,
    ret_addr: ?usize,
) noreturn {
    const addr_str = ret_addr orelse 0;

    _ = trace;
    gpio_init();
    set_led();
    // Blink the led if ther was an error and no serial
    if (!serial_initialised) {
        while (true) {
            delay_ms(500);
            clear_led();
            delay_ms(500);
            set_led();
        }
    }
    std.log.err("Reached panic with message: {s}, ret_addr=0x{X}", .{ msg, addr_str });
    while (true) {}
}

fn enable_systick(frequency: usize) void {
    const counter_val: u24 = @intCast((frequency / 1000) - 1);
    regs.STK.LOAD_.write(.{ .RELOAD = counter_val });
    regs.STK.VAL.write(.{ .CURRENT = 0 });
    regs.STK.CTRL.modify(.{ .ENABLE = 1, .CLKSOURCE = 1 });
}

fn gpio_init() void {
    // Turn on clock for port C
    regs.RCC.APB2ENR.modify(.{ .IOPCEN = 1, .IOPAEN = 1 });
    // Pin 13 output, open drain
    regs.GPIOC.CRH.modify(.{ .MODE13 = 0b10, .CNF13 = 0b01 });
    regs.GPIOA.CRL.modify(.{ .MODE7 = 0b10, .CNF7 = 0b00 });
}

const UARTOptions = struct {
    baud: usize,
    pin_enable: bool,
};

fn usart_init(baud: usize) void {
    // Enable Clocks
    regs.RCC.APB2ENR.modify(.{ .IOPBEN = 1, .USART1EN = 1, .AFIOEN = 1 });
    regs.AFIO.MAPR.modify(.{ .USART1_REMAP = 1 });
    regs.GPIOB.CRL.modify(.{
        // TX = PB6 in REMAP=1
        .MODE6 = 0b10, // Output < 2 Mhz
        .CNF6 = 0b10, // AFIO Push-Pull
        // RX = PB7 in REMAP=1
        .MODE7 = 0b00, // Input
        .CNF7 = 0b10, // Pull down (ODR=0)
    });
    // Pull up tx
    regs.GPIOB.ODR.modify(.{ .ODR6 = 1 });
    const target_baud: u32 = @divFloor(clk_freq, baud);
    regs.USART1.CR1.write(.{ .UE = 1 });
    regs.USART1.BRR.write_raw(target_baud);
    serial_initialised = true;
}

fn set_led() void {
    regs.GPIOC.ODR.modify(.{ .ODR13 = 0 });
}

fn clear_led() void {
    regs.GPIOC.ODR.modify(.{ .ODR13 = 1 });
}

/// Enable but don't start the counter
fn timer_init() void {
    // Enable clocks
    regs.RCC.APB2ENR.modify(.{ .IOPAEN = 1, .AFIOEN = 1 });
    regs.RCC.APB1ENR.modify(.{ .TIM2EN = 1 });

    regs.GPIOA.CRL.modify(.{
        .MODE0 = 0b10, // Output < 2 Mhz
        .CNF0 = 0b10, // AFIO Push-Pull
    });

    // 7 + 1
    regs.TIM2.PSC.write(.{ .PSC = timer_prescalar - 1 });
    regs.TIM2.CCMR1_Output.modify(.{
        .OC1M = 0b011, // Toggle Mode
    });
    regs.TIM2.CCER.modify(.{ .CC1E = 1 });
}

fn freq_to_timer(freq: f32) u16 {
    const timer_max = (1 << 16) - 1;
    const timer_val = @divFloor(@divFloor(timer_freq, freq), 2) - 1;
    assert(timer_val < timer_max, "Requested freq out of range for timer {d} Hz", .{freq});
    return @intFromFloat(timer_val);
}

fn beep_timer(timer: u16) void {
    if (timer == 0) {
        regs.TIM2.CR1.write(.{ .CEN = 0 });
        return;
    }

    regs.TIM2.ARR.write(.{ .ARR = timer });
    regs.TIM2.CCR1.write(.{ .CCR1 = timer });
    regs.TIM2.CNT.write(.{ .CNT = 0 });
    regs.TIM2.CR1.write(.{ .CEN = 1 });
}

const Scale = enum { C, Cs, D, Ef, E, F, Fs, G, Gs, A, Bf, B };

/// A mapping from note to timer value
const TimerScale: std.EnumArray(Scale, u16) = blk: {
    const base_freq = 440.0;
    const base_freq_pos: isize = @intFromEnum(Scale.A);
    const twelve_root_two = std.math.pow(f64, 2, -(1.0 / 12.0));
    var arr = std.EnumArray(Scale, u16).initUndefined();
    @setEvalBranchQuota(5000);
    // Assign values based on 12 tet
    for (std.enums.values(Scale)) |note| {
        const note_pos: isize = @intFromEnum(note) - base_freq_pos;
        const freq = base_freq * std.math.pow(f64, twelve_root_two, -@as(f64, note_pos));
        arr.set(note, freq_to_timer(@floatCast(freq)));
    }
    break :blk arr;
};

const Note = struct {
    note: Scale,
    // Shifts only support u4, so store an extra bit for sign
    octave: i5,

    pub fn beep(self: Note) void {
        const base_note = TimerScale.get(self.note);
        const shift: u4 = @intCast(@abs(self.octave));
        const timer_val = if (self.octave >= 0) base_note >> shift else base_note << shift;
        beep_timer(timer_val);
    }
};

const Duration = packed struct {
    mantissa: u8 = 0,
    fraction: u8 = 0,

    /// Convert duration to microseconds
    pub fn to_us(self: Duration, bpm: usize) usize {
        const us_per_minute = 1_000_000 * 60;
        const us_per_beat = @divFloor(us_per_minute, bpm);
        const mantissa_us = self.mantissa * us_per_beat;
        const frac_us = (us_per_beat >> 8) * self.fraction;
        return mantissa_us + frac_us;
    }
};

const SongItem = struct {
    note: ?Note,
    /// Duration is a fixed point representation of beats: 16-bits for frac, 16 bits mantissa
    duration: Duration,
};

const Song = struct { bpm: usize, sequence: []SongItem };

const UART = enum {
    USART1,
    USART2,
};

fn UARTWriter(uart: UART) type {
    return struct {
        const Self = @This();
        const Regs: type = switch (uart) {
            .USART1 => regs.USART1,
            .USART2 => regs.USART2,
        };

        writer: Writer,

        pub fn init(buffer: []u8) Self {
            return .{
                .writer = .{
                    .vtable = &.{
                        .drain = Self.uart_drain,
                    },
                    .buffer = buffer,
                },
            };
        }

        const UARTError = error{
            NotEnabled,
        };

        fn uart_send_char(char: u8) void {
            while (Self.Regs.SR.read().TXE == 0) {}

            Self.Regs.DR.write(.{ .DR = char });
        }

        fn uart_send_msg(msg: []const u8) UARTError!usize {
            if (msg.len == 0) return 0;
            Self.Regs.CR1.modify(.{ .TE = 1 });
            defer Self.Regs.CR1.modify(.{ .TE = 0 });

            const CR1 = Self.Regs.CR1.read();
            if (CR1.UE != 1 and CR1.TE != 1) {
                return UARTError.NotEnabled;
            }

            var written_bytes: usize = 0;
            for (msg) |char| {
                uart_send_char(char);
                written_bytes += 1;
            }
            while (Self.Regs.SR.read().TC == 0) {}
            return written_bytes;
        }

        fn uart_drain(writer: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
            const buffered = writer.buffered();
            var total_bytes: usize = 0;
            if (buffered.len > 0) {
                total_bytes += uart_send_msg(buffered) catch return Writer.Error.WriteFailed;
                _ = writer.consumeAll();
            }

            for (data) |data_entry| {
                total_bytes += uart_send_msg(data_entry) catch return Writer.Error.WriteFailed;
            }
            for (0..splat-1) |_| {
                total_bytes += uart_send_msg(data[data.len - 1]) catch return Writer.Error.WriteFailed;
            }
            return total_bytes;
        }
    };
}

fn init() void {
    // Configure System clock
    enable_systick(clk_freq);
    usart_init(9600);
    gpio_init();
    timer_init();
}

fn delay_ms(delay: usize) void {
    var delay_counter = delay;
    while (delay_counter > 0) {
        if (regs.STK.CTRL.read().COUNTFLAG != 0) {
            delay_counter -= 1;
        }
    }
}

export fn main() noreturn {
    init();
    clear_led();
    delay_ms(1000);
    //const c_major = [_]SongItem{
    //    .{ .note = .{ .note = .A, .octave = -1 }, .duration = .{ .fraction = 0x80 } },
    //    .{ .note = .{ .note = .B, .octave = -1 }, .duration = .{ .fraction = 0x80 } },
    //    .{ .note = .{ .note = .C, .octave = 0 }, .duration = .{ .fraction = 0x80 } },
    //    .{ .note = .{ .note = .D, .octave = 0 }, .duration = .{ .fraction = 0x80 } },
    //    .{ .note = .{ .note = .E, .octave = 0 }, .duration = .{ .fraction = 0x80 } },
    //    .{ .note = .{ .note = .F, .octave = 0 }, .duration = .{ .fraction = 0x80 } },
    //    .{ .note = .{ .note = .Gs, .octave = 0 }, .duration = .{ .fraction = 0x80 } },
    //    .{ .note = .{ .note = .A, .octave = 0 }, .duration = .{ .fraction = 0x80 } },
    //    .{ .note = .{ .note = .B, .octave = 0 }, .duration = .{ .fraction = 0x80 } },
    //    .{ .note = .{ .note = .C, .octave = 1 }, .duration = .{ .fraction = 0x80 } },
    //    .{ .note = .{ .note = .D, .octave = 1 }, .duration = .{ .fraction = 0x80 } },
    //    .{ .note = .{ .note = .E, .octave = 1 }, .duration = .{ .fraction = 0x80 } },
    //    .{ .note = .{ .note = .F, .octave = 1 }, .duration = .{ .fraction = 0x80 } },
    //    .{ .note = .{ .note = .Gs, .octave = 1 }, .duration = .{ .fraction = 0x80 } },
    //    .{ .note = .{ .note = .A, .octave = 1 }, .duration = .{ .fraction = 0x80 } },
    //    .{ .note = .{ .note = .B, .octave = 1 }, .duration = .{ .fraction = 0x80 } },
    //    .{ .note = .{ .note = .C, .octave = 2 }, .duration = .{ .fraction = 0x80 } },
    //    .{ .note = .{ .note = .D, .octave = 2 }, .duration = .{ .fraction = 0x80 } },
    //    .{ .note = .{ .note = .E, .octave = 2 }, .duration = .{ .fraction = 0x80 } },
    //    .{ .note = .{ .note = .F, .octave = 2 }, .duration = .{ .fraction = 0x80 } },
    //    .{ .note = .{ .note = .Gs, .octave = 2 }, .duration = .{ .fraction = 0x80 } },
    //    .{ .note = .{ .note = .A, .octave = 2 }, .duration = .{ .fraction = 0x80 } },
    //    .{ .note = null, .duration = .{ .mantissa = 1 } },
    //};
    const scale = [_]Scale{ .A, .B, .C, .D, .E, .F, .G };

    const bpm = 100;
    const interval = Duration{ .fraction = 0x60 };
    const octaves = 3;

    while (true) {
        delay_ms(200);
        var octave: i5 = -2;
        while (true) octave_loop: {
            for (scale) |scale_note| {
                if (scale_note == .C) {
                    octave += 1;
                }
                if (scale_note == scale[0] and octave > octaves) {
                    octave = -2;
                    break :octave_loop;
                }
                const item = SongItem{ .duration = interval, .note = .{ .note = scale_note, .octave = octave } };

                if (item.note) |note| {
                    std.log.info("Playing note {t} octave {d}", .{ note.note, note.octave });
                    note.beep();
                } else {
                    beep_timer(0);
                }
                delay_ms(item.duration.to_us(bpm) / 1000);
            }
        }
    }
}
