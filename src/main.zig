const std = @import("std");
const windows = std.os.windows;
const yazap = @import("yazap");

const nvidia = @import("nvidia.zig");
const nvapi = nvidia.nvapi;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var allocator = gpa.allocator();

// These fields should be u32, but translate-C converts hex values to signed integers
// and it's easier to @bitCast them to u32 at the point of use
const DriverSetting = struct {
    id: i32,
    name: []const u8,
    value: i32,
};

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

pub fn main() !u8 {
    const Arg = yazap.Arg;
    var app = yazap.App.init(allocator, "nv-stutter-fix", "Fixes stuttering on NVIDIA GPUs during DRM-protected video playback in Electron");
    var cmd = app.rootCommand();
    try cmd.addArg(Arg.singleValueOption("delete-app-path", null, "Full path to the application executable for which to DELETE the Nvidia settings profile"));
    try cmd.addArg(Arg.singleValueOption("create-app-path", null, "Full path to the application executable for which to CREATE the Nvidia settings profile"));
    const args = app.parseProcess() catch {
        try app.displayHelp();
        return 1;
    };

    var delete_path: ?[]const u8 = args.getSingleValue("delete-app-path");
    var create_path: ?[]const u8 = args.getSingleValue("create-app-path");

    const nvapi_dll = try loadDll();

    const NvAPI_DRS_CreateSession = try nvidia.queryNvFunc(nvapi_dll, "NvAPI_DRS_CreateSession");
    const NvAPI_DRS_DestroySession = try nvidia.queryNvFunc(nvapi_dll, "NvAPI_DRS_DestroySession");
    const NvAPI_DRS_LoadSettings = try nvidia.queryNvFunc(nvapi_dll, "NvAPI_DRS_LoadSettings");
    const NvAPI_DRS_SaveSettings = try nvidia.queryNvFunc(nvapi_dll, "NvAPI_DRS_SaveSettings");

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
        const deleted = try deleteProfileByAppPath(nvapi_dll, drs_session, app_path);
        if (!deleted) {
            _ = try deleteProfileByName(nvapi_dll, drs_session, app_path);
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
        _ = try deleteProfileByName(nvapi_dll, drs_session, app_path);

        std.debug.print("Creating new profile for {s}\n", .{app_path});

        createProfileForAppPath(nvapi_dll, drs_session, app_path) catch {
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

pub fn loadDll() !windows.HMODULE {
    const dll = "nvapi64.dll";
    const dll_w = std.unicode.utf8ToUtf16LeStringLiteral(dll);
    const nvapi_module_opt = windows.kernel32.LoadLibraryW(dll_w);

    if (nvapi_module_opt == null) {
        std.debug.print("Failed to load {s}: {any}\n", .{ dll, windows.kernel32.GetLastError() });
        return error.FailedToLoadNvApi;
    }

    const nvapi_module = nvapi_module_opt.?;
    return nvapi_module;
}

fn getProfileInfo(
    nvapi_dll: windows.HMODULE,
    session: nvapi.NvDRSSessionHandle,
    profile: nvapi.NvDRSProfileHandle,
) !nvapi.NVDRS_PROFILE_V1 {
    var info: nvapi.NVDRS_PROFILE_V1 = undefined;
    info.version = nvapi.NVDRS_PROFILE_VER1;

    const NvAPI_DRS_GetProfileInfo = try nvidia.queryNvFunc(nvapi_dll, "NvAPI_DRS_GetProfileInfo");
    const ret = NvAPI_DRS_GetProfileInfo(session, profile, &info);

    if (ret != 0) {
        std.debug.print("Failed to get profile: {d}\n", .{ret});
        return error.GetProfileError;
    }

    return info;
}

fn deleteProfileByAppPath(
    nvapi_dll: windows.HMODULE,
    session: nvapi.NvDRSSessionHandle,
    path: []const u8,
) !bool {
    const path_w: *nvapi.NvAPI_UnicodeString = try nvidia.encodeString(path);

    var profile: nvapi.NvDRSProfileHandle = undefined;

    var app: nvapi.NVDRS_APPLICATION_V1 = undefined;
    app.version = nvapi.NVDRS_APPLICATION_VER_V1;

    {
        const NvAPI_DRS_FindApplicationByName = try nvidia.queryNvFunc(nvapi_dll, "NvAPI_DRS_FindApplicationByName");
        const ret = NvAPI_DRS_FindApplicationByName(session, path_w, &profile, @ptrCast(&app));

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
    return maybeDeleteProfile(nvapi_dll, session, profile);
}

fn deleteProfileByName(
    nvapi_dll: windows.HMODULE,
    session: nvapi.NvDRSSessionHandle,
    profile_name: []const u8,
) !bool {
    const profile_name_w: *nvapi.NvAPI_UnicodeString = try nvidia.encodeString(profile_name);

    var profile: nvapi.NvDRSProfileHandle = undefined;

    {
        const NvAPI_DRS_FindProfileByName = try nvidia.queryNvFunc(nvapi_dll, "NvAPI_DRS_FindProfileByName");
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
    return maybeDeleteProfile(nvapi_dll, session, profile);
}

fn maybeDeleteProfile(
    nvapi_dll: windows.HMODULE,
    session: nvapi.NvDRSSessionHandle,
    profile: nvapi.NvDRSProfileHandle,
) !bool {
    var profile_info: nvapi.NVDRS_PROFILE_V1 = try getProfileInfo(nvapi_dll, session, profile);

    if (profile_info.isPredefined == 1) {
        std.debug.print("Profile is predefined. Ignoring.\n", .{});
        return false;
    }

    const profile_name = try nvidia.decodeString(profile_info.profileName);
    std.debug.print("Deleting profile: {s}\n", .{profile_name});

    const NvAPI_DRS_DeleteProfile = try nvidia.queryNvFunc(nvapi_dll, "NvAPI_DRS_DeleteProfile");
    const ret = NvAPI_DRS_DeleteProfile(session, profile);
    if (ret != 0) {
        std.debug.print("Failed to delete profile: {d}\n", .{ret});
        return false;
    }

    std.debug.print("Deleted profile: {s}\n", .{profile_name});
    return true;
}

fn createProfileForAppPath(
    nvapi_dll: windows.HMODULE,
    session: nvapi.NvDRSSessionHandle,
    app_path: []const u8,
) !void {
    const app_path_w: *nvapi.NvAPI_UnicodeString = try nvidia.encodeString(app_path);

    var profile_info: nvapi.NVDRS_PROFILE_V1 = .{
        .version = nvapi.NVDRS_PROFILE_VER1,
        .isPredefined = 0,
        .profileName = undefined,
        .gpuSupport = 0,
        .numOfApps = 0,
        .numOfSettings = 0,
    };
    @memcpy(&profile_info.profileName, app_path_w);

    var profile_handle: nvapi.NvDRSProfileHandle = undefined;

    {
        const NvAPI_DRS_CreateProfile = try nvidia.queryNvFunc(nvapi_dll, "NvAPI_DRS_CreateProfile");
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

    var application: nvapi.NVDRS_APPLICATION_V1 = .{
        .version = nvapi.NVDRS_APPLICATION_VER_V1,
        .isPredefined = 0,
        .appName = undefined,
        .userFriendlyName = undefined,
        .launcher = undefined,
    };

    @memcpy(&application.appName, app_path_w);
    @memcpy(&application.userFriendlyName, app_path_w);
    @memset(&application.launcher, 0);

    {
        const NvAPI_DRS_CreateApplication = try nvidia.queryNvFunc(nvapi_dll, "NvAPI_DRS_CreateApplication");
        const ret = NvAPI_DRS_CreateApplication(session, profile_handle, @ptrCast(&application));

        if (ret != 0) {
            std.debug.print("Failed to create profile: {d}\n", .{ret});
            return error.CreateProfileError;
        }
    }

    for (settings) |setting| {
        try setSetting(nvapi_dll, session, profile_handle, setting);
    }
}

fn setSetting(
    nvapi_dll: windows.HMODULE,
    session: nvapi.NvDRSSessionHandle,
    profile: nvapi.NvDRSProfileHandle,
    setting: DriverSetting,
) !void {
    var nv_setting: nvapi.NVDRS_SETTING_V1 = .{
        .version = nvapi.NVDRS_SETTING_VER1,
        .settingId = @as(u32, @bitCast(setting.id)),
        .settingName = undefined,
        .settingType = nvapi.NVDRS_DWORD_TYPE,
        .settingLocation = nvapi.NVDRS_CURRENT_PROFILE_LOCATION,
        .isCurrentPredefined = 0,
        .isPredefinedValid = 0,
        .current = .{ .u32CurrentValue = @as(u32, @bitCast(setting.value)) },
        .predefined = .{ .u32PredefinedValue = @as(u32, @bitCast(setting.value)) },
    };

    @memcpy(&nv_setting.settingName, try nvidia.encodeString(setting.name));

    const NvAPI_DRS_SetSetting = try nvidia.queryNvFunc(nvapi_dll, "NvAPI_DRS_SetSetting");
    const ret = NvAPI_DRS_SetSetting(session, profile, &nv_setting);
    if (ret != 0) {
        std.debug.print("Failed to set setting: {s} = {d}\n", .{ setting.name, setting.value });
        return;
    }
    std.debug.print("Set: {s} = {d}\n", .{ setting.name, setting.value });
}
