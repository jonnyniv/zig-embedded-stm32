const std = @import("std");
const regs = @import("registers");

fn assert(cond: bool, comptime msg: []const u8, args: anytype) void {
    if (!cond) {
        std.debug.panic(msg, args);
    }
}

fn delay_ms(delay: usize) void {
    var delayCounter = delay;
    while (delayCounter > 0) {
        if (regs.STK.CTRL.read().COUNTFLAG != 0) {
            delayCounter -= 1;
        }
    }
}

pub const UARTType = enum {
    USART1,
    USART2,
    USART3,
    UART4,
    UART5,
};

pub fn UART(uart: UARTType) type {
    return struct {
        initialised: bool = false,

        const Self = @This();

        const Error = error{
            NotEnabled,
        };

        const Regs: type = switch (uart) {
            .USART1 => regs.USART1,
            .USART2 => regs.USART2,
            .USART3 => regs.USART3,
            .UART4 => regs.UART4,
            .UART5 => regs.UART5,
        };
        const Peripheral: UARTType = uart;

        pub const Options = struct {
            clk_freq: u32,
            baud: u32,
            remap: bool,
        };

        pub fn writer(self: Self, buffer: []u8) !std.Io.Writer {
            if (!self.initialised) return Error.NotEnabled;
            return .{
                .vtable = &.{
                    .drain = Self.drain,
                },
                .buffer = buffer,
            };
        }

        pub fn initPeripheral(self: *Self, options: Options) void {
            switch (Peripheral) {
                .USART1 => {
                    regs.RCC.APB2ENR.modify(.{ .USART1EN = 1 });
                },
                .USART2 => {
                    regs.RCC.APB1ENR.modify(.{ .USART2EN = 1 });
                },
                inline else => |uart_type| @compileError(@tagName(uart_type) ++ " not supported"),
            }
            regs.RCC.APB2ENR.modify(.{ .AFIOEN = 1 });
            switch (Peripheral) {
                .USART1 => {
                    if (options.remap) {
                        regs.AFIO.MAPR.modify(.{ .USART1_REMAP = 1 });
                        regs.RCC.APB2ENR.modify(.{ .IOPBEN = 1 });
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
                    } else {
                        regs.AFIO.MAPR.modify(.{ .USART1_REMAP = 0 });
                        regs.RCC.APB2ENR.modify(.{ .IOPAEN = 1 });
                        regs.GPIOA.CRH.modify(.{
                            // TX = PA9 in REMAP=0
                            .MODE9 = 0b10, // Output < 2 Mhz
                            .CNF9 = 0b10, // AFIO Push-Pull
                            // RX = PA10 in REMAP=0
                            .MODE10 = 0b00, // Input
                            .CNF10 = 0b10, // Pull down (ODR=0)
                        });
                        // Pull up tx
                        regs.GPIOA.ODR.modify(.{ .ODR9 = 1 });
                    }
                },
                inline else => |uart_type| @compileError(@tagName(uart_type) ++ " not supported"),
            }
            const targetBaud: u32 = @divFloor(options.clk_freq, options.baud);
            Self.Regs.CR1.write(.{ .UE = 1 });
            Self.Regs.BRR.write_raw(targetBaud);
            self.initialised = true;
        }

        fn sendChar(char: u8) void {
            while (Self.Regs.SR.read().TXE == 0) {}

            Self.Regs.DR.write(.{ .DR = char });
        }

        fn sendMsg(msg: []const u8) Error!usize {
            if (msg.len == 0) return 0;
            Self.Regs.CR1.modify(.{ .TE = 1 });
            defer Self.Regs.CR1.modify(.{ .TE = 0 });

            const CR1 = Self.Regs.CR1.read();
            if (CR1.UE != 1 and CR1.TE != 1) {
                return Error.NotEnabled;
            }

            var writtenBytes: usize = 0;
            for (msg) |char| {
                sendChar(char);
                writtenBytes += 1;
            }
            while (Self.Regs.SR.read().TC == 0) {}
            return writtenBytes;
        }

        fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const buffered = w.buffered();
            var totalBytes: usize = 0;
            if (buffered.len > 0) {
                totalBytes += sendMsg(buffered) catch return std.Io.Writer.Error.WriteFailed;
                _ = w.consumeAll();
            }

            for (data) |data_entry| {
                totalBytes += sendMsg(data_entry) catch return std.Io.Writer.Error.WriteFailed;
            }
            for (0..splat - 1) |_| {
                totalBytes += sendMsg(data[data.len - 1]) catch return std.Io.Writer.Error.WriteFailed;
            }
            return totalBytes;
        }
    };
}

