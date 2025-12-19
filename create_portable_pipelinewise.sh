#!/usr/bin/env bash
# create_portable_pipelinewise.sh
#
# Creates a fully portable PipelineWise installation with separate virtualenvs for core CLI and connectors.
# See README.md in the portable directory for full usage and troubleshooting instructions.

set -euo pipefail

# ========== CONFIGURATION ==========
PORTABLE_ROOT="portable-pipelinewise"
VENV_ROOT="$PORTABLE_ROOT/.virtualenvs"
CONNECTORS=(
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
PYTHON_MIN=3.8
PYTHON_MAX=3.13
PSYCOPG2_MIN=2.9.5
LIBPQ_MIN=100000

# ========== UTILITY FUNCTIONS ==========
function error_exit() {
  echo -e "\n[ERROR] $1" >&2
  exit 1
}

function info() {
  echo -e "\n[INFO] $1"
}

function check_python_version() {
  local pyver
  pyver=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])') || error_exit "Python3 not found."
  local pymajor pyminor
  pymajor=$(echo "$pyver" | cut -d. -f1)
  pyminor=$(echo "$pyver" | cut -d. -f2)
  if (( pymajor != 3 )); then
    error_exit "Python 3 required. Found $pyver."
  fi
  if (( pyminor < 8 || pyminor > 13 )); then
    error_exit "Python version must be 3.8-3.13. Found $pyver."
  fi
  info "Using Python $pyver"
}

function check_system_deps() {
  info "Checking system dependencies..."
  command -v python3 >/dev/null || error_exit "python3 is required."
  command -v pip3 >/dev/null || error_exit "pip3 is required."
  command -v gcc >/dev/null || error_exit "gcc is required."
  command -v make >/dev/null || error_exit "make is required."
  command -v pg_config >/dev/null || error_exit "PostgreSQL client libraries (libpq-dev or postgresql-devel) are required."
  command -v openssl >/dev/null || error_exit "OpenSSL is required."
}

function check_disk_space() {
  local avail
  avail=$(df -Pk . | awk 'NR==2 {print $4}')
  if (( avail < 500000 )); then
    error_exit "At least 500MB free disk space required."
  fi
}

function backup_existing() {
  if [ -d "$PORTABLE_ROOT" ]; then
    local ts="$(date +%Y%m%d_%H%M%S)"
    local backup_dir="${PORTABLE_ROOT}_backup_$ts"
    info "Backing up existing $PORTABLE_ROOT to $backup_dir ..."
    mv "$PORTABLE_ROOT" "$backup_dir"
  fi
}

function prompt_cleanup() {
  if [ -d "$PORTABLE_ROOT" ]; then
    echo "Directory $PORTABLE_ROOT already exists."
    read -p "Delete and start fresh? (y/N): " yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
      backup_existing
    else
      echo "Skipping setup. Exiting."
      exit 0
    fi
  fi
}

function create_venv() {
  local venv_path="$1"
  info "Creating virtualenv at $venv_path ..."
  python3 -m venv "$venv_path" || error_exit "Failed to create virtualenv at $venv_path."
  "$venv_path/bin/pip" install --upgrade pip setuptools wheel
}

function install_pipelinewise_cli() {
  local venv_path="$VENV_ROOT/pipelinewise"
  create_venv "$venv_path"
  info "Installing PipelineWise CLI ..."
  "$venv_path/bin/pip" install . || error_exit "Failed to install PipelineWise CLI."
}

function install_connector() {
  local name="$1"
  local venv_path="$VENV_ROOT/$name"
  create_venv "$venv_path"
  info "Installing $name ..."
  case "$name" in
    tap-postgres)
      # Install tap-postgres without dependencies to avoid psycopg2-binary version conflicts
      "$venv_path/bin/pip" install --no-deps "pipelinewise-tap-postgres==1.8.4" || error_exit "Failed to install tap-postgres."
      # Install required dependencies
      "$venv_path/bin/pip" install "pipelinewise-singer-python==1.3.0" strict-rfc3339 || error_exit "Failed to install tap-postgres dependencies."
      # Force install compatible psycopg2-binary version
      "$venv_path/bin/pip" install --upgrade --force-reinstall "psycopg2-binary>=2.9.5" || error_exit "Failed to upgrade psycopg2-binary."
      ;;
    target-postgres)
      # Install target-postgres without dependencies to avoid psycopg2-binary version conflicts
      "$venv_path/bin/pip" install --no-deps "pipelinewise-target-postgres==2.1.2" || error_exit "Failed to install target-postgres."
      # Install required dependencies
      "$venv_path/bin/pip" install "pipelinewise-singer-python==1.3.0" inflection || error_exit "Failed to install target-postgres dependencies."
      # Force install compatible psycopg2-binary version
      "$venv_path/bin/pip" install --upgrade --force-reinstall "psycopg2-binary>=2.9.5" || error_exit "Failed to upgrade psycopg2-binary."
      ;;
    transform-field)
      "$venv_path/bin/pip" install "pipelinewise-transform-field" || error_exit "Failed to install transform-field."
      ;;
    *)
      error_exit "Unknown connector: $name"
      ;;
  esac
}

