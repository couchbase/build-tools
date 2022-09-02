FILE(MAKE_DIRECTORY ${CMAKE_INSTALL_PREFIX}/bin)

# Determine which directory to copy libs from
IF (CMAKE_BUILD_TYPE STREQUAL "Debug" AND
    IS_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/lib/Debug")
    SET (LIB_DIR Debug)
ELSE()
    SET (LIB_DIR Release)
ENDIF ()

IF (WIN32)
    FILE (GLOB _v8libs "lib/${LIB_DIR}/*.dll")
    FOREACH (_v8lib ${_v8libs})
        FILE (COPY "${_v8lib}" DESTINATION "${CMAKE_INSTALL_PREFIX}/bin")
    ENDFOREACH ()
ELSE (WIN32)
    FILE (COPY lib/${LIB_DIR}/
          DESTINATION "${CMAKE_INSTALL_PREFIX}/lib")
ENDIF (WIN32)
