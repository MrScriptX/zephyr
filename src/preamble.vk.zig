pub const Error = error {
    Incomplete,
    OutOfHostMemory,
    OutOfDeviceMemory,
    InitializationFailed,
    LayerNotPresent,
    ExtensionNotPresent,
    IncompatibleDriver,
    SurfaceLostKHR,
    ValidationFailed,
    OutOfDateKHR,
    FullScreenExclusiveModeLostExt,
    DeviceLost,
    NotReady,
    SuboptimalKHR,
    Timeout,
    OutOfPoolMemory,
    FragmentedPool,
    Unknown
};

// Themselves VK_VERSION_1_0 baseline, but their C return type
// (PFN_vkVoidFunction, a bare function-pointer typedef) is the one shape the
// generic emitter can't render -- hand-declared here instead of generated.
// Used by the generated loadInstanceCommands/loadDeviceCommands to resolve
// version/extension-gated commands (see emit.zig's writeCommands).
pub extern fn vkGetInstanceProcAddr(instance: Instance, pName: [*c]const u8) callconv(.c) ?*const anyopaque;
pub extern fn vkGetDeviceProcAddr(device: Device, pName: [*c]const u8) callconv(.c) ?*const anyopaque;

pub fn check_result(result: Result) Error!void {
    switch (result) {
        .success => return,
        .incomplete => return Error.Incomplete,
        .suboptimal_khr => return Error.SuboptimalKHR,
        .timeout => return Error.Timeout,
        .not_ready => return Error.NotReady,
        .error_out_of_host_memory => return Error.OutOfHostMemory,
        .error_out_of_device_memory => return Error.OutOfDeviceMemory,
        .error_initialization_failed => return Error.InitializationFailed,
        .error_layer_not_present => return Error.LayerNotPresent,
        .error_extension_not_present => return Error.ExtensionNotPresent,
        .error_incompatible_driver => return Error.IncompatibleDriver,
        .error_device_lost => return Error.DeviceLost,
        .error_full_screen_exclusive_mode_lost_ext => return Error.FullScreenExclusiveModeLostExt,
        .error_out_of_date_khr => return Error.OutOfDateKHR,
        .error_surface_lost_khr => return Error.SurfaceLostKHR,
        .error_out_of_pool_memory => return Error.OutOfPoolMemory,
        .error_fragmented_pool => return Error.FragmentedPool,
        else => return Error.Unknown,
    }
}
