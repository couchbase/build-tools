FILE (COPY bin/jeprof DESTINATION "${CMAKE_INSTALL_PREFIX}/bin")
IF (WIN32)
    # Different directories for Release and Debug builds.
    # Only copy bin/ dir with .dlls. Stub libraries (.lib) in lib/ are
    # not copied into install dir as only needed at compile-time.
    IF (CMAKE_BUILD_TYPE STREQUAL "Debug")
        SET (libdir Debug/bin)
    ELSE ()
        SET (libdir Release/bin)
    ENDIF ()
ELSE()
    SET (libdir lib)
ENDIF()

FILE (COPY ${libdir} DESTINATION "${CMAKE_INSTALL_PREFIX}")

SET_PROPERTY (GLOBAL APPEND PROPERTY CBDEPS_PREFIX_PATH "${CMAKE_CURRENT_SOURCE_DIR}")
