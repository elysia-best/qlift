#!/usr/bin/env bash
# generate_qt6_swift_module.sh
#
# Uses Doxygen to extract the public API (classes, members, enums) from a
# system Qt6 installation and generates:
#
#   Sources/CQt6Widgets/module.modulemap   - Swift module map for Qt6
#   Sources/CQt6Widgets/qt6-api-summary.json - JSON summary of Qt6 API
#
# The module map follows Swift's guide on wrapping C/C++ libraries:
#   https://www.swift.org/documentation/articles/wrapping-c-cpp-library-in-swift.html
#
# Usage:
#   ./scripts/generate_qt6_swift_module.sh [--no-install] [--modules "QtCore QtGui QtWidgets"]
#
# Options:
#   --no-install   Skip automatic installation of Qt6 / Doxygen
#   --modules      Space-separated list of Qt6 modules to document (default: all public modules)
#   --output-dir   Override the output directory (default: Sources/CQt6Widgets)
#
# Requirements:
#   - qt6-base-dev (or equivalent Qt6 development package)
#   - doxygen
#   - python3
#   - pkg-config

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "${CYAN}[STEP]${NC}  $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
NO_INSTALL=false
# Default public Qt6 modules (space-separated)
QT6_MODULES_ARG=""
OUTPUT_DIR="${REPO_ROOT}/Sources/CQt6Widgets"
DOXYGEN_BUILD_DIR="${REPO_ROOT}/.build/doxygen-qt6"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-install)
            NO_INSTALL=true
            shift
            ;;
        --modules)
            QT6_MODULES_ARG="$2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -h|--help)
            # Print usage from the header comment block
            sed -n '/^# Usage:/,/^# Requirements:/p' "$0"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Step 1: Install dependencies
# ---------------------------------------------------------------------------
install_deps() {
    log_step "Checking dependencies..."

    local missing_qt=false
    local missing_doxygen=false

    if ! pkg-config --exists Qt6Core 2>/dev/null; then
        missing_qt=true
    fi
    if ! command -v doxygen &>/dev/null; then
        missing_doxygen=true
    fi

    if "$missing_qt" || "$missing_doxygen"; then
        if "$NO_INSTALL"; then
            if "$missing_qt";      then log_error "Qt6 not found. Install qt6-base-dev and re-run."; fi
            if "$missing_doxygen"; then log_error "Doxygen not found. Install doxygen and re-run."; fi
            exit 1
        fi

        log_info "Installing missing dependencies..."
        if command -v apt-get &>/dev/null; then
            local pkgs=()
            "$missing_qt"      && pkgs+=(qt6-base-dev)
            "$missing_doxygen" && pkgs+=(doxygen)
            sudo apt-get install -y "${pkgs[@]}"
        elif command -v brew &>/dev/null; then
            "$missing_qt"      && brew install qt6
            "$missing_doxygen" && brew install doxygen
        else
            log_error "Cannot auto-install dependencies. Please install qt6-base-dev and doxygen manually."
            exit 1
        fi
    fi

    log_info "All dependencies present."
}

# ---------------------------------------------------------------------------
# Step 2: Detect Qt6 installation
# ---------------------------------------------------------------------------
detect_qt6() {
    log_step "Detecting Qt6 installation..."

    if ! pkg-config --exists Qt6Core; then
        log_error "Qt6Core not found via pkg-config. Ensure Qt6 development headers are installed."
        exit 1
    fi

    QT6_VERSION="$(pkg-config --modversion Qt6Core)"
    # includedir points to the *parent* of the qt6/ subdirectory
    QT6_INCLUDE_PARENT="$(pkg-config --variable=includedir Qt6Core)"
    # The actual Qt6 root include dir contains QtCore/, QtWidgets/, etc.
    QT6_INCLUDE_DIR="${QT6_INCLUDE_PARENT}/qt6"

    if [[ ! -d "${QT6_INCLUDE_DIR}" ]]; then
        # Fallback: look for a qt6 subdirectory relative to includedir
        QT6_INCLUDE_DIR="$(find "${QT6_INCLUDE_PARENT}" -maxdepth 2 -name "QtCore" -type d \
                           2>/dev/null | head -1 | xargs -I{} dirname {})"
        if [[ -z "${QT6_INCLUDE_DIR}" || ! -d "${QT6_INCLUDE_DIR}" ]]; then
            log_error "Could not locate Qt6 include directory under ${QT6_INCLUDE_PARENT}."
            exit 1
        fi
    fi

    log_info "Qt6 version    : ${QT6_VERSION}"
    log_info "Qt6 include dir: ${QT6_INCLUDE_DIR}"
}

