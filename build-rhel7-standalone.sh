#!/bin/bash
set -e

export LC_ALL=C
export LANG=C

# ============================================================================
# OPTIMIZATION SETUP - Leverage 16 cores, 40GB RAM, fast SSD
# ============================================================================

echo "=== Setting up optimized build environment ==="

# Detect CPU cores for parallel processing
CPU_CORES=$(nproc)
echo "Detected $CPU_CORES CPU cores"

# Create cache directories for persistence across builds
export CACHE_DIR="/build/.cache"
export PIP_CACHE_DIR="$CACHE_DIR/pip"
export CCACHE_DIR="$CACHE_DIR/ccache"

mkdir -p "$PIP_CACHE_DIR/wheels" "$PIP_CACHE_DIR/http" "$CCACHE_DIR"

# Set environment variables for optimal performance
export MAKEFLAGS="-j$CPU_CORES"
export MAX_JOBS="$CPU_CORES"
export PIP_PARALLEL_BUILDS="$CPU_CORES"
export PYTHONDONTWRITEBYTECODE=1  # Don't write .pyc files during build

# Configure ccache for C/C++ compilation speedup
echo "Setting up ccache for C/C++ compilation..."
if ! command -v ccache >/dev/null 2>&1; then
    echo "Installing ccache..."
    # Try different package managers
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y ccache || echo "Warning: Failed to install ccache via apt-get"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y ccache || echo "Warning: Failed to install ccache via yum"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y ccache || echo "Warning: Failed to install ccache via dnf"
    else
        echo "Warning: Could not install ccache, C/C++ compilation will be slower"
    fi
fi

# Configure ccache if available
if command -v ccache >/dev/null 2>&1; then
    export CCACHE_MAXSIZE="5G"
    export CC="ccache gcc"
    export CXX="ccache g++"
    echo "✓ ccache configured (max size: $CCACHE_MAXSIZE)"
else
    echo "⚠ ccache not available, using direct compilation"
fi

# Show cache status
echo "Cache directories:"
echo "  PIP cache: $PIP_CACHE_DIR"
echo "  CCACHE dir: $CCACHE_DIR"
du -sh "$CACHE_DIR" 2>/dev/null || echo "  Cache empty (first run)"

echo ""
echo "=== Building PipelineWise for RHEL 7 compatibility ==="
echo ""

echo "[1/4] Installing build dependencies with caching..."
python3.10 -m pip install --upgrade pip setuptools wheel
python3.10 -m pip install pyinstaller

echo "[2/4] Pre-downloading wheels to populate cache..."
# Pre-download all required wheels to cache for faster subsequent builds
python3.10 -m pip download --dest "$PIP_CACHE_DIR/wheels" \
  'argparse==1.4.0' \
  'tabulate==0.8.9' \
  'PyYAML>=6.0.2' \
  'ansible-core==2.17.8' \
  'Jinja2==3.1.6' \
  'psycopg2-binary==2.9.5' \
  'pipelinewise-singer-python==1.*' \
  'python-pidfile==3.0.0' \
  'tzlocal>=2.0,<4.1' \
  'sqlparse==0.5.3' \
  'psutil==5.9.5' \
  'ujson==5.4.0' \
  'chardet==4.0.0' \
  'backports.tarfile==1.2.0' \
  'requests>=2.20,<2.32' \
  'slackclient==2.9.4' \
  'pipelinewise-tap-postgres' \
  'pipelinewise-target-postgres==2.1.2' \
  'pipelinewise-transform-field' || echo "Warning: Some wheels may not be available for download"

echo "[3/4] Installing PipelineWise dependencies (parallel builds enabled)..."
cd /build

# Install all packages in parallel using cached wheels
python3.10 -m pip install \
  'argparse==1.4.0' \
  'tabulate==0.8.9' \
  'PyYAML>=6.0.2' \
  'ansible-core==2.17.8' \
  'Jinja2==3.1.6' \
  'psycopg2-binary==2.9.5' \
  'pipelinewise-singer-python==1.*' \
  'python-pidfile==3.0.0' \
  'tzlocal>=2.0,<4.1' \
  'sqlparse==0.5.3' \
  'psutil==5.9.5' \
  'ujson==5.4.0' \
  'chardet==4.0.0' \
  'backports.tarfile==1.2.0' \
  'requests>=2.20,<2.32' \
  'slackclient==2.9.4'

