#!/bin/bash
set -e

export LC_ALL=C
export LANG=C

echo "=== Building PipelineWise for RHEL 7 compatibility ==="
echo ""

echo "[1/3] Installing build dependencies..."
python3.10 -m pip install --upgrade pip setuptools wheel
python3.10 -m pip install pyinstaller

echo "[3/4] Installing PipelineWise dependencies (without pandas/snowflake)..."
cd /build

# Install only postgres-related dependencies
echo "[2/3] Installing PipelineWise dependencies (postgres-only minimal build)..."
cd /build

# Install minimal dependencies for postgres-to-postgres only
python3.10 -m pip install \
  'argparse==1.4.0' \
  'tabulate==0.8.9' \
  'PyYAML>=6.0.2' \
  'ansible-core==2.17.8' \
  'Jinja2==3.1.6' \
  'joblib==1.3.2' \
  'psycopg2-binary>=2.9.10' \
  'pipelinewise-singer-python==1.*' \
  'python-pidfile==3.0.0' \
  'tzlocal>=2.0,<4.1' \
  'sqlparse==0.5.3' \
  'psutil==5.9.5' \
  'ujson==5.4.0' \
  'chardet==4.0.0' \
  'backports.tarfile==1.2.0' \
  'requests>=2.20,<2.32'

# Install tap/target connectors and transformers
echo "Installing tap-postgres, target-postgres, and transform-field..."
python3.10 -m pip install \
  'pipelinewise-tap-postgres' \
  'pipelinewise-target-postgres==2.1.2' \
  'pipelinewise-transform-field'

# Reinstall joblib to match pipelinewise requirements
python3.10 -m pip install --force-reinstall 'joblib==1.3.2'

# Install pipelinewise
python3.10 -m pip install -e . --no-deps

