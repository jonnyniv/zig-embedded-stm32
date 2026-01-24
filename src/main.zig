const std = @import("std");
const regs = @import("registers");
const periphs = @import("peripherals.zig");

// Types
const MainUART = periphs.UART(.USART1);
const I2CAddr = u7;
const I2CRW = enum(u1) {
    read = 1,
    write = 0,
};

// Set up logging
pub const std_options = std.Options{
    .log_level = .debug,
    .logFn = log,
};

// Hardware constants
const base_freq = 8_000_000;
const base_period_ns = 1_000_000_000 / base_freq;
const i2c_freq = 100_000;
const timer_prescalar = 8;
const timer_freq = @divFloor(base_freq, timer_prescalar);
const aht100_ic2addr: I2CAddr = 0b0111000;

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

fn init_i2c() void {
    // Enable Clocks for GPIO and I2C
    regs.RCC.APB1ENR.modify(.{ .I2C1EN = 1 });
    regs.RCC.APB2ENR.modify(.{ .IOPBEN = 1, .AFIOEN = 1 });

    // Configure pins
    regs.AFIO.MAPR.modify(.{ .I2C1_REMAP = 1 });
    regs.GPIOB.CRH.modify(.{
        // SCL = PB8 in REMAP=1
        .MODE8 = 0b01, // Output < 10 Mhz
        .CNF8 = 0b11, // AFIO Open-Drain
        // SDA = PB0 in REMAP=1
        .MODE9 = 0b01, // Output < 10 Mhz
        .CNF9 = 0b11, // AFIO Open-Drain
    });

    // Configure I2C speed, clock control, and rise time (From datasheet)
    regs.I2C1.CR2.modify(.{ .FREQ = 8 });
    const ccr_div: u12 = @divFloor(base_freq, 2 * i2c_freq);
    regs.I2C1.CCR.modify(.{ .CCR = ccr_div });

    const sm_mode_risetime_ns = 1000;
    const rise_time_reg: u6 = @divFloor(sm_mode_risetime_ns, base_period_ns) + 1;
    regs.I2C1.TRISE.modify(.{ .TRISE = rise_time_reg });

    regs.I2C1.CR1.modify(.{ .PE = 1 });
}

fn i2c_start() void {
    regs.I2C1.CR1.modify(.{ .START = 1 });
    while (regs.I2C1.SR1.read().SB != 1) {}
}

fn i2c_send_addr(addr: I2CAddr, mode: I2CRW) void {
    const addr_byte: u8 = addr << 1 | @intFromEnum(mode);
    regs.I2C1.DR.write(.{ .DR = addr_byte });
    while (regs.I2C1.SR1.read().ADDR != 1) {}
    const set_mode: I2CRW = switch (regs.I2C1.SR2.read().TRA) {
        0 => .read,
        1 => .write,
    };
    assert(set_mode == mode, "I2C Addr phase: set_mode({t}) != mode({t})", .{ set_mode, mode });
}

fn i2c_read(addr: I2CAddr, bytes: usize, result_buf: []u8) []u8 {
    i2c_start();
    i2c_send_addr(addr, .read);
    if (bytes == 1) {
        regs.I2C1.CR1.modify(.{ .ACK = 0 });
        regs.I2C1.CR1.modify(.{ .STOP = 1 });
        while (regs.I2C1.SR1.read().RxNE != 1) {}
        result_buf[0] = regs.I2C1.DR.read().DR;
        return result_buf[0..1];

        // } else if (bytes == 2) {
    } else {
        regs.I2C1.CR1.modify(.{ .ACK = 1 });
        regs.I2C1.CR1.modify(.{ .STOP = 0 });
        var idx: usize = 0;
        while (true) : (idx += 1) {
            if (idx >= bytes) {
                break;
            }
            const bytes_remaining = bytes - idx;
            // Second-to-last byte, we must send NACK
            if (bytes_remaining == 3) {
                while (regs.I2C1.SR1.read().BTF != 1) {}
                regs.I2C1.CR1.modify(.{ .ACK = 0 });
            } else if (bytes_remaining == 2) {
                regs.I2C1.CR1.modify(.{ .STOP = 1 });
            } else {
                while (regs.I2C1.SR1.read().RxNE != 1) {}
            }
            result_buf[idx] = regs.I2C1.DR.read().DR;
        }
        return result_buf[0..idx];
    }
}