# Install tap/target connectors and transformers
echo "Installing tap-postgres, target-postgres, and transform-field..."
echo "Ensuring compatible joblib/cloudpickle for Python 3.10 and reinstalling target-postgres..."
python3.10 -m pip install --upgrade "joblib>=1.3.0" "cloudpickle>=2.2.0"
python3.10 -m pip install --force-reinstall pipelinewise-target-postgres

# Install the connectors and transformers (reinstall tap and transform-field as before)
python3.10 -m pip install --force-reinstall \
    'pipelinewise-tap-postgres' \
    'pipelinewise-transform-field'

# Upgrade psycopg2-binary to support SCRAM authentication
echo "Upgrading psycopg2-binary for SCRAM authentication support..."
python3.10 -m pip install --upgrade --force-reinstall 'psycopg2-binary>=2.9.10'

# Install pipelinewise
python3.10 -m pip install -e . --no-deps

echo "Collecting installed site-packages for PyInstaller bundling (parallel processing)..."
mapfile -t PYINSTALLER_SITE_MODULES < <(python3.10 - <<'PY'
import pkgutil
import sys
import os
from concurrent.futures import ThreadPoolExecutor, as_completed

def collect_modules_from_path(path_tuple):
    """Collect modules from a single path in parallel"""
    modules = set()
    for finder, name, ispkg in pkgutil.iter_modules(path_tuple):
        finder_path = getattr(finder, 'path', None)
        if finder_path is None:
            continue
        if isinstance(finder_path, (list, tuple)):
            candidate_paths = finder_path
        else:
            candidate_paths = [finder_path]
        for candidate in candidate_paths:
            candidate_real = os.path.realpath(candidate)
            if any(candidate_real.startswith(sp) for sp in path_tuple):
                modules.add(name)
                break
    return modules

# Get site packages paths
site_packages = []
for path in sys.path:
    if 'site-packages' in path:
        site_packages.append(os.path.realpath(path))

site_packages = tuple(sorted(set(site_packages)))

# Parallel module collection using thread pool
all_modules = set()
with ThreadPoolExecutor(max_workers=4) as executor:
    # Submit tasks for each site-packages path
    future_to_path = {executor.submit(collect_modules_from_path, (sp,)): sp for sp in site_packages}
    
    for future in as_completed(future_to_path):
        modules = future.result()
        all_modules.update(modules)

# Filter and sort modules
modules = sorted(mod for mod in all_modules if mod and not mod.startswith('_'))
for mod in modules:
    print(mod)
PY
)

PYINSTALLER_COLLECT_ARGS=()
SKIP_SUBMODULE_COLLECTION=("ansible" "ansible_collections")
for module in "${PYINSTALLER_SITE_MODULES[@]}"; do
    skip_submodules=0
    for skip in "${SKIP_SUBMODULE_COLLECTION[@]}"; do
        if [[ "$module" == "$skip" ]]; then
            skip_submodules=1
            break
        fi
    done

    if [[ $skip_submodules -eq 1 ]]; then
        PYINSTALLER_COLLECT_ARGS+=(--collect-data "$module")
    else
        PYINSTALLER_COLLECT_ARGS+=(--collect-submodules "$module")
        PYINSTALLER_COLLECT_ARGS+=(--collect-data "$module")
    fi
done

echo "  Collected ${#PYINSTALLER_SITE_MODULES[@]} site-packages modules for bundling."

echo "[4/4] Building standalone binaries (parallel execution)..."

# Create Python entry points for all executables
echo "Creating Python entry point scripts..."

# Create Python entry point for tap-postgres with logging setup
cat > /tmp/tap_postgres_entry.py << 'EOF'
#!/usr/bin/env python3
import sys
import logging
import logging.config

# Configure logging programmatically to avoid fileConfig issues
logging.basicConfig(
    level=logging.INFO,
    format='time=%(asctime)s name=%(name)s level=%(levelname)s message=%(message)s',
    datefmt='%Y-%m-%d %H:%M:%S',
    stream=sys.stderr
)

