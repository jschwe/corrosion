## Corrosion design

Corrosion is a CMake module that allows integrating Rust crates into the CMake build process.
The main goal is to allow integrating Rust code into existing C/C++ CMake projects.
This can be broadly split into the following two scenarios: 

A: Rust code is built as a library (static or dynamic) and linked into / with a C/C++ CMake binary target.
B: Rust code is built as a binary (or `cdylib` shared library) and C/C++ code is linked into it.

Scenario B can generally also be easily achieved by using cargo, `build.rs` build-scripts and,
when cross-compiling, setting necessary environment variables.
Corrosion nevertheless supports this, since cargo lacks "post-build" tasks, which can also be
an important part of existing CMake projects (e.g. packaging or signing steps).
Scenario A is expected to be the most common, with existing CMake projects using corrosion to
incrementally add Rust to their build.
Since there are quite a few rust libraries which in turn depend again on C or C++ libraries,
often using `build.rs` scripts to build such dependencies, corrosion also needs to support
Scenario B in conjunction with Scenario A.


### Constraints

- CMake: To make integrating corrosion into existing projects as seamless as possible, it should be 
         dependency-free, meaning we restrict ourselves to CMake and a rust toolchain. Since Rust is 
         a compiled language and cold build times can be significant, Corrosion should be implemented
         entirely in CMake. See the [Background on CMake] section for more details on the limitations 
         that CMake imposes.
- Reuse cargo: Corrosion is a volunteer project, with limited maintainer time capacity. This means
  that replacing / re-implementing cargo and directly invoking `rustc` is out of scope. 
  See also the section on [other build systems integrating rust code] for more technical considerations 
  in this regard.

[Background on CMake]: #background-on-cmake
[a]: #other-non-cargo-build-systems-integrating-rust-code

### Background on CMake

The CMake build system works in two phases. In the first phase (called configure), cmake parses the 
root `CMakeLists.txt` file (and recursively any included CMake files). During this process all 
CMake code is evaluated and CMake uses a [CMake Generator] to configure
a build directory with the build rules for a native build system. 
As an example `cmake -S. -Bbuild -GNinja` will use the Ninja Generator to create `build.ninja` rules
in the `build` directory, based on the parse CMake code.
The CMake language itself can only be used during this configure phase.
The actual build can be started by running `cmake --build build`, however, no CMake code is interpreted
during the build (unless one of the build-rules marks configuring as outdated and re-runs configure).

CMake does provide [Generator expressions],but they only allow doing a very limited set of operations at 
build-time. In General, almost all of Corrosions work must be done at configure time, since that is when
CMake code is run.
This includes defining build targets, build outputs and byproducts, dependency edges and **link dependencies**.

[CMake Generators]: https://cmake.org/cmake/help/latest/manual/cmake-generators.7.html
[Generator expressions]: https://cmake.org/cmake/help/latest/manual/cmake-generator-expressions.7.html

### Background on building rust code with cargo

The rust compiler `rustc` is shipped together with `cargo`, the default build system for rust projects. 
Rust projects are organized into [packages and crates]. Crates are the unit that `rustc` compiles.
It consists of a root source file, and any further source files that are (recursively) referenced.
There are different crate kinds:
- Libraries: with `lib`, `static`, `dylib` (shared with rust-ABI), `cdylib` (shared with C-ABI) artifacts
- Executables: with a `bin` type artifact

A package consists of one or more crates and is described by a `Cargo.toml` manifest. Each package may contain
at most one library (but with multiple artifact kinds possible) and an arbitrary number of executable crates.

