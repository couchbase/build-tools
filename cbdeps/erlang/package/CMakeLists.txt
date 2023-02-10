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
    # Install copies various binaties into lib/erlang/bin, so we need to fix
    # their rpaths here too
    IF (UNIX AND NOT APPLE)
        EXECUTE_PROCESS (COMMAND bash -c
        "for f in $(find ${CMAKE_INSTALL_PREFIX}/lib/erlang/bin -type f);
        do
            if file $f | grep -q ELF && readelf -d $f | grep -e 'tinfo' -q; then
                patchelf --set-rpath '$ORIGIN/'$(realpath --relative-to $(dirname $f) ${CMAKE_INSTALL_PREFIX}/lib) $f;
            fi;
        done"
        )
    ENDIF ()
ENDIF ()
