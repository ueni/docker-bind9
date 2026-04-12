#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s nullglob

ROOTFS="/rootfs"
SYSROOT="/"
COPY_APP=1
COPY_PYTHON=0
COPY_NSS=0
COPY_SSL=0
COPY_ZONEINFO=0
STRIP_ELF=0
USE_LDD_FAST=0
DRY_RUN=0
CLEAN_OUTPUT=0
QUIET=0
VERBOSE=0
PYTHON_MODE="minimal"

BIN_LIST_FILE=""
MANIFEST_FILE=""

INPUTS=()
PYTHON_HINT_ARGS=()
PYTHON_HINTS=()

declare -A COPIED_PATHS=()
declare -A VISITED_ELF=()
declare -A RESOLVED_NEEDED_CACHE=()
declare -A DEFAULT_LIB_DIRS_SEEN=()
declare -A PYTHON_HINTS_SEEN=()
DEFAULT_LIB_DIRS=()

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf 'WARN: %s\n' "$*" >&2
}

log_info() {
    (( QUIET )) && return 0
    printf '%s\n' "$*" >&2
}

log_debug() {
    (( QUIET )) && return 0
    (( VERBOSE )) || return 0
    printf 'DEBUG: %s\n' "$*" >&2
}

usage() {
    cat <<'EOF_USAGE'
Usage:
  copy-rootfs.sh [OPTIONS] [ENTRY ...]

Create a minimal rootfs by copying input executables/scripts/shared libraries
and their runtime files into an output directory.

Entries may be provided directly and/or with a file list.
This tool expects trusted inputs. It parses ELF metadata and script shebangs.
Do not use it on untrusted artifacts.

Options:
  -o, --output-dir DIR     Destination rootfs directory (default: /rootfs)
      --sysroot DIR        Source sysroot to read from (default: /)
  -f, --file FILE          Read inputs from FILE, one entry per line
  -p, --python             Copy Python runtime for detected/specified interpreters
  -P, --python-bin PATH    Add a Python interpreter to copy runtime for
      --python-mode MODE   Python tree copy mode: minimal|full (default: minimal)
  -n, --nss                Copy NSS/runtime name-service files and backend libs
  -s, --ssl                Copy CA bundles / SSL config if present
  -z, --zoneinfo           Copy timezone data
  -S, --strip              Strip copied ELF files with strip --strip-unneeded
  -L, --ldd-fast           Resolve ELF dependencies via ldd fast path

                           Use only when all of the following are true:
                           - inputs are trusted
                           - binaries are native for the running host
                           - --sysroot is /
                           - you want host loader resolution semantics

                           This is faster and follows the host loader
                           configuration such as ld.so.cache, ld.so.conf,
                           and multiarch library selection.

                           Do not use for:
                           - untrusted inputs
                           - foreign/cross-architecture binaries
                           - alternate sysroots / offline rootfs analysis

      --no-copy-app        Do not copy non-ELF script inputs themselves
      --manifest FILE      Write copied entries with SHA-256 to FILE
      --dry-run            Print actions without modifying the output directory
      --clean              Remove output directory before copying
  -v, --verbose            Enable verbose logging
  -q, --quiet              Suppress non-error output
  -h, --help               Show this help and exit

Entry formats:
  auto:VALUE               Auto-detect input type (default if no prefix is given)
  bin:VALUE                Resolve VALUE as command/binary/script input
  lib:VALUE                Resolve VALUE as shared library input

VALUE formats:
  - absolute path, e.g. /usr/bin/curl or /usr/lib/libz.so.1
  - command name, e.g. curl              (for auto:/bin:)
  - SONAME, e.g. libz.so.1               (for lib:)

Input file format:
  - One entry per line
  - Empty lines are ignored
  - Lines starting with '#' are ignored

Manifest format:
  type<TAB>sha256<TAB>path

  - regular files: SHA-256 of file content
  - symlinks:      SHA-256 of symlink target string
  - directories:   '-'

Examples:
  copy-rootfs.sh -o /tmp/rootfs /usr/bin/curl /usr/bin/grep
  copy-rootfs.sh -o /tmp/rootfs -L /usr/bin/octave-cli
  copy-rootfs.sh -o /tmp/rootfs lib:libz.so.1 lib:/usr/lib/libssl.so.3
  copy-rootfs.sh -o /tmp/rootfs -f apps.txt
  copy-rootfs.sh -o /tmp/rootfs --sysroot /mnt/sysroot bin:/usr/bin/bash
  copy-rootfs.sh -o /tmp/rootfs -p -P /usr/bin/python3 /app/my_script.py
EOF_USAGE
}

require_cmd() {
    local cmd
    for cmd in "$@"; do
        command -v -- "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
    done
}

validate_rootfs() {
    [[ -n "$ROOTFS" ]] || die "output directory must not be empty"
    [[ "$ROOTFS" != "/" ]] || die "refusing to use / as output directory"
}

validate_sysroot() {
    [[ -n "$SYSROOT" ]] || die "sysroot must not be empty"
    [[ -d "$SYSROOT" ]] || die "sysroot directory not found: $SYSROOT"
    SYSROOT="$(cd -- "$SYSROOT" && pwd -P)"
}

