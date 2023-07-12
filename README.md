# electron-nv-stutter-fix

Playing back DRM-encrypted media in Electron can lead to unbearable frame drops and stuttering on certain setups with NVIDIA GPUs using VRR monitors.

In most cases these issues can be resolved by disabling VSync and Maximum Frame Rate in Nvidia control panel settings.

## Usage

This CLI application automatically applies NVIDIA Control Panel changes to fix the stuttering.

```shell
# Deletes the custom application profile for the given application
electron-nv-stutter-fix.exe --delete-app-path "c:\\users\\user\\appdata\\local\\multiviewerforf1\\app-0.0.0\\multiviewer for f1.exe"

# Creates the custom application profile the given application
electron-nv-stutter-fix.exe --create-app-path "c:\\users\\user\\appdata\\local\\multiviewerforf1\\app-0.0.0\\multiviewer for f1.exe"
```

In applications that use an auto-update mechanism which installs the app in versioned directories, `--delete-app-path` and `--create-app-path` can be 
combined during the auto-update process to delete the old Nvidia application profile and replace it with a new one.

## Compatibility

Windows x64 with NVIDIA drivers installed.