The crate artifact kind is specified in the `Cargo.toml` manifest, but can also be overridden by passing a flag
to `rustc`. For the purpose of interfacing with C/C++ code, we are only interested in `static` and `cdylib` 
libraries, as well as `bin` executables. 
`static` library artifacts bundle the library **and all dependencies** into one `.a` static library artifact, that
can be used by the platforms standard linker.
`cdylib` artifacts will also bundle dependencies, unless the dependency is also a shared library. 
The standard `lib` target (also often called `rlib` for rust-lib), will not bundle the dependencies, but the 
rust project has not committed to a stabilized format. There is [an issue](https://github.com/rust-lang/rust/issues/73632)
and a [Pre-RFC](https://internals.rust-lang.org/t/pre-rfc-stabilize-a-version-of-the-rlib-format/17558) discussing
stabilization of the `rlib` format, in a way that linkers could directly consume `rlib`s, but progress seems to have
stalled.
If the rlib format does eventually get stabilized, this will change some of the design constrains and allow us to 
solve some of the limitations corrosion currently has around linking rust static libraries into C code.

The cargo build system is also responsible for managing and resolving dependencies, picking suitable versions
based on semantic versioning, as well as resolving the set of enabled features on a package. 

[packages and crates]: https://doc.rust-lang.org/book/ch07-01-packages-and-crates.html

#### `build.rs` build scripts

Packages can define `build.rs` [build scripts](https://doc.rust-lang.org/cargo/reference/build-scripts.html),
which will be built and run by `cargo` before building the crate. Build scripts can perform arbitrary actions,
which most commonly are probing for the presence of native libraries, building C/C++ code and passing information
to cargo by printing to stdout. This commonly includes telling cargo to link against a library, or adding
flags to the linker command line.
This behavior is obviously problematic in the context of `CMake`, which expects link dependencies and flags to
be computable at configure time. 


#### Further reading

[Libs and Metadata]: https://rustc-dev-guide.rust-lang.org/backend/libs-and-metadata.html
[Rust Linkage]: https://doc.rust-lang.org/reference/linkage.html

### Other Non-cargo build systems integrating Rust code

There are a number of third-party build systems which support building Rust without cargo, including
[bazel], [buck], [buck2] and [build.gn]. All of these build systems are maintained by large corporations
and want to be in charge of the whole build process. 
This means that build rules need to be defined for **every crate in the dependency tree**, including 
rules either replacing `build.rs` scripts or modeling the behavior in the native build system.
This process works well, but since the amount of work scales with the number of supported crates,
this model is not feasible for corrosion.
Re-implementing cargo features like feature resolving, dependency resolving and fetching in CMake would
both be a huge effort, and also come with side effects like relying on specficis of the `rlib` format
(which is not yet stable, see the section on [building rust code with cargo](#background-on-building-rust-code-with-cargo))

[bazel]: https://bazelbuild.github.io/rules_rust/
[buck]: https://buck.build/rule/rust_library.html
[buck2]: https://buck2.build/docs/prelude/rules/rust/
[build.gn]: https://google.github.io/comprehensive-rust/chromium/adding-third-party-crates/generating-gn-build-rules.html

### Corrosion Architecture

Instead of requiring manual definition of build rules for every crate, corrosion wants to automatically create 
appropriate build targets and rules, based on the metadata cargo provides.
As already mentioned before, replacing `cargo` is out of scope for corrosion, since the additional complexity would be 
beyond what is possible given limited maintainer capacity. For the sake of argument, corrosion would need to support:

- Dependency management, including downloading dependencies from `crates.io` and picking suitable versions
- [Feature resolving] and resolving the dependency tree (including optional dependencies)
- Either support build-scripts, or maintain CMake replacements modeling build-script side-effects.

[Feature resolving]: https://doc.rust-lang.org/cargo/reference/features.html

On a high level, corrosion can be split into the following parts

1. Finding Rust and resolving the available rust toolchains
2. Determine which crates to import
3. Add CMake targets for the crates from step one, corresponding build rules and define output artifacts
4. Relocation rules to place the output artifacts at standard locations expected by user provided `OUTPUT_DIRECTORY` variables
5. Utility functions to customize the build rules
6. Utility functions providing functionality of builtin CMake functions for the imported rust targets (like `install` or `link_libraries`)

#### Finding Rust

Before we can do anything else, we should first try to find and resolve the available rust toolchains. 
Rust can be managed by the system package manager, but on most developer systems it will be managed by [rustup].
`rustup` is a tool that manages Rust toolchains, including installing and updating. It also works as a proxy
executable, meaning that for rustup managed installations the `cargo` and `rustc` executables in `PATH` will
actually point to `rustup`. Based on which [toolchain overrides] are set, rustup will then invoke the respective
cargo toolchain. 

In CMake toolchains are generally configured once during the configure phase and are then fixed (since CMake code
often will set flags depending on the resolved compiler version).
For corrosion this means that we will resolve the rust toolchain `rustup` proxies to, based on the user configuration
at `configure` time. This compiler will then be fixed, and corrosion will not use the `rustup` proxy for the actual 
building.
As a convenience, corrosion creates a cache variable with a list of available toolchains, so users can conveniently
change the rust toolchain with a cmake TUI or GUI configuration tool.

During this stage corrosion will also configure a dummy Rust project to determine the native library dependencies
of the standard library on the given system. 
See section [Linking native libraries rust code depends on](#linking-native-libraries-rust-code-depends-on)
for more details.

Rust is a cross-compiler, so when using CMake to cross-compile, corrosion makes an attempt to guess the correct
target triple based on the CMake configuration. This is however just a best-effort approach and corrosion requires
the user to explicitly set the target triple when it can't be sure of the appropriate rust target triple.

[rustup]: https://rust-lang.github.io/rustup/
[toolchain overrides]: https://rust-lang.github.io/rustup/overrides.html
[CMake find modules]: https://cmake.org/cmake/help/book/mastering-cmake/chapter/Finding%20Packages.html

#### Importing crates

Before creating CMake build targets for our rust crates, we first need to determine which crates to import.
Instead of parsing `Cargo.toml` manifest files, corrosion uses `cargo metadata` which provides information
in a stable JSON format. `cargo metadata` can provide information about a whole [workspace], which allows us
to import multiple packages from a workspace at once. 
CMake has supported JSON natively since CMake 3.19, which allows us to parse the metadata output somewhat conveniently
in `CorrosionGenerator.cmake`. 

The process here is pretty straight forward and roughly can be summarized as iterating over all packages in the 
workspace and adding CMake targets for all crates that are `cdylib`, `static` or `bin` targets. 
During this process crates can also be filtered out, or the crate-type can be overriden.

[workspace]: https://doc.rust-lang.org/book/ch14-03-cargo-workspaces.html

#### Adding CMake targets

For each crate that we import, we also need a corresponding CMake target and rules to build the artifacts.
We can define our library and executable targets with the standard `add_library()` and `add_executable()` 
functions, with the [`IMPORTED`] option. This will tell CMake that these targets are built in some opaque
way, not built-in to CMake. This is required, since CMake does not support rust targets out of the box. 
We separately define a custom build target `cargo-build_${target_name}`, containing the rule for building 
the target artifact(s), and use `add_dependencies` to make the `IMPORTED` target depend on our custom build rule. 

No build-system is static, and of course also Rust crates can be configured in multiple ways, including: 
- cargo feature flags
- build profile (debug, release, custom)
- environment variables
- rustflags (flags passed to the `rustc` compiler invocation)
- linker flags
- ...

In traditional CMake such options were often controlled by the current value of variables at the time of creating
the target. In modern CMake, [target properties] are the preferred way to set such build options, which gives the user
more control and makes user code often more readable.
Corrosion supports this as much as possible and exposes the options listed above on a per-target basis. 
The target property names themselves are not part of the public API, and intended to be only set by corrosion utility
functions, such as `corrosion_set_features()`. 
One downside of supporting such target properties, is that they will (out of necessity) be set by the user after
corrosion has imported the crates. In most cases we can delay evaluating the options to generate time, by using 
[generator expressions]. One major drawback is that generator expressions, besides being limited in what can be achieved,
are not very readable and challenging to debug, since they will only be evaluated at generate time.
However, being able to import a whole workspace and easily setting custom options on a per-target basis makes this
corrosion-internal complexity a worth-while tradeoff. 


[`IMPORTED`]: https://cmake.org/cmake/help/latest/prop_tgt/IMPORTED.html
[target properties]: todo
[generator expressions]: https://cmake.org/cmake/help/latest/manual/cmake-generator-expressions.7.html

#### The custom build rule

The rust artifacts are built by the `_cargo-build_${target_name}` [custom target],
that executes `cargo rustc` in a modified environment with flags depending on the
configuration and target properties. 
We use `cargo rustc` over `cargo build`, since it allows us to pass custom rustflags
to only **the final** `rustc` invocation, which can be important especially for linker flags.
The environment is modified to contain certain environment variables, mainly ensuring that
`cc-rs` or `cmake-rs` in build-scripts are configured to use the same compiler as CMake.

Using a custom target has one downside: It will be considered to be always out-of-date and
rerun on every build. In terms of build-time this might be negligible, since cargo will
not rebuild if nothing changed, but it will pollute the output with cargo status messages. 
This could be improved by switching to [`add_custom_command`], but this requires being able
to specify the output artifacts of the command, which we currently are not able to do.
The background here is that in custom commands or custom targets, specifying the output artifacts
(or byproducts) of a command may only use a limited subset of generator expressions.
Unfortunately corrosion is using the `$<TARGET_PROPERTY>` generator expression, which is unsupported
in this context, as part of the target directory. 
The target property evaluation was added to support the [hostbuild] target property, so removing it
would be a breaking change.
When the cargo option [--artifact-dir] (or similar) get stabilized, then we could solve
this issue without a breaking change, since we could tell cargo to copy the artifacts 
into a specific directory. 

[custom target]: https://cmake.org/cmake/help/latest/command/add_custom_target.html
[`add_custom_command`]: https://cmake.org/cmake/help/latest/command/add_custom_command.html
[hostbuild]: #hostbuild
[artifact-dir]: https://github.com/rust-lang/cargo/issues/6790


#### Relocating the target artifacts to the expected directories

CMake specifies a number of `OUTPUT_DIRECTORY` variables / properties (e.g. [RUNTIME_OUTPUT_DIRECTORY]),
which allow users to specify where a build output should be placed.
Since corrosion is creating `IMPORTED` targets, we hence also need to re-implement this functionality
to match users expectations. 
The logic required to uplift the relevant target artifacts to the expected directory can't be expressed
via generator expressions.
Instead, we use a new CMake feature, which allows [deferring the execution of CMake code] until the end of scope.
This allows us to schedule a function to run at the end of the file that instructed corrosion to import crates,
where we know that user code will have already set the target properties on our imported targets.
This enables us to evaluate the `OUTPUT_DIRECTORY` target properties **at configure time** 

Todo: Why _corrosion_set_imported_location and post-build command two seperate functions. 


[RUNTIME_OUTPUT_DIRECTORY]: https://cmake.org/cmake/help/latest/prop_tgt/RUNTIME_OUTPUT_DIRECTORY.html
[deferring the execution of CMake code]: https://cmake.org/cmake/help/latest/command/cmake_language.html#defer

#### Linking native libraries rust code depends on

When linking a Rust static library into a CMake shared library or executable, the linker invocation is controlled by CMake rules.
Rust code can depend on native libraries, which of course need to be added to the linker invocation. 
Native libraries may be (conditionally) added when compiling Rust code which is annotated with `#[link(name = "")]`,
or by `build.rs` build scripts. Rust can be configured to print the list of libraries and linker arguments after the build,
however, CMake expects to know the link libraries at configure time!

What users naturally can do, is inspect the list and write the result into their CMake. This works of course, but 
the feasibility depends heavily on how often the required libraries might change and is bad user experience. 
To at least make pure Rust projects (using the standard library) work out of the box, corrosion **builds** a dummy
hello-world Rust project during CMake configure time and parses the required linker arguments from `rustc`s output. 
The amount of time required to do this is negligible and this approach is much more reliable than hand-maintaining
a target-specific list of link libraries. 

Despite the restrictions I mentioned before, there is a way to parse and pass a complete list of link libraries
to the linker invocation! Linkers, due to historic reasons, support so-called response files, which enables reading
linker arguments from a file! If we specify a response file as a linker argument, then we can wrap the cargo invocation
in a portable CMake script, parse the `rustc` output and write the link libraries into the response file, for the 
linker to consume. This was tried out [in #472](https://github.com/corrosion-rs/corrosion/pull/472), but it turns
out to not be portable due to current limitations in CMake. See the discussion in the 
[upstream CMake issue](https://gitlab.kitware.com/cmake/cmake/-/issues/26011) for ways forward. 
To summarize, on Linux, when using `lld` (which does not require the linked libraries to be ordered), this approach
works great - to support `ld` and other order dependant linkers, a (minor) CMake change would be needed, but this
requires someone to champion it upstream. For this feature to work with the MSVC Generator further CMake changes 
might be necessary since CMake apparently passes link arguments via a project configuration file, 
in which context response files are not supported. 


#### `Rustc` invoking the Linker

The previous section discussed issues when CMake rules invoke the linker.
When building Rust executable or shared libraries however, rustc will invoke the linker.
CMakes `target_link_libraries()` obviously won't work for imported targets, so corrosion needs to provide
an alternative ( `corrosion_link_libraries()`), which re-implements the necessary behavior. 
Additionally, corrosion also needs to override the default linker that rustc chooses to ensure linking works
out of the box in major use-cases:

If C++ code is linked into the target, then we want to use the C++ compiler as the linker driver,
so that the (correct) C++ standard library implementation is linked. 
Additionally, when cross-compiling, `rustc` by default does not select a suitable linker driver for many targets
(defaulting to just `cc` in many cases), which corrosion can easily fix by setting the target c or c++ compiler as the
linker driver.
The major exception here is when using the `msvc` compiler, where no compiler driver is used when linker, hence corrosion
does not override the linker choice. 
If corrosion does happen to get the linker choice wrong (which could happen on niche targets), users can use 
`corrosion_set_linker()` to override the default choice

#### Shared library Soname

....


#### hostbuild

One common usecase is to not only compile code for the target architecture, but as part of the 
build also compile targets for the host architecture (e.g. a code or bindings generator). 
Since this usecase is quite common, especially in embedded, corrosion has added a hostbuild option,
which allows compiling a target for the host architecture instead of cross-compiling it.
CMake natively does not support this (when building C/C++ projects), and recommends configuring 
another CMake project for the host architecture inside the current CMake build. 
This can be quite cumbersome, and since building Rust is outside the traditional CMake build rules, 
supporting compilation of Rust executables for the host target is not too much effort and 
boils down to the following:

- Defining a target property to control whether to force compilation for the host target
- Link with the standard rust libraries for the host instead of for the target.
- Uplift the target artifact from the **host**-target directory
- Mixing C/C++ with the rust executable is explicitly out of scope


#### FFI bindings

When mixing C/C++ with Rust, language bindings are required so that both sides have a shared understanding of
datastructures and functions that may be shared across the language boundary.
There are several tools in rust, which allow generating such bindings, among others [`bindgen`], [`cbindgen`]
and [`cxx`].

`bindgen` can generate Rust definitions out of C/C++ header files. This works very well from Rust `build.rs` scripts,
since the bindings are consumed only by Rust code, and there is no real need for corrosion to help here. 

`cbindgen` can create C header files from Rust code. This means that we need to ensure that these header files are
generated before they are used in a C/C++ build rule, and hence need to specify such a build dependency rule (in CMake).
Corrosion provides the `corrosion_experimental_cbindgen()` utility function, which can
- build the `cbindgen` tool from source if not installed
- Add a CMake target which runs cbindgen and generates the bindings (based on the users configuration)
- Add the necessary build dependencies on consumers 
- Specify when the bindings need to be regenerated (`cbindgen --depfile` outputs a depfile)
- Support `install`-ing header files

See the [corrosion documentations section on cbindgen](https://corrosion-rs.github.io/corrosion/ffi_bindings.html#cbindgen-integration)
for more details on the usage.

While it is possible to run `cbindgen` from `build.rs` scripts instead of using the utility function corrosion provides,
there are some downsides / considerations: 

- This requires  adding a build dependency from the consumer to whichever target generates the binding via 
  `build.rs` (as a side-effect). (This can make the build slower / less parallel)
- Since the header files rules are not known to CMake, this might lead to harder to debug errors if the build
  dependencies are specified wrong.
- installing the header files requires custom rules

Therefore, we  recommend using the function `corrosion_experimental_cbindgen()` to generate bindings with
cbindgen.

`cxx` generates **bidirectional** bindings, which means that it generates both Rust and C code.
See the documentation of [corrosion_add_cxxbridge](https://corrosion-rs.github.io/corrosion/ffi_bindings.html#cxx-integration)
for usage details. 
Similar to `cbindgen`, we also recommend to prefer this utility function over using `build.rs`, to ensure that build
rules and order are correct. When linking a C/C++ library, which requires `cxx` bindings into a Rust executable, using
corrosions helper function is not just recommended, but required, since generating C source files from `build.rs` 
would lead to a cyclic dependency.

[`bindgen`]: https://github.com/rust-lang/rust-bindgen
[`cbindgen`]: https://github.com/mozilla/cbindgen
[`cxx`]: https://cxx.rs/

### Testing

Unit-testing is not really applicable to a project like corrosion, hence we mainly use integration tests, i.e. 
configuring and building test CMake projects, testing different features of corrosion. 
To keep this portable, corrosion uses the CMake built-in test framework `ctest`.
Ctest build fixtures allow us to split each integration test project into 4 different tests:
configuring, building, running the test executable and clean-up.

Corrosion relies on automated testing in CI to run the tests in a number of different configurations, 
testing the different host platforms, target architectures, CMake Generators, rust versions and corrosion features.
The Matrix size obviously explodes quickly, so we limit the size by not testing all possible combinations,
but trying to ensure everything is covered in a reasonable way. E.g. we only test the oldest supported
rust version, and additionally run some tests with the latest stable or nightly version in CI.
