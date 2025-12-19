#!/usr/bin/env bash
# test_portable_installation.sh
#
# Tests the portable PipelineWise .run file by extracting it to a temporary directory
# and verifying the installation works correctly.
# Usage:
#   ./test_portable_installation.sh [--verbose|--quiet|--json] [--fix] [--test-db <params>]

set -euo pipefail

# ========== CONFIGURATION ==========
RUN_FILE="portable-pipelinewise.run"
TEMP_DIR=$(mktemp -d)
PORTABLE_ROOT="$TEMP_DIR/portable-pipelinewise"
VENV_ROOT="$PORTABLE_ROOT/.virtualenvs"
BIN_DIR="$PORTABLE_ROOT/bin"
CONFIG_DIR="$PORTABLE_ROOT/config"
CONNECTORS=(
  "pipelinewise"
  "tap-postgres"
  "target-postgres"
  "transform-field"
)
WRAPPERS=(
  "plw"
  "tap-postgres"
  "target-postgres"
  "transform-field"
)
PSYCOPG2_MIN=2.9.5
LIBPQ_MIN=100000
REQUIRED_PKG=(psycopg2)
REQUIRED_DOCKER_IMAGES=("centos/python-36-centos7:latest")

# ========== ARGUMENT PARSING ==========
VERBOSE=0
QUIET=0
JSON=0
FIX=0
TEST_DB=0
DB_PARAMS=""