require_absolute_logical() {
    local logical="$1"
    [[ "$logical" == /* ]] || die "expected absolute logical path, got: $logical"
}

logical_to_fs() {
    local logical="$1"
    require_absolute_logical "$logical"
    if [[ "$SYSROOT" == "/" ]]; then
        printf '%s\n' "$logical"
    else
        printf '%s\n' "$SYSROOT$logical"
    fi
}

fs_to_logical() {
    local fs_path="$1"
    if [[ "$SYSROOT" == "/" ]]; then
        printf '%s\n' "$fs_path"
        return 0
    fi

    case "$fs_path" in
        "$SYSROOT")
            printf '/\n'
            ;;
        "$SYSROOT"/*)
            printf '%s\n' "${fs_path#"$SYSROOT"}"
            ;;
        *)
            die "path escapes sysroot: $fs_path"
            ;;
    esac
}

normalize_logical_path() {
    local path="$1"
    local part
    local last_index
    local -a parts=()

    require_absolute_logical "$path"

    IFS='/' read -r -a parts <<< "$path"
    local -a normalized=()

    for part in "${parts[@]}"; do
        case "$part" in
            ""|.) ;;
            ..)
                if ((${#normalized[@]} > 0)); then
                    last_index=$((${#normalized[@]} - 1))
                    unset "normalized[$last_index]"
                fi
                ;;
            *)
                normalized+=("$part")
                ;;
        esac
    done

    if ((${#normalized[@]} == 0)); then
        printf '/\n'
        return 0
    fi

    printf '/%s\n' "$(IFS=/; printf '%s' "${normalized[*]}")"
}

logical_symlink_target() {
    local logical="$1"
    local srcfs target logical_target

    require_absolute_logical "$logical"
    srcfs="$(logical_to_fs "$logical")"
    [[ -L "$srcfs" ]] || return 0

    target="$(readlink -- "$srcfs")"
    [[ -n "$target" ]] || return 0

    if [[ "$target" == /* ]]; then
        normalize_logical_path "$target"
        return 0
    fi

    logical_target="$(dirname -- "$logical")/$target"
    normalize_logical_path "$logical_target"
}

manifest_hash_for_dst() {
    local logical="$1"
    local dstfs="$ROOTFS$logical"
    local target

    if [[ -L "$dstfs" ]]; then
        target="$(readlink -- "$dstfs")"
        printf '%s' "$target" | sha256sum | awk '{print $1}'
        return 0
    fi

    if [[ -f "$dstfs" ]]; then
        sha256sum -- "$dstfs" | awk '{print $1}'
        return 0
    fi

    printf '%s\n' "-"
}

manifest_type_for_dst() {
    local logical="$1"
    local dstfs="$ROOTFS$logical"

    if [[ -L "$dstfs" ]]; then
        printf '%s\n' "symlink"
    elif [[ -f "$dstfs" ]]; then
        printf '%s\n' "file"
    elif [[ -d "$dstfs" ]]; then
        printf '%s\n' "dir"
    else
        printf '%s\n' "other"
    fi
}

record_manifest() {
    local logical="$1"
    local type hash

    [[ -n "$MANIFEST_FILE" ]] || return 0
    (( DRY_RUN )) && return 0

    type="$(manifest_type_for_dst "$logical")"
    hash="$(manifest_hash_for_dst "$logical")"

    printf '%s\t%s\t%s\n' "$type" "$hash" "$logical" >> "$MANIFEST_FILE"
}

mkdir_p() {
    local dir="$1"
    if (( DRY_RUN )); then
        log_info "mkdir -p -- $dir"
        return 0
    fi
    mkdir -p -- "$dir"
}

remove_output_dir() {
    if (( DRY_RUN )); then
        log_info "rm -rf -- $ROOTFS"
        return 0
    fi
    rm -rf -- "$ROOTFS"
}

is_elf_logical() {
    local logical="$1"
    local srcfs
    srcfs="$(logical_to_fs "$logical")"
    [[ -f "$srcfs" ]] || return 1
    readelf -h -- "$srcfs" >/dev/null 2>&1
}

should_strip() {
    (( STRIP_ELF ))
}

strip_fs_if_requested() {
    local fs_path="$1"
    should_strip || return 0
    readelf -h -- "$fs_path" >/dev/null 2>&1 || return 0
    if (( DRY_RUN )); then
        log_info "strip --strip-unneeded -- $fs_path"
        return 0
    fi
    strip --strip-unneeded -- "$fs_path"
}

copy_regular_logical_file() {
    local logical="$1"
    local srcfs dstfs

    srcfs="$(logical_to_fs "$logical")"
    dstfs="$ROOTFS$logical"

    mkdir_p "$(dirname -- "$dstfs")"
    if (( DRY_RUN )); then
        log_info "cp -a -- $srcfs $dstfs"
    else
        cp -a -- "$srcfs" "$dstfs"
        strip_fs_if_requested "$dstfs"
    fi
    record_manifest "$logical"
}

copy_symlink_logical() {
    local logical="$1"
    local srcfs dstfs target

    srcfs="$(logical_to_fs "$logical")"
    dstfs="$ROOTFS$logical"
    target="$(readlink -- "$srcfs")"

    mkdir_p "$(dirname -- "$dstfs")"
    if (( DRY_RUN )); then
        log_info "ln -snf -- $target $dstfs"
    else
        ln -snf -- "$target" "$dstfs"
    fi
    record_manifest "$logical"
}

copy_dir_recursive() {
    local logical="$1"
    local srcfs rel sublogical

    srcfs="$(logical_to_fs "$logical")"
    [[ -d "$srcfs" ]] || return 0

    mkdir_p "$ROOTFS$logical"
    record_manifest "$logical"

    while IFS= read -r -d '' rel; do
        rel="${rel#./}"
        [[ -n "$rel" ]] || continue
        sublogical="${logical%/}/$rel"
        copy_logical_path "$sublogical"
    done < <(
        cd -- "$srcfs"
        find . -mindepth 1 -print0
    )
}

copy_logical_path() {
    local logical="$1"
    local srcfs realfs real_logical target_logical

    require_absolute_logical "$logical"
    [[ -n "${COPIED_PATHS[$logical]+x}" ]] && return 0

    srcfs="$(logical_to_fs "$logical")"
    [[ -e "$srcfs" || -L "$srcfs" ]] || return 0

    COPIED_PATHS["$logical"]=1

    if [[ -L "$srcfs" ]]; then
        copy_symlink_logical "$logical"
        target_logical="$(logical_symlink_target "$logical" || true)"
        if [[ -n "$target_logical" && "$target_logical" != "$logical" ]]; then
            copy_logical_path "$target_logical"
        fi
        realfs="$(readlink -f -- "$srcfs" 2>/dev/null || true)"
        if [[ -n "$realfs" ]]; then
            real_logical="$(fs_to_logical "$realfs")"
            if [[ "$real_logical" != "$logical" && "$real_logical" != "$target_logical" ]]; then
                copy_logical_path "$real_logical"
            fi
        fi
        return 0
    fi

    if [[ -d "$srcfs" ]]; then
        copy_dir_recursive "$logical"
        return 0
    fi

    copy_regular_logical_file "$logical"
}

python_skip_rel() {
    local rel="$1"

    case "$rel" in
        */__pycache__|*/__pycache__/*|__pycache__|__pycache__/*) return 0 ;;
        */test|*/test/*|test|test/*) return 0 ;;
        */tests|*/tests/*|tests|tests/*) return 0 ;;
        */idlelib|*/idlelib/*|idlelib|idlelib/*) return 0 ;;
        */tkinter|*/tkinter/*|tkinter|tkinter/*) return 0 ;;
        */turtledemo|*/turtledemo/*|turtledemo|turtledemo/*) return 0 ;;
        */ensurepip|*/ensurepip/*|ensurepip|ensurepip/*) return 0 ;;
    esac
    return 1
}

copy_tree_with_filter() {
    local logical_root="$1"
    local mode="$2"
    local srcfs rel sublogical

    srcfs="$(logical_to_fs "$logical_root")"
    [[ -d "$srcfs" ]] || return 0

    mkdir_p "$ROOTFS$logical_root"
    record_manifest "$logical_root"

    while IFS= read -r -d '' rel; do
        rel="${rel#./}"
        [[ -n "$rel" ]] || continue

        if [[ "$mode" == "minimal" ]] && python_skip_rel "$rel"; then
            continue
        fi

        sublogical="${logical_root%/}/$rel"
        copy_logical_path "$sublogical"
    done < <(
        cd -- "$srcfs"
        find . -mindepth 1 -print0
    )
}

elf_interp_logical() {
    local logical="$1"
    local srcfs
    srcfs="$(logical_to_fs "$logical")"
    LC_ALL=C readelf -lW -- "$srcfs" 2>/dev/null \
        | sed -n 's#.*Requesting program interpreter: \(.*\)]#\1#p'
}

elf_needed_sonames() {
    local logical="$1"
    local srcfs
    srcfs="$(logical_to_fs "$logical")"
    LC_ALL=C readelf -dW -- "$srcfs" 2>/dev/null \
        | awk '/NEEDED/ { gsub(/\[|\]/, "", $5); print $5 }'
}

elf_runpath_raw() {
    local logical="$1"
    local srcfs
    srcfs="$(logical_to_fs "$logical")"
    LC_ALL=C readelf -dW -- "$srcfs" 2>/dev/null \
        | sed -n 's#.*RUNPATH.*\[\(.*\)\]#\1#p'
}

elf_rpath_raw() {
    local logical="$1"
    local srcfs
    srcfs="$(logical_to_fs "$logical")"
    LC_ALL=C readelf -dW -- "$srcfs" 2>/dev/null \
        | sed -n 's#.*RPATH.*\[\(.*\)\]#\1#p'
}

elf_header_field() {
    local logical="$1"
    local field="$2"
    local srcfs

    srcfs="$(logical_to_fs "$logical")"
    LC_ALL=C readelf -h -- "$srcfs" 2>/dev/null \
        | awk -F: -v f="$field" '
            $1 ~ ("^[[:space:]]*" f "$") {
                gsub(/^[[:space:]]+/, "", $2)
                print $2
                exit
            }
        '
}

elf_class_machine() {
    local logical="$1"
    local class machine

    class="$(elf_header_field "$logical" "Class" || true)"
    machine="$(elf_header_field "$logical" "Machine" || true)"

    [[ -n "$class" && -n "$machine" ]] || return 1
    printf '%s\t%s\n' "$class" "$machine"
}

elf_matches_arch() {
    local ref_logical="$1"
    local cand_logical="$2"
    local ref cand

    ref="$(elf_class_machine "$ref_logical" 2>/dev/null || true)"
    cand="$(elf_class_machine "$cand_logical" 2>/dev/null || true)"

    [[ -n "$ref" && -n "$cand" ]] || return 1
    [[ "$ref" == "$cand" ]]
}

elf_multiarch_patterns() {
    local logical="$1"
    local class machine
    local -a patterns=()

    class="$(elf_header_field "$logical" "Class" || true)"
    machine="$(elf_header_field "$logical" "Machine" || true)"
    [[ -n "$class" && -n "$machine" ]] || return 1

    case "$machine" in
        "Advanced Micro Devices X86-64")
            patterns+=(x86_64-linux-gnu x86_64-*)
            if [[ "$class" == "ELF32" ]]; then
                patterns+=(x86_64-linux-gnux32 x86_64-*-gnux32)
            fi
            ;;
        "Intel 80386")
            patterns+=(i386-linux-gnu i486-linux-gnu i586-linux-gnu i686-linux-gnu)
            ;;
        "AArch64")
            patterns+=(aarch64-linux-gnu aarch64-*)
            ;;
        "ARM")
            patterns+=(arm-linux-gnueabihf arm-linux-gnueabi arm-*)
            ;;
        "RISC-V")
            if [[ "$class" == "ELF64" ]]; then
                patterns+=(riscv64-linux-gnu riscv64-*)
            else
                patterns+=(riscv32-linux-gnu riscv32-*)
            fi
            ;;
        "PowerPC64")
            patterns+=(powerpc64-linux-gnu powerpc64-* ppc64-linux-gnu)
            ;;
        "PowerPC64 LE")
            patterns+=(powerpc64le-linux-gnu powerpc64le-* ppc64le-linux-gnu)
            ;;
        "PowerPC")
            patterns+=(powerpc-linux-gnu powerpc-* ppc-linux-gnu)
            ;;
        "IBM S/390")
            patterns+=(s390-linux-gnu s390-*)
            ;;
        "IBM S/390 64-bit")
            patterns+=(s390x-linux-gnu s390x-*)
            ;;
        "MIPS")
            patterns+=(mips-linux-gnu mipsel-linux-gnu mips-*)
            ;;
        "MIPS R3000")
            patterns+=(mips-linux-gnu mipsel-linux-gnu mips-*)
            ;;
        *)
            return 1
            ;;
    esac

    printf '%s\n' "${patterns[@]}"
}

path_components_match_glob() {
    local path="$1"
    local glob="$2"
    local IFS='/'
    local comp
    read -r -a comps <<< "${path#/}"

    for comp in "${comps[@]}"; do
        [[ -n "$comp" ]] || continue
        [[ "$comp" == $glob ]] && return 0
    done
    return 1
}

dir_matches_elf_arch() {
    local elf_logical="$1"
    local dir="$2"
    local -a patterns=()
    local p
    local has_arch_component=0

    while IFS= read -r p; do
        [[ -n "$p" ]] && patterns+=("$p")
    done < <(elf_multiarch_patterns "$elf_logical" || true)

    ((${#patterns[@]} > 0)) || return 0

    for p in \
        x86_64-linux-gnu x86_64-linux-gnux32 \
        i386-linux-gnu i486-linux-gnu i586-linux-gnu i686-linux-gnu \
        aarch64-linux-gnu \
        arm-linux-gnueabihf arm-linux-gnueabi \
        riscv64-linux-gnu riscv32-linux-gnu \
        powerpc64-linux-gnu powerpc64le-linux-gnu powerpc-linux-gnu \
        ppc64-linux-gnu ppc64le-linux-gnu ppc-linux-gnu \
        s390-linux-gnu s390x-linux-gnu \
        mips-linux-gnu mipsel-linux-gnu; do
        if path_components_match_glob "$dir" "$p"; then
            has_arch_component=1
            break
        fi
    done

    if (( ! has_arch_component )); then
        return 0
    fi

    for p in "${patterns[@]}"; do
        if path_components_match_glob "$dir" "$p"; then
            return 0
        fi
    done

    return 1
}

add_default_lib_dir() {
    local logical_dir="$1"
    [[ "$logical_dir" == /* ]] || return 0
    [[ -d "$(logical_to_fs "$logical_dir")" ]] || return 0
    [[ -n "${DEFAULT_LIB_DIRS_SEEN[$logical_dir]+x}" ]] && return 0
    DEFAULT_LIB_DIRS_SEEN["$logical_dir"]=1
    DEFAULT_LIB_DIRS+=("$logical_dir")
}

build_default_lib_dirs() {
    local base basefs d dbasefs
    ((${#DEFAULT_LIB_DIRS[@]} == 0)) || return 0

    for base in /lib /lib64 /usr/lib /usr/lib64 /usr/local/lib /usr/local/lib64; do
        add_default_lib_dir "$base"
        basefs="$(logical_to_fs "$base")"
        [[ -d "$basefs" ]] || continue

        for d in "$basefs"/*; do
            [[ -d "$d" ]] || continue
            add_default_lib_dir "$(fs_to_logical "$d")"

            for dbasefs in "$d"/*; do
                [[ -d "$dbasefs" ]] || continue
                add_default_lib_dir "$(fs_to_logical "$dbasefs")"
            done
        done
    done
}

expand_search_dir_token() {
    local elf_logical="$1"
    local token="$2"
    local origin platform candidate out

    origin="$(dirname -- "$elf_logical")"
    platform="$(uname -m 2>/dev/null || printf 'unknown')"

    for candidate in "lib64" "lib"; do
        out="$token"
        out="${out//\$ORIGIN/$origin}"
        out="${out//\$\{ORIGIN\}/$origin}"
        out="${out//\$LIB/$candidate}"
        out="${out//\$\{LIB\}/$candidate}"
        out="${out//\$PLATFORM/$platform}"
        out="${out//\$\{PLATFORM\}/$platform}"
        if [[ "$out" == /* ]]; then
            printf '%s\n' "$out"
        else
            printf '%s\n' "$origin/$out"
        fi
        [[ "$token" == *'$LIB'* || "$token" == *'${LIB}'* ]] || break
    done
}

collect_search_dirs_for_elf() {
    local elf_logical="$1"
    local runpath rpath part dir
    local -A seen=()

    runpath="$(elf_runpath_raw "$elf_logical" || true)"
    rpath="$(elf_rpath_raw "$elf_logical" || true)"

    if [[ -n "$runpath" ]]; then
        for part in ${runpath//:/ }; do
            while IFS= read -r dir; do
                [[ -n "$dir" ]] || continue
                [[ -n "${seen[$dir]+x}" ]] && continue
                seen["$dir"]=1
                printf '%s\n' "$dir"
            done < <(expand_search_dir_token "$elf_logical" "$part")
        done
    elif [[ -n "$rpath" ]]; then
        for part in ${rpath//:/ }; do
            while IFS= read -r dir; do
                [[ -n "$dir" ]] || continue
                [[ -n "${seen[$dir]+x}" ]] && continue
                seen["$dir"]=1
                printf '%s\n' "$dir"
            done < <(expand_search_dir_token "$elf_logical" "$part")
        done
    fi

    build_default_lib_dirs
    for dir in "${DEFAULT_LIB_DIRS[@]}"; do
        dir_matches_elf_arch "$elf_logical" "$dir" || continue
        [[ -n "${seen[$dir]+x}" ]] && continue
        seen["$dir"]=1
        printf '%s\n' "$dir"
    done
}

resolve_needed_for_elf() {
    local elf_logical="$1"
    local soname="$2"
    local cache_key candidate dir dirfs candidate_logical

    cache_key="$elf_logical|$soname"
    if [[ -n "${RESOLVED_NEEDED_CACHE[$cache_key]+x}" ]]; then
        printf '%s\n' "${RESOLVED_NEEDED_CACHE[$cache_key]}"
        return 0
    fi

    while IFS= read -r dir; do
        [[ -n "$dir" ]] || continue
        dirfs="$(logical_to_fs "$dir")"
        candidate="$dirfs/$soname"

        if [[ -e "$candidate" || -L "$candidate" ]]; then
            candidate_logical="$(fs_to_logical "$candidate")"

            if elf_matches_arch "$elf_logical" "$candidate_logical"; then
                RESOLVED_NEEDED_CACHE["$cache_key"]="$candidate_logical"
                printf '%s\n' "${RESOLVED_NEEDED_CACHE[$cache_key]}"
                return 0
            fi
        fi
    done < <(collect_search_dirs_for_elf "$elf_logical")

    return 1
}

can_use_ldd_fast() {
    (( USE_LDD_FAST )) || return 1
    [[ "$SYSROOT" == "/" ]]
}

ldd_resolved_logicals() {
    local logical="$1"
    local srcfs dep

    can_use_ldd_fast || return 1
    srcfs="$(logical_to_fs "$logical")"

    LC_ALL=C ldd -- "$srcfs" 2>/dev/null \
        | awk '
            $2 == "=>" && $3 ~ /^\// { print $3 }
            $1 ~ /^\// { print $1 }
        ' \
        | while IFS= read -r dep; do
            [[ -n "$dep" ]] || continue
            printf '%s\n' "$(fs_to_logical "$dep")"
        done \
        | sort -u
}

copy_elf_recursive() {
    local input_logical="$1"
    local srcfs realfs real_logical interp soname dep_logical

    require_absolute_logical "$input_logical"
    srcfs="$(logical_to_fs "$input_logical")"
    [[ -e "$srcfs" || -L "$srcfs" ]] || return 0

    copy_logical_path "$input_logical"

    realfs="$(readlink -f -- "$srcfs" 2>/dev/null || printf '%s\n' "$srcfs")"
    real_logical="$(fs_to_logical "$realfs")"
    [[ "$real_logical" != "$input_logical" ]] && copy_logical_path "$real_logical"

    is_elf_logical "$real_logical" || return 0
    [[ -n "${VISITED_ELF[$real_logical]+x}" ]] && return 0
    VISITED_ELF["$real_logical"]=1

    log_debug "resolve ELF: $real_logical"

    interp="$(elf_interp_logical "$real_logical" || true)"
    if [[ -n "$interp" ]]; then
        copy_logical_path "$interp"
        copy_elf_recursive "$interp"
    fi

    if can_use_ldd_fast; then
        while IFS= read -r dep_logical; do
            [[ -n "$dep_logical" ]] || continue
            copy_logical_path "$dep_logical"
            copy_elf_recursive "$dep_logical"
        done < <(ldd_resolved_logicals "$real_logical")
        return 0
    fi

    while IFS= read -r soname; do
        [[ -n "$soname" ]] || continue
        dep_logical="$(resolve_needed_for_elf "$real_logical" "$soname" || true)"
        if [[ -z "$dep_logical" ]]; then
            warn "unresolved dependency for $real_logical: $soname"
            continue
        fi
        copy_logical_path "$dep_logical"
        copy_elf_recursive "$dep_logical"
    done < <(elf_needed_sonames "$real_logical")
}

register_python_hint() {
    local logical="$1"
    require_absolute_logical "$logical"
    [[ -n "${PYTHON_HINTS_SEEN[$logical]+x}" ]] && return 0
    PYTHON_HINTS_SEEN["$logical"]=1
    PYTHON_HINTS+=("$logical")
}

is_python_interpreter_name() {
    local logical="$1"
    local base
    base="$(basename -- "$logical")"
    [[ "$base" =~ ^python([0-9]+(\.[0-9]+)?)?$ ]]
}

is_perl_interpreter_name() {
    local logical="$1"
    local base
    base="$(basename -- "$logical")"
    [[ "$base" =~ ^perl([0-9]+(\.[0-9]+)?)?$ ]]
}

python_version_from_logical() {
    local logical="$1"
    local realfs reallogical base

    realfs="$(readlink -f -- "$(logical_to_fs "$logical")" 2>/dev/null || logical_to_fs "$logical")"
    reallogical="$(fs_to_logical "$realfs")"
    base="$(basename -- "$reallogical")"

    if [[ "$base" =~ ^python([0-9]+\.[0-9]+)$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    if [[ "$base" =~ ^python([0-9]+)$ ]]; then
        printf '%s.0\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

python_sysconfig_paths_host() {
    local logical="$1"
    local srcfs

    srcfs="$(logical_to_fs "$logical")"
    [[ "$SYSROOT" == "/" ]] || return 1
    [[ -x "$srcfs" ]] || return 1

    "$srcfs" - <<'PY'
import os
import sysconfig
seen = set()
for key in ("stdlib", "platstdlib", "purelib", "platlib"):
    p = sysconfig.get_path(key)
    if not p:
        continue
    p = os.path.realpath(p)
    if p in seen:
        continue
    seen.add(p)
    print(p)
PY
}

guess_python_paths() {
    local logical="$1"
    local version=""
    local realfs reallogical bindir prefix cand

    version="$(python_version_from_logical "$logical" || true)"
    realfs="$(readlink -f -- "$(logical_to_fs "$logical")" 2>/dev/null || logical_to_fs "$logical")"
    reallogical="$(fs_to_logical "$realfs")"
    bindir="$(dirname -- "$reallogical")"
    prefix="$(dirname -- "$bindir")"

    if [[ -n "$version" ]]; then
        for cand in \
            "$prefix/lib/python$version" \
            "$prefix/lib64/python$version" \
            "/usr/lib/python$version" \
            "/usr/lib64/python$version" \
            "/usr/local/lib/python$version" \
            "/usr/local/lib64/python$version"; do
            [[ -d "$(logical_to_fs "$cand")" ]] && printf '%s\n' "$cand"
        done
    fi
}

copy_python_runtime_for() {
    local interp_logical="$1"
    local p dep_so rel
    local -A seen=()

    copy_elf_recursive "$interp_logical"

    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        if [[ "$p" == "$SYSROOT"/* ]]; then
            p="$(fs_to_logical "$p")"
        fi
        [[ "$p" == /* ]] || continue
        [[ -d "$(logical_to_fs "$p")" ]] || continue
        [[ -n "${seen[$p]+x}" ]] && return 0
        seen["$p"]=1

        copy_tree_with_filter "$p" "$PYTHON_MODE"

        while IFS= read -r dep_so; do
            rel="${dep_so#$(logical_to_fs "$p")/}"
            copy_elf_recursive "${p%/}/$rel"
        done < <(find "$(logical_to_fs "$p")" -type f -name '*.so' -print)
    done < <(
        python_sysconfig_paths_host "$interp_logical" || guess_python_paths "$interp_logical"
    )
}

perl_inc_paths_host() {
    local logical="$1"
    local srcfs

    srcfs="$(logical_to_fs "$logical")"
    [[ "$SYSROOT" == "/" ]] || return 1
    [[ -x "$srcfs" ]] || return 1

    "$srcfs" -e '
        my %seen;
        for my $path (@INC) {
            next unless defined $path && length $path;
            next unless -d $path;
            next if $seen{$path}++;
            print "$path\n";
        }
    '
}

copy_perl_runtime_for() {
    local interp_logical="$1"
    local p dep_so rel
    local -A seen=()

    copy_elf_recursive "$interp_logical"

    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        if [[ "$p" == "$SYSROOT"/* ]]; then
            p="$(fs_to_logical "$p")"
        fi
        [[ "$p" == /* ]] || continue
        [[ -d "$(logical_to_fs "$p")" ]] || continue
        [[ -n "${seen[$p]+x}" ]] && continue
        seen["$p"]=1

        copy_logical_path "$p"

        while IFS= read -r dep_so; do
            rel="${dep_so#$(logical_to_fs "$p")/}"
            copy_elf_recursive "${p%/}/$rel"
        done < <(find "$(logical_to_fs "$p")" -type f -name '*.so' -print)
    done < <(perl_inc_paths_host "$interp_logical" || true)
}

parse_nss_modules() {
    local nss_logical="$1"
    local srcfs

    srcfs="$(logical_to_fs "$nss_logical")"
    [[ -f "$srcfs" ]] || return 0

    awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        {
            sub(/#.*/, "")
            split($0, parts, ":")
            if (length(parts) < 2) next
            rest = parts[2]
            n = split(rest, fields, /[[:space:]]+/)
            for (i = 1; i <= n; i++) {
                if (fields[i] == "" || fields[i] ~ /^\[/ || fields[i] ~ /\]$/) continue
                if (fields[i] ~ /^[A-Za-z0-9_+-]+$/) print fields[i]
            }
        }
    ' "$srcfs" | sort -u
}