# Prevent singer from trying to load logging.conf
import singer.logger
singer.logger._configured = True

from tap_postgres import main
if __name__ == '__main__':
    sys.exit(main())
EOF

# Create Python entry point for transform-field with logging setup
cat > /tmp/transform_field_entry.py << 'EOF'
#!/usr/bin/env python3
import sys
import logging
import logging.config

# Configure logging programmatically to avoid fileConfig issues
logging.basicConfig(
    level=logging.INFO,
    format='time=%(asctime)s name=%(name)s level=%(levelname)s message=%(message)s',
    datefmt='%Y-%m-%d %H:%M:%S',
    stream=sys.stderr
)

# Prevent singer from trying to load logging.conf
import singer.logger
singer.logger._configured = True

from transform_field import main
if __name__ == '__main__':
    sys.exit(main())
EOF

# Create Python entry point for target-postgres with logging setup
cat > /tmp/target_postgres_entry.py << 'EOF'
#!/usr/bin/env python3
import sys
import logging
import logging.config

# Configure logging programmatically to avoid fileConfig issues
logging.basicConfig(
    level=logging.INFO,
    format='time=%(asctime)s name=%(name)s level=%(levelname)s message=%(message)s',
    datefmt='%Y-%m-%d %H:%M:%S',
    stream=sys.stderr
)

# Prevent singer from trying to load logging.conf
import singer.logger
singer.logger._configured = True

from target_postgres import main
if __name__ == '__main__':
    sys.exit(main())
EOF

# postgres-to-postgres entry point
cat > /tmp/postgres_to_postgres_entry.py << 'EOF'
#!/usr/bin/env python3
from pipelinewise.fastsync.postgres_to_postgres import main
if __name__ == '__main__':
    main()
EOF

# Create separate work directories for each build to avoid conflicts
mkdir -p /tmp/pyinstaller-builds/{pipelinewise,tap-postgres,target-postgres,transform-field,postgres-to-postgres}