pub const I2C1 = struct {
    const Self = @This();
    const Regs = regs.I2C1;

    const log = std.log.scoped(.i2c);

    pub const Addr = u7;
    pub const RWMode = enum(u1) {
        read = 1,
        write = 0,
    };

    pub fn init(base_freq: u32, i2c_freq: u32) void {
        const base_period_ns = 1_000_000_000 / base_freq;
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
        Self.Regs.CR2.modify(.{ .FREQ = 8 });
        const ccr_div: u12 = @intCast(@divFloor(base_freq, 2 * i2c_freq));
        Self.Regs.CCR.modify(.{ .CCR = ccr_div });

        const sm_mode_risetime_ns = 1000;
        const rise_time_reg: u6 = @intCast(@divFloor(sm_mode_risetime_ns, base_period_ns) + 1);
        Self.Regs.TRISE.modify(.{ .TRISE = rise_time_reg });

        Self.Regs.CR1.modify(.{ .PE = 1 });
        log.info("{s}: initialised", .{@typeName(Self)});
    }

    pub fn start() void {
        Self.Regs.CR1.modify(.{ .START = 1 });
        while (Self.Regs.SR1.read().SB != 1) {}
        log.debug("{s}: start bit sent", .{@typeName(Self)});
    }

    pub fn sendAddr(addr: Addr, mode: RWMode) void {
        log.debug("{s}: sending address 0x{x}, mode {t}", .{ @typeName(Self), addr, mode });
        const addrByte: u8 = addr << 1 | @intFromEnum(mode);
        Self.Regs.DR.write(.{ .DR = addrByte });
        while (Self.Regs.SR1.read().ADDR != 1) {}
        const setMode: RWMode = switch (Self.Regs.SR2.read().TRA) {
            0 => .read,
            1 => .write,
        };
        assert(setMode == mode, "I2C Addr phase: set_mode({t}) != mode({t})", .{ setMode, mode });
    }

    pub fn read(addr: Addr, bytes: usize, resultBuf: []u8) []u8 {
        log.info("{s}: Reading {d} bytes from device 0x{x}", .{ @typeName(Self), bytes, addr });
        assert(resultBuf.len >= bytes, "result_buf is not long enough for i2c read! {d} < {d}", .{ resultBuf.len, bytes });
        Self.start();
        if (bytes == 2) {
            Self.Regs.CR1.modify(.{ .POS = 1, .ACK = 1 });
        }
        Self.sendAddr(addr, .read);
        if (bytes == 1) {
            Self.Regs.CR1.modify(.{ .ACK = 0 });
            Self.Regs.CR1.modify(.{ .STOP = 1 });
            while (Self.Regs.SR1.read().RxNE != 1) {}
            const byte = Self.Regs.DR.read().DR;
            log.debug("{s}: Read byte 0x{x}", .{ @typeName(Self), byte });
            resultBuf[0] = byte;
            log.debug("{s}: Read complete", .{@typeName(Self)});
            return resultBuf[0..1];
        } else if (bytes == 2) {
            Self.Regs.CR1.modify(.{ .ACK = 0 });
            while (Self.Regs.SR1.read().BTF != 1) {}
            Self.Regs.CR1.modify(.{ .STOP = 1, .POS = 0 });
            {
                const byte = Self.Regs.DR.read().DR;
                resultBuf[0] = byte;
                log.debug("{s}: Read byte 0x{x}", .{ @typeName(Self), byte });
            }
            {
                const byte = Self.Regs.DR.read().DR;
                resultBuf[1] = byte;
                log.debug("{s}: Read byte 0x{x}", .{ @typeName(Self), byte });
            }
            log.debug("{s}: Read complete", .{@typeName(Self)});
            return resultBuf[0..2];
        } else {
            Self.Regs.CR1.modify(.{ .ACK = 1, .STOP = 0 });
            var idx: usize = 0;
            while (true) : (idx += 1) {
                if (idx >= bytes) {
                    break;
                }
                const bytesRemaining = bytes - idx;
                // Second-to-last byte, we must send NACK
                if (bytesRemaining == 3) {
                    while (Self.Regs.SR1.read().BTF != 1) {}
                    Self.Regs.CR1.modify(.{ .ACK = 0 });
                } else if (bytesRemaining == 2) {
                    Self.Regs.CR1.modify(.{ .STOP = 1 });
                } else {
                    while (Self.Regs.SR1.read().RxNE != 1) {}
                }
                const byte = Self.Regs.DR.read().DR;
                log.debug("{s}: Read byte 0x{x}", .{ @typeName(Self), byte });
                resultBuf[idx] = byte;
            }
            log.debug("{s}: Read complete", .{@typeName(Self)});
            return resultBuf[0..idx];
        }
    }

    pub fn write(addr: Addr, msg: []const u8) void {
        log.info("{s}: Writing {d} bytes to addr 0x{x}", .{ @typeName(Self), msg.len, addr });
        Self.start();
        Self.sendAddr(addr, .write);
        while (Self.Regs.SR1.read().TxE != 1) {}
        for (msg) |byte| {
            log.debug("{s}: Wrote 0x{x}", .{ @typeName(Self), byte });
            Self.Regs.DR.write(.{ .DR = byte });
            while (Self.Regs.SR1.read().TxE != 1) {}
        }
        while (Self.Regs.SR1.read().BTF != 1) {}
        Self.Regs.CR1.modify(.{ .STOP = 1 });
        log.debug("{s}: Write complete", .{@typeName(Self)});
    }
};

