cmake_minimum_required(VERSION 3.15)
project(test_project VERSION 0.1.0)
include(../../test_header.cmake)

corrosion_import_crate(MANIFEST_PATH rust/Cargo.toml OVERRIDE_CRATE_TYPE my_rust_lib=staticlib,cdylib)

add_executable(cpp-exe main.cpp)
target_link_libraries(cpp-exe PUBLIC my_rust_lib)

add_executable(cpp-exe-shared main.cpp)
target_link_libraries(cpp-exe-shared
        PUBLIC my_rust_lib-shared)