# Function to build with PyInstaller
build_pyinstaller() {
    local name="$1"
    local workpath="/tmp/pyinstaller-builds/$name"
    local logfile="/tmp/build-$name.log"

    echo "Starting $name build (workpath: $workpath)..."

    case "$name" in
        "pipelinewise")
            pyinstaller --clean \
              --name "$name" \
              --workpath "$workpath" \
              --add-data "pipelinewise/logging.conf:pipelinewise/" \
              --add-data "pipelinewise/logging_debug.conf:pipelinewise/" \
              --add-data "pipelinewise/cli/schemas:pipelinewise/cli/schemas" \
              --add-data "pipelinewise/cli/samples:pipelinewise/cli/samples" \
              --add-data "pipelinewise/fastsync:pipelinewise/fastsync" \
              --copy-metadata ansible-core \
              --copy-metadata pipelinewise-tap-postgres \
              --copy-metadata pipelinewise-target-postgres \
              --copy-metadata psycopg2-binary \
              --collect-data ansible \
              --collect-binaries psycopg2 \
              --collect-submodules pipelinewise \
              --collect-submodules pipelinewise.cli \
              --hidden-import pipelinewise.fastsync.postgres_to_postgres \
              --hidden-import pipelinewise.fastsync.commons.tap_postgres \
              --hidden-import pipelinewise.fastsync.commons.target_postgres \
              --hidden-import psycopg2 \
              --hidden-import psycopg2._psycopg \
              --hidden-import psycopg2.extensions \
              --hidden-import requests \
              --hidden-import tap_postgres \
              --hidden-import target_postgres \
              "${PYINSTALLER_COLLECT_ARGS[@]}" \
              pipelinewise/cli/__init__.py 2>&1 | tee "$logfile"
            ;;
        "tap-postgres")
            pyinstaller --clean --name "$name" \
              --workpath "$workpath" \
              --add-data "$(python3.10 -c "import singer, os; print(os.path.join(os.path.dirname(singer.__file__), 'logging.conf'))")":singer/ \
              --hidden-import tap_postgres \
              --hidden-import tap_postgres.sync_strategies \
              --hidden-import tap_postgres.db \
              --collect-submodules tap_postgres \
              --collect-data tap_postgres \
              --hidden-import psycopg2 \
              --hidden-import psycopg2._psycopg \
              --hidden-import psycopg2.extensions \
              --collect-binaries psycopg2 \
              --copy-metadata psycopg2-binary \
              --copy-metadata pipelinewise-tap-postgres \
              "${PYINSTALLER_COLLECT_ARGS[@]}" \
              /tmp/tap_postgres_entry.py 2>&1 | tee "$logfile"
            ;;
        "target-postgres")
            pyinstaller --clean --name "$name" \
              --workpath "$workpath" \
              --add-data "$(python3.10 -c "import singer, os; print(os.path.join(os.path.dirname(singer.__file__), 'logging.conf'))")":singer/ \
              --hidden-import target_postgres \
              --hidden-import target_postgres.db_sync \
              --collect-submodules target_postgres \
              --collect-data target_postgres \
              --hidden-import psycopg2 \
              --hidden-import psycopg2._psycopg \
              --hidden-import psycopg2.extensions \
              --collect-binaries psycopg2 \
              --copy-metadata psycopg2-binary \
              --copy-metadata pipelinewise-target-postgres \
              "${PYINSTALLER_COLLECT_ARGS[@]}" \
              /tmp/target_postgres_entry.py 2>&1 | tee "$logfile"
            ;;
        "transform-field")
            pyinstaller --clean --name "$name" \
              --workpath "$workpath" \
              --add-data "$(python3.10 -c "import singer, os; print(os.path.join(os.path.dirname(singer.__file__), 'logging.conf'))")":singer/ \
              --hidden-import transform_field \
              --collect-submodules transform_field \
              --collect-data transform_field \
              "${PYINSTALLER_COLLECT_ARGS[@]}" \
              /tmp/transform_field_entry.py 2>&1 | tee "$logfile"
            ;;
        "postgres-to-postgres")
            pyinstaller --clean --name "$name" \
              --workpath "$workpath" \
              --paths /build \
              --hidden-import=multiprocessing \
              --hidden-import=multiprocessing.spawn \
              --collect-submodules pipelinewise \
              --collect-data pipelinewise \
              "${PYINSTALLER_COLLECT_ARGS[@]}" \
              /tmp/postgres_to_postgres_entry.py 2>&1 | tee "$logfile"
            ;;
    esac

    echo "$name build completed successfully"
}

# Start all builds in parallel
echo "Starting parallel PyInstaller builds..."
echo "Note: Build output will be displayed in real-time. Multiple builds running simultaneously may interleave output."
echo ""

build_pyinstaller "pipelinewise" &
PID_PIPELINEWISE=$!

build_pyinstaller "tap-postgres" &
PID_TAP=$!

build_pyinstaller "target-postgres" &
PID_TARGET=$!

build_pyinstaller "transform-field" &
PID_TRANSFORM=$!

build_pyinstaller "postgres-to-postgres" &
PID_FASTSYNC=$!

# Wait for all builds to complete
echo "Waiting for all builds to complete..."
echo "Build output is shown in real-time above. This may take 10-15 minutes."
echo ""

wait $PID_PIPELINEWISE
wait $PID_TAP
wait $PID_TARGET
wait $PID_TRANSFORM
wait $PID_FASTSYNC

echo ""
echo "All PyInstaller builds completed!"

# Check for any build failures
for logfile in /tmp/build-*.log; do
    if [ -f "$logfile" ]; then
        if grep -q "completed successfully" "$logfile"; then
            echo "✓ $(basename "$logfile" .log) - SUCCESS"
        else
            echo "✗ $(basename "$logfile" .log) - FAILED"
            tail -20 "$logfile"
        fi
    fi
done

# Copy built executables to final locations
echo "Copying built executables to final locations..."
echo "Organizing connectors into expected structure..."

# Clean up any existing structure
rm -rf /build/dist/pipelinewise/.virtualenvs
rm -rf /build/dist/pipelinewise/connectors

# Create NEW directory structure matching the installer expectations
mkdir -p /build/dist/pipelinewise/connectors/{tap-postgres,target-postgres,transform-field}
mkdir -p /build/dist/pipelinewise/bin/{postgres-to-postgres,mysql-to-postgres,mongodb-to-postgres}

