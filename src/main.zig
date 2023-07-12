const std = @import("std");
const windows = std.os.windows;
const yazap = @import("yazap");

const nvapi = @cImport({
    @cInclude("stddef.h");
    @cInclude("nvapi_lite_common.h");
    @cInclude("NvApiDriverSettings.h");
    // Zig translate-C doesn't handle nvapi.h correctly,
    // @cInclude("nvapi.h");
    // so we have to manually include the relevant parts...
    @cInclude("custom_nvapi_structs.h");
});

// ... and manually define the functions we need:
extern fn NvAPI_DRS_CreateSession(handle: *nvapi.NvDRSSessionHandle) nvapi.NvAPI_Status;
extern fn NvAPI_DRS_DestroySession(handle: nvapi.NvDRSSessionHandle) nvapi.NvAPI_Status;
extern fn NvAPI_DRS_LoadSettings(handle: nvapi.NvDRSSessionHandle) nvapi.NvAPI_Status;
extern fn NvAPI_DRS_SaveSettings(handle: nvapi.NvDRSSessionHandle) nvapi.NvAPI_Status;

extern fn NvAPI_DRS_GetNumProfiles(
    handle: nvapi.NvDRSSessionHandle,
    num_profiles: *nvapi.NvU32,
) nvapi.NvAPI_Status;

extern fn NvAPI_DRS_EnumProfiles(
    session_handle: nvapi.NvDRSSessionHandle,
    profile_index: nvapi.NvU32,
    profile_handle: *nvapi.NvDRSProfileHandle,
) nvapi.NvAPI_Status;

extern fn NvAPI_DRS_FindApplicationByName(
    session_handle: nvapi.NvDRSSessionHandle,
    path: *const nvapi.NvAPI_UnicodeString,
    profile_handle: *nvapi.NvDRSProfileHandle,
    application: *nvapi.NVDRS_APPLICATION,
) nvapi.NvAPI_Status;

extern fn NvAPI_DRS_FindProfileByName(
    session_handle: nvapi.NvDRSSessionHandle,
    profile_name: *const nvapi.NvAPI_UnicodeString,
    profile_handle: *nvapi.NvDRSProfileHandle,
) nvapi.NvAPI_Status;

extern fn NvAPI_DRS_GetProfileInfo(
    session_handle: nvapi.NvDRSSessionHandle,
    profile_handle: nvapi.NvDRSProfileHandle,
    out_info: *nvapi.NVDRS_PROFILE,
) nvapi.NvAPI_Status;

extern fn NvAPI_DRS_DeleteProfile(
    session_handle: nvapi.NvDRSSessionHandle,
    profile_handle: nvapi.NvDRSProfileHandle,
) nvapi.NvAPI_Status;

extern fn NvAPI_DRS_CreateProfile(
    session_handle: nvapi.NvDRSSessionHandle,
    profile_info: *nvapi.NVDRS_PROFILE,
    profile_handle: *nvapi.NvDRSProfileHandle,
) nvapi.NvAPI_Status;

extern fn NvAPI_DRS_CreateApplication(
    session_handle: nvapi.NvDRSSessionHandle,
    profile_handle: nvapi.NvDRSProfileHandle,
    application: *nvapi.NVDRS_APPLICATION,
) nvapi.NvAPI_Status;

extern fn NvAPI_DRS_SetSetting(
    session_handle: nvapi.NvDRSSessionHandle,
    profile_handle: nvapi.NvDRSProfileHandle,
    setting: *nvapi.NVDRS_SETTING,
) nvapi.NvAPI_Status;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var allocator = gpa.allocator();

// These fields should be u32, but translate-C converts hex values to signed integers
// and it's easier to @bitCast them to u32 at the point of use
const DriverSetting = struct {
    id: i32,
    name: []const u8,
    value: i32,
};

