const std = @import("std");
const regs = @import("registers.zig");

const clk_freq = 8000_000;

fn enable_systick(frequency: usize) void {
    const counter_val: u24 = @intCast((frequency / 1000) - 1);
    regs.STK.LOAD_.write(.{ .RELOAD = counter_val });
    regs.STK.VAL.write(.{ .CURRENT = 0 });
    regs.STK.CTRL.modify(.{ .ENABLE = 1, .CLKSOURCE = 1 });
}

fn gpio_init() void {
    // Turn on clock for port C
    regs.RCC.APB2ENR.modify(.{ .IOPCEN = 1 });
    // Pin 7 output, open drain
    regs.GPIOC.CRH.modify(.{ .MODE13 = 0b10, .CNF13 = 0b01 });
}

fn delay_ms(delay: usize) void {
    var delay_counter = delay;
    while (delay_counter > 0) {
        if (regs.STK.CTRL.read().COUNTFLAG != 0) {
            delay_counter -= 1;
        }
    }
}

fn init() void {
    // Configure System clock
    enable_systick(clk_freq);
    gpio_init();
}

export fn main() noreturn {
    init();

    while (true) {
        delay_ms(500);
        const val = regs.GPIOC.ODR.read().ODR13;
        regs.GPIOC.ODR.modify(.{ .ODR13 = ~val });
    }
}
