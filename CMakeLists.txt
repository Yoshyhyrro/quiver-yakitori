cmake_minimum_required(VERSION 3.21)
project(quiver_system C CXX)

# Force C23 Standard (ISO/IEC 9899:2024)
set(CMAKE_C_STANDARD 23)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Fetch Chicken Scheme flags using chicken-config
execute_process(
    COMMAND chicken-config --cflags
    OUTPUT_VARIABLE CHICKEN_CFLAGS
    OUTPUT_STRIP_TRAILING_WHITESPACE
)

execute_process(
    COMMAND chicken-config --libs
    OUTPUT_VARIABLE CHICKEN_LIBRARIES
    OUTPUT_STRIP_TRAILING_WHITESPACE
)

execute_process(
    COMMAND chicken-config --include-dir
    OUTPUT_VARIABLE CHICKEN_INCLUDE_DIR
    OUTPUT_STRIP_TRAILING_WHITESPACE
)

include_directories(${CHICKEN_INCLUDE_DIR} src/c)

# 1. Compile C23 low-precision arithmetic library
add_library(quiver_c23 SHARED src/c/quiver_c23.c)
set_target_properties(quiver_c23 PROPERTIES C_STANDARD 23)

# 2. Transpile Chicken Scheme source into C using csc
add_custom_command(
    OUTPUT ${CMAKE_BINARY_DIR}/quiver_scheme.c
    COMMAND csc -to-stdout -emit-all-import-libraries ${CMAKE_CURRENT_SOURCE_DIR}/src/scheme/quiver.scm > ${CMAKE_BINARY_DIR}/quiver_scheme.c
    DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/src/scheme/quiver.scm
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Transpiling Chicken Scheme to C..."
)

# 3. Build shared library from generated Scheme C wrapper
add_library(quiver_bridge SHARED ${CMAKE_BINARY_DIR}/quiver_scheme.c)

/* Explicitly append header directory to the bridge target */
target_include_directories(quiver_bridge PRIVATE ${CHICKEN_INCLUDE_DIR} src/c)

target_link_libraries(quiver_bridge PRIVATE quiver_c23 ${CHICKEN_LIBRARIES})