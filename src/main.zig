const std = @import("std");
const regs = @import("registers.zig");

const clk_freq = 8_000_000;

fn enable_systick(frequency: usize) void {
    const counter_val: u24 = @intCast((frequency / 1000) - 1);
    regs.STK.LOAD_.write(.{ .RELOAD = counter_val });
    regs.STK.VAL.write(.{ .CURRENT = 0 });
    regs.STK.CTRL.modify(.{ .ENABLE = 1, .CLKSOURCE = 1 });
}

fn localPanic(
    msg: []const u8,
    ret_addr: ?usize,
) noreturn {
    _ = ret_addr;
    gpio_init();
    set_led();
    std.log.err("Reached panic with message: {s}", .{msg});
    while (true) {
        asm volatile ("nop");
    }
}
pub const panic = std.debug.FullPanic(localPanic);

fn gpio_init() void {
    // Turn on clock for port C
    regs.RCC.APB2ENR.modify(.{ .IOPCEN = 1 });
    // Pin 13 output, open drain
    regs.GPIOC.CRH.modify(.{ .MODE13 = 0b10, .CNF13 = 0b01 });
}

fn usart_init(baud: usize) void {
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
}

fn set_led() void {
    regs.GPIOC.ODR.modify(.{ .ODR13 = 0 });
}

fn clear_led() void {
    regs.GPIOC.ODR.modify(.{ .ODR13 = 1 });
}

const UARTError = error{
    NotEnabled,
};

fn uart_send_char(char: u8) void {
    while (regs.USART1.SR.read().TXE == 0) {
        asm volatile ("nop");
    }

    regs.USART1.DR.write(.{ .DR = char });
}

fn uart_send_msg(msg: []const u8) UARTError!usize {
    regs.USART1.CR1.modify(.{ .TE = 1 });
    defer regs.USART1.CR1.modify(.{ .TE = 0 });

    const CR1 = regs.USART1.CR1.read();
    if (CR1.UE != 1 and CR1.TE != 1) {
        return UARTError.NotEnabled;
    }

    var written_bytes: usize = 0;
    for (msg) |char| {
        uart_send_char(char);
        written_bytes += 1;
    }
    while (regs.USART1.SR.read().TC == 0) {
        asm volatile ("nop");
    }
    return written_bytes;
}

const UART1 = struct {
    const UART1Writer = std.io.Writer(UART1, UARTError, write);
    pub fn writer() UART1Writer {
        return UART1Writer {
            .context = UART1{}
        };
    }
    pub fn write(self: UART1, msg: []const u8) UARTError!usize {
        _ = self;
        return uart_send_msg(msg);
    }
};

pub const std_options = std.Options{
    .log_level = .debug,
    .logFn = log,
};
fn log(comptime message_level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
    const level_txt = comptime message_level.asText();
    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
    UART1.writer().print(level_txt ++ prefix2 ++ format ++ "\r\n", args) catch return;
}

fn init() void {
    // Configure System clock
    enable_systick(clk_freq);
    gpio_init();
    usart_init(9600);
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

    while (true) {
        //uart_send_msg(message);
        delay_ms(3000);
        std.debug.assert(false);

    }
}
