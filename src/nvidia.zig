const std = @import("std");
const HMODULE = std.os.windows.HMODULE;
pub const nvapi = @cImport({
    @cInclude("stddef.h");
    @cInclude("nvapi.h");
    @cInclude("nvapi_interface.h");
    @cInclude("NvApiDriverSettings.h");
});

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var allocator = gpa.allocator();

/// Converts a NvAPI UTF-16 string to a Zig string.
pub fn decodeString(str: nvapi.NvAPI_UnicodeString) ![]const u8 {
    const all_with_sentinel: [*:0]const u16 = @ptrCast(&str);
    const before_sentinel: [:0]const u16 = std.mem.span(all_with_sentinel);

    return std.unicode.utf16leToUtf8Alloc(allocator, before_sentinel);
}

/// Converts a Zig ASCII string to a NvAPI UTF-16 string.
pub fn encodeString(str: []const u8) !*nvapi.NvAPI_UnicodeString {
    const len = nvapi.NVAPI_UNICODE_STRING_MAX;

    var encoded: []u16 = try allocator.alloc(u16, len);
    @memset(encoded, 0);
    _ = try std.unicode.utf8ToUtf16Le(encoded, str);

    return encoded[0..len];
}

pub fn queryNvFunc(
    nvapi_module: HMODULE,
    comptime name: []const u8,
) !*NvFnTypeByName(name) {
    const func_id = try nvFnIdByName(name);
    const query_fn_addr = std.os.windows.kernel32.GetProcAddress(nvapi_module, "nvapi_QueryInterface");

    if (query_fn_addr == null) {
        return error.MissingQueryInterface;
    }

    // Unwrap and cast the function pointer for `nvapi_QueryInterface`
    const NvAPI_QueryInterfaceFn = fn (id: nvapi.NvU32) ?*anyopaque;
    const query_fn: *NvAPI_QueryInterfaceFn = @ptrCast(query_fn_addr.?);

    // Call `nvapi_QueryInterface` to get a pointer to the function we want
    const nv_fn = query_fn(func_id);

    if (nv_fn == null) {
        return error.FunctionDoesNotExist;
    } else {
        return @ptrCast(nv_fn.?);
    }
}

/// Returns the type of the NvAPI function with the given name.
fn NvFnTypeByName(comptime name: []const u8) type {
    if (!@hasDecl(nvapi, name)) {
        @compileError("nvapi.h does not have a function named " ++ name);
    }

    return @TypeOf(@field(nvapi, name));
}

/// Finds the function ID for the NvAPI function with the given name
/// by searching the table in nvapi_interface.h.
fn nvFnIdByName(comptime name: []const u8) !nvapi.NvU32 {
    for (nvapi.nvapi_interface_table) |entry| {
        const entry_name = std.mem.span(entry.func);

        if (std.mem.eql(u8, entry_name, name)) {
            return entry.id;
        }
    }

    return error.MissingInterfaceTableEntry;
}