function check_libpq_version() {
  local venv_path="$1"
  local name="$2"
  local version
  version=$("$venv_path/bin/python" -c 'import psycopg2; print(getattr(psycopg2, "__libpq_version__", 0))' 2>/dev/null || echo 0)
  if (( version < LIBPQ_MIN )); then
    error_exit "$name: libpq version $version is too old. Must be >= $LIBPQ_MIN (PostgreSQL 10+)."
  fi
  echo "$version"
}

function create_wrapper() {
  local name="$1"
  local venv_name="$2"
  local entry="$3"
  local wrapper="$PORTABLE_ROOT/bin/$name"
  mkdir -p "$PORTABLE_ROOT/bin"
  cat > "$wrapper" <<EOF
#!/usr/bin/env bash
VENV_DIR="\$(dirname "\${BASH_SOURCE[0]}")/../.virtualenvs/$venv_name"
source "\$VENV_DIR/bin/activate"
exec $entry "\$@"
EOF
  chmod +x "$wrapper"
}

function create_master_activation() {
  cat > "$PORTABLE_ROOT/setup_environment.sh" <<EOF
#!/usr/bin/env bash
# Source this script to activate the portable PipelineWise environment
export PIPELINEWISE_HOME="\$(dirname "\${BASH_SOURCE[0]}")"
export PATH="\$PIPELINEWISE_HOME/bin:\$PATH"
export VIRTUALENV_HOME="\$PIPELINEWISE_HOME/.virtualenvs"
export PYTHONPATH="\$PIPELINEWISE_HOME"
EOF
  chmod +x "$PORTABLE_ROOT/setup_environment.sh"
}

function create_verify_script() {
  cat > "$PORTABLE_ROOT/verify_installation.sh" <<'EOF'
#!/usr/bin/env bash
set -e

function check_venv() {
  local venv="$1"
  if [ ! -d "$venv" ]; then
    echo "❌ $venv missing"; exit 1
  fi
}

function check_psycopg2() {
  local venv="$1"
  local name="$2"
  "$venv/bin/python" -c 'import psycopg2; assert int(getattr(psycopg2, "__libpq_version__", 0)) >= 100000, "libpq too old"' || { echo "❌ $name libpq < 100000"; exit 1; }
}

for v in .virtualenvs/pipelinewise .virtualenvs/tap-postgres .virtualenvs/target-postgres .virtualenvs/transform-field; do
  check_venv "$v"
done

check_psycopg2 .virtualenvs/tap-postgres tap-postgres
check_psycopg2 .virtualenvs/target-postgres target-postgres

for w in bin/plw bin/tap-postgres bin/target-postgres bin/transform-field; do
  [ -x "$w" ] || { echo "❌ $w not executable"; exit 1; }
done

echo "✅ All checks passed."
EOF
  chmod +x "$PORTABLE_ROOT/verify_installation.sh"
}

function create_config_templates() {
  mkdir -p "$PORTABLE_ROOT/config"
  cat > "$PORTABLE_ROOT/config/target_postgres_archive.yml" <<'EOF'
# Example target_postgres config
# ...
EOF
  cat > "$PORTABLE_ROOT/config/tap_postgres_source.yml" <<'EOF'
# Example tap_postgres config
# ...
EOF
  cat > "$PORTABLE_ROOT/config/transform_sample.yml" <<'EOF'
# Example transform-field config
# ...
EOF
}

function create_requirements_txt() {
  cat > "$PORTABLE_ROOT/requirements.txt" <<EOF
# System dependencies for portable PipelineWise
python3 (>=3.8, <=3.12, !=3.13)
pip
virtualenv
gcc
make
libpq-dev (Debian/Ubuntu) or postgresql-devel (RHEL/CentOS)
openssl
EOF
}

