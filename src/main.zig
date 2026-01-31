const std = @import("std");
const regs = @import("registers");
const periphs = @import("peripherals.zig");

// Types
const MainUART = periphs.UART(.USART1);
const I2C1 = periphs.I2C1;
const AHT10 = periphs.AHT10;

// Set up logging
pub const std_options = std.Options{
    .log_level = .debug,
    .logFn = log,
};

// Hardware constants
const base_freq = 8_000_000;
const i2c_freq = 100_000;
const timer_prescalar = 8;
const timer_freq = @divFloor(base_freq, timer_prescalar);

// Global state
var global_uart: MainUART = .{};
var i2c_initialised = false;

fn assert(cond: bool, comptime msg: []const u8, args: anytype) void {
    if (!cond) {
        std.debug.panic(msg, args);
    }
}

fn log(comptime message_level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
    const level_txt = comptime message_level.asText();
    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
    var uart_buf: [64]u8 = undefined;
    var uart_writer = global_uart.writer(&uart_buf) catch return;
    uart_writer.print(level_txt ++ prefix2 ++ format ++ "\r\n", args) catch return;
    uart_writer.flush() catch return;
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
    if (!global_uart.initialised) {
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

fn init_xosc() void {
    regs.RCC.CR.modify(.{ .HSEON = 1 });
    regs.RCC.CFGR.modify(.{ .SW = 0b01 });
    // Wait for settling
    while (regs.RCC.CFGR.read().SWS != 0b01) {}
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
    const base_freq_a = 440.0;
    const base_freq_pos: isize = @intFromEnum(Scale.A);
    const twelve_root_two = std.math.pow(f64, 2, -(1.0 / 12.0));
    var arr = std.EnumArray(Scale, u16).initUndefined();
    @setEvalBranchQuota(5000);
    // Assign values based on 12 tet
    for (std.enums.values(Scale)) |note| {
        const note_pos: isize = @intFromEnum(note) - base_freq_pos;
        const freq = base_freq_a * std.math.pow(f64, twelve_root_two, -@as(f64, note_pos));
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

fn init() void {
    // Configure System clock
    init_xosc();
    enable_systick(base_freq);
    global_uart.init_peripheral(base_freq, 9600);
    I2C1.init(base_freq, i2c_freq);
    gpio_init();
    // timer_init();
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
    std.log.info("-------------Initialised-------------", .{});

    // var status: AHT10.Status = @bitCast(I2C1.read(aht100_ic2addr, 1, &i2c_buf)[0]);
    AHT10.write_cmd(.softReset);
    delay_ms(20);
    AHT10.write_cmd(.initialise);
    delay_ms(20);

    while (true) {
        const aht10_reading = AHT10.read_result_polling();
        const humidity = aht10_reading.humidityToFloat();
        std.log.info("Humidity: {d:.2}%", .{humidity});
        const temperature = aht10_reading.temperatureToFloat();
        std.log.info("Temperature: {d:.2} C", .{temperature});
        delay_ms(2000);
    }

    // const scale = [_]Scale{ .A, .B, .C, .D, .E, .F, .G };
    // const bpm = 100;
    // const interval = Duration{ .fraction = 0x60 };
    // const octaves = 3;
    //
    // while (true) {
    //     delay_ms(200);
    //     var octave: i5 = -2;
    //     while (true) octave_loop: {
    //         for (scale) |scale_note| {
    //             if (scale_note == .C) {
    //                 octave += 1;
    //             }
    //             if (scale_note == scale[0] and octave > octaves) {
    //                 octave = -2;
    //                 break :octave_loop;
    //             }
    //             const item = SongItem{ .duration = interval, .note = .{ .note = scale_note, .octave = octave } }jk;
    //
    //             if (item.note) |note| {
    //                 std.log.info("Playing note {t} octave {d}", .{ note.note, note.octave });
    //                 note.beep();
    //             } else {
    //                 beep_timer(0);
    //             }
    //             delay_ms(item.duration.to_us(bpm) / 1000);
    //         }
    //     }
    // }
}
