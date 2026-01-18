const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {

    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    //const target = b.standardTargetOptions(.{});
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .thumb,
        .os_tag = .freestanding,
        .abi = .eabihf,
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m3 },
        .cpu_features_add = std.Target.arm.featureSet(&[_]std.Target.arm.Feature{.fp_armv8d16sp}),
    });

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = std.builtin.OptimizeMode.ReleaseSafe;

    const register_mod = b.createModule(.{
        .root_source_file = b.path("src/registers/STM32F103_regs.zig"),
        .target = target,
        .optimize = optimize,
    });

    // We will also create a module for our other entry point, 'main.zig'.
    const exe_mod = b.createModule(.{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    exe_mod.addImport("registers", register_mod);

    const exe_name = "zig_embedded";
    const exe = b.addExecutable(.{
        .name = exe_name ++ ".elf",
        .root_module = exe_mod,
        .linkage = .static,
    });
    exe.link_gc_sections = true;
    exe.link_data_sections = true;
    exe.link_function_sections = true;

    exe.addAssemblyFile(b.path("src/build/startup_stm32f103xb.s"));
    exe.setLinkerScript(b.path("src/build/STM32F103C8Tx_FLASH.ld"));

    exe.entry = .{ .symbol_name = "Reset_Handler" };

    b.installArtifact(exe);

    const assembly = b.addInstallFile(exe.getEmittedAsm(), "source.s");
    assembly.step.dependOn(&exe.step);
    b.default_step.dependOn(&assembly.step);

    // Produce .bin file from .elf
    const bin = b.addObjCopy(exe.getEmittedBin(), .{
        .format = .bin,
    });
    bin.step.dependOn(&exe.step);
    const copy_bin = b.addInstallBinFile(bin.getOutput(), exe_name ++ ".bin");
    copy_bin.step.dependOn(&bin.step);
    b.default_step.dependOn(&copy_bin.step);

    const run_renode = b.addSystemCommand(&.{ "renode", "--console" });
    run_renode.addFileArg(b.path("resource/stm32f103.resc"));
    run_renode.step.dependOn(&copy_bin.step);
    b.step("renode", "run in renode").dependOn(&run_renode.step);

    const run_flash = b.addSystemCommand(&.{
        "st-flash",
        "--reset",
        "write",
        b.getInstallPath(copy_bin.dir, copy_bin.dest_rel_path),
        "0x08000000",
    });
    run_flash.step.dependOn(&copy_bin.step);
    b.step("flash", "Flash to microcontroller").dependOn(&run_flash.step);

    const run_gdb = b.addSystemCommand(&.{"arm-none-eabi-gdb"});
    run_gdb.addArtifactArg(exe);
    run_gdb.addArgs(&.{ "-ex", "target remote :3333" });
    run_gdb.step.dependOn(&copy_bin.step);
    b.step("gdb", "start gdb server and connect to 3333").dependOn(&run_gdb.step);

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // REVISIT: Unit tests could be used if the business logic is pushed into an isolated module.

    // const exe_unit_tests = b.addTest(.{
    //     .root_module = exe_mod,
    // });

    // const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // // Similar to creating the run step earlier, this exposes a `test` step to
    // // the `zig build --help` menu, providing a way for the user to request
    // // running the unit tests.
    // const test_step = b.step("test", "Run unit tests");
    // test_step.dependOn(&run_exe_unit_tests.step);
}
