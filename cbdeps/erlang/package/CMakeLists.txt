# Invoke Erlang 'Install' to update the Erlang ROOTDIR - interface is
# different on Windows vs. Unix, as are the files we need to copy
IF (WIN32)
    FILE (GLOB ERTS_DIR "erts-*")
    FILE (
        COPY Install.ini lib releases "${ERTS_DIR}"
        DESTINATION "${CMAKE_INSTALL_PREFIX}"
    )
    FILE (TO_NATIVE_PATH "${CMAKE_INSTALL_PREFIX}" NATIVE_INSTALL_PREFIX)
    EXECUTE_PROCESS (
        COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/Install.exe"
            -s "${NATIVE_INSTALL_PREFIX}"
    )
    FILE (REMOVE "${CMAKE_INSTALL_PREFIX}/Install.ini")
ELSE ()
    FILE (COPY bin lib DESTINATION "${CMAKE_INSTALL_PREFIX}")
    EXECUTE_PROCESS (
        COMMAND "${CMAKE_INSTALL_PREFIX}/lib/erlang/Install"
            -minimal "${CMAKE_INSTALL_PREFIX}/lib/erlang"
    )
ENDIF ()