pub fn main() !u8 {
    const Arg = yazap.Arg;

    var app = yazap.App.init(allocator, "nv-stutter-fix", "Fixes stuttering on NVIDIA GPUs during DRM-protected video playback in Electron");
    defer app.deinit();

    var cmd = app.rootCommand();
    try cmd.addArg(Arg.singleValueOption("delete-app-path", null, "Full path to the application executable for which to DELETE the Nvidia settings profile"));
    try cmd.addArg(Arg.singleValueOption("create-app-path", null, "Full path to the application executable for which to CREATE the Nvidia settings profile"));

    const matches = app.parseProcess() catch {
        try app.displayHelp();
        return 1;
    };

    var delete_path: ?[]const u8 = matches.getSingleValue("delete-app-path");
    var create_path: ?[]const u8 = matches.getSingleValue("create-app-path");

    var drs_session: nvapi.NvDRSSessionHandle = undefined;

    {
        const ret = NvAPI_DRS_CreateSession(&drs_session);
        if (ret != 0) {
            std.debug.print("Failed to create DRS session: {d}\n", .{ret});
            return 10;
        }
        std.debug.print("Successfully created DRS session.\n", .{});
    }

    defer _ = NvAPI_DRS_DestroySession(drs_session);

    {
        const ret = NvAPI_DRS_LoadSettings(drs_session);
        if (ret != 0) {
            std.debug.print("Failed to load settings: {d}\n", .{ret});
            return 11;
        }
        std.debug.print("Successfully loaded settings\n", .{});
    }

    // Delete old profile
    if (delete_path) |app_path| {
        const deleted = try deleteProfileByAppPath(drs_session, app_path);
        if (!deleted) {
            _ = try deleteProfileByName(drs_session, app_path);
        }
    } else {
        std.debug.print("--delete-app-path not specified, skipping profile deletion.\n", .{});
    }

    // Save settings
    {
        const ret = NvAPI_DRS_SaveSettings(drs_session);
        if (ret != 0) {
            std.debug.print("Failed to save settings: {d}\n", .{ret});
            return 30;
        }
        std.debug.print("Successfully saved settings\n", .{});
    }

    // Create new profile
    if (create_path) |app_path| {
        std.debug.print("Deleting any existing profiles for {s}\n", .{app_path});
        _ = try deleteProfileByName(drs_session, app_path);

        std.debug.print("Creating new profile for {s}\n", .{app_path});

        createProfileForAppPath(drs_session, app_path) catch {
            return 20;
        };
    } else {
        std.debug.print("--create-app-path not specified, skipping profile creation.\n", .{});
    }

    // Save settings
    {
        const ret = NvAPI_DRS_SaveSettings(drs_session);
        if (ret != 0) {
            std.debug.print("Failed to save settings: {d}\n", .{ret});
            return 30;
        }
        std.debug.print("Successfully saved settings\n", .{});
    }

    return 0;
}

fn getProfileInfo(session: nvapi.NvDRSSessionHandle, profile: nvapi.NvDRSProfileHandle) !nvapi.NVDRS_PROFILE {
    var info: nvapi.NVDRS_PROFILE = undefined;
    info.version = nvapi.NVDRS_PROFILE_VER;

    const ret = NvAPI_DRS_GetProfileInfo(session, profile, &info);

    if (ret != 0) {
        std.debug.print("Failed to get profile: {d}\n", .{ret});
        return error.GetProfileError;
    }

    return info;
}

fn deleteProfileByAppPath(session: nvapi.NvDRSSessionHandle, path: []const u8) !bool {
    const path_w: *nvapi.NvAPI_UnicodeString = try nvApiEncodeString(path);

    var profile: nvapi.NvDRSProfileHandle = undefined;

    var app: nvapi.NVDRS_APPLICATION_V4 = undefined;
    app.version = nvapi.NVDRS_APPLICATION_VER_V4;

    {
        const ret = NvAPI_DRS_FindApplicationByName(session, path_w, &profile, &app);

        if (ret == nvapi.NVAPI_EXECUTABLE_NOT_FOUND) {
            std.debug.print("Application NOT found: {s}\n", .{path});
            return false;
        }

        if (ret != 0) {
            std.debug.print("Failed to get application by name: {d}\n", .{ret});
            return false;
        }
    }

    std.debug.print("Found profile by application name: {s}\n", .{path});
    return maybeDeleteProfile(session, profile);
}

fn deleteProfileByName(session: nvapi.NvDRSSessionHandle, profile_name: []const u8) !bool {
    const profile_name_w: *nvapi.NvAPI_UnicodeString = try nvApiEncodeString(profile_name);

    var profile: nvapi.NvDRSProfileHandle = undefined;

    {
        const ret = NvAPI_DRS_FindProfileByName(session, profile_name_w, &profile);

        if (ret == nvapi.NVAPI_PROFILE_NOT_FOUND) {
            std.debug.print("Profile NOT found by name: {s}\n", .{profile_name});
            return false;
        }

        if (ret != 0) {
            std.debug.print("Failed to get profile by name: {d}\n", .{ret});
            return false;
        }
    }

    std.debug.print("Found profile by profile name: {s}\n", .{profile_name});
    return maybeDeleteProfile(session, profile);
}

fn maybeDeleteProfile(
    session: nvapi.NvDRSSessionHandle,
    profile: nvapi.NvDRSProfileHandle,
) !bool {
    var profile_info: nvapi.NVDRS_PROFILE = try getProfileInfo(session, profile);

    if (profile_info.isPredefined == 1) {
        std.debug.print("Profile is predefined. Ignoring.\n", .{});
        return false;
    }

    const profile_name = try nvApiDecodeString(profile_info.profileName);
    std.debug.print("Deleting profile: {s}\n", .{profile_name});

    const ret = NvAPI_DRS_DeleteProfile(session, profile);
    if (ret != 0) {
        std.debug.print("Failed to delete profile: {d}\n", .{ret});
        return false;
    }

    std.debug.print("Deleted profile: {s}\n", .{profile_name});
    return true;
}