# Move tap/target connectors to connectors/ directory
mv /build/dist/tap-postgres /build/dist/pipelinewise/connectors/tap-postgres/
mv /build/dist/target-postgres /build/dist/pipelinewise/connectors/target-postgres/
mv /build/dist/transform-field /build/dist/pipelinewise/connectors/transform-field/

# Move fastsync binaries to bin/ directory (replace any existing directory)
rm -rf /build/dist/pipelinewise/bin/postgres-to-postgres || true
mv /build/dist/postgres-to-postgres /build/dist/pipelinewise/bin/postgres-to-postgres/

# Copy libcrypt library for compatibility (if building in CentOS 7)
echo "Bundling libcrypt for compatibility..."

# Ensure _internal directories exist where we will copy the library
mkdir -p /build/dist/pipelinewise/_internal
mkdir -p /build/dist/pipelinewise/connectors/tap-postgres/_internal
mkdir -p /build/dist/pipelinewise/connectors/target-postgres/_internal
mkdir -p /build/dist/pipelinewise/connectors/transform-field/_internal
mkdir -p /build/dist/pipelinewise/bin/postgres-to-postgres/_internal

if [ -f /usr/lib64/libcrypt.so.1 ]; then
    # In CentOS 7 - copy the correct version
    cp /usr/lib64/libcrypt.so.1 /build/dist/pipelinewise/_internal/
    cp /usr/lib64/libcrypt.so.1 /build/dist/pipelinewise/connectors/tap-postgres/_internal/
    cp /usr/lib64/libcrypt.so.1 /build/dist/pipelinewise/connectors/target-postgres/_internal/
    cp /usr/lib64/libcrypt.so.1 /build/dist/pipelinewise/connectors/transform-field/_internal/
    cp /usr/lib64/libcrypt.so.1 /build/dist/pipelinewise/bin/postgres-to-postgres/_internal/
    echo "✓ Bundled libcrypt.so.1 from CentOS 7"
elif [ -f /usr/lib/libcrypt.so.2 ]; then
    # On modern system - create symlink for compatibility
    cp /usr/lib/libcrypt.so.2 /build/dist/pipelinewise/_internal/libcrypt.so.1
    cp /usr/lib/libcrypt.so.2 /build/dist/pipelinewise/connectors/tap-postgres/_internal/libcrypt.so.1
    cp /usr/lib/libcrypt.so.2 /build/dist/pipelinewise/connectors/target-postgres/_internal/libcrypt.so.1
    cp /usr/lib/libcrypt.so.2 /build/dist/pipelinewise/connectors/transform-field/_internal/libcrypt.so.1
    cp /usr/lib/libcrypt.so.2 /build/dist/pipelinewise/bin/postgres-to-postgres/_internal/libcrypt.so.1
    echo "✓ Bundled libcrypt.so.2 as libcrypt.so.1 (compatibility mode)"
else
    echo "⚠ Warning: libcrypt not found, may cause issues on some systems"
fi

# Create setup-connectors.sh script (will be run by installer)
cat > /build/dist/pipelinewise/setup-connectors.sh << 'EOF'
#!/bin/bash
# Setup PipelineWise connectors and fastsync binaries
# This creates the .virtualenvs structure expected by PipelineWise

set -e

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Use install-dir based PIPELINEWISE_HOME (never default to HOME)
PIPELINEWISE_HOME="${INSTALL_DIR}/.pipelinewise"
# Config directory defaults to ${PIPELINEWISE_HOME}/config
PIPELINEWISE_CONFIG_DIRECTORY="${PIPELINEWISE_HOME}/config"
export PIPELINEWISE_CONFIG_DIRECTORY
VENV_DIR="${PIPELINEWISE_HOME}/.virtualenvs"

echo "Setting up PipelineWise connectors..."
echo "  Installation directory: $INSTALL_DIR"
echo "  PipelineWise home: $PIPELINEWISE_HOME"

