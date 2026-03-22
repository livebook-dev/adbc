cmake_minimum_required(VERSION 3.16 FATAL_ERROR)
project(adbc_nif C CXX)

if(NOT DEFINED PRIV_DIR)
    if(DEFINED MIX_APP_PATH AND NOT "${MIX_APP_PATH}" STREQUAL "")
        if(WIN32)
            string(REPLACE "\\" "/" MIX_APP_PATH "${MIX_APP_PATH}")
        endif()
        set(PRIV_DIR "${MIX_APP_PATH}/priv")
    else()
        set(PRIV_DIR "${CMAKE_CURRENT_SOURCE_DIR}/priv")
    endif()
endif()
message(STATUS "Using PRIV_DIR: ${PRIV_DIR}")

if(DEFINED ERTS_INCLUDE_DIR AND NOT "${ERTS_INCLUDE_DIR}" STREQUAL "")
    set(ERTS_INCLUDE_DIR "${ERTS_INCLUDE_DIR}")
else()
    set(ERTS_INCLUDE_DIR_ONE_LINER "erl -noshell -eval \"io:format('~ts/erts-~ts/include/', [code:root_dir(), erlang:system_info(version)]), halt().\"")
    if(WIN32)
        execute_process(COMMAND powershell -command "${ERTS_INCLUDE_DIR_ONE_LINER}" OUTPUT_VARIABLE ERTS_INCLUDE_DIR)
    else()
        execute_process(COMMAND bash -c "${ERTS_INCLUDE_DIR_ONE_LINER}" OUTPUT_VARIABLE ERTS_INCLUDE_DIR)
    endif()
    set(ERTS_INCLUDE_DIR "${ERTS_INCLUDE_DIR}")
endif()
message(STATUS "Using ERTS_INCLUDE_DIR: ${ERTS_INCLUDE_DIR}")

if(UNIX AND APPLE)
    set(CMAKE_SHARED_LINKER_FLAGS "-undefined dynamic_lookup")
endif()

set(CMAKE_CXX_STANDARD 17)
if(DEFINED ENV{TARGET_GCC_FLAGS})
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} $ENV{TARGET_GCC_FLAGS}")
endif()

message(STATUS "CMAKE_TOOLCHAIN_FILE: ${CMAKE_TOOLCHAIN_FILE}")

find_package(AdbcDriverManager REQUIRED PATHS "${PRIV_DIR}/" NO_DEFAULT_PATH)
include_directories("${PRIV_DIR}/include")

if(WIN32)
    string(REPLACE "\\" "/" C_SRC "${C_SRC}")
    string(REPLACE "\\" "/" NANOARROW_SRC "${NANOARROW_SRC}")
endif()
set(SOURCE_FILES
    "${C_SRC}/nif_utils.cpp"
    "${C_SRC}/adbc_nif.cpp"
)

include_directories("${ERTS_INCLUDE_DIR}")
include_directories("${ADBC_SRC}/c/include")
include_directories("${NANOARROW_SRC}")

add_library(adbc_nif SHARED
    "${NANOARROW_SRC}/nanoarrow.c"
    "${NANOARROW_SRC}/flatcc.c"
    "${NANOARROW_SRC}/nanoarrow_ipc.c"
    ${SOURCE_FILES}
)
target_link_libraries(adbc_nif PUBLIC AdbcDriverManager::adbc_driver_manager_shared)
install(
    TARGETS adbc_nif
    RUNTIME DESTINATION "${PRIV_DIR}"
)

set_target_properties(adbc_nif PROPERTIES PREFIX "")
if(NOT WIN32)
    set_target_properties(adbc_nif PROPERTIES SUFFIX ".so")
endif()
set_target_properties(adbc_nif PROPERTIES
    INSTALL_RPATH_USE_LINK_PATH TRUE
    BUILD_WITH_INSTALL_RPATH TRUE
)

if(WIN32)
    file(GLOB adbc_dll_loader_sources CONFIGURE_DEPENDS "${C_SRC}/dll_loader/*.cpp")
    add_library(adbc_dll_loader SHARED ${adbc_dll_loader_sources})
    set_property(TARGET adbc_dll_loader PROPERTY CXX_STANDARD 17)
    target_include_directories(adbc_dll_loader PUBLIC ${ERTS_INCLUDE_DIR})
    install(
        TARGETS adbc_dll_loader
        DESTINATION "${PRIV_DIR}"
    )
    SET_TARGET_PROPERTIES(adbc_dll_loader PROPERTIES PREFIX "")
endif()

if(UNIX AND NOT APPLE)
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wall -Wno-unused-but-set-variable -Wno-reorder")
    set_target_properties(adbc_nif PROPERTIES INSTALL_RPATH "\$ORIGIN/lib")
elseif(UNIX AND APPLE)
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wall -Wno-reorder-ctor")
    set(CMAKE_SHARED_LINKER_FLAGS "-flat_namespace -undefined dynamic_lookup")
    set_target_properties(adbc_nif PROPERTIES INSTALL_RPATH "@loader_path/lib")
endif()

if(WIN32)
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} /bigobj /wd4996 /wd4267 /wd4068")
else()
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fPIC")
    if (CMAKE_BUILD_TYPE STREQUAL "Debug")
        set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -O0 -g3")
    else()
        set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -O3")
    endif()
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wno-unused-function -Wno-sign-compare -Wno-unused-parameter -Wno-missing-field-initializers -Wno-deprecated-declarations")
endif()
