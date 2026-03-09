const std = @import("std");
const regs = @import("registers");

fn assert(cond: bool, comptime msg: []const u8, args: anytype) void {
    if (!cond) {
        switch (@import("builtin").mode) {
            .Debug, .ReleaseSafe => {
                std.debug.panic(msg, args);
            },
            inline else => {
                unreachable;
            },
        }
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

pub const GPIOPort = enum {
    A,
    B,
    C,
    D,
};

pub fn GPIO(port: GPIOPort) type {
    return struct {
        pub const Self = @This();
        pub const Port = port;
        pub const Regs = switch (Port) {
            .A => regs.GPIOA,
            .B => regs.GPIOB,
            .C => regs.GPIOC,
            .D => regs.GPIOD,
        };

        pub const scoped_log = std.log.scoped(.gpio);
        const log = struct {
            pub fn err(
                comptime format: []const u8,
                args: anytype,
            ) void {
                scoped_log.err(@typeName(Self) ++ ": " ++ format, args);
            }

            pub fn warn(
                comptime format: []const u8,
                args: anytype,
            ) void {
                scoped_log.warn(@typeName(Self) ++ ": " ++ format, args);
            }

            pub fn info(
                comptime format: []const u8,
                args: anytype,
            ) void {
                scoped_log.info(@typeName(Self) ++ ": " ++ format, args);
            }

            pub fn debug(
                comptime format: []const u8,
                args: anytype,
            ) void {
                scoped_log.debug(@typeName(Self) ++ ": " ++ format, args);
            }
        };

        pub const Mode = enum {
            outputPushPull,
            outputOpenDrain,
            afioPushPull,
            afioOpenDrain,
            inputAnalog,
            input,
        };

        pub const TieMode = enum {
            floating,
            pullUp,
            pullDown,
        };

        pub const Speed = enum(u2) {
            max2Mhz = 0b10,
            max10Mhz = 0b01,
            max50Mhz = 0b11,
        };

        /// tieMode is only used in afioPushPull and input modes.
        /// speed is only used in output modes
        pub const Options = struct {
            mode: Mode,
            speed: Speed = .max2Mhz,
            tieMode: TieMode = .pullDown,
        };

        pub const Pin = struct {
            options: Options,
            number: u4,

            pub fn set(self: Pin) void {
                switch (self.options.mode) {
                    .outputPushPull => {},
                }
            }
        };

        /// Sets up a GPIO pin including speed and ties
        pub fn configurePin(pin: u4, options: Options) void {
            log.debug("configuring pin {d} mode {t} speed {t}", .{ pin, options.mode, options.speed });

            const apb2enr = blk: {
                var val = regs.RCC.APB2ENR.read();
                switch (Port) {
                    .A => {
                        val.IOPAEN = 1;
                    },
                    .B => {
                        val.IOPBEN = 1;
                    },
                    .C => {
                        val.IOPCEN = 1;
                    },
                    .D => {
                        val.IOPDEN = 1;
                    },
                }
                break :blk val;
            };

            regs.RCC.APB2ENR.write(apb2enr);

            const cnfVal: u2 = switch (options.mode) {
                .outputPushPull, .inputAnalog => 0b00,
                .outputOpenDrain => 0b01,
                .afioPushPull => 0b10,
                .afioOpenDrain => 0b11,
                .input => switch (options.tieMode) {
                    .floating => 0b01,
                    .pullDown, .pullUp => 0b10,
                },
            };

            log.debug("Cnf val will be 0b{b}", .{ cnfVal });

            const modeVal: u2 = switch (options.mode) {
                .input, .inputAnalog => 0b00,
                else => @intFromEnum(options.speed),
            };

            log.debug("Mode val will be 0b{b}", .{ modeVal });

            const newPinCfg: u4 = std.math.shl(u4, cnfVal, 2) | modeVal;
            const shiftVal: u32 = @as(u32, @intCast(pin % 8)) * 4;
            const pinCfgMask: u32 = std.math.shl(u32, 0xf, shiftVal);

            if (pin < 8) {
                const pinCfgOrig = Regs.CRL.read();
                var pinCfgVal: u32 = @bitCast(pinCfgOrig);
                pinCfgVal &= ~pinCfgMask;
                pinCfgVal |= std.math.shl(u32, newPinCfg, shiftVal);
                Regs.CRL.write_raw(pinCfgVal);
            } else {
                const pinCfgOrig = Regs.CRH.read();
                var pinCfgVal: u32 = @bitCast(pinCfgOrig);
                pinCfgVal &= ~pinCfgMask;
                pinCfgVal |= std.math.shl(u32, newPinCfg, shiftVal);
                Regs.CRH.write_raw(pinCfgVal);
            }

            if (options.tieMode == .pullDown) {
                var odrVal = Regs.ODR.read_raw();
                const pinMask = std.math.shl(u16, 1, pin);
                odrVal = odrVal & (~pinMask);
                Regs.ODR.write_raw(odrVal);
            } else if (options.tieMode == .pullUp) {
                var odrVal = Regs.ODR.read_raw();
                const pinMask = std.math.shl(u16, 1, pin);
                odrVal = odrVal | pinMask;
                Regs.ODR.write_raw(odrVal);
            }
        }
    };
}

pub const GPIOA = GPIO(.A);
pub const GPIOB = GPIO(.B);
pub const GPIOC = GPIO(.C);
pub const GPIOD = GPIO(.D);

pub const UARTPeripheral = enum {
    USART1,
    USART2,
    USART3,
    UART4,
    UART5,
};

pub fn UART(uart: UARTPeripheral) type {
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
        const Peripheral: UARTPeripheral = uart;

        pub const Options = struct {
            base_freq: u32,
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
                        // TX
                        GPIOB.configurePin(6, .{ .mode = .afioPushPull, .tieMode = .pullUp });
                        // RX
                        GPIOB.configurePin(7, .{ .mode = .input });
                    } else {
                        regs.AFIO.MAPR.modify(.{ .USART1_REMAP = 0 });
                        // TX
                        GPIOA.configurePin(9, .{ .mode = .afioPushPull, .tieMode = .pullUp });
                        // RX
                        GPIOA.configurePin(10, .{ .mode = .input });
                    }
                },
                inline else => |uart_type| @compileError(@tagName(uart_type) ++ " not supported"),
            }
            const targetBaud: u32 = @divFloor(options.base_freq, options.baud);
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

    const scoped_log = std.log.scoped(.i2c);
    const log = struct {
        pub fn err(
            comptime format: []const u8,
            args: anytype,
        ) void {
            scoped_log.err(@typeName(Self) ++ ": " ++ format, args);
        }

        pub fn warn(
            comptime format: []const u8,
            args: anytype,
        ) void {
            scoped_log.warn(@typeName(Self) ++ ": " ++ format, args);
        }

        pub fn info(
            comptime format: []const u8,
            args: anytype,
        ) void {
            scoped_log.info(@typeName(Self) ++ ": " ++ format, args);
        }

        pub fn debug(
            comptime format: []const u8,
            args: anytype,
        ) void {
            scoped_log.debug(@typeName(Self) ++ ": " ++ format, args);
        }
    };

    pub const Options = struct {
        base_freq: u32,
        i2c_freq: u32,
        remap: bool,
    };

    pub const Addr = u7;
    pub const RWMode = enum(u1) {
        read = 1,
        write = 0,
    };

    pub fn init(options: Options) void {
        const base_period_ns = 1_000_000_000 / options.base_freq;
        //TODO: Configure for generic I2C

        // Enable Clocks for GPIO and I2C
        regs.RCC.APB1ENR.modify(.{ .I2C1EN = 1 });
        regs.RCC.APB2ENR.modify(.{ .AFIOEN = 1 });

        // Configure pins
        if (options.remap) {
            regs.AFIO.MAPR.modify(.{ .I2C1_REMAP = 1 });
            // SCL
            GPIOB.configurePin(8, .{ .mode = .afioOpenDrain, .speed = .max10Mhz });
            // SDA
            GPIOB.configurePin(9, .{ .mode = .afioOpenDrain, .speed = .max10Mhz });
        } else {
            assert(false, "Unsupported: I2C Remap = false", .{});
        }

        // Configure I2C speed, clock control, and rise time (From datasheet)
        Self.Regs.CR2.modify(.{ .FREQ = 8 });
        const ccr_div: u12 = @intCast(@divFloor(options.base_freq, 2 * options.i2c_freq));
        Self.Regs.CCR.modify(.{ .CCR = ccr_div });

        const sm_mode_risetime_ns = 1000;
        const rise_time_reg: u6 = @intCast(@divFloor(sm_mode_risetime_ns, base_period_ns) + 1);
        Self.Regs.TRISE.modify(.{ .TRISE = rise_time_reg });

        Self.Regs.CR1.modify(.{ .PE = 1 });
        log.info("initialised", .{});
    }

    pub fn start() void {
        Self.Regs.CR1.modify(.{ .START = 1 });
        while (Self.Regs.SR1.read().SB != 1) {}
        log.debug("start bit sent", .{});
    }

    pub fn sendAddr(addr: Addr, mode: RWMode) void {
        log.debug("sending address 0x{x}, mode {t}", .{ addr, mode });
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
        log.info("Reading {d} bytes from device 0x{x}", .{ bytes, addr });
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
            log.debug("Read byte 0x{x}", .{byte});
            resultBuf[0] = byte;
            log.debug("Read complete", .{});
            return resultBuf[0..1];
        } else if (bytes == 2) {
            Self.Regs.CR1.modify(.{ .ACK = 0 });
            while (Self.Regs.SR1.read().BTF != 1) {}
            Self.Regs.CR1.modify(.{ .STOP = 1, .POS = 0 });
            {
                const byte = Self.Regs.DR.read().DR;
                resultBuf[0] = byte;
                log.debug("Read byte 0x{x}", .{byte});
            }
            {
                const byte = Self.Regs.DR.read().DR;
                resultBuf[1] = byte;
                log.debug("Read byte 0x{x}", .{byte});
            }
            log.debug("Read complete", .{});
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
                log.debug("Read byte 0x{x}", .{byte});
                resultBuf[idx] = byte;
            }
            log.debug("Read complete", .{});
            return resultBuf[0..idx];
        }
    }

    pub fn write(addr: Addr, msg: []const u8) void {
        log.info("Writing {d} bytes to addr 0x{x}", .{ msg.len, addr });
        Self.start();
        Self.sendAddr(addr, .write);
        while (Self.Regs.SR1.read().TxE != 1) {}
        for (msg) |byte| {
            log.debug("Wrote 0x{x}", .{byte});
            Self.Regs.DR.write(.{ .DR = byte });
            while (Self.Regs.SR1.read().TxE != 1) {}
        }
        while (Self.Regs.SR1.read().BTF != 1) {}
        Self.Regs.CR1.modify(.{ .STOP = 1 });
        log.debug("Write complete", .{});
    }
};