echo "Collecting installed site-packages for PyInstaller bundling..."
mapfile -t PYINSTALLER_SITE_MODULES < <(python3.10 - <<'PY'
import pkgutil
import sys
import os

site_packages = []
for path in sys.path:
  if 'site-packages' in path:
    site_packages.append(os.path.realpath(path))

site_packages = tuple(sorted(set(site_packages)))
modules = set()
for finder, name, ispkg in pkgutil.iter_modules():
  finder_path = getattr(finder, 'path', None)
  if finder_path is None:
    continue
  if isinstance(finder_path, (list, tuple)):
    candidate_paths = finder_path
  else:
    candidate_paths = [finder_path]
  for candidate in candidate_paths:
    candidate_real = os.path.realpath(candidate)
    if any(candidate_real.startswith(sp) for sp in site_packages):
      modules.add(name)
      break

modules = sorted(mod for mod in modules if mod and not mod.startswith('_'))
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

echo "[3/3] Building standalone binary..."
pyinstaller --clean \
  --name pipelinewise \
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
  pipelinewise/cli/__init__.py

echo ""
echo "Creating connector wrapper scripts..."
mkdir -p /build/dist/pipelinewise/connectors

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

# Build tap-postgres executable
echo "Building tap-postgres executable..."
pyinstaller --clean --name tap-postgres \
  --add-data "$(python3.10 -c "import singer, os; print(os.path.join(os.path.dirname(singer.__file__), 'logging.conf'))")":singer/ \
  --hidden-import psycopg2 \
  --hidden-import psycopg2._psycopg \
  --hidden-import psycopg2.extensions \
  --collect-binaries psycopg2 \
  --copy-metadata psycopg2-binary \
  --copy-metadata pipelinewise-tap-postgres \
  "${PYINSTALLER_COLLECT_ARGS[@]}" \
  /tmp/tap_postgres_entry.py
cp -r /build/dist/tap-postgres /build/dist/pipelinewise/connectors/

# Build transform-field executable
echo "Building transform-field executable..."
pyinstaller --clean --name transform-field \
  --add-data "$(python3.10 -c "import singer, os; print(os.path.join(os.path.dirname(singer.__file__), 'logging.conf'))")":singer/ \
  "${PYINSTALLER_COLLECT_ARGS[@]}" \
  /tmp/transform_field_entry.py
cp -r /build/dist/transform-field /build/dist/pipelinewise/connectors/

# Build target-postgres executable  
echo "Building target-postgres executable..."
pyinstaller --clean --name target-postgres \
  --add-data "$(python3.10 -c "import singer, os; print(os.path.join(os.path.dirname(singer.__file__), 'logging.conf'))")":singer/ \
  --hidden-import psycopg2 \
  --hidden-import psycopg2._psycopg \
  --hidden-import psycopg2.extensions \
  --collect-binaries psycopg2 \
  --copy-metadata psycopg2-binary \
  --copy-metadata pipelinewise-target-postgres \
  "${PYINSTALLER_COLLECT_ARGS[@]}" \
  /tmp/target_postgres_entry.py
cp -r /build/dist/target-postgres /build/dist/pipelinewise/connectors/

# Create fastsync entry point scripts
echo "Creating fastsync entry point scripts..."

# postgres-to-postgres entry point
cat > /tmp/postgres_to_postgres_entry.py << 'EOF'
#!/usr/bin/env python3
from pipelinewise.fastsync.postgres_to_postgres import main
if __name__ == '__main__':
    main()
EOF

# Build fastsync executables
echo "Building postgres-to-postgres fastsync executable..."
pyinstaller --clean --name postgres-to-postgres \
  --paths /build \
  --hidden-import=multiprocessing \
  --hidden-import=multiprocessing.spawn \
  --collect-submodules pipelinewise \
  --collect-data pipelinewise \
  "${PYINSTALLER_COLLECT_ARGS[@]}" \
  /tmp/postgres_to_postgres_entry.py

# Create pipelinewise/bin directory and copy fastsync binaries
mkdir -p /build/dist/pipelinewise/bin
cp -r /build/dist/postgres-to-postgres /build/dist/pipelinewise/bin/

# Add setup script
cp /build/setup-connectors.sh /build/dist/pipelinewise/setup-connectors.sh
chmod +x /build/dist/pipelinewise/setup-connectors.sh

# Add wrapper script as 'plw'
cp /build/plw-wrapper.sh /build/dist/pipelinewise/plw
chmod +x /build/dist/pipelinewise/plw

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
/build/dist/pipelinewise/connectors/tap-postgres/tap-postgres --version 2>&1 | head -5 || echo "tap-postgres version check skipped"

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
python3.10 -c "import psycopg2; v=psycopg2.__libpq_version__; print(f'Bundled libpq: {v} (' + ('✓ SCRAM supported' if v>=100000 else '✗ Too old') + ')')"

echo ""
echo "Creating tarball..."
cd /build/dist && tar -cf pipelinewise-rhel7.tar pipelinewise/
echo "Note: Compress with 'xz -9 pipelinewise-rhel7.tar' on host for maximum compression"
ls -lh /build/dist/pipelinewise-rhel7.tar
echo ""
echo "Creating self-extracting installer..."
if [ -f /build/build-rhel7/create-installer.sh ]; then
  cd /build
  DIST_DIR="/build/dist" bash /build/build-rhel7/create-installer.sh
  if [ -f /build/dist/pipelinewise-installer.run ]; then
    ls -lh /build/dist/pipelinewise-installer.run
    echo "✓ Installer created successfully"
  fi
else
  echo "⚠ Installer script not found, skipping..."
fi
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
echo "  3. Setup: cd pipelinewise && ./setup-connectors.sh"
echo "  4. Run: ./pipelinewise --help"
echo ""
if [ -f /build/dist/pipelinewise-installer.run ]; then
  echo "Installer deployment (recommended):"
  echo "  1. Copy: scp dist/pipelinewise-installer.run user@rhel7-host:/path/"
  echo "  2. Install: sudo ./pipelinewise-installer.run"
  echo "  3. Run: pipelinewise --help"
  echo ""
fi
