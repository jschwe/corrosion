# Quick Start

You can add corrosion to your project via the `FetchContent` CMake module or one of the other methods
described in TODO: crosslink.
Afterwards you can import Rust targets defined in a `Cargo.toml` manifest file by using
`corrosion_import_crate`. This will add CMake targets with names matching the crate names defined
in the Cargo.toml manifest. These targets can then subsequently be used, e.g. to link the imported
target into a regular C/C++ target.

```cmake
include(FetchContent)

FetchContent_Declare(
    Corrosion
    GIT_REPOSITORY https://github.com/corrosion-rs/corrosion.git
    GIT_TAG v0.3.2 # Optionally specify a commit hash, version tag or branch here
)
# Set any global configuration variables such as `Rust_TOOLCHAIN` before this line!
FetchContent_MakeAvailable(Corrosion)

# Import targets defined in a package or workspace manifest `Cargo.toml` file
corrosion_import_crate(MANIFEST_PATH rust-lib/Cargo.toml)

add_executable(your_cool_cpp_bin main.cpp)
target_link_libraries(your_cool_cpp_bin PUBLIC rust-lib)
```

Please see the Usage chapter for a complete discussion of possible configuration options to
finetune the behavior.  TODO: cross-link