function create_readme() {
  cat > "$PORTABLE_ROOT/README.md" <<'EOF'
# Portable PipelineWise

## System Requirements
- Python 3.8-3.12 (not 3.13)
- pip, virtualenv
- gcc, make
- libpq-dev (Debian/Ubuntu) or postgresql-devel (RHEL/CentOS)
- openssl

## Installation
```bash
./create_portable_pipelinewise.sh
```

## Usage
```bash
source setup_environment.sh
plw import --dir /path/to/configs/
plw run --tap tap_name --target target_name
```

## Configuration
See `config/` for examples.

## Troubleshooting
- If SCRAM authentication fails, check libpq version (must be >= 100000)
- Use `verify_installation.sh` to check installation
- See requirements.txt for system dependencies

## Updating psycopg2
To update psycopg2-binary, activate the relevant venv and run:
```bash
pip install --upgrade psycopg2-binary
```

## Command Reference
- plw: PipelineWise CLI
- tap-postgres: Tap Postgres connector
- target-postgres: Target Postgres connector
- transform-field: Transform-field connector
EOF
}

# ========== MAIN SCRIPT ==========
prompt_cleanup
check_python_version
check_system_deps
check_disk_space

info "Creating directory structure..."
mkdir -p "$VENV_ROOT"

install_pipelinewise_cli
for conn in "${CONNECTORS[@]}"; do
  install_connector "$conn"
done

info "Checking libpq versions..."
libpq_tap=$(check_libpq_version "$VENV_ROOT/tap-postgres" "tap-postgres")
libpq_target=$(check_libpq_version "$VENV_ROOT/target-postgres" "target-postgres")

info "Creating wrapper scripts..."
  create_wrapper plw pipelinewise pipelinewise
create_wrapper tap-postgres tap-postgres tap-postgres
create_wrapper target-postgres target-postgres target-postgres
create_wrapper transform-field transform-field transform-field

create_master_activation
create_verify_script
create_config_templates
create_requirements_txt
create_readme

info "Installation complete."
info "Run 'source $PORTABLE_ROOT/setup_environment.sh' to activate."
info "Run '$PORTABLE_ROOT/verify_installation.sh' to verify installation."

info "Creating self-extractable .run file..."
tar -czf portable-pipelinewise.tar.gz "$PORTABLE_ROOT"

cat > portable-pipelinewise.run << 'EOF'
#!/bin/bash
# Portable PipelineWise Self-Extractor

echo "========================================"
echo "  Portable PipelineWise Installer"
echo "========================================"
echo
echo "This will extract the portable PipelineWise installation."
echo

# Default destination
DEFAULT_DEST="$HOME"

echo "Enter destination directory (default: $DEFAULT_DEST): "
read -r dest
dest=${dest:-$DEFAULT_DEST}

# Expand ~ if present
dest="${dest/#\~/$HOME}"

# Check if directory exists
if [ ! -d "$dest" ]; then
  echo "Directory '$dest' does not exist."
  echo "Create it? (y/N): "
  read -r create
  if [[ "$create" =~ ^[Yy]$ ]]; then
    mkdir -p "$dest" || { echo "Failed to create directory '$dest'."; exit 1; }
  else
    echo "Exiting."
    exit 1
  fi
fi

# Check if destination already has PipelineWise files
if [ -f "$dest/setup_environment.sh" ] || [ -d "$dest/bin" ] || [ -d "$dest/.virtualenvs" ]; then
  echo "Warning: PipelineWise files already exist in '$dest'."
  echo "Overwrite? (y/N): "
  read -r overwrite
  if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
    echo "Exiting."
    exit 1
  fi
  # Remove existing PipelineWise files
  rm -f "$dest/setup_environment.sh"
  rm -f "$dest/verify_installation.sh"
  rm -f "$dest/README.md"
  rm -f "$dest/requirements.txt"
  rm -rf "$dest/bin"
  rm -rf "$dest/config"
  rm -rf "$dest/.virtualenvs"
fi

echo "Extracting to '$dest'..."

# Find the line number where the archive starts
ARCHIVE_LINE=$(awk '/^__ARCHIVE_BELOW__/ {print NR + 1; exit 0;}' "$0")

# Extract the tar archive, stripping the top-level directory
tail -n +$ARCHIVE_LINE "$0" | tar -xz --strip-components=1 -C "$dest"

echo
echo "========================================"
echo "  Extraction Complete!"
echo "========================================"
echo
echo "To use PipelineWise:"
echo "  cd '$dest'"
echo "  source setup_environment.sh"
echo "  plw --help"
echo
echo "To verify installation:"
echo "  ./verify_installation.sh"
echo
echo "See README.md for full documentation."

exit 0

__ARCHIVE_BELOW__
EOF

# Append the tar archive
cat portable-pipelinewise.tar.gz >> portable-pipelinewise.run

# Make executable
chmod +x portable-pipelinewise.run

# Clean up
rm portable-pipelinewise.tar.gz

info "Self-extractable file created: portable-pipelinewise.run"
info "You can distribute this file and run it on other systems."
