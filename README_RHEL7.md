# **PipelineWise RHEL7 Standalone Build & Deployment Guide**

**Version:** 0.73.0  
**Last Updated:** December 20, 2025  
**Build Type:** Portable RHEL7-compatible standalone distribution

---

## **Table of Contents**

1. [Overview](#overview)
2. [Architecture & Bundle Structure](#architecture--bundle-structure)
3. [Build Process](#build-process)
4. [Deployment](#deployment)
5. [Configuration & Runtime](#configuration--runtime)
6. [Testing & Verification](#testing--verification)
7. [Troubleshooting](#troubleshooting)
8. [CI/CD Integration](#cicd-integration)
9. [Migration Guide](#migration-guide)
10. [Reference](#reference)

---

## **Overview**

### **Purpose**

This guide documents the **RHEL7 standalone distribution** of PipelineWise, which provides a fully self-contained, portable deployment suitable for:

- RHEL/CentOS 7+ environments with GLIBC 2.17+
- Air-gapped or restricted network environments
- Production deployments without Docker dependencies
- Environments requiring SCRAM-SHA-256 PostgreSQL authentication

### **Key Features**

✅ **Zero Python dependencies** - All components bundled via PyInstaller  
✅ **SCRAM authentication support** - PostgreSQL 10+ compatible via bundled libpq  
✅ **FastSync enabled** - Full postgres-to-postgres replication support  
✅ **Self-extracting installer** - One-command deployment  
✅ **RHEL7 compatibility** - Bundled `libcrypt.so.1` and compatibility libs  
✅ **Performance optimized** - Parallel builds, ccache, compressed archives

### **What You'll Get**

After building, you'll have three deployment artifacts:

| Artifact | Size | Use Case |
|----------|------|----------|
| `pipelinewise/` | ~400MB | Direct extraction bundle |
| `pipelinewise-rhel7.tar.xz` | ~120MB | Manual deployment via tarball |
| `pipelinewise-installer.run` | ~120MB | **Recommended:** Self-extracting installer |

---

## **Architecture & Bundle Structure**

### **Directory Layout**

The bundle follows this structure to support both **bundled connectors** and **runtime virtualenv discovery**:

```
pipelinewise/
├── pipelinewise                    # Main CLI executable (PyInstaller bundle)
├── _internal/                      # PyInstaller runtime dependencies
│   ├── libcrypt.so.1              # RHEL7 compatibility lib
│   ├── libssl.so.1.1              # SSL/TLS support
│   └── ... (other bundled libs)
├── bin/                            # FastSync executables
│   ├── postgres-to-postgres/
│   │   ├── postgres-to-postgres   # Standalone fastsync binary
│   │   └── _internal/             # FastSync dependencies
│   ├── mysql-to-postgres/         # (Future support)
│   └── mongodb-to-postgres/       # (Future support)
├── connectors/                     # Tap/Target connector bundles
│   ├── tap-postgres/
│   │   ├── tap-postgres           # Standalone tap binary
│   │   └── _internal/             # Tap dependencies
│   ├── target-postgres/
│   │   ├── target-postgres        # Standalone target binary
│   │   └── _internal/             # Target dependencies
│   └── transform-field/
│       ├── transform-field        # Transform connector
│       └── _internal/             # Transform dependencies
├── setup-connectors.sh             # Creates ~/.pipelinewise/.virtualenvs symlinks
├── plw                            # Wrapper with auto-setup (recommended)
├── env.sh                         # Environment configuration script
└── logging.conf                   # Logging configuration

Runtime structure (created by setup-connectors.sh):
~/.pipelinewise/.virtualenvs/
├── tap-postgres/bin/
│   └── tap-postgres → /install/path/connectors/tap-postgres/tap-postgres
├── target-postgres/bin/
│   └── target-postgres → /install/path/connectors/target-postgres/target-postgres
├── transform-field/bin/
│   └── transform-field → /install/path/connectors/transform-field/transform-field
└── pipelinewise/bin/
    └── postgres-to-postgres → /install/path/bin/postgres-to-postgres/postgres-to-postgres
```

### **Why This Structure?**

PipelineWise discovers connectors via `$PIPELINEWISE_HOME/.virtualenvs/<connector>/bin/<executable>`. The build creates:[2][3]

1. **Bundled executables** in `connectors/` and `bin/` (portable, no Python deps)
2. **Runtime symlinks** via `setup-connectors.sh` (mimics virtualenv layout)
3. **Wrapper scripts** (`plw`, `env.sh`) that auto-setup on first use

This design enables:
- ✅ Portable distribution (all files in one directory)
- ✅ PipelineWise runtime compatibility (finds connectors in expected locations)
- ✅ Multi-user support (each user gets own `.virtualenvs` in their `$HOME`)

---

## **Build Process**

### **Prerequisites**

**Build Host Requirements:**
- Docker installed and running
- 16GB+ RAM (for parallel builds)
- 40GB+ free disk space
- Build time: ~10-15 minutes (with ccache)

**Build Container:**
```bash
# Using official CentOS 7 base for GLIBC 2.17 compatibility
FROM centos:7
RUN yum install -y python3.10 gcc gcc-c++ make ccache xz
```

### **Build Script: `build-rhel7-standalone.sh`**

The build script performs these steps:

#### **1. Environment Setup (Optimization)**
```bash
# Leverage available resources
CPU_CORES=$(nproc)                          # Auto-detect cores
export MAKEFLAGS="-j$CPU_CORES"            # Parallel make
export CCACHE_MAXSIZE="5G"                 # C/C++ compilation cache
export PIP_CACHE_DIR="/build/.cache/pip"   # Persistent pip cache
```

#### **2. Dependency Installation**
```bash
# Install build tools and PipelineWise dependencies
python3.10 -m pip install --upgrade pip setuptools wheel pyinstaller
python3.10 -m pip install \
  ansible-core==2.17.8 \
  psycopg2-binary>=2.9.10 \
  pipelinewise-tap-postgres \
  pipelinewise-target-postgres \
  pipelinewise-transform-field
```

**Key:** `psycopg2-binary>=2.9.10` provides SCRAM-SHA-256 support via bundled libpq 14+

#### **3. Parallel PyInstaller Builds**
```bash
# Build all components in parallel (5 simultaneous builds)
build_pyinstaller "pipelinewise" &
build_pyinstaller "tap-postgres" &
build_pyinstaller "target-postgres" &
build_pyinstaller "transform-field" &
build_pyinstaller "postgres-to-postgres" &
wait
```

Each build creates a standalone PyInstaller bundle with:
- Embedded Python interpreter
- All dependencies bundled in `_internal/`
- Single executable entry point

#### **4. Bundle Assembly**
```bash
# Create connectors/ directory structure
mkdir -p dist/pipelinewise/connectors/{tap-postgres,target-postgres,transform-field}
mkdir -p dist/pipelinewise/bin/postgres-to-postgres

# Move PyInstaller bundles to correct locations
mv dist/tap-postgres dist/pipelinewise/connectors/tap-postgres/
mv dist/target-postgres dist/pipelinewise/connectors/target-postgres/
mv dist/transform-field dist/pipelinewise/connectors/transform-field/
mv dist/postgres-to-postgres dist/pipelinewise/bin/postgres-to-postgres/

# Bundle compatibility libraries
cp /usr/lib64/libcrypt.so.1 dist/pipelinewise/_internal/
# (Repeated for each connector bundle)
```

#### **5. Wrapper Scripts Creation**
```bash
# Create setup-connectors.sh (executed at install time)
cat > dist/pipelinewise/setup-connectors.sh << 'EOF'
#!/bin/bash
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINEWISE_HOME="${PIPELINEWISE_HOME:-${HOME}/.pipelinewise}"
VENV_DIR="${PIPELINEWISE_HOME}/.virtualenvs"

# Create virtualenv structure with symlinks
mkdir -p "${VENV_DIR}/tap-postgres/bin"
ln -sf "${INSTALL_DIR}/connectors/tap-postgres/tap-postgres" \
       "${VENV_DIR}/tap-postgres/bin/tap-postgres"
# (Repeated for all connectors and fastsync)
EOF

# Create plw wrapper (auto-runs setup on first use)
cat > dist/pipelinewise/plw << 'EOF'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PIPELINEWISE_HOME="${PIPELINEWISE_HOME:-${HOME}/.pipelinewise}"

# Auto-setup if not already done
if [ ! -d "${PIPELINEWISE_HOME}/.virtualenvs" ]; then
    "${SCRIPT_DIR}/setup-connectors.sh"
fi

exec "${SCRIPT_DIR}/pipelinewise" "$@"
EOF
```

#### **6. Archive Creation**
```bash
# Create compressed tarball (parallel xz compression)
tar -cf - pipelinewise/ | xz -9 -T$(nproc) > pipelinewise-rhel7.tar.xz

# Create self-extracting installer
./create-self-extracting-installer.sh
```

### **Running the Build**

**Option 1: Docker Build (Recommended)**
```bash
# Clone repository
git clone https://github.com/transferwise/pipelinewise.git
cd pipelinewise

# Run build in CentOS 7 container
docker run --rm \
  -v $(pwd):/build \
  -w /build \
  centos:7 \
  bash -c '
    yum install -y python3.10 gcc make ccache xz &&
    chmod +x build-rhel7-standalone.sh &&
    ./build-rhel7-standalone.sh
  ' 2>&1 | tee build_log_$(date +%Y%m%d_%H%M%S).txt
```

**Option 2: Native Build (RHEL7/CentOS7 host)**
```bash
chmod +x build-rhel7-standalone.sh
./build-rhel7-standalone.sh
```

**Expected Output:**
```
=== Building PipelineWise for RHEL 7 compatibility ===
[1/4] Installing build dependencies...
[2/4] Pre-downloading wheels...
[3/4] Installing dependencies...
[4/4] Building standalone binaries (parallel)...
  Starting pipelinewise build...
  Starting tap-postgres build...
  Starting target-postgres build...
  Starting transform-field build...
  Starting postgres-to-postgres build...
All PyInstaller builds completed!
✓ Tarball created: dist/pipelinewise-rhel7.tar.xz (122MB)
✓ Installer created: dist/pipelinewise-installer.run (122MB)
```

---

## **Deployment**

### **Method 1: Self-Extracting Installer (Recommended)**

The `.run` installer is a **self-contained Bash script** with embedded tarball.

#### **Basic Installation**

```bash
# Copy installer to target host
scp dist/pipelinewise-installer.run user@target-host:/tmp/

# On target host, run installer
chmod +x /tmp/pipelinewise-installer.run
/tmp/pipelinewise-installer.run

# Follow interactive prompts:
# Install to [/root/pipelinewise]: /opt/pipelinewise
```

#### **Non-Interactive Installation**
```bash
# Install to custom directory
echo "/opt/pipelinewise" | /tmp/pipelinewise-installer.run

# Install to user home (no sudo)
/tmp/pipelinewise-installer.run --user

# Install to specific directory non-interactively
/tmp/pipelinewise-installer.run --dir /srv/pipelinewise
```

#### **Installer Behavior**

The installer performs these steps:

1. **Extracts bundle** to chosen directory
2. **Runs `setup-connectors.sh`** automatically (creates `~/.pipelinewise/.virtualenvs`)
3. **Creates symlinks** in `/usr/local/bin` (system-wide) or `~/.local/bin` (user install)
4. **Verifies installation** by running `pipelinewise --version`

**Installer Output:**
```
=============================================
  PipelineWise v0.73.0 Installer
  RHEL 7+ Standalone Distribution
=============================================

ℹ Checking system requirements...
✓ GLIBC version: 2.17 (>= 2.17 required)
✓ Disk space: 15000MB available

Installation Directory: /opt/pipelinewise
ℹ Extracting PipelineWise binaries...
✓ Extraction complete

ℹ Configuring PipelineWise environment...
✓ Executables configured
✓ Environment script created: env.sh

ℹ Testing installation...
✓ Main executable: PipelineWise 0.73.0
✓ tap-postgres: OK
✓ target-postgres: OK

✓ Installation completed successfully!

Quick Start:
  1. cd /opt/pipelinewise && source env.sh
  2. pipelinewise --version
  3. pipelinewise import_config --dir /path/to/config
```

### **Method 2: Manual Tarball Deployment**

For advanced users or automated deployments:

```bash
# Copy tarball
scp dist/pipelinewise-rhel7.tar.xz user@target:/tmp/

# Extract on target
cd /opt
tar -xJf /tmp/pipelinewise-rhel7.tar.xz

# Run setup manually
cd /opt/pipelinewise
./setup-connectors.sh

# Configure environment
source env.sh
```

### **Post-Installation Verification**

```bash
# Check installation
ls -la /opt/pipelinewise/
# Expected: pipelinewise, plw, env.sh, connectors/, bin/

# Check connector symlinks
ls -la ~/.pipelinewise/.virtualenvs/
# Expected: tap-postgres/, target-postgres/, transform-field/, pipelinewise/

# Verify main executable
/opt/pipelinewise/pipelinewise --version
# Expected: PipelineWise 0.73.0 - Command Line Interface

# Verify fastsync
ls -la ~/.pipelinewise/.virtualenvs/pipelinewise/bin/postgres-to-postgres
# Expected: symlink to /opt/pipelinewise/bin/postgres-to-postgres/postgres-to-postgres

# Test connector
~/.pipelinewise/.virtualenvs/tap-postgres/bin/tap-postgres --help
# Expected: tap-postgres help output
```

---

## **Configuration & Runtime**

### **Environment Variables**

| Variable | Default | Purpose |
|----------|---------|---------|
| `PIPELINEWISE_HOME` | `~/.pipelinewise` | Where configs, logs, and virtualenvs are stored |
| `PATH` | (modified) | Adds PipelineWise bin directory |

### **Using `env.sh` (Recommended)**

```bash
# Source environment script
cd /opt/pipelinewise
source env.sh

# Now available in PATH
pipelinewise --version
plw --help
```

### **Using `plw` Wrapper (Recommended)**

The `plw` wrapper provides Docker-compatible CLI and **auto-setup**:

```bash
# First run auto-creates ~/.pipelinewise/.virtualenvs
/opt/pipelinewise/plw --version

# Import configuration
/opt/pipelinewise/plw import_config --dir /path/to/configs

# Run sync
/opt/pipelinewise/plw run_tap --tap my_tap --target my_target
```

### **Configuration Structure**

Follow PipelineWise's standard YAML configuration:[2]

```yaml
# tap_postgres_prod.yml
id: tap_postgres_prod
name: Production PostgreSQL
type: tap-postgres
owner: data-team@company.com
target: target_postgres_warehouse

db_conn:
  host: prod-db.company.com
  port: 5432
  user: replication_user
  password: "${POSTGRES_PASSWORD}"  # From environment
  dbname: production
  
# Enable FastSync for initial load
fastsync: true

schemas:
  - source_schema: public
    target_schema: prod_public
    tables:
      - table_name: customers
        replication_method: LOG_BASED
        replication_key: id
      - table_name: orders
        replication_method: LOG_BASED
        replication_key: order_id
```

### **Import and Run**

```bash
# Import configurations
plw import_config --dir /etc/pipelinewise/configs

# Verify imported taps
plw status

# Run initial sync (uses fastsync for initial load)
plw run_tap --tap tap_postgres_prod --target target_postgres_warehouse

# Schedule with cron
0 */6 * * * /opt/pipelinewise/plw run_tap --tap tap_postgres_prod --target target_postgres_warehouse >> /var/log/pipelinewise/sync.log 2>&1
```

---

## **Testing & Verification**

### **End-to-End Testing**

The project includes comprehensive E2E tests in `test_e2e_postgres.sh`.

#### **Quick Test (5 minutes)**

```bash
# Tests: Basic sync, SCRAM auth, schema validation
./test_e2e_postgres.sh --quick 2>&1 | tee e2e_quick.log
```

**Tests performed:**
- ✅ Test F: SCRAM-SHA-256 authentication
- ✅ Test A: Initial full sync (1000 customers, 500 orders)
- ✅ Test B: Incremental sync (insert/update/delete)

#### **Full Test Suite (15 minutes)**

```bash
# All tests including performance and schema changes
./test_e2e_postgres.sh --full 2>&1 | tee e2e_full.log
```

**Additional tests:**
- ✅ Test C: Schema evolution (ALTER TABLE)
- ✅ Test D: Field transformations
- ✅ Test E: Large volume (10,000 orders, 50,000 items)

#### **Test Output**

```
2025-12-20 07:40:05 [INFO] Starting PipelineWise PostgreSQL E2E Tests
2025-12-20 07:40:05 ✅ Docker is available
2025-12-20 07:40:05 ✅ docker-compose is available
2025-12-20 07:40:05 ✅ PipelineWise RHEL7 tarball found
2025-12-20 07:40:09 ✅ All containers are ready
2025-12-20 07:40:21 ✅ PipelineWise deployed successfully
2025-12-20 07:40:23 [INFO] === TEST A: Initial Full Sync ===
2025-12-20 07:40:26 ✅ Test A: Initial sync - PASSED (3s)
2025-12-20 07:40:30 [INFO] === TEST B: Incremental Sync ===
2025-12-20 07:40:35 ✅ Test B: Incremental sync - PASSED (5s)

Test Results:
Test A: Initial Full Sync    PASSED   1000 rows synced in 3s
Test B: Incremental Sync     PASSED   150 changes synced
Test F: SCRAM Auth          PASSED   PostgreSQL 13

Reports: test_results/test_summary.txt
```

### **Manual Verification**

#### **1. Check FastSync Availability**

```bash
# Verify fastsync binary exists
ls -la /opt/pipelinewise/bin/postgres-to-postgres/postgres-to-postgres

# Verify symlink in virtualenvs
readlink -f ~/.pipelinewise/.virtualenvs/pipelinewise/bin/postgres-to-postgres

# Test fastsync help
~/.pipelinewise/.virtualenvs/pipelinewise/bin/postgres-to-postgres --help
```

**Expected output:**
```
usage: postgres-to-postgres [-h] --tap TAP --properties PROPERTIES --target TARGET
                             --transform TRANSFORM [--temp_dir TEMP_DIR]

FastSync from Postgres to Postgres
...
```

#### **2. Verify SCRAM Support**

```bash
# Check bundled libpq version
python3.10 << 'EOF'
import psycopg2
libpq_ver = psycopg2.__libpq_version__
print(f"libpq version: {libpq_ver} ({'SCRAM supported' if libpq_ver >= 100000 else 'Too old'})")
EOF
```

**Expected:** `libpq version: 140000 (SCRAM supported)`

#### **3. Test Connector Discovery**

```bash
# Check if PipelineWise finds connectors
plw validate --tap tap_postgres_test --target target_postgres_test
```

**Expected:** No "connector not found" errors

---

## **Troubleshooting**

### **Common Issues & Solutions**

#### **Issue 1: "Table sync function is not implemented"**

**Symptom:**
```
ERROR: Table sync function is not implemented from tap-postgres 
datasources to target-postgres type of targets
```

**Cause:** FastSync binary not found in expected location

**Solution:**
```bash
# Check if fastsync exists
ls -la ~/.pipelinewise/.virtualenvs/pipelinewise/bin/postgres-to-postgres

# If missing, re-run setup
cd /opt/pipelinewise
./setup-connectors.sh

# Verify symlink created
readlink -f ~/.pipelinewise/.virtualenvs/pipelinewise/bin/postgres-to-postgres
# Should output: /opt/pipelinewise/bin/postgres-to-postgres/postgres-to-postgres
```

#### **Issue 2: GLIBC version mismatch**

**Symptom:**
```
./pipelinewise: /lib64/libc.so.6: version `GLIBC_2.18' not found
```

**Cause:** Built on system with newer GLIBC than target

**Solution:**
```bash
# Check GLIBC version on target
ldd --version
# Must be >= 2.17

# If too old, rebuild on CentOS 7:
docker run --rm -v $(pwd):/build centos:7 bash -c '
  yum install -y python3.10 gcc make &&
  cd /build && ./build-rhel7-standalone.sh
'
```

#### **Issue 3: libcrypt.so.1 not found**

**Symptom:**
```
error while loading shared libraries: libcrypt.so.1: cannot open shared object file
```

**Cause:** `libcrypt.so.1` not bundled or not in correct location

**Solution:**
```bash
# Check if bundled
ls -la /opt/pipelinewise/_internal/libcrypt.so.1

# If missing, copy from build system
cp /usr/lib64/libcrypt.so.1 /opt/pipelinewise/_internal/

# Also copy to connectors
cp /usr/lib64/libcrypt.so.1 /opt/pipelinewise/connectors/tap-postgres/_internal/
cp /usr/lib64/libcrypt.so.1 /opt/pipelinewise/connectors/target-postgres/_internal/
```

#### **Issue 4: Permission denied**

**Symptom:**
```
bash: ./pipelinewise: Permission denied
```

**Solution:**
```bash
# Make executables executable
chmod +x /opt/pipelinewise/pipelinewise
chmod +x /opt/pipelinewise/plw
find /opt/pipelinewise/connectors -name "tap-*" -exec chmod +x {} \;
find /opt/pipelinewise/bin -name "postgres-to-postgres" -exec chmod +x {} \;
```

#### **Issue 5: SCRAM authentication failed**

**Symptom:**
```
psycopg2.OperationalError: FATAL: password authentication failed
```

**Cause:** Old libpq version without SCRAM support

**Solution:**
```bash
# Check bundled psycopg2 version
python3.10 -c "import psycopg2; print(psycopg2.__libpq_version__)"
# Must be >= 100000 (version 10.0)

# If too old, rebuild with psycopg2-binary >= 2.9.10
# Edit build-rhel7-standalone.sh:
python3.10 -m pip install --upgrade --force-reinstall 'psycopg2-binary>=2.9.10'
```

### **Debug Mode**

```bash
# Run with verbose logging
export LOGGING_CONF_FILE=/opt/pipelinewise/logging_debug.conf
plw run_tap --tap my_tap --target my_target

# Check logs
tail -f ~/.pipelinewise/logs/tap-postgres/*.log
```

### **Support Checklist**

Before opening an issue, collect:

```bash
# System info
cat /etc/os-release
ldd --version

# Installation info
/opt/pipelinewise/pipelinewise --version
ls -la ~/.pipelinewise/.virtualenvs/
readlink -f ~/.pipelinewise/.virtualenvs/pipelinewise/bin/postgres-to-postgres

# Test fastsync directly
~/.pipelinewise/.virtualenvs/pipelinewise/bin/postgres-to-postgres --help

# Recent logs
tail -100 ~/.pipelinewise/logs/*.log
```

---

## **CI/CD Integration**

### **GitHub Actions Example**

```yaml
name: Build RHEL7 Standalone

on:
  push:
    branches: [main]
    tags: ['v*']

jobs:
  build:
    runs-on: ubuntu-latest
    container: centos:7
    
    steps:
      - uses: actions/checkout@v3
      
      - name: Install Build Dependencies
        run: |
          yum install -y python3.10 gcc gcc-c++ make ccache xz
      
      - name: Build Standalone Bundle
        run: |
          chmod +x build-rhel7-standalone.sh
          ./build-rhel7-standalone.sh
        timeout-minutes: 30
      
      - name: Run E2E Tests
        run: |
          chmod +x test_e2e_postgres.sh
          ./test_e2e_postgres.sh --quick
      
      - name: Upload Artifacts
        uses: actions/upload-artifact@v3
        with:
          name: pipelinewise-rhel7
          path: |
            dist/pipelinewise-rhel7.tar.xz
            dist/pipelinewise-installer.run
      
      - name: Create Release
        if: startsWith(github.ref, 'refs/tags/')
        uses: softprops/action-gh-release@v1
        with:
          files: |
            dist/pipelinewise-rhel7.tar.xz
            dist/pipelinewise-installer.run
```

### **Jenkins Pipeline**

```groovy
pipeline {
    agent {
        docker {
            image 'centos:7'
            args '-v $PWD:/build'
        }
    }
    
    stages {
        stage('Build') {
            steps {
                sh '''
                    yum install -y python3.10 gcc make ccache xz
                    cd /build
                    chmod +x build-rhel7-standalone.sh
                    ./build-rhel7-standalone.sh
                '''
            }
        }
        
        stage('Test') {
            steps {
                sh './test_e2e_postgres.sh --quick'
            }
        }
        
        stage('Archive') {
            steps {
                archiveArtifacts artifacts: 'dist/*.tar.xz,dist/*.run', fingerprint: true
            }
        }
    }
}
```

---

## **Migration Guide**

### **From Docker to Standalone**

#### **1. Export Existing Configuration**

```bash
# In Docker environment
docker exec pipelinewise pipelinewise status --format json > pipelines.json

# Copy config directory
docker cp pipelinewise:/app/.pipelinewise/config ./pipelinewise-configs
```

#### **2. Deploy Standalone**

```bash
# Install on target
./pipelinewise-installer.run --dir /opt/pipelinewise

# Copy configs
cp -r ./pipelinewise-configs/* /opt/pipelinewise/configs/

# Import
cd /opt/pipelinewise
./plw import_config --dir /opt/pipelinewise/configs
```

#### **3. Update Cron Jobs**

```bash
# Old (Docker)
0 */6 * * * docker exec pipelinewise pipelinewise run_tap --tap my_tap

# New (Standalone)
0 */6 * * * /opt/pipelinewise/plw run_tap --tap my_tap >> /var/log/pipelinewise.log 2>&1
```

### **From Source Install to Standalone**

**Benefits of switching:**
- ✅ No Python version conflicts
- ✅ No virtualenv management
- ✅ Faster deployment
- ✅ Easier upgrades

**Migration steps:**
1. Backup existing configs: `~/.pipelinewise/config/`
2. Uninstall source version: `rm -rf ~/pipelinewise`
3. Install standalone: `./pipelinewise-installer.run`
4. Restore configs: `plw import_config --dir /path/to/backup`

---

## **Reference**

### **File Locations**

| Item | Location |
|------|----------|
| Main executable | `/opt/pipelinewise/pipelinewise` |
| Wrapper | `/opt/pipelinewise/plw` |
| FastSync binaries | `/opt/pipelinewise/bin/*/` |
| Connector bundles | `/opt/pipelinewise/connectors/*/` |
| Runtime virtualenvs | `~/.pipelinewise/.virtualenvs/` |
| Configurations | `~/.pipelinewise/config/` |
| State files | `~/.pipelinewise/*/state.json` |
| Logs | `~/.pipelinewise/logs/` |

### **Build Artifacts**

| File | Size | Compression | Use |
|------|------|-------------|-----|
| `pipelinewise/` | ~400MB | None | Direct extraction |
| `pipelinewise-rhel7.tar.xz` | ~120MB | xz -9 | Manual deployment |
| `pipelinewise-installer.run` | ~122MB | xz -9 + bash header | Recommended |

### **Performance Metrics**

| Operation | Time | Notes |
|-----------|------|-------|
| Build (cold) | 15-20 min | First build, no cache |
| Build (warm) | 8-12 min | With ccache and pip cache |
| Install | 30-60 sec | Self-extracting installer |
| Initial sync (1K rows) | 3-5 sec | With FastSync |
| Incremental sync (100 rows) | 1-2 sec | Log-based replication |

### **System Requirements**

**Minimum:**
- RHEL/CentOS 7 (GLIBC 2.17)
- 2GB RAM
- 500MB disk space
- PostgreSQL 9.6+ (source/target)

**Recommended:**
- RHEL/CentOS 7+ (GLIBC 2.17+)
- 4GB+ RAM
- 2GB+ disk space
- PostgreSQL 10+ (for SCRAM support)

### **Useful Commands**

```bash
# Check status
plw status

# Validate config
plw validate --tap my_tap --target my_target

# Run sync
plw run_tap --tap my_tap --target my_target

# View logs
tail -f ~/.pipelinewise/logs/*/singer.log

# Re-run setup
/opt/pipelinewise/setup-connectors.sh

# Update installation
# (Extract new version to same location, overwrites files)
./pipelinewise-installer-new.run --dir /opt/pipelinewise
```

### **Documentation Links**

- [PipelineWise Official Docs][1]
- [Creating Pipelines Guide][2]
- [Installation Methods][3]
- [GitHub Repository][4]

---

## **Changelog**

### **v0.73.0 (2025-12-20)**
- ✅ Added RHEL7 standalone build support
- ✅ Implemented `connectors/` directory structure
- ✅ Added FastSync postgres-to-postgres support
- ✅ Bundled `libcrypt.so.1` for RHEL7 compatibility
- ✅ Created self-extracting installer
- ✅ Added comprehensive E2E test suite
- ✅ SCRAM-SHA-256 authentication support (psycopg2-binary 2.9.10+)

---

**Questions?** Open an issue on GitHub or contact the PipelineWise team.[4]

[1](https://transferwise.github.io/pipelinewise/)
[2](https://transferwise.github.io/pipelinewise/installation_guide/creating_pipelines.html)
[3](https://transferwise.github.io/pipelinewise/installation_guide/installation.html)
[4](https://github.com/transferwise/pipelinewise)
[5](https://github.com/transferwise/pipelinewise-target-redshift/blob/master/README.md)
[6](https://github.com/transferwise/pipelinewise/blob/master/README.md)
[7](https://desktopcommander.app/blog/2025/12/08/markdown-best-practices-technical-documentation/)
[8](https://blog.devgenius.io/data-ingestion-with-pipelinewise-and-airflow-cdc69f72148f)
[9](https://pypi.org/project/pipelinewise-tap-s3-csv/)
[10](https://experienceleague.adobe.com/en/docs/contributor/contributor-guide/writing-essentials/markdown)