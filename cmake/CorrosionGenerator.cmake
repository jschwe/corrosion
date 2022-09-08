function(_cargo_metadata out manifest)
    get_property(
        RUSTC_EXECUTABLE
        TARGET Rust::Rustc PROPERTY IMPORTED_LOCATION
    )
    get_property(
        CARGO_EXECUTABLE
        TARGET Rust::Cargo PROPERTY IMPORTED_LOCATION
    )
    execute_process(
        COMMAND
            ${CMAKE_COMMAND} -E env
                CARGO_BUILD_RUSTC=${RUSTC_EXECUTABLE}
                ${CARGO_EXECUTABLE}
                    metadata
                        --manifest-path ${manifest}
                        --format-version 1
        OUTPUT_VARIABLE json
        COMMAND_ERROR_IS_FATAL ANY
    )

    set(${out} ${json} PARENT_SCOPE)
endfunction()

# Todo: this function could also probably be eliminated or reduced in size...
# Potentially this could also be moved to the corrosion side for code reuse with the other
# generator
# The Rust target triple and C target may mismatch (slightly) in some rare usecases.
# So instead of relying on CMake to provide System information, we parse the Rust target triple,
# since that is relevant for determining which libraries the Rust code requires for linking.
function(_generator_parse_platform manifest rust_version target_triple)

    # If the target_triple is a path to a custom target specification file, then strip everything
    # except the filename from `target_triple`.
    get_filename_component(target_triple_ext "${target_triple}" EXT)
    if(target_triple_ext)
        if(NOT (target_triple_ext STREQUAL ".json"))
            message(FATAL_ERROR "Failed to parse target triple `${target_triple}`. "
                "Invalid file extension `${target_triple_ext}` found."
                "Help: Custom Rust target-triples must be a path to a `.json` file. "
                "Other file extensions are not supported. Built-in target names may not contain a "
                "dot."
            )
        endif()
        get_filename_component(target_triple "${target_triple}"  NAME_WE)
    endif()

    # The vendor part may be left out from the target triple, and since `env` is also optional,
    # we determine if vendor is present by matching against a list of known vendors.
    set(known_vendors "apple"
        "esp" # riscv32imc-esp-espidf
        "fortanix"
        "kmc"
        "pc"
        "nintendo"
        "nvidia"
        "openwrt"
        "unknown"
        "uwp" # aarch64-uwp-windows-msvc
        "wrs" # e.g. aarch64-wrs-vxworks
        "sony"
        "sun"
    )
    # todo: allow users to add additional vendors to the list via a cmake variable.
    list(JOIN known_vendors "|" known_vendors_joined)
    # vendor is optional - We detect if vendor is present by matching against a known list of
    # vendors. The next field is the OS, which we assume to always be present, while the last field
    # is again optional and contains the environment.
    string(REGEX MATCH
            "^([a-z0-9_]+)-((${known_vendors_joined})-)?([a-z0-9_]+)(-([a-z0-9_]+))?$"
            whole_match
            "${target_triple}"
    )
    if((NOT whole_match) AND (NOT CORROSION_NO_WARN_PARSE_TARGET_TRIPLE_FAILED))
        message(WARNING "Failed to parse target-triple `${target_triple}`."
                        "Corrosion attempts to link required C libraries depending on the OS "
                        "specified in the Rust target-triple for Linux, MacOS and windows.\n"
                        "Note: If you are targeting a different OS you can surpress this warning by"
                        " setting the CMake cache variable "
                        "`CORROSION_NO_WARN_PARSE_TARGET_TRIPLE_FAILED`."
                        "Please consider opening an issue on github if you encounter this warning."
        )
    endif()

    set(target_arch "${CMAKE_MATCH_1}")
    set(target_vendor "${CMAKE_MATCH_3}")
    set(os "${CMAKE_MATCH_4}")
    set(env "${CMAKE_MATCH_6}")

    message(DEBUG "Parsed Target triple: arch: ${target_arch}, vendor: ${target_vendor}, "
            "OS: ${os}, env: ${env}")

    set(libs "")
    set(libs_debug "")
    set(libs_release "")

    set(is_windows FALSE)
    set(is_windows_msvc FALSE)
    set(is_windows_gnu FALSE)
    set(is_macos FALSE)

    if(os STREQUAL "windows")
        set(is_windows TRUE)

        if(NOT COR_NO_STD)
          list(APPEND libs "advapi32" "userenv" "ws2_32")
        endif()

        if(env STREQUAL "msvc")
            set(is_windows_msvc TRUE)

            if(NOT COR_NO_STD)
              list(APPEND libs_debug "msvcrtd")
              list(APPEND libs_release "msvcrt")
            endif()
        elseif(env STREQUAL "gnu")
            set(is_windows_gnu TRUE)

            if(NOT COR_NO_STD)
              list(APPEND libs "gcc_eh" "pthread")
            endif()
        endif()

        if(NOT COR_NO_STD)
          if(rust_version VERSION_LESS "1.33.0")
              list(APPEND libs "shell32" "kernel32")
          endif()

          if(rust_version VERSION_GREATER_EQUAL "1.57.0")
              list(APPEND libs "bcrypt")
          endif()
        endif()
    elseif(target_vendor STREQUAL "apple" AND os STREQUAL "darwin")
        set(is_macos TRUE)

        if(NOT COR_NO_STD)
           list(APPEND libs "System" "resolv" "c" "m")
        endif()
    elseif(os STREQUAL "linux")
        if(NOT COR_NO_STD)
           list(APPEND libs "dl" "rt" "pthread" "gcc_s" "c" "m" "util")
        endif()
    endif()

    set_source_files_properties(
        ${manifest}
        PROPERTIES
            CORROSION_PLATFORM_LIBS "${libs}"
            CORROSION_PLATFORM_LIBS_DEBUG "${libs_debug}"
            CORROSION_PLATFORM_LIBS_RELEASE "${libs_release}"

            CORROSION_PLATFORM_IS_WINDOWS "${is_windows}"
            CORROSION_PLATFORM_IS_WINDOWS_MSVC "${is_windows_msvc}"
            CORROSION_PLATFORM_IS_WINDOWS_GNU "${is_windows_gnu}"
            CORROSION_PLATFORM_IS_MACOS "${is_macos}"
    )