for arg in "$@"; do
  case $arg in
    --verbose) VERBOSE=1 ;;
    --quiet) QUIET=1 ;;
    --json) JSON=1 ;;
    --fix) FIX=1 ;;
    --test-db)
      TEST_DB=1
      shift
      DB_PARAMS="$1"
      ;;
  esac
  shift || true
  [ $# -eq 0 ] && break
done

function log() {
  if (( QUIET )); then return; fi
  echo -e "$1"
}
function logv() {
  if (( VERBOSE )); then echo -e "$1"; fi
}
function logerr() {
  echo -e "$1" >&2
}
function json_out() {
  if (( JSON )); then echo "$1"; fi
}

# ========== VERIFICATION FUNCTIONS ==========
RESULTS=()
function check_venv_exists() {
  local venv="$1"
  if [ -d "$VENV_ROOT/$venv" ]; then
    RESULTS+=("$venv:ok")
    log "✅ venv $venv exists"
  else
    RESULTS+=("$venv:fail")
    logerr "❌ venv $venv missing"
    ((FIX)) && fix_venv "$venv"
  fi
}
function fix_venv() {
  local venv="$1"
  logerr "[FIX] Cannot fix venv when testing .run file. Rebuild the .run file instead."
}
function fix_wrapper() {
  local wrapper="$1"
  logerr "[FIX] Cannot fix wrapper when testing .run file. Rebuild the .run file instead."
}
function fix_psycopg2() {
  local venv="$1"
  logerr "[FIX] Cannot fix psycopg2 when testing .run file. Rebuild the .run file instead."
}
function check_venv_activatable() {
  local venv="$1"
  if "$VENV_ROOT/$venv/bin/python" -c 'import sys; print(sys.executable)' >/dev/null 2>&1; then
    log "✅ venv $venv activatable"
  else
    logerr "❌ venv $venv not activatable"
    ((FIX)) && fix_venv "$venv"
  fi
}
function check_wrapper() {
  local wrapper="$1"
  if [ -x "$BIN_DIR/$wrapper" ]; then
    log "✅ wrapper $wrapper exists and is executable"
  else
    logerr "❌ wrapper $wrapper missing or not executable"
    ((FIX)) && fix_wrapper "$wrapper"
  fi
}
function fix_wrapper() {
  local wrapper="$1"
  log "[FIX] Attempting to recreate wrapper $wrapper ..."
  (cd "$PORTABLE_ROOT" && ../create_portable_pipelinewise.sh)
}
function check_wrapper_venv() {
  local wrapper="$1"
  local venv="$2"
  local out
  out=$("$BIN_DIR/$wrapper" --version 2>&1 || true)
  ((VERBOSE)) && log "DEBUG: $wrapper output: '$out'"
  if [[ -n "$out" ]]; then
    log "✅ $wrapper runs and activates $venv"
  else
    logerr "❌ $wrapper does not activate $venv properly"
    ((FIX)) && fix_wrapper "$wrapper"
  fi
}
function check_libpq_version() {
  local venv="$1"
  local name="$2"
  local version
  version=$("$VENV_ROOT/$venv/bin/python" -c 'import psycopg2; print(getattr(psycopg2, "__libpq_version__", 0))' 2>/dev/null || echo 0)
  if (( version >= LIBPQ_MIN )); then
    log "✅ $name libpq version $version"
  else
    logerr "❌ $name libpq version $version (too old)"
    ((FIX)) && fix_psycopg2 "$venv"
  fi
}
function fix_psycopg2() {
  local venv="$1"
  log "[FIX] Upgrading psycopg2-binary in $venv ..."
  "$VENV_ROOT/$venv/bin/pip" install --upgrade "psycopg2-binary>=$PSYCOPG2_MIN"
}
function check_python_imports() {
  local venv="$1"
  shift
  local pkgs=("$@")
  for pkg in "${pkgs[@]}"; do
    if "$VENV_ROOT/$venv/bin/python" -c "import $pkg" >/dev/null 2>&1; then
      log "✅ $venv: can import $pkg"
    else
      logerr "❌ $venv: cannot import $pkg"
      ((FIX)) && logerr "[FIX] Cannot fix imports when testing .run file. Rebuild the .run file instead."
    fi
  done
}
function check_config_dir() {
  if [ -d "$CONFIG_DIR" ] && [ -w "$CONFIG_DIR" ]; then
    log "✅ config dir exists and is writable"
  else
    logerr "❌ config dir missing or not writable"
    ((FIX)) && logerr "[FIX] Cannot fix config dir when testing .run file. Rebuild the .run file instead."
  fi
}

# ========== FUNCTIONALITY TESTS ==========
function test_import_module() {
  local venv="$1"; local module="$2"
  if "$VENV_ROOT/$venv/bin/python" -c "import $module" >/dev/null 2>&1; then
    log "✅ $venv: can import $module"
  else
    logerr "❌ $venv: cannot import $module"
  fi
}
function test_cli_help() {
  local cmd="$1"
  if "$BIN_DIR/$cmd" --help >/dev/null 2>&1; then
    log "✅ $cmd --help works"
  else
    logerr "❌ $cmd --help failed"
  fi
}
function test_cli_version() {
  local cmd="$1"
  if "$BIN_DIR/$cmd" --version >/dev/null 2>&1; then
    log "✅ $cmd --version works"
  else
    logerr "❌ $cmd --version failed"
  fi
}

function check_docker_images() {
  if ! command -v docker >/dev/null 2>&1; then
    logerr "❌ docker not found"
    return
  fi
  for img in "${REQUIRED_DOCKER_IMAGES[@]}"; do
    if docker images --format "table {{.Repository}}:{{.Tag}}" | grep -q "^${img}$"; then
      log "✅ docker image $img available"
    else
      logerr "❌ docker image $img not found"
    fi
  done
}

# ========== OPTIONAL DB TESTS ==========
function test_db_connect() {
  local venv="$1"; local cmd="$2"; local params="$3"
  if "$BIN_DIR/$cmd" --discover $params >/dev/null 2>&1; then
    log "✅ $cmd can connect to DB and discover"
  else
    logerr "❌ $cmd cannot connect to DB"
  fi
}

# ========== REPORTING ==========
function print_versions_table() {
  printf "\n%-30s %-15s %-10s\n" "Connector" "Version" "libpq"
  for v in "tap-postgres" "target-postgres"; do
    local ver libpq
    ver=$("$VENV_ROOT/$v/bin/python" -c 'import pkg_resources; print(pkg_resources.get_distribution("psycopg2-binary").version)' 2>/dev/null || echo "-")
    libpq=$("$VENV_ROOT/$v/bin/python" -c 'import psycopg2; print(getattr(psycopg2, "__libpq_version__", 0))' 2>/dev/null || echo "0")
    printf "%-30s %-15s %-10s\n" "$v" "$ver" "$libpq"
  done
}
function print_pkg_table() {
  for v in "${CONNECTORS[@]}"; do
    printf "\n%-30s\n" "$v"
    "$VENV_ROOT/$v/bin/pip" freeze | grep -E 'psycopg2|singer-python' || echo "-"
  done
}
function print_size() {
  du -sh "$PORTABLE_ROOT"
}

function cleanup() {
  logv "Cleaning up temporary directory: $TEMP_DIR"
  rm -rf "$TEMP_DIR"
}

# ========== MAIN ==========
trap cleanup EXIT

# Check if .run file exists
if [ ! -f "$RUN_FILE" ]; then
  logerr "❌ $RUN_FILE not found. Run create_portable_pipelinewise.sh first."
  exit 1
fi

log "Extracting $RUN_FILE to $TEMP_DIR..."
echo "$TEMP_DIR" | ./"$RUN_FILE" >/dev/null 2>&1 || { logerr "❌ Failed to extract $RUN_FILE"; exit 1; }
log "✅ Extraction complete"

# Verify extraction
if [ ! -d "$PORTABLE_ROOT" ]; then
  logerr "❌ Extraction failed - $PORTABLE_ROOT not found"
  exit 1
fi
for v in "${CONNECTORS[@]}"; do
  check_venv_exists "$v"
  check_venv_activatable "$v"
  if [[ "$v" == *"postgres"* ]]; then
    check_python_imports "$v" psycopg2
  fi
done
for i in "${!WRAPPERS[@]}"; do
  w="${WRAPPERS[$i]}"
  v="${CONNECTORS[$i]}"
  check_wrapper "$w"
  check_wrapper_venv "$w" "$v"
done
check_libpq_version "tap-postgres" "tap-postgres"
check_libpq_version "target-postgres" "target-postgres"
check_config_dir

check_docker_images

test_import_module "tap-postgres" "tap_postgres"
test_import_module "target-postgres" "target_postgres"
test_import_module "transform-field" "transform_field"
test_cli_help plw
test_cli_version tap-postgres
test_cli_version target-postgres

test_cli_help transform-field

test_cli_help tap-postgres

test_cli_help target-postgres

if (( TEST_DB )); then
  test_db_connect "tap-postgres" tap-postgres "$DB_PARAMS"
  test_db_connect "target-postgres" target-postgres "$DB_PARAMS"
fi

print_versions_table
print_pkg_table
print_size

log "\nAll checks complete."
