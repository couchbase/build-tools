# Simple script to create a ConfigVersion.cmake file for a project
# Invoke with:
#
#   cmake -D PACKAGE=Mypackage -D VERSION=X.Y.Z \
#       -D OUTPUT=/path/to/cmake -P create_config_version.cmake
#
# This will create `MypackageConfigVersion.cmake` in the specified
# OUTPUT directory. VERSION should be just the (preferably semver)
# version, not including -BLD_NUM.
#
# By default this will specify "SameMajorVersion" compatibility. Pass
# `-D COMPATIBILITY=AnyNewerVersion` to switch this. Legal values are
# described in the CMake documentation:
# https://cmake.org/cmake/help/latest/module/CMakePackageConfigHelpers.html#command:write_basic_package_version_file


cmake_minimum_required (VERSION 3.19)

if (NOT DEFINED PACKAGE)
    message (FATAL_ERROR "PACKAGE not defined")
endif ()
if (NOT DEFINED VERSION)
    message (FATAL_ERROR "VERSION not defined")
endif ()
if (NOT DEFINED OUTPUT)
    message (FATAL_ERROR "OUTPUT not defined")
endif ()
if (NOT DEFINED COMPATIBILITY)
    set (COMPATIBILITY SameMajorVersion)
endif ()

include (CMakePackageConfigHelpers)
write_basic_package_version_file (
    "${OUTPUT}/${PACKAGE}ConfigVersion.cmake"
    VERSION ${VERSION}
    COMPATIBILITY ${COMPATIBILITY}
)