endfunction()

# Add targets for the static and/or shared libraries of the rust target.
# The generated byproduct names are returned via the `out_lib_byproducts` variable name.
# todo: this does not depend on JSON, so this may also be shared with the rust generator.
function(_corrosion_add_library_target manifest target_name has_staticlib has_cdylib out_lib_byproducts)

    if(NOT (has_staticlib OR has_cdylib))
        message(FATAL_ERROR "Unknown library type")
    endif()

    get_source_file_property(is_windows ${manifest} CORROSION_PLATFORM_IS_WINDOWS)
    get_source_file_property(is_windows_msvc ${manifest} CORROSION_PLATFORM_IS_WINDOWS_MSVC)
    get_source_file_property(is_windows_gnu ${manifest} CORROSION_PLATFORM_IS_WINDOWS_GNU)
    get_source_file_property(is_macos ${manifest} CORROSION_PLATFORM_IS_MACOS)

    # target file names
    string(REPLACE "-" "_" lib_name "${target_name}")

    if(is_windows_msvc)
        set(static_lib_name "${lib_name}.lib")
    else()
        set(static_lib_name "lib${lib_name}.a")
    endif()

    if(is_windows)
        set(dynamic_lib_name "${lib_name}.dll")
    elseif(is_macos)
        set(dynamic_lib_name "lib${lib_name}.dylib")
    else()
        set(dynamic_lib_name "lib${lib_name}.so")
    endif()

    if(MSVC)
        set(implib_name "${lib_name}.dll.lib")
    elseif(is_windows_gnu)
        set(implib_name "lib${lib_name}.dll.a")
    elseif(is_windows)
        message(FATAL_ERROR "Unknown windows environment - Can't determine implib name")
    endif()


    set(pdb_name "${lib_name}.pdb")

    set(byproducts)
    if(has_staticlib)
        list(APPEND byproducts ${static_lib_name})
    endif()

    if(has_cdylib)
        list(APPEND byproducts ${dynamic_lib_name})
        if(is_windows)
            list(APPEND byproducts ${implib_name})
        endif()
    endif()

    # Only shared libraries and executables have PDBs on Windows
    # We don't know why PDBs aren't generated for staticlibs...
    if(is_windows_msvc AND has_cdylib)
        list(APPEND byproducts "${pdb_name}")
    endif()

    if(has_staticlib)
        add_library(${target_name}-static STATIC IMPORTED GLOBAL)
        add_dependencies(${target_name}-static cargo-build_${target_name})

        corrosion_internal_set_imported_location("${target_name}-static" "IMPORTED_LOCATION"
                "${static_lib_name}" ${CMAKE_CONFIGURATION_TYPES})

        get_source_file_property(libs ${manifest} CORROSION_PLATFORM_LIBS)
        get_source_file_property(libs_debug ${manifest} CORROSION_PLATFORM_LIBS_DEBUG)
        get_source_file_property(libs_release ${manifest} CORROSION_PLATFORM_LIBS_RELEASE)

        if(libs)
            set_property(
                    TARGET ${target_name}-static
                    PROPERTY INTERFACE_LINK_LIBRARIES ${libs}
            )
            if(is_macos)
                set_property(TARGET ${target_name}-static
                        PROPERTY INTERFACE_LINK_DIRECTORIES "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/lib"
                        )
            endif()
        endif()

        # Todo: maybe guard this and only do it on multi config generators?
        if(libs_debug)
            set_property(
                    TARGET ${target_name}-static
                    PROPERTY INTERFACE_LINK_LIBRARIES_DEBUG ${libs_debug}
            )
        endif()

        if(libs_release)
            foreach(config "RELEASE" "MINSIZEREL" "RELWITHDEBINFO")
                set_property(
                        TARGET ${target_name}-static
                        PROPERTY INTERFACE_LINK_LIBRARIES_${config} ${libs_release}
                )
            endforeach()
        endif()
    endif()

    if(has_cdylib)
        add_library(${target_name}-shared SHARED IMPORTED GLOBAL)
        add_dependencies(${target_name}-shared cargo-build_${target_name})

        # Todo: (Not new issue): What about IMPORTED_SONAME and IMPORTED_NO_SYSTEM?
        corrosion_internal_set_imported_location("${target_name}-shared" "IMPORTED_LOCATION"
                "${dynamic_lib_name}" ${CMAKE_CONFIGURATION_TYPES})

        if(is_windows)
            corrosion_internal_set_imported_location("${target_name}-shared" "IMPORTED_IMPLIB"
                    "${implib_name}" ${CMAKE_CONFIGURATION_TYPES})
        endif()

        if(is_macos)
            set_property(TARGET ${target_name}-shared
                    PROPERTY INTERFACE_LINK_DIRECTORIES "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/lib"
                    )
        endif()
    endif()

    add_library(${target_name} INTERFACE)

    if(has_cdylib AND has_staticlib)
        if(BUILD_SHARED_LIBS)
            target_link_libraries(${target_name} INTERFACE ${target_name}-shared)
        else()
            target_link_libraries(${target_name} INTERFACE ${target_name}-static)
        endif()
    elseif(has_cdylib)
        target_link_libraries(${target_name} INTERFACE ${target_name}-shared)
    else()
        target_link_libraries(${target_name} INTERFACE ${target_name}-static)
    endif()

    set(${out_lib_byproducts} "${byproducts}" PARENT_SCOPE)