# ---------------------------------------------------------------------------
# Step 3: Determine which modules to process
# ---------------------------------------------------------------------------
select_modules() {
    log_step "Selecting Qt6 modules to document..."

    # Default public modules
    local default_modules=(
        QtCore QtGui QtWidgets QtNetwork QtSql QtXml
        QtDBus QtTest QtConcurrent QtOpenGL QtOpenGLWidgets QtPrintSupport
    )

    local selected=()
    local source_modules
    if [[ -n "${QT6_MODULES_ARG}" ]]; then
        read -ra source_modules <<< "${QT6_MODULES_ARG}"
    else
        source_modules=("${default_modules[@]}")
    fi

    local input_paths=""
    for mod in "${source_modules[@]}"; do
        local mod_dir="${QT6_INCLUDE_DIR}/${mod}"
        if [[ -d "${mod_dir}" ]]; then
            selected+=("${mod}")
            input_paths+=" ${mod_dir}"
        else
            log_warn "Module directory not found, skipping: ${mod_dir}"
        fi
    done

    if [[ ${#selected[@]} -eq 0 ]]; then
        log_error "No Qt6 module directories found under ${QT6_INCLUDE_DIR}."
        exit 1
    fi

    QT6_SELECTED_MODULES=("${selected[@]}")
    QT6_INPUT_PATHS="${input_paths# }"  # strip leading space

    log_info "Modules selected: ${QT6_SELECTED_MODULES[*]}"
}

# ---------------------------------------------------------------------------
# Step 4: Generate Doxyfile from template
# ---------------------------------------------------------------------------
generate_doxyfile() {
    log_step "Generating Doxyfile..."

    mkdir -p "${DOXYGEN_BUILD_DIR}"

    sed \
        -e "s|@QT6_INPUT@|${QT6_INPUT_PATHS}|g" \
        -e "s|@OUTPUT_DIRECTORY@|${DOXYGEN_BUILD_DIR}|g" \
        -e "s|@QT6_VERSION@|${QT6_VERSION}|g" \
        "${SCRIPT_DIR}/Doxyfile.in" > "${DOXYGEN_BUILD_DIR}/Doxyfile"

    log_info "Doxyfile written to ${DOXYGEN_BUILD_DIR}/Doxyfile"
}

# ---------------------------------------------------------------------------
# Step 5: Run Doxygen
# ---------------------------------------------------------------------------
run_doxygen() {
    log_step "Running Doxygen on Qt6 headers (this may take a moment)..."

    (cd "${DOXYGEN_BUILD_DIR}" && doxygen Doxyfile)

    local xml_dir="${DOXYGEN_BUILD_DIR}/xml"
    if [[ ! -f "${xml_dir}/index.xml" ]]; then
        log_error "Doxygen did not produce xml/index.xml in ${DOXYGEN_BUILD_DIR}."
        exit 1
    fi

    log_info "Doxygen completed. XML output: ${xml_dir}"
}

# ---------------------------------------------------------------------------
# Step 6: Parse XML and generate Swift module map
# ---------------------------------------------------------------------------
generate_swift_module() {
    log_step "Parsing Doxygen XML and generating Swift module map..."

    mkdir -p "${OUTPUT_DIR}"
    mkdir -p "${DOXYGEN_BUILD_DIR}"

    # The detailed module map (with absolute header paths) goes to the build
    # directory so it is not committed to version control.  The file in
    # Sources/CQt6Widgets/module.modulemap is a portable pkgconfig-based version
    # that is suitable for committing and works on any Qt6 installation.
    python3 "${SCRIPT_DIR}/parse_doxygen_xml.py" \
        --xml-dir          "${DOXYGEN_BUILD_DIR}/xml" \
        --qt6-include-dir  "${QT6_INCLUDE_DIR}" \
        --qt6-version      "${QT6_VERSION}" \
        --module-map-out   "${DOXYGEN_BUILD_DIR}/module.modulemap" \
        --summary-out      "${DOXYGEN_BUILD_DIR}/qt6-api-summary.json"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo ""
    echo -e "${CYAN}=================================================${NC}"
    echo -e "${CYAN} Qt6 Swift Module Generator${NC}"
    echo -e "${CYAN} Repo: ${REPO_ROOT}${NC}"
    echo -e "${CYAN}=================================================${NC}"
    echo ""

    install_deps
    detect_qt6
    select_modules
    generate_doxyfile
    run_doxygen
    generate_swift_module

    echo ""
    log_info "=== Generation complete ==="
    log_info "Build artifacts (not committed to repo):"
    log_info "  ${DOXYGEN_BUILD_DIR}/module.modulemap      (detailed, with absolute header paths)"
    log_info "  ${DOXYGEN_BUILD_DIR}/qt6-api-summary.json  (full Qt6 API: classes, methods, enums)"
    echo ""
    log_info "The portable module map committed to the repo is:"
    log_info "  ${OUTPUT_DIR}/module.modulemap"
    echo ""
    log_info "To use Qt6 from Swift, add a systemLibrary target to Package.swift:"
    echo '  .systemLibrary(name: "CQt6Widgets", pkgConfig: "Qt6Widgets",'
    echo '                 providers: [.apt(["qt6-base-dev"])])'
    echo ""
    log_info "Then add the dependency to your Swift target and import with:"
    echo '  import CQt6Widgets'
    echo ""
}

main "$@"
