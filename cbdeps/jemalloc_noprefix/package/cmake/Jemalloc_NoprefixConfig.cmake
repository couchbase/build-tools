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

# Jemalloc_Noprefix cmake module. This defines well-formed "Modern
# CMake" imported target Jemalloc::noprefix, which has appropriate
# LOCATION and INCLUDE_DIRECTORIES properties. It will also set the
# variable Jemalloc_Noprefix_FOUND to 1.

include(SelectLibraryConfigurations)

get_filename_component(_pkgroot "${CMAKE_CURRENT_LIST_DIR}/../" ABSOLUTE)

set (Jemalloc_Noprefix_FOUND 1)
set (_jemalloc_includedirs "${_pkgroot}/include")
if (WIN32)
    # On Windows also need to add the 'msvc_compat' subdir to include
    # path to provide an implementation of <strings.h>.
    list(APPEND _jemalloc_includedirs ${_jemalloc_includedirs}/msvc_compat)
endif ()

if (WIN32)
    set (_jemalloc_lib_debug "${_pkgroot}/Debug/lib/jemalloc_noprefixd.lib")
    set (_jemalloc_lib_release "${_pkgroot}/Release/lib/jemalloc_noprefix.lib")
else ()
    if (APPLE)
        set (_ext dylib)
    else ()
        set (_ext so)
    endif ()
    set (_jemalloc_lib_debug "${_pkgroot}/lib/libjemalloc_noprefixd.${_ext}")
    set (_jemalloc_lib_release "${_pkgroot}/lib/libjemalloc_noprefix.${_ext}")
endif ()

# Ensure all named files exist
set (_cmake_files ${_jemalloc_includedirs})
foreach(_cmake_config release debug)
    list(APPEND _cmake_files "${_jemalloc_lib_${_cmake_config}}")
endforeach()
foreach(_cmake_file IN LISTS _cmake_files)
    if(NOT EXISTS "${_cmake_file}")
        message(FATAL_ERROR "Jemalloc_NoprefixConfig.cmake references the file
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

# Create "Modern CMake" imported targets for same.
add_library(Jemalloc::noprefix SHARED IMPORTED)
set_target_properties(Jemalloc::noprefix
    PROPERTIES
    IMPORTED_CONFIGURATIONS "Release;Debug"
    IMPORTED_LOCATION_DEBUG ${_jemalloc_lib_debug}
    IMPORTED_LOCATION_RELEASE ${_jemalloc_lib_release})
target_include_directories(Jemalloc::noprefix INTERFACE
    ${_jemalloc_includedirs})