pub const SPI1 = struct {
    pub const Self = @This();
    pub const Regs = regs.SPI1;

    pub const Options = struct {
        pub const CLKPolarity = enum(u1) {
            idleLow = 0,
            idleHigh = 1,
        };

        pub const ClkPhase = enum(u1) {
            dataFirst = 0,
            dataSecond = 1,
        };

        pub const SlaveSelectOutput = enum(u1) {
            /// SS output is disabled in master mode and the cell can work in multimaster configuration
            disabled = 0,
            /// SS output is enabled in master mode and when the cell is enabled. The cell cannot work in a multimaster environment.
            enabled = 1,
        };

        pub const FrameFormat = enum(u1) {
            msbFirst = 0,
            lsbFirst = 1,
        };

        pub const DuplexMode = enum {
            fullDuplex,
            bidirectionalHalf,
            rxOnly,
            txOnly,
        };

        /// Prescalar is computed 2**(baud_prescalar + 1)
        baudPrescalar: u3,
        clkPolarity: CLKPolarity,
        clkPhase: ClkPhase,
        slaveSelectOutput: SlaveSelectOutput,
        frameFormat: FrameFormat,
        duplexMode: DuplexMode,

        /// Function Pin RemapPin
        /// SPI1_NSS PA4 PA15
        /// SPI1_SCK PA5 PB3
        /// SPI1_MISO PA6 PB4
        /// SPI1_MOSI PA7 PB5
        remap: bool,
    };

    options: Options,

    pub fn init(options: Options) Self {
        // TODO: Configure for generic SPI
        regs.RCC.APB2ENR.modify(.{ .SPI1EN = 1, .AFIOEN = 1 });

        if (!options.remap) {
            // SCK
            GPIOA.configurePin(5, .{ .mode = .afioPushPull, .speed = .max10Mhz });
            if (options.duplexMode == .fullDuplex or options.duplexMode == .bidirectionalHalf or options.duplexMode == .txOnly) {
                // MOSI
                GPIOA.configurePin(7, .{ .mode = .afioPushPull, .speed = .max10Mhz });
            }
            if (options.duplexMode == .fullDuplex or options.duplexMode == .rxOnly) {
                // MISO
                GPIOA.configurePin(6, .{ .mode = .input, .tieMode = .pullUp });

                if (options.slaveSelectOutput == .enabled) {
                    // NSS
                    GPIOA.configurePin(4, .{ .mode = .afioPushPull, .speed = .max10Mhz });
                }
            }
        } else {
            regs.AFIO.MAPR.modify(.{ .SPI1_REMAP = 1 });
            // SCK
            GPIOB.configurePin(3, .{ .mode = .afioPushPull, .speed = .max10Mhz });

            if (options.duplexMode == .fullDuplex or options.duplexMode == .bidirectionalHalf or options.duplexMode == .txOnly) {
                // MOSI
                GPIOB.configurePin(5, .{ .mode = .afioPushPull, .speed = .max10Mhz });
            }
            if (options.duplexMode == .fullDuplex or options.duplexMode == .rxOnly) {
                // MISO
                GPIOB.configurePin(6, .{ .mode = .input, .tieMode = .pullUp });
                if (options.slaveSelectOutput == .enabled) {
                    // NSS
                    GPIOA.configurePin(15, .{ .mode = .afioPushPull, .speed = .max10Mhz });
                }
            }
        }

        if (options.slaveSelectOutput == .enabled) {
            Regs.CR2.modify(.{ .SSOE = @intFromEnum(options.slaveSelectOutput) });
        }

        Regs.CR1.modify(.{
            .SPE = 1, // Enable
            .MSTR = 1, // Master mode
            .BR = options.baudPrescalar,
            .CPOL = @intFromEnum(options.clkPolarity),
            .CPHA = @intFromEnum(options.clkPhase),
            .DFF = @intFromEnum(options.frameFormat),
        });
        return Self{ .options = options };
    }

    pub fn write(self: Self, bytes: []u8) void {
        Regs.DR.write(.{ .DR = bytes[0] });
        while (Regs.SR.read().TXE == 0) {}
        if (bytes.len > 1) {
            for (bytes[1..]) |byte| {
                Regs.DR.write(.{ .DR = byte });
                if (self.options.duplexMode == .fullDuplex) {
                    while (Regs.SR.read().RXNE == 0) {}
                }
            }
            while (Regs.SR.read().TXE == 0) {}
        }
        while (Regs.SR.read().BSY == 1) {}
    }
};

// External Peripherals

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

        pub fn init() void {
            Self.writeCmd(.softReset);
            delay_ms(20);
            Self.writeCmd(.initialise);
            delay_ms(20);
            const status = Self.readStatus();
            assert(status.cal_enable == 1, "AHT10 not in cal after init!", .{});
        }

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
