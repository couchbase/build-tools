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

# ICU4C cmake module.
#
# This defines a well-formed "Modern CMake" imported target
# icu::icu4c, which has appropriate LOCATION and
# INCLUDE_DIRECTORIES properties.

get_filename_component(_pkgroot "${CMAKE_CURRENT_LIST_DIR}/../" ABSOLUTE)

# Only one include directory
set (icu4c_INCLUDE_DIRS "${_pkgroot}/include")

# Multiple libraries - each needs an IMPORTED CMake target, and we will
# create an INTERFACE wrapper for conveniently linking against all of
# them
set (icu4c_LIBRARIES)
set (icu4c_TARGETS)
foreach (libname uc i18n data)
    file (GLOB _sofile "${_pkgroot}/lib/libicu${libname}.so.*.*")
    if (NOT _sofile)
        message(FATAL_ERROR "Could not find ICU4C library libicu${libname}.so.*.*")
    endif ()
    list (APPEND icu4c_LIBRARIES ${_sofile})

    set (_target "icu::icu${libname}")
    list (APPEND icu4c_TARGETS ${_target})
    add_library(${_target} SHARED IMPORTED)
    set_target_properties(${_target} PROPERTIES IMPORTED_LOCATION ${_sofile})
    target_include_directories(${_target} INTERFACE ${icu4c_INCLUDE_DIRS})
endforeach (libname)

# Ensure all named files exist
set (_cmake_files ${icu4c_INCLUDE_DIRS} ${icu4c_LIBRARIES})
foreach(_cmake_file IN LISTS _cmake_files)
    if(NOT EXISTS "${_cmake_file}")
        message(FATAL_ERROR "icu4cConfig.cmake references the file
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

# Create wrapper interface.
add_library(icu::icu4c IMPORTED INTERFACE)
target_link_libraries(
    icu::icu4c INTERFACE ${icu4c_TARGETS}
)
target_include_directories(icu::icu4c INTERFACE ${icu4c_INCLUDE_DIRS})

message (STATUS "Found ICU4C libraries at ${icu4c_LIBRARIES}")
message (STATUS "Found ICU4C include files at ${icu4c_INCLUDE_DIRS}")