endfunction()

# todo: this also does not use JSON and could be shared...
function(_corrosion_add_bin_target workspace_manifest_path bin_name out_byproducts)
    if(NOT bin_name)
        message(FATAL_ERROR "No bin_name in _corrosion_add_bin_target for target ${target_name}")
    endif()

    set(byproducts "")
    string(REPLACE "-" "_" bin_name_underscore "${bin_name}")

    set(pdb_name "${bin_name_underscore}.pdb")

    get_source_file_property(is_windows ${workspace_manifest_path} CORROSION_PLATFORM_IS_WINDOWS)
    get_source_file_property(is_windows_msvc ${workspace_manifest_path} CORROSION_PLATFORM_IS_WINDOWS_MSVC)
    get_source_file_property(is_macos ${workspace_manifest_path} CORROSION_PLATFORM_IS_MACOS)

    if(is_windows_msvc)
        list(APPEND byproducts "${pdb_name}")
    endif()

    if(is_windows)
        set(bin_filename "${bin_name}.exe")
    else()
        set(bin_filename "${bin_name}")
    endif()

    list(APPEND byproducts "${bin_filename}")

    # Todo: This is compatible with the way corrosion previously exposed the bin name,
    # but maybe we want to prefix the exposed name with the package name?
    add_executable(${bin_name} IMPORTED GLOBAL)
    add_dependencies(${bin_name} cargo-build_${bin_name})

    if(is_macos)
        set_property(TARGET ${bin_name}
                PROPERTY INTERFACE_LINK_DIRECTORIES "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/lib"
                )
    endif()

    corrosion_internal_set_imported_location("${bin_name}" "IMPORTED_LOCATION"
                        "${bin_filename}" ${CMAKE_CONFIGURATION_TYPES})

    set(${out_byproducts} "${byproducts}" PARENT_SCOPE)
endfunction()