fn createProfileForAppPath(session: nvapi.NvDRSSessionHandle, app_path: []const u8) !void {
    const app_path_w: *nvapi.NvAPI_UnicodeString = try nvApiEncodeString(app_path);

    var profile_info: nvapi.NVDRS_PROFILE = .{
        .version = nvapi.NVDRS_PROFILE_VER,
        .isPredefined = 0,
        .profileName = undefined,
        .gpuSupport = .{ .ignored = 0 },
        .numOfApps = 0,
        .numOfSettings = 0,
    };
    @memcpy(&profile_info.profileName, app_path_w);

    var profile_handle: nvapi.NvDRSProfileHandle = undefined;

    {
        const ret = NvAPI_DRS_CreateProfile(session, &profile_info, &profile_handle);

        switch (ret) {
            0 => {},
            nvapi.NVAPI_PROFILE_NAME_IN_USE => {
                std.debug.print("Profile already exists: {s}\n", .{app_path});
                return error.ProfileAlreadyExists;
            },
            else => {
                std.debug.print("Failed to create profile: {d}\n", .{ret});
                return error.CreateProfileError;
            },
        }
    }

    var application: nvapi.NVDRS_APPLICATION = .{
        .version = nvapi.NVDRS_APPLICATION_VER,
        .isPredefined = 0,
        .ignored = 0,
        .appName = undefined,
        .userFriendlyName = undefined,
        .launcher = undefined,
        .fileInFolder = undefined,
        .commandLine = undefined,
    };

    @memcpy(&application.appName, app_path_w);
    @memcpy(&application.userFriendlyName, app_path_w);
    @memset(&application.launcher, 0);
    @memset(&application.fileInFolder, 0);
    @memset(&application.commandLine, 0);

    {
        const ret = NvAPI_DRS_CreateApplication(session, profile_handle, &application);

        if (ret != 0) {
            std.debug.print("Failed to create profile: {d}\n", .{ret});
            return error.CreateProfileError;
        }
    }

    // These values were discovered experimentally by manually creating a profile in the
    // NVIDIA control panel and reading the raw values that were set.
    // Disabling VSync and Frame rate limiter through the GUI results in these values being set.
    const settings: []const DriverSetting = &.{
        .{
            .id = nvapi.FRL_FPS_ID,
            .name = nvapi.FRL_FPS_STRING,
            .value = nvapi.FRL_FPS_DISABLED,
        },
        .{
            .id = nvapi.VSYNCMODE_ID,
            .name = nvapi.VSYNCMODE_STRING,
            .value = nvapi.VSYNCMODE_FORCEOFF,
        },
        .{
            .id = nvapi.VSYNCTEARCONTROL_ID,
            .name = nvapi.VSYNCTEARCONTROL_STRING,
            .value = nvapi.VSYNCTEARCONTROL_DISABLE,
        },
        .{
            .id = nvapi.VSYNCSMOOTHAFR_ID,
            .name = nvapi.VSYNCSMOOTHAFR_STRING,
            .value = nvapi.VSYNCSMOOTHAFR_OFF,
        },
    };

    for (settings) |setting| {
        try setSetting(session, profile_handle, setting);
    }
}

fn setSetting(
    session: nvapi.NvDRSSessionHandle,
    profile: nvapi.NvDRSProfileHandle,
    setting: DriverSetting,
) !void {
    var nv_setting: nvapi.NVDRS_SETTING = .{
        .version = nvapi.NVDRS_SETTING_VER,
        .settingId = @as(u32, @bitCast(setting.id)),
        .settingName = undefined,
        .settingType = nvapi.NVDRS_DWORD_TYPE,
        .settingLocation = nvapi.NVDRS_CURRENT_PROFILE_LOCATION,
        .isCurrentPredefined = 0,
        .isPredefinedValid = 0,
        .current = .{ .u32CurrentValue = @as(u32, @bitCast(setting.value)) },
        .predefined = .{ .u32PredefinedValue = @as(u32, @bitCast(setting.value)) },
    };

    @memcpy(&nv_setting.settingName, try nvApiEncodeString(setting.name));

    const ret = NvAPI_DRS_SetSetting(session, profile, &nv_setting);
    if (ret != 0) {
        std.debug.print("Failed to set setting: {s} = {d}\n", .{ setting.name, setting.value });
        return;
    }
    std.debug.print("Set: {s} = {d}\n", .{ setting.name, setting.value });
}

/// Converts a NvAPI UTF-16 string to a Zig string.
fn nvApiDecodeString(str: nvapi.NvAPI_UnicodeString) ![]const u8 {
    const all_with_sentinel: [*:0]const u16 = @ptrCast(&str);
    const before_sentinel: [:0]const u16 = std.mem.span(all_with_sentinel);

    return std.unicode.utf16leToUtf8Alloc(allocator, before_sentinel);
}

/// Converts a Zig ASCII string to a NvAPI UTF-16 string.
fn nvApiEncodeString(str: []const u8) !*nvapi.NvAPI_UnicodeString {
    const len = nvapi.NVAPI_UNICODE_STRING_MAX;

    var encoded: []u16 = try allocator.alloc(u16, len);
    @memset(encoded, 0);
    _ = try std.unicode.utf8ToUtf16Le(encoded, str);

    return encoded[0..len];
}