/// AHT10 Temperature and Humidity Sensor
pub fn AHT10(i2c: type) type {
    return struct {
        const Self = @This();
        const I2C = i2c;
        const DataReadLen = 6;
        const I2CAddr: I2C.Addr = 0b0111000;

        pub const log = std.log.scoped(.aht10);

        pub const Cmd = enum(u8) {
            initialise = 0b11100001,
            softReset = 0b10111010,
            triggerMeasurement = 0b10101100,
        };

        pub const Mode = enum(u2) {
            normal = 0,
            cyclic = 1,
            // Both of these modes map to command
            command_0 = 2,
            command_1 = 3,
        };

        pub const Status = packed struct(u8) {
            reserved_0: u3,
            cal_enable: u1,
            reserved_1: u1,
            mode: Mode,
            busy: u1,
        };

        pub fn writeCmd(cmd: Cmd) void {
            const cmd_buf: [1]u8 = .{@intFromEnum(cmd)};
            I2C.write(I2CAddr, &cmd_buf);
        }

        pub fn readStatus() Status {
            var status_buf: [@bitSizeOf(Status) / 8]u8 = undefined;
            const status: Status = @bitCast(I2C.read(I2CAddr, 1, &status_buf)[0]);
            return status;
        }

        pub fn readResultPolling() Data {
            Self.writeCmd(.triggerMeasurement);
            var dataBuf: [DataReadLen]u8 = undefined;

            var status = Self.readStatus();
            while (status.busy == 1) {
                delay_ms(75);
                status = @bitCast(I2C.read(I2CAddr, 1, &dataBuf)[0]);
            }
            const readingData = I2C.read(I2CAddr, 6, &dataBuf);
            status = @bitCast(readingData[0]);
            assert(status.busy == 0, "Self is busy!", .{});
            return .fromSlice(readingData[1..]);
        }

        pub const Data = struct {
            humidity: u20,
            temperature: u20,

            // Based on the measurement bit width
            const divisionFactor: f32 = std.math.exp2(20.0);

            pub fn fromSlice(data: []const u8) Data {
                assert(data.len == 5, "Self Reading must be a slice of 5 bytes, found {d}", .{data.len});
                var humidity: u20 = 0;
                var temperature: u20 = 0;
                humidity = std.math.shl(u20, data[0], 12);
                humidity |= std.math.shl(u20, data[1], 4);
                const humidityHalf = (data[2] & 0xf0) >> 4;
                const temperatureHalf = (data[2] & 0x0f);
                humidity |= humidityHalf;

                temperature = std.math.shl(u20, temperatureHalf, 16);
                temperature |= std.math.shl(u20, data[3], 8);
                temperature |= data[4];

                return .{ .humidity = humidity, .temperature = temperature };
            }

            pub fn humidityToFloat(self: Data) f32 {
                const floatHumidity: f32 = @floatFromInt(self.humidity);
                const result = floatHumidity * 100 / divisionFactor;
                return result;
            }

            pub fn temperatureToFloat(self: Data) f32 {
                const floatTemperature: f32 = @floatFromInt(self.temperature);
                const result = (floatTemperature / divisionFactor) * 200 - 50;
                return result;
            }
        };
    };
}