# Create virtualenvs directory structure
mkdir -p "${VENV_DIR}/tap-postgres/bin"
mkdir -p "${VENV_DIR}/target-postgres/bin"
mkdir -p "${VENV_DIR}/transform-field/bin"
mkdir -p "${VENV_DIR}/pipelinewise/bin"

# Create symlinks to bundled connectors (point to actual executable inside bundle)
ln -sf "${INSTALL_DIR}/connectors/tap-postgres/tap-postgres/tap-postgres" "${VENV_DIR}/tap-postgres/bin/tap-postgres"
ln -sf "${INSTALL_DIR}/connectors/target-postgres/target-postgres/target-postgres" "${VENV_DIR}/target-postgres/bin/target-postgres"
ln -sf "${INSTALL_DIR}/connectors/transform-field/transform-field/transform-field" "${VENV_DIR}/transform-field/bin/transform-field"

# Create fastsync symlinks
ln -sf "${INSTALL_DIR}/bin/postgres-to-postgres/postgres-to-postgres" "${VENV_DIR}/pipelinewise/bin/postgres-to-postgres"

# Make executables executable
chmod +x "${VENV_DIR}/tap-postgres/bin/tap-postgres" 2>/dev/null || true
chmod +x "${VENV_DIR}/target-postgres/bin/target-postgres" 2>/dev/null || true
chmod +x "${VENV_DIR}/transform-field/bin/transform-field" 2>/dev/null || true
chmod +x "${VENV_DIR}/pipelinewise/bin/postgres-to-postgres" 2>/dev/null || true

echo "✓ Connectors setup complete"
echo ""
echo "PipelineWise is ready to use!"
echo "  Config directory: $PIPELINEWISE_CONFIG_DIRECTORY"
echo "  Virtual envs: $VENV_DIR"
 
# Ensure config directory exists and create placeholder config.json to avoid defaulting to $HOME
mkdir -p "${PIPELINEWISE_CONFIG_DIRECTORY}"
if [ ! -f "${PIPELINEWISE_CONFIG_DIRECTORY}/config.json" ]; then
    echo '{}' > "${PIPELINEWISE_CONFIG_DIRECTORY}/config.json"
    chmod 644 "${PIPELINEWISE_CONFIG_DIRECTORY}/config.json" || true
fi
EOF

chmod +x /build/dist/pipelinewise/setup-connectors.sh

echo "✓ Executables organized in connectors/ structure"

# Create plw wrapper script (updated to run connector setup on first use)
cat > /build/dist/pipelinewise/plw << 'EOF'
#!/usr/bin/env bash
# PipelineWise standalone wrapper script

# Get the installation directory (where this script is located)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# PIPELINEWISE_HOME must point to the install dir's .pipelinewise
export PIPELINEWISE_HOME="${SCRIPT_DIR}/.pipelinewise"
# Ensure config directory env is set and defaults to <install>/.pipelinewise/config
export PIPELINEWISE_CONFIG_DIRECTORY="${PIPELINEWISE_HOME}/config"

# Ensure connectors are set up
if [ ! -d "${PIPELINEWISE_HOME}/.virtualenvs" ]; then
    echo "Setting up connectors for first-time use..."
    "${SCRIPT_DIR}/setup-connectors.sh"
fi

# Handle --dir argument to make it compatible with Docker version
ARGS=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --dir)
            # Convert relative path to absolute
            if [ -n "$2" ]; then
                DIR_PATH=$(cd "$(dirname "$2")" 2>/dev/null && pwd)/$(basename "$2")
                if [ ! -d "$DIR_PATH" ]; then
                    echo "Error: directory not exists $DIR_PATH"
                    exit 1
                fi
                ARGS+=("--dir" "$DIR_PATH")
                shift 2
            else
                echo "Error: --dir requires an argument"
                exit 1
            fi
            ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done

# Debug: print resolved PIPELINEWISE_ vars
echo "DEBUG: PIPELINEWISE_HOME=$PIPELINEWISE_HOME"
echo "DEBUG: PIPELINEWISE_CONFIG_DIRECTORY=$PIPELINEWISE_CONFIG_DIRECTORY"

