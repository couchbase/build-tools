#
#     Copyright 2024 Couchbase, Inc.
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.

# Jemalloc cmake module.
# This module sets the following variables in your  project::
#
#  Jemalloc_FOUND - true
#  Jemalloc_LIBRARIES, path to selected (Debug / Release) library variant
#      (.so on Linux, .dylib on macOS, .lib on Windows)
#  Jemalloc_INCLUDE_DIRS, where to find the jemalloc headers
#
# It also defines well-formed "Modern CMake" imported target
# Jemalloc::jemalloc, which has appropriate LOCATION and
# INCLUDE_DIRECTORIES properties.

include(SelectLibraryConfigurations)

get_filename_component(_pkgroot "${CMAKE_CURRENT_LIST_DIR}/../" ABSOLUTE)

set (Jemalloc_FOUND 1)

set (Jemalloc_INCLUDE_DIRS "${_pkgroot}/include")
if (WIN32)
    # On Windows also need to add the 'msvc_compat' subdir to include
    # path to provide an implementation of <strings.h>.
    list(APPEND Jemalloc_INCLUDE_DIRS ${Jemalloc_INCLUDE_DIRS}/msvc_compat)
endif ()

if (WIN32)
    set (Jemalloc_LIBRARY_DEBUG "${_pkgroot}/Debug/lib/jemallocd.lib")
    set (Jemalloc_DLL_DEBUG "${_pkgroot}/Debug/bin/jemallocd.dll")
    set (Jemalloc_LIBRARY_RELEASE "${_pkgroot}/Release/lib/jemalloc.lib")
    set (Jemalloc_DLL_RELEASE "${_pkgroot}/Release/bin/jemalloc.dll")
else ()
    if (APPLE)
        set (_ext dylib)
    else ()
        set (_ext so)
    endif ()
    set (Jemalloc_LIBRARY_DEBUG "${_pkgroot}/lib/libjemallocd.${_ext}")
    set (Jemalloc_LIBRARY_RELEASE "${_pkgroot}/lib/libjemalloc.${_ext}")
endif ()

# Ensure all named files exist
set (_cmake_files ${Jemalloc_INCLUDE_DIRS})
foreach(_cmake_config RELEASE DEBUG)
    list(APPEND _cmake_files "${Jemalloc${_cmake_target}_LIBRARY_${_cmake_config}}")
endforeach()
foreach(_cmake_file IN LISTS _cmake_files)
    if(NOT EXISTS "${_cmake_file}")
        message(FATAL_ERROR "JemallocConfig.cmake references the file
   \"${_cmake_file}\"
but this file does not exist.  Possible reasons include:
* The file was deleted, renamed, or moved to another location.
* An install or uninstall procedure did not complete successfully.
* The installation package was faulty and contained
    \"${CMAKE_CURRENT_LIST_FILE}\"
but not all the files it references.
")
    endif()
endforeach()

# Set Jemalloc_LIBRARIES to the correct Debug / Release lib based on the
# current BUILD_TYPE
select_library_configurations(Jemalloc)

# Create "Modern CMake" imported targets for same.
add_library(Jemalloc::jemalloc SHARED IMPORTED)
if (WIN32)
    set_target_properties(Jemalloc::jemalloc PROPERTIES
        IMPORTED_CONFIGURATIONS "Release;Debug"
        IMPORTED_LOCATION_DEBUG ${Jemalloc_DLL_DEBUG}
        IMPORTED_LOCATION_RELEASE ${Jemalloc_DLL_RELEASE}
        IMPORTED_IMPLIB_DEBUG ${Jemalloc_LIBRARY_DEBUG}
        IMPORTED_IMPLIB_RELEASE ${Jemalloc_LIBRARY_RELEASE})
else ()
    set_target_properties(Jemalloc::jemalloc PROPERTIES
        IMPORTED_CONFIGURATIONS "Release;Debug"
        IMPORTED_LOCATION_DEBUG ${Jemalloc_LIBRARY_DEBUG}
        IMPORTED_LOCATION_RELEASE ${Jemalloc_LIBRARY_RELEASE})
endif ()
target_include_directories(Jemalloc::jemalloc INTERFACE
    ${Jemalloc_INCLUDE_DIRS})