resolve_global_library() {
    local soname="$1"
    local dir dirfs candidate candidate_logical

    build_default_lib_dirs
    for dir in "${DEFAULT_LIB_DIRS[@]}"; do
        dirfs="$(logical_to_fs "$dir")"
        candidate="$dirfs/$soname"
        if [[ -e "$candidate" || -L "$candidate" ]]; then
            candidate_logical="$(fs_to_logical "$candidate")"
            printf '%s\n' "$candidate_logical"
            return 0
        fi
    done
    return 1
}

copy_nss_runtime() {
    local f mod soname logical

    for f in \
        /etc/nsswitch.conf \
        /etc/hosts \
        /etc/resolv.conf \
        /etc/services \
        /etc/gai.conf \
        /etc/passwd \
        /etc/group \
        /etc/shadow \
        /etc/gshadow \
        /etc/adduser.conf \
        /etc/deluser.conf \
        /etc/login.defs \
        /etc/default/useradd; do
        [[ -e "$(logical_to_fs "$f")" ]] && copy_logical_path "$f"
    done

    while IFS= read -r mod; do
        [[ -n "$mod" ]] || continue
        soname="libnss_${mod}.so.2"
        logical="$(resolve_global_library "$soname" || true)"
        [[ -n "$logical" ]] && copy_elf_recursive "$logical"

        case "$mod" in
            dns|resolve)
                logical="$(resolve_global_library "libresolv.so.2" || true)"
                [[ -n "$logical" ]] && copy_elf_recursive "$logical"
                ;;
        esac
    done < <(parse_nss_modules /etc/nsswitch.conf)
}