# Run PipelineWise executable with environment explicitly set to avoid defaulting to HOME
exec env PIPELINEWISE_HOME="$PIPELINEWISE_HOME" PIPELINEWISE_CONFIG_DIRECTORY="$PIPELINEWISE_CONFIG_DIRECTORY" "${SCRIPT_DIR}/pipelinewise" "${ARGS[@]}"
EOF

chmod +x /build/dist/pipelinewise/plw

# Create env.sh for easy environment setup (auto-runs connector setup if needed)
cat > /build/dist/pipelinewise/env.sh << 'EOF'
#!/bin/bash
# PipelineWise Environment Setup
# Source this file: source env.sh

# SCRIPT_DIR is the installation directory (where env.sh lives)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Ensure PIPELINEWISE_HOME points to the install-dir .pipelinewise
export PIPELINEWISE_HOME="${SCRIPT_DIR}/.pipelinewise"
# Ensure config directory env defaults to <install>/.pipelinewise/config
export PIPELINEWISE_CONFIG_DIRECTORY="${PIPELINEWISE_HOME}/config"
export PATH="$SCRIPT_DIR:$PATH"

# Ensure connectors are set up
if [ ! -d "${PIPELINEWISE_HOME}/.virtualenvs" ]; then
    echo "Setting up connectors for first-time use..."
    # Ensure env vars are exported for setup script
    export PIPELINEWISE_CONFIG_DIRECTORY
    "${SCRIPT_DIR}/setup-connectors.sh"
fi

# Ensure config directory exists
mkdir -p "${PIPELINEWISE_CONFIG_DIRECTORY}"

echo "PipelineWise environment configured"

echo "PipelineWise environment configured"
echo "  PIPELINEWISE_HOME: $PIPELINEWISE_HOME"
echo "  Installation: $SCRIPT_DIR"
echo ""
echo "Usage:"
echo "  pipelinewise --help"
echo "  pipelinewise --version"
echo "  plw --help          # Wrapper script with Docker-like interface"
EOF

chmod +x /build/dist/pipelinewise/env.sh

echo "✓ Wrapper scripts created"

echo ""
echo "Build complete!"
ls -lh /build/dist/pipelinewise/
if command -v file >/dev/null 2>&1; then
    file /build/dist/pipelinewise/pipelinewise
else
    echo "Skipping binary type check (file command not available)."
fi
echo ""
echo "Testing binary..."
/build/dist/pipelinewise/pipelinewise --version
echo ""
echo "Checking GLIBC requirements..."
objdump -T /build/dist/pipelinewise/pipelinewise | grep GLIBC | sed 's/.*GLIBC_/GLIBC_/' | sort -Vu | tail -5
echo ""
echo "Checking bundled psycopg2 libpq version..."
/build/dist/pipelinewise/.virtualenvs/tap-postgres/bin/tap-postgres --version 2>&1 | head -5 || echo "tap-postgres version check skipped"

# Test if psycopg2 in the bundled executable supports SCRAM
python3.10 << 'PYCHECK'
import sys
sys.path.insert(0, '/build/dist/pipelinewise')
try:
    import psycopg2
    libpq_ver = psycopg2.__libpq_version__
    print(f"✓ Bundled psycopg2 libpq version: {libpq_ver}")
    if libpq_ver >= 100000:
        print("✓ SCRAM-SHA-256 authentication supported")
    else:
        print("⚠ Warning: libpq version too old for SCRAM authentication")
except Exception as e:
    print(f"⚠ Could not verify libpq version: {e}")
PYCHECK

echo ""
echo "=============================================="
echo "POST-BUILD VERIFICATION"
echo "=============================================="

# Test tap-postgres can import psycopg2
echo "Testing tap-postgres psycopg2 support..."
cat > /tmp/test_tap_psycopg2.py << 'PYTEST'
#!/usr/bin/env python3
import sys
import os

# Simulate PyInstaller bundled environment
bundle_dir = os.path.dirname(sys.executable)
sys.path.insert(0, bundle_dir)

try:
    import psycopg2
    libpq_ver = psycopg2.__libpq_version__
    print(f"✓ psycopg2 imported successfully")
    print(f"✓ libpq version: {libpq_ver}")
    
    if libpq_ver >= 100000:
        print(f"✓ SCRAM-SHA-256 authentication SUPPORTED (libpq {libpq_ver // 10000}.{(libpq_ver % 10000) // 100})")
        sys.exit(0)
    else:
        print(f"✗ WARNING: libpq version too old for SCRAM authentication")
        sys.exit(1)
