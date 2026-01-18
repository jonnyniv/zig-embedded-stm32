const std = @import("std");
const regs = @import("registers");

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

        pub fn writer(self: Self, buffer: []u8) !std.Io.Writer {
            if (!self.initialised) return Error.NotEnabled;
            return .{
                .vtable = &.{
                    .drain = Self.drain,
                },
                .buffer = buffer,
            };
        }

        pub fn init_peripheral(self: *Self, clk_freq: u32, baud: u32) void {
            switch (Peripheral) {
                .USART1 => {
                    regs.RCC.APB2ENR.modify(.{ .USART1EN = 1 });
                },
                .USART2 => {
                    regs.RCC.APB1ENR.modify(.{ .USART2EN = 1 });
                },
                inline else => |uart_type| @compileError(@tagName(uart_type) ++ " not supported"),
            }
            regs.RCC.APB2ENR.modify(.{ .IOPBEN = 1, .AFIOEN = 1 });
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
            Self.Regs.CR1.write(.{ .UE = 1 });
            Self.Regs.BRR.write_raw(target_baud);
            self.initialised = true;
        }

        fn send_char(char: u8) void {
            while (Self.Regs.SR.read().TXE == 0) {}

            Self.Regs.DR.write(.{ .DR = char });
        }

        fn send_msg(msg: []const u8) Error!usize {
            if (msg.len == 0) return 0;
            Self.Regs.CR1.modify(.{ .TE = 1 });
            defer Self.Regs.CR1.modify(.{ .TE = 0 });

            const CR1 = Self.Regs.CR1.read();
            if (CR1.UE != 1 and CR1.TE != 1) {
                return Error.NotEnabled;
            }

            var written_bytes: usize = 0;
            for (msg) |char| {
                send_char(char);
                written_bytes += 1;
            }
            while (Self.Regs.SR.read().TC == 0) {}
            return written_bytes;
        }

        fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const buffered = w.buffered();
            var total_bytes: usize = 0;
            if (buffered.len > 0) {
                total_bytes += send_msg(buffered) catch return std.Io.Writer.Error.WriteFailed;
                _ = w.consumeAll();
            }

            for (data) |data_entry| {
                total_bytes += send_msg(data_entry) catch return std.Io.Writer.Error.WriteFailed;
            }
            for (0..splat - 1) |_| {
                total_bytes += send_msg(data[data.len - 1]) catch return std.Io.Writer.Error.WriteFailed;
            }
            return total_bytes;
        }
    };
}
