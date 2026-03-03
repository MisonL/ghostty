//! Transitional software backend shim.
//!
//! The long-term plan is a true CPU software renderer under `src/renderer`.
//! For now, this keeps backend wiring and build configuration stable while we
//! incrementally add dedicated CPU rendering pieces.
//!
//! Compatibility policy:
//! - Apple platforms: route through Metal.
//! - Linux/other non-Apple: route through OpenGL path.
//! - `software_renderer_cpu_effective=true`: route through the CPU MVP scaffold.

const builtin = @import("builtin");
const build_config = @import("../build_config.zig");
const Backend = @import("backend.zig").Backend;
const CPUBackend = @import("CPU.zig").CPU;
const OpenGL = @import("OpenGL.zig").OpenGL;
const Metal = @import("Metal.zig").Metal;

pub const routed_backend = Backend.softwareRouteForOsTag(builtin.os.tag);

const software_renderer_cpu_effective = if (@hasDecl(build_config, "software_renderer_cpu_effective"))
    build_config.software_renderer_cpu_effective
else
    build_config.software_renderer_cpu_mvp;

pub const Software = if (software_renderer_cpu_effective)
    CPUBackend
else switch (routed_backend) {
    .opengl => OpenGL,
    .metal => Metal,
    else => unreachable,
};
