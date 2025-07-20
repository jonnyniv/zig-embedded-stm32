const std = @import("std");
const regs = @import("registers.zig");

export fn main() noreturn {
    // Turn on clock for port C
    regs.RCC.APB2ENR.modify(.{.IOPCEN = 1,});
    // Pin 7 output, open drain
    regs.GPIOC.CRH.modify(.{.MODE13 = 0b10, .CNF13 = 0b01});

    while (true) {
        for (0..200000) |_| {
            asm volatile ("nop");
        }
        const val = regs.GPIOC.ODR.read().ODR13;
        regs.GPIOC.ODR.modify(.{.ODR13 = ~val});

    }
}