# Add targets (crates) of one package
function(_generator_add_package_targets workspace_manifest_path package_manifest_path package_name targets profile out_created_targets)
    # target types
    set(has_staticlib FALSE)
    set(has_cdylib FALSE)
    set(corrosion_targets "")


    # Add a custom target with the package (crate) name, as a convenience to build everything in a
    # crate.
    # Note: may cause problems if package_name == bin_name...
    #add_custom_target("${package_name}")
    # todo: verify on windows if this actually needs to be done...
    string(REPLACE "\\" "/" manifest_path "${package_manifest_path}")

    string(JSON targets_len LENGTH "${targets}")
    math(EXPR targets_len-1 "${targets_len} - 1")

    foreach(ix RANGE ${targets_len-1})
        #
        string(JSON target GET "${targets}" ${ix})
        string(JSON target_name GET "${target}" "name")
        string(JSON target_kind GET "${target}" "kind")
        string(JSON target_kind_len LENGTH "${target_kind}")
        string(JSON target_name GET "${target}" "name")

        math(EXPR target_kind_len-1 "${target_kind_len} - 1")
        set(kinds)
        foreach(ix RANGE ${target_kind_len-1})
            string(JSON kind GET "${target_kind}" ${ix})
            list(APPEND kinds ${kind})
        endforeach()

        if("staticlib" IN_LIST kinds OR "cdylib" IN_LIST kinds)
            if("staticlib" IN_LIST kinds)
                set(has_staticlib TRUE)
            endif()

            if("cdylib" IN_LIST kinds)
                set(has_cdylib TRUE)
            endif()
            set(lib_byproducts "")
            _corrosion_add_library_target("${manifest_path}" "${target_name}" "${has_staticlib}" "${has_cdylib}" lib_byproducts)

            _add_cargo_build(
                PACKAGE ${package_name}
                TARGET ${target_name}
                MANIFEST_PATH "${manifest_path}"
                PROFILE "${profile}"
                TARGET_KIND "lib"
                BYPRODUCTS "${lib_byproducts}"
            )
            list(APPEND corrosion_targets ${target_name})

        elseif("bin" IN_LIST kinds)
            set(bin_byproducts "")
            _corrosion_add_bin_target("${workspace_manifest_path}" "${target_name}" "bin_byproducts")

            _add_cargo_build(
                PACKAGE "${package_name}"
                TARGET "${target_name}"
                MANIFEST_PATH "${manifest_path}"
                PROFILE "${profile}"
                TARGET_KIND "bin"
                BYPRODUCTS "${bin_byproducts}"
            )
            list(APPEND corrosion_targets ${target_name})
        else()
            # ignore other kinds (like examples, tests, build scripts, ...)
        endif()
    endforeach()

    if(NOT corrosion_targets)
        message(DEBUG "No relevant targets found in package ${package_name} - Ignoring")
    endif()
    set(${out_created_targets} "${corrosion_targets}" PARENT_SCOPE)

endfunction()


function(_generator_add_cargo_targets)
    set(options "")
    set(one_value_args MANIFEST_PATH TARGET RUST_VERSION PROFILE)
    set(multi_value_args CRATES)
    cmake_parse_arguments(
        GGC
        "${options}"
        "${one_value_args}"
        "${multi_value_args}"
        ${ARGN}
    )

    _cargo_metadata(json ${GGC_MANIFEST_PATH})
    string(JSON packages GET "${json}" "packages")
    string(JSON workspace_members GET "${json}" "workspace_members")

    string(JSON pkgs_len LENGTH "${packages}")
    math(EXPR pkgs_len-1 "${pkgs_len} - 1")

    string(JSON ws_mems_len LENGTH ${workspace_members})
    math(EXPR ws_mems_len-1 "${ws_mems_len} - 1")

    _generator_parse_platform(${GGC_MANIFEST_PATH} ${GGC_RUST_VERSION} ${GGC_TARGET})

    set(created_targets "")
    foreach(ix RANGE ${pkgs_len-1})
        string(JSON pkg GET "${packages}" ${ix})
        string(JSON pkg_id GET "${pkg}" "id")
        string(JSON pkg_name GET "${pkg}" "name")
        string(JSON pkg_manifest_path GET "${pkg}" "manifest_path")
        string(JSON targets GET "${pkg}" "targets")

        string(JSON targets_len LENGTH "${targets}")
        math(EXPR targets_len-1 "${targets_len} - 1")
        foreach(ix RANGE ${ws_mems_len-1})
            string(JSON ws_mem GET "${workspace_members}" ${ix})
            if(ws_mem STREQUAL pkg_id AND ((NOT GGC_CRATES) OR (pkg_name IN_LIST GGC_CRATES)))
                message(DEBUG "Found ${targets_len} targets in package ${pkg_name}")

                _generator_add_package_targets("${GGC_MANIFEST_PATH}" "${pkg_manifest_path}" "${pkg_name}" "${targets}" "${GGC_PROFILE}" curr_created_targets)
                list(APPEND created_targets "${curr_created_targets}")
            endif()
        endforeach()
    endforeach()

    if(NOT created_targets)
        message(FATAL_ERROR "found no targets in ${pkgs_len} packages")
    else()
        message(DEBUG "Corrosion created the following CMake targets: ${curr_created_targets}")
    endif()
endfunction()