fn i2c_write(addr: I2CAddr, msg: []u8) void {
    i2c_start();
    i2c_send_addr(addr, .write);
    while (regs.I2C1.SR1.read().TxE != 1) {}
    for (msg) |byte| {
        regs.I2C1.DR.write(.{ .DR = byte });
        while (regs.I2C1.SR1.read().TxE != 1) {}
    }
    while (regs.I2C1.SR1.read().BTF != 1) {}
    regs.I2C1.CR1.modify(.{ .STOP = 1 });
}

fn init() void {
    // Configure System clock
    init_xosc();
    enable_systick(base_freq);
    global_uart.init_peripheral(base_freq, 9600);
    init_i2c();
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

const AHT10Cmd = enum(u8) {
    initialise = 0b11100001,
    softReset = 0b10111010,
    triggerMeasurement = 0b10101100,
};

const AHT10Mode = enum(u2) {
    normal = 0,
    cyclic = 1,
    command_0 = 2,
    command_1 = 3,
};

const AHT10Status = packed struct(u8) {
    reserved_0: u3,
    cal_enable: u1,
    reserved_1: u1,
    mode: AHT10Mode,
    busy: u1,
};

const AHT10Data = struct {
    humidity: u20,
    temperature: u20,

    pub fn fromSlice(data: []const u8) AHT10Data {
        assert(data.len == 5, "AHT10 Reading must be a slice of 5 bytes, found {d}", .{data.len});
        var humidity: u20 = 0;
        var temperature: u20 = 0;
        humidity = std.math.shl(u20, data[0], 12);
        humidity |= std.math.shl(u20, data[1], 4);
        const humidity_half = (data[2] & 0xf0) >> 4;
        const temperature_half = (data[2] & 0x0f);
        humidity |= humidity_half;

        temperature = std.math.shl(u20, temperature_half, 16);
        temperature |= std.math.shl(u20, data[3], 8);
        temperature |= data[4];

        return .{ .humidity = humidity, .temperature = temperature };
    }

    pub fn humidityToFloat(self: AHT10Data) f32 {
        const division_factor: f32 = std.math.exp2(20.0);
        const float_humidity: f32 = @floatFromInt(self.humidity);
        const result = float_humidity * 100 / division_factor;
        return result;
    }

    pub fn temperatureToFloat(self: AHT10Data) f32 {
        const division_factor: f32 = std.math.exp2(20.0);
        const float_temperature: f32 = @floatFromInt(self.temperature);
        const result = (float_temperature / division_factor) * 200 - 50;
        return result;
    }
};

export fn main() noreturn {
    init();
    clear_led();
    delay_ms(1000);
    std.log.info("-------------Initialised-------------", .{});

    var i2c_buf: [64]u8 = undefined;
    var status: AHT10Status = @bitCast(i2c_read(aht100_ic2addr, 1, &i2c_buf)[0]);
    var cmd: [1]u8 = .{@intFromEnum(AHT10Cmd.softReset)};
    i2c_write(aht100_ic2addr, &cmd);
    delay_ms(20);
    cmd[0] = @intFromEnum(AHT10Cmd.initialise);
    i2c_write(aht100_ic2addr, &cmd);
    delay_ms(20);

    while (true) {
        cmd[0] = @intFromEnum(AHT10Cmd.triggerMeasurement);
        i2c_write(aht100_ic2addr, &cmd);
        status = @bitCast(i2c_read(aht100_ic2addr, 1, &i2c_buf)[0]);
        while (status.busy == 1) {
            delay_ms(75);
            status = @bitCast(i2c_read(aht100_ic2addr, 1, &i2c_buf)[0]);
        }
        const temperature_result = i2c_read(aht100_ic2addr, 6, &i2c_buf);
        status = @bitCast(temperature_result[0]);
        assert(status.busy == 0, "AHT10 is busy!", .{});
        const aht10_reading: AHT10Data = .fromSlice(temperature_result[1..]);
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