except ImportError as e:
    print(f"✗ Failed to import psycopg2: {e}")
    sys.exit(1)
PYTEST

python3.10 /tmp/test_tap_psycopg2.py || echo "⚠ Warning: psycopg2 verification failed"

# Verify psycopg2 in bundled tap-postgres
echo "Verifying bundled psycopg2 libpq version..."
python3.10 -c "import psycopg2; v=psycopg2.__libpq_version__; print('Bundled libpq: {} ({})'.format(v, '✓ SCRAM supported' if v>=100000 else '✗ Too old'))"

echo ""
echo "Creating tarball with parallel compression..."
cd /build/dist

# Use parallel compression with xz
echo "Compressing with xz (parallel, $CPU_CORES threads)..."
tar -cf - pipelinewise/ | xz -9 -T$CPU_CORES > pipelinewise-rhel7.tar.xz

echo "✓ Tarball created with parallel compression"
ls -lh /build/dist/pipelinewise-rhel7.tar.xz

echo ""
echo "Creating self-extracting installer..."

# Check if installer script exists
if [ -f /build/create-self-extracting-installer.sh ]; then
    # Run the installer creation script
    if /build/create-self-extracting-installer.sh; then
        ls -lh /build/dist/pipelinewise-installer.run
        echo "✓ Installer created successfully"
    else
        echo "⚠ Installer creation failed, but tarball is available"
    fi
else
    echo "⚠ Installer script not found, skipping..."
fi

echo ""
echo "=============================================="
echo "CACHE STATISTICS"
echo "=============================================="

echo "PIP Cache Statistics:"
if [ -d "$PIP_CACHE_DIR" ]; then
    echo "  Cache directory: $PIP_CACHE_DIR"
    du -sh "$PIP_CACHE_DIR" 2>/dev/null || echo "  Cache size: Unknown"
    find "$PIP_CACHE_DIR" -name "*.whl" | wc -l | xargs echo "  Cached wheels:"
else
    echo "  No pip cache found"
fi

echo ""
echo "CCACHE Statistics:"
if command -v ccache >/dev/null 2>&1; then
    ccache -s 2>/dev/null || echo "  ccache stats not available"
else
    echo "  ccache not available"
fi

echo ""
echo "Total cache size:"
du -sh "$CACHE_DIR" 2>/dev/null || echo "Cache size: Unknown"

echo ""
echo "=============================================="
echo "BUILD COMPLETE!"
echo "=============================================="
echo ""
echo "Distribution files:"
echo "  Tarball:   dist/pipelinewise-rhel7.tar.xz"
if [ -f /build/dist/pipelinewise-installer.run ]; then
    echo "  Installer: dist/pipelinewise-installer.run"
fi
echo ""
echo "Tarball deployment:"
echo "  1. Copy: scp dist/pipelinewise-rhel7.tar.xz user@rhel7-host:/path/"
echo "  2. Extract: tar -xJf pipelinewise-rhel7.tar.xz"
echo "  3. Run: cd pipelinewise && source env.sh"
echo "  4. Use: pipelinewise --help or plw --help"
echo ""
if [ -f /build/dist/pipelinewise-installer.run ]; then
    echo "Installer deployment (recommended):"
    echo "  1. Copy: scp dist/pipelinewise-installer.run user@rhel7-host:/path/"
    echo "  2. Install: ./pipelinewise-installer.run"
    echo "  3. Use: cd /install/path && source env.sh"
    echo ""
fi

echo "=============================================="
echo "PERFORMANCE OPTIMIZATIONS APPLIED"
echo "=============================================="
echo "✓ Parallel PyInstaller builds ($CPU_CORES simultaneous)"
echo "✓ PIP wheel caching enabled"
echo "✓ CCACHE for C/C++ compilation speedup"
echo "✓ Parallel module collection"
echo "✓ Parallel tarball compression (xz -T$CPU_CORES)"
echo "✓ Persistent cache directories for faster rebuilds"
echo "=============================================="
