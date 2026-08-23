cmake_minimum_required(VERSION 3.22.1)

project("enve-document-native" C CXX)

add_compile_options(
    "-ffile-prefix-map=${CMAKE_SOURCE_DIR}=."
    "-ffile-prefix-map=${CMAKE_BINARY_DIR}=."
    -Wno-builtin-macro-redefined
    -Wno-macro-redefined
    -D__DATE__="\"1970-01-01\""
    -D__TIME__="\"00:00:00\""
)

set(CMAKE_C_STANDARD 99)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -Wl,-z,max-page-size=16384")

set(USE_ENCRYPTION OFF CACHE BOOL "Enable libmobi DRM support" FORCE)
set(USE_LIBXML2 OFF CACHE BOOL "Use libxml2" FORCE)
set(USE_ZLIB OFF CACHE BOOL "Use zlib" FORCE)
set(USE_MINIZ ON CACHE BOOL "Use bundled miniz" FORCE)
set(BUILD_SHARED_LIBS ON CACHE BOOL "Build shared libraries" FORCE)

add_subdirectory(libmobi)

set_target_properties(mobi PROPERTIES
    VERSION ""
    SOVERSION ""
    C_VISIBILITY_PRESET default
)

add_library(enve_mobi SHARED enve_mobi_bridge.c)

target_include_directories(enve_mobi PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/libmobi/src
)

find_library(log-lib log)

target_link_libraries(enve_mobi PRIVATE
    mobi
    ${log-lib}
)

set(WHISPER_DIR ${CMAKE_CURRENT_SOURCE_DIR}/whisper)

set(GGML_NATIVE          OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP          OFF CACHE BOOL "" FORCE)
set(GGML_BUILD_TESTS     OFF CACHE BOOL "" FORCE)
set(GGML_BUILD_EXAMPLES  OFF CACHE BOOL "" FORCE)

include(FetchContent)
FetchContent_Declare(ggml SOURCE_DIR ${WHISPER_DIR}/ggml)
FetchContent_MakeAvailable(ggml)
foreach(ggml_target ggml ggml-base ggml-cpu)
    if(TARGET ${ggml_target})
        target_compile_options(${ggml_target} PRIVATE -O3 -march=armv8.2-a+fp16)
    endif()
endforeach()

add_library(whisper SHARED
    ${WHISPER_DIR}/whisper.cpp
    enve_whisper.cpp
)
target_compile_definitions(whisper PUBLIC GGML_USE_CPU)
target_compile_definitions(whisper PRIVATE WHISPER_VERSION="1.8.4")
target_compile_options(whisper PRIVATE -O3 -march=armv8.2-a+fp16)
target_include_directories(whisper PRIVATE
    ${WHISPER_DIR}
    ${WHISPER_DIR}/ggml/include
    ${WHISPER_DIR}/ggml/src
    ${WHISPER_DIR}/ggml/src/ggml-cpu
)
target_link_libraries(whisper ${log-lib} android ggml)