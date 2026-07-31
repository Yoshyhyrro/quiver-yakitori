cmake_minimum_required(VERSION 3.21)
project(quiver_system C CXX)

# Force C23 Standard (ISO/IEC 9899:2024)
set(CMAKE_C_STANDARD 23)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Retrieve CHICKEN Scheme compiler flags via csc
execute_process(
    COMMAND csc -cflags
    OUTPUT_VARIABLE CHICKEN_CFLAGS_STR
    OUTPUT_STRIP_TRAILING_WHITESPACE
)

# Convert string into CMake list format for compile options
separate_arguments(CHICKEN_CFLAGS UNIX_COMMAND "${CHICKEN_CFLAGS_STR}")

execute_process(
    COMMAND csc -ldflags
    OUTPUT_VARIABLE CHICKEN_LDFLAGS_STR
    OUTPUT_STRIP_TRAILING_WHITESPACE
)
separate_arguments(CHICKEN_LDFLAGS UNIX_COMMAND "${CHICKEN_LDFLAGS_STR}")

execute_process(
    COMMAND csc -libs
    OUTPUT_VARIABLE CHICKEN_LIBS_STR
    OUTPUT_STRIP_TRAILING_WHITESPACE
)
separate_arguments(CHICKEN_LIBS UNIX_COMMAND "${CHICKEN_LIBS_STR}")

# Register C header source path
include_directories(src/c)

# 1. Compile C23 low-precision arithmetic library
add_library(quiver_c23 SHARED src/c/quiver_c23.c)
set_target_properties(quiver_c23 PROPERTIES C_STANDARD 23)

# 2. Transpile CHICKEN Scheme source into C using csc
add_custom_command(
    OUTPUT ${CMAKE_BINARY_DIR}/quiver_scheme.c
    COMMAND csc -to-stdout -emit-all-import-libraries ${CMAKE_CURRENT_SOURCE_DIR}/src/scheme/quiver.scm ${CMAKE_CURRENT_SOURCE_DIR}/src/scheme/quiver-experiment.scm > ${CMAKE_BINARY_DIR}/quiver_scheme.c
    DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/src/scheme/quiver.scm ${CMAKE_CURRENT_SOURCE_DIR}/src/scheme/quiver-experiment.scm
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Transpiling CHICKEN Scheme to C..."
)

# 3. Build executable target from transpiled Scheme wrapper
add_executable(quiver_bridge ${CMAKE_BINARY_DIR}/quiver_scheme.c)

# Apply csc compiler and linker flags to executable target
target_compile_options(quiver_bridge PRIVATE ${CHICKEN_CFLAGS})
target_link_options(quiver_bridge PRIVATE ${CHICKEN_LDFLAGS})
target_link_libraries(quiver_bridge PRIVATE quiver_c23 ${CHICKEN_LIBS})