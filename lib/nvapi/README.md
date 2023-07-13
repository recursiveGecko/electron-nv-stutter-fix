Vendored dependencies in this directory were obtained from: 

https://download.nvidia.com/XFree86/nvapi-open-source-sdk/

Home page: https://developer.nvidia.com/rtx/path-tracing/nvapi/get-started

# Changes

Minor modification to the header files were required to enable the project to build correctly.

## nvapi.h

* Collapsed `NVDRS_PROFILE_V1.gpuSupport` bitfield into `NvU32`

* Added names for union fields of `NVDRS_SETTING_V1` (`predefined` and `current`)