copy_runtime_extras() {
    local f

    if (( COPY_NSS )); then
        copy_nss_runtime
    fi

    if (( COPY_SSL )); then
        for f in \
            /etc/ssl/certs \
            /etc/ssl/openssl.cnf \
            /etc/pki/tls/certs/ca-bundle.crt \
            /etc/ssl/cert.pem \
            /usr/local/share/ca-certificates \
            /usr/share/ca-certificates; do
            [[ -e "$(logical_to_fs "$f")" ]] && copy_logical_path "$f"
        done
    fi

    if (( COPY_ZONEINFO )); then
        [[ -e "$(logical_to_fs /etc/localtime)" ]] && copy_logical_path /etc/localtime
        [[ -d "$(logical_to_fs /usr/share/zoneinfo)" ]] && copy_logical_path /usr/share/zoneinfo
    fi
}

resolve_command_input() {
    local item="$1"
    local resolved=""
    local base

    if [[ "$item" == /* ]]; then
        [[ -e "$(logical_to_fs "$item")" || -L "$(logical_to_fs "$item")" ]] || die "cannot resolve input: $item"
        printf '%s\n' "$item"
        return 0
    fi

    if [[ "$item" == */* ]]; then
        base="$(cd -- "$(dirname -- "$item")" 2>/dev/null && pwd -P)/$(basename -- "$item")"
        [[ -e "$base" || -L "$base" ]] || die "cannot resolve input: $item"
        if [[ "$SYSROOT" != "/" ]]; then
            die "relative path inputs are only supported with --sysroot /: $item"
        fi
        printf '%s\n' "$base"
        return 0
    fi

    if [[ "$SYSROOT" == "/" ]]; then
        resolved="$(type -P -- "$item" 2>/dev/null || true)"
        [[ -n "$resolved" ]] || die "cannot resolve input: $item"
        printf '%s\n' "$resolved"
        return 0
    fi

    for resolved in "/usr/local/bin/$item" "/usr/bin/$item" "/bin/$item" "/usr/local/sbin/$item" "/usr/sbin/$item" "/sbin/$item"; do
        if [[ -e "$(logical_to_fs "$resolved")" || -L "$(logical_to_fs "$resolved")" ]]; then
            printf '%s\n' "$resolved"
            return 0
        fi
    done

    die "cannot resolve input in sysroot: $item"
}

resolve_library_input() {
    local item="$1"
    local logical=""

    if [[ "$item" == /* ]]; then
        [[ -e "$(logical_to_fs "$item")" || -L "$(logical_to_fs "$item")" ]] || die "cannot resolve library input: $item"
        printf '%s\n' "$item"
        return 0
    fi

    if [[ "$item" == */* ]]; then
        if [[ "$SYSROOT" != "/" ]]; then
            die "relative library paths are only supported with --sysroot /: $item"
        fi
        logical="$(cd -- "$(dirname -- "$item")" 2>/dev/null && pwd -P)/$(basename -- "$item")"
        [[ -e "$logical" || -L "$logical" ]] || die "cannot resolve library input: $item"
        printf '%s\n' "$logical"
        return 0
    fi

    logical="$(resolve_global_library "$item" || true)"
    [[ -n "$logical" ]] || die "cannot resolve library SONAME: $item"
    printf '%s\n' "$logical"
}

parse_shebang_interpreter() {
    local logical="$1"
    local srcfs first rest
    local -a words=()

    srcfs="$(logical_to_fs "$logical")"
    [[ -f "$srcfs" ]] || return 0

    IFS= read -r first < "$srcfs" || true
    [[ "$first" == '#!'* ]] || return 0

    rest="${first#\#!}"
    rest="${rest#"${rest%%[![:space:]]*}"}"
    read -r -a words <<< "$rest"
    ((${#words[@]} > 0)) || return 0

    if [[ "${words[0]}" == "/usr/bin/env" || "${words[0]}" == "/bin/env" ]]; then
        if ((${#words[@]} >= 3)) && [[ "${words[1]}" == "-S" ]]; then
            printf '%s\n' "${words[2]}"
            return 0
        fi
        if ((${#words[@]} >= 2)); then
            printf '%s\n' "${words[1]}"
            return 0
        fi
        return 0
    fi

    printf '%s\n' "${words[0]}"
}

process_input() {
    local logical="$1"
    local interp

    if is_elf_logical "$logical"; then
        copy_elf_recursive "$logical"
        if is_python_interpreter_name "$logical"; then
            register_python_hint "$logical"
        fi
        return 0
    fi

    if (( COPY_APP )); then
        copy_logical_path "$logical"
    fi

    interp="$(parse_shebang_interpreter "$logical" || true)"
    if [[ -n "$interp" ]]; then
        if [[ "$interp" != /* ]]; then
            interp="$(resolve_command_input "$interp")"
        fi
        copy_elf_recursive "$interp"
        if is_python_interpreter_name "$interp"; then
            register_python_hint "$interp"
        elif is_perl_interpreter_name "$interp"; then
            copy_perl_runtime_for "$interp"
        fi
    fi
}

process_library_input() {
    local logical="$1"

    if ! is_elf_logical "$logical"; then
        die "library input is not an ELF file: $logical"
    fi

    copy_elf_recursive "$logical"
}

resolve_entry() {
    local entry="$1"
    local kind value logical

    kind="auto"
    value="$entry"

    case "$entry" in
        auto:*)
            kind="auto"
            value="${entry#auto:}"
            ;;
        bin:*)
            kind="bin"
            value="${entry#bin:}"
            ;;
        lib:*)
            kind="lib"
            value="${entry#lib:}"
            ;;
    esac

    [[ -n "$value" ]] || die "empty entry: $entry"

    case "$kind" in
        auto|bin)
            logical="$(resolve_command_input "$value")"
            printf '%s\t%s\n' "$kind" "$logical"
            ;;
        lib)
            logical="$(resolve_library_input "$value")"
            printf '%s\t%s\n' "$kind" "$logical"
            ;;
        *)
            die "unsupported entry type: $kind"
            ;;
    esac
}

read_input_file() {
    local file="$1"
    local line trimmed

    [[ -f "$file" ]] || die "input file not found: $file"

    while IFS= read -r line || [[ -n "$line" ]]; do
        trimmed="${line#"${line%%[![:space:]]*}"}"
        trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
        [[ -n "$trimmed" ]] || continue
        [[ "${trimmed:0:1}" == "#" ]] && continue
        INPUTS+=("$trimmed")
    done < "$file"
}

parse_args() {
    while (($#)); do
        case "$1" in
            -o|--output-dir)
                (($# >= 2)) || die "missing value for $1"
                ROOTFS="$2"
                shift 2
                ;;
            --output-dir=*)
                ROOTFS="${1#*=}"
                shift
                ;;
            --sysroot)
                (($# >= 2)) || die "missing value for $1"
                SYSROOT="$2"
                shift 2
                ;;
            --sysroot=*)
                SYSROOT="${1#*=}"
                shift
                ;;
            -f|--file)
                (($# >= 2)) || die "missing value for $1"
                BIN_LIST_FILE="$2"
                shift 2
                ;;
            --file=*)
                BIN_LIST_FILE="${1#*=}"
                shift
                ;;
            -p|--python)
                COPY_PYTHON=1
                shift
                ;;
            -P|--python-bin)
                (($# >= 2)) || die "missing value for $1"
                COPY_PYTHON=1
                PYTHON_HINT_ARGS+=("$2")
                shift 2
                ;;
            --python-bin=*)
                COPY_PYTHON=1
                PYTHON_HINT_ARGS+=("${1#*=}")
                shift
                ;;
            --python-mode)
                (($# >= 2)) || die "missing value for $1"
                PYTHON_MODE="$2"
                shift 2
                ;;
            --python-mode=*)
                PYTHON_MODE="${1#*=}"
                shift
                ;;
            -n|--nss)
                COPY_NSS=1
                shift
                ;;
            -s|--ssl)
                COPY_SSL=1
                shift
                ;;
            -z|--zoneinfo)
                COPY_ZONEINFO=1
                shift
                ;;
            -S|--strip)
                STRIP_ELF=1
                shift
                ;;
            -L|--ldd-fast)
                USE_LDD_FAST=1
                shift
                ;;
            --no-copy-app)
                COPY_APP=0
                shift
                ;;
            --manifest)
                (($# >= 2)) || die "missing value for $1"
                MANIFEST_FILE="$2"
                shift 2
                ;;
            --manifest=*)
                MANIFEST_FILE="${1#*=}"
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --clean)
                CLEAN_OUTPUT=1
                shift
                ;;
            -v|--verbose)
                VERBOSE=1
                shift
                ;;
            -q|--quiet)
                QUIET=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                while (($#)); do
                    INPUTS+=("$1")
                    shift
                done
                ;;
            -*)
                die "unknown option: $1"
                ;;
            *)
                INPUTS+=("$1")
                shift
                ;;
        esac
    done

    case "$PYTHON_MODE" in
        minimal|full) ;;
        *) die "invalid --python-mode: $PYTHON_MODE (expected: minimal|full)" ;;
    esac
}

main() {
    local item kind logical py resolved

    require_cmd bash readelf cp find awk sed readlink head sort dirname basename uname sha256sum

    parse_args "$@"
    validate_sysroot
    validate_rootfs

    if (( STRIP_ELF )); then
        require_cmd strip
    fi

    if (( USE_LDD_FAST )); then
        require_cmd ldd
        [[ "$SYSROOT" == "/" ]] || die "--ldd-fast requires --sysroot /"
    fi

    if [[ -n "$BIN_LIST_FILE" ]]; then
        read_input_file "$BIN_LIST_FILE"
    fi

    ((${#INPUTS[@]} > 0 || ${#PYTHON_HINT_ARGS[@]} > 0)) || {
        usage >&2
        exit 1
    }

    if (( CLEAN_OUTPUT )); then
        remove_output_dir
    fi
    mkdir_p "$ROOTFS"

    if [[ -n "$MANIFEST_FILE" ]] && ! (( DRY_RUN )); then
        mkdir_p "$(dirname -- "$MANIFEST_FILE")"
        {
            printf 'type\tsha256\tpath\n'
        } > "$MANIFEST_FILE"
    fi

    for item in "${PYTHON_HINT_ARGS[@]}"; do
        register_python_hint "$(resolve_command_input "$item")"
    done

    for item in "${INPUTS[@]}"; do
        resolved="$(resolve_entry "$item")"
        kind="${resolved%%$'\t'*}"
        logical="${resolved#*$'\t'}"

        log_info "processing [$kind]: $logical"

        case "$kind" in
            auto|bin)
                process_input "$logical"
                ;;
            lib)
                process_library_input "$logical"
                ;;
            *)
                die "internal error: unexpected entry kind: $kind"
                ;;
        esac
    done

    if (( COPY_PYTHON )); then
        ((${#PYTHON_HINTS[@]} > 0)) || die "--python requested but no Python interpreter was detected or specified"
        for py in "${PYTHON_HINTS[@]}"; do
            log_info "copying python runtime for: $py"
            copy_python_runtime_for "$py"
        done
    fi

    copy_runtime_extras
}

main "$@"
