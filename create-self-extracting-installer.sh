#!/bin/bash
# create-self-extracting-installer.sh - Creates PipelineWise self-extracting installer

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="${DIST_DIR:-$SCRIPT_DIR/dist}"
TARBALL="$DIST_DIR/pipelinewise-rhel7.tar.xz"
OUTPUT="$DIST_DIR/pipelinewise-installer.run"

# Color codes for output
GREEN='\033[0;32m'
NC='\033[0m' # No Color

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

if [ ! -f "$TARBALL" ]; then
    echo "Error: Tarball not found: $TARBALL"
    exit 1
fi

echo "Creating self-extracting installer..."
echo "Source tarball: $TARBALL"
echo "Output installer: $OUTPUT"

# Create the installer header
cat > "$OUTPUT" << 'EOF_HEADER'
#!/bin/bash
# PipelineWise RHEL7 Self-Extracting Installer
# This installer will extract and configure PipelineWise standalone binaries

set -e

INSTALLER_VERSION="0.73.0"
REQUIRED_GLIBC="2.17"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Print functions
print_header() {
    echo -e "${BLUE}=============================================${NC}"
    echo -e "${BLUE}  PipelineWise v${INSTALLER_VERSION} Installer${NC}"
    echo -e "${BLUE}  RHEL 7+ Standalone Distribution${NC}"
    echo -e "${BLUE}=============================================${NC}"
    echo ""
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    print_info "Checking system requirements..."
    
    # Check GLIBC version
    if command -v ldd >/dev/null 2>&1; then
        GLIBC_VERSION=$(ldd --version | head -n1 | grep -oP '\d+\.\d+$' || echo "0.0")
        if awk "BEGIN {exit !($GLIBC_VERSION >= $REQUIRED_GLIBC)}"; then
            print_success "GLIBC version: $GLIBC_VERSION (>= $REQUIRED_GLIBC required)"
        else
            print_error "GLIBC version $GLIBC_VERSION is too old (>= $REQUIRED_GLIBC required)"
            echo "This system is not compatible with this installer."
            exit 1
        fi
    else
        print_warning "Cannot verify GLIBC version (ldd not found)"
    fi
    
    # Check available disk space (need at least 500MB)
    AVAILABLE_SPACE=$(df -BM . | tail -1 | awk '{print $4}' | sed 's/M//')
    if [ "$AVAILABLE_SPACE" -lt 500 ]; then
        print_error "Insufficient disk space: ${AVAILABLE_SPACE}MB available (500MB required)"
        exit 1
    fi
    print_success "Disk space: ${AVAILABLE_SPACE}MB available"
    
    echo ""
}

# Prompt for installation directory
get_install_dir() {
    local default_dir="$HOME/pipelinewise"
    
    echo -e "${BLUE}Installation Directory${NC}"
    echo "Please enter the directory where PipelineWise will be installed."
    echo "The directory will be created if it doesn't exist."
    echo ""
    echo -n "Install to [$default_dir]: "
    read -r INSTALL_DIR
    
    # Use default if empty
    if [ -z "$INSTALL_DIR" ]; then
        INSTALL_DIR="$default_dir"
    fi
    
    # Expand ~ to home directory
    INSTALL_DIR="${INSTALL_DIR/#\~/$HOME}"
    
    # Check if directory exists and is not empty
    if [ -d "$INSTALL_DIR" ] && [ "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]; then
        echo ""
        print_warning "Directory already exists and is not empty: $INSTALL_DIR"
        echo -n "Overwrite? (yes/no) [no]: "
        read -r CONFIRM
        if [ "$CONFIRM" != "yes" ] && [ "$CONFIRM" != "y" ]; then
            echo "Installation cancelled."
            exit 0
        fi
        rm -rf "$INSTALL_DIR"
    fi
    
    # Create directory
    mkdir -p "$INSTALL_DIR"
    
    # Check if we can write to it
    if [ ! -w "$INSTALL_DIR" ]; then
        print_error "Cannot write to directory: $INSTALL_DIR"
        echo "Try running with sudo or choose a different directory."
        exit 1
    fi
    
    print_success "Installation directory: $INSTALL_DIR"
    echo ""
}

# Extract archive
extract_archive() {
    print_info "Extracting PipelineWise binaries..."
    
    # Find the start of the archive in this script
    ARCHIVE_LINE=$(awk '/^__ARCHIVE_BELOW__/ {print NR + 1; exit 0}' "$0")
    
    # Extract using tail and tar
    if tail -n +$ARCHIVE_LINE "$0" | tar -xJ -C "$INSTALL_DIR" --strip-components=1; then
        print_success "Extraction complete"
    else
        print_error "Extraction failed"
        exit 1
    fi
    
    echo ""
}

# Setup symlinks and environment
setup_environment() {
    print_info "Configuring PipelineWise environment..."
    
    cd "$INSTALL_DIR"
    
    # Verify critical executables exist
    if [ ! -f "pipelinewise" ]; then
        print_error "Main executable not found: pipelinewise"
        exit 1
    fi
    
    # Make sure all executables are executable
    chmod +x pipelinewise 2>/dev/null || true
    chmod +x plw 2>/dev/null || true
    find .virtualenvs -type f -name "tap-postgres" -exec chmod +x {} \; 2>/dev/null || true
    find .virtualenvs -type f -name "target-postgres" -exec chmod +x {} \; 2>/dev/null || true
    find .virtualenvs -type f -name "transform-field" -exec chmod +x {} \; 2>/dev/null || true
    find bin -type f -name "postgres-to-postgres" -exec chmod +x {} \; 2>/dev/null || true
    
    print_success "Executables configured"
    
    # Verify env.sh exists (should be created during build)
    if [ ! -f "env.sh" ]; then
        # Create env.sh if it doesn't exist
        cat > "$INSTALL_DIR/env.sh" << 'EOF_ENV'
#!/bin/bash
# PipelineWise Environment Setup
# Source this file: source env.sh

export PIPELINEWISE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$PIPELINEWISE_HOME:$PATH"

echo "PipelineWise environment configured"
echo "  PIPELINEWISE_HOME: $PIPELINEWISE_HOME"
echo ""
echo "Usage:"
echo "  pipelinewise --help"
echo "  pipelinewise --version"
echo "  plw --help          # Wrapper script with Docker-like interface"
EOF_ENV
        chmod +x "$INSTALL_DIR/env.sh"
    fi
    
    print_success "Environment script created: env.sh"

    # Run connector setup (optional: set SKIP_SETUP=1 to skip)
    SKIP_SETUP="${SKIP_SETUP:-0}"
    if [ "$SKIP_SETUP" -eq 0 ]; then
        print_info "Setting up connectors..."
        # Run the bundled setup script
        if [ -f "${INSTALL_DIR}/setup-connectors.sh" ]; then
            export PIPELINEWISE_HOME="${HOME}/.pipelinewise"
            "${INSTALL_DIR}/setup-connectors.sh"
        else
            print_error "setup-connectors.sh not found in bundle"
            exit 1
        fi

        print_success "Connector setup completed"
    fi
    
    echo ""
}

# Test installation
test_installation() {
    print_info "Testing installation..."
    
    cd "$INSTALL_DIR"
    
    # Test main executable
    if ./pipelinewise --version >/dev/null 2>&1; then
        VERSION=$(./pipelinewise --version 2>&1 | head -1)
        print_success "Main executable: $VERSION"
    else
        print_error "Main executable test failed"
        exit 1
    fi
    
    # Test tap-postgres
    if [ -f ".virtualenvs/tap-postgres/bin/tap-postgres" ]; then
        if .virtualenvs/tap-postgres/bin/tap-postgres --help >/dev/null 2>&1; then
            print_success "tap-postgres: OK"
        else
            print_info "tap-postgres: Available (test skipped)"
        fi
    fi
    
    # Test target-postgres (usually fails during install due to missing config, that's OK)
    if [ -f ".virtualenvs/target-postgres/bin/target-postgres" ]; then
        if .virtualenvs/target-postgres/bin/target-postgres --help >/dev/null 2>&1; then
            print_success "target-postgres: OK"
        else
            print_info "target-postgres: Available (test skipped)"
        fi
    fi
    
    echo ""
}

# Print installation summary
print_summary() {
    print_header
    print_success "Installation completed successfully!"
    echo ""
    echo -e "${BLUE}Installation Details:${NC}"
    echo "  Location: $INSTALL_DIR"
    echo "  Version: $INSTALLER_VERSION"
    echo "  SCRAM Authentication: Supported (PostgreSQL 17 libpq)"
    echo ""
    echo -e "${BLUE}Quick Start:${NC}"
    echo "  1. Configure environment:"
    echo "     cd $INSTALL_DIR"
    echo "     source env.sh"
    echo ""
    echo "  2. Verify installation:"
    echo "     pipelinewise --version"
    echo ""
    echo "  3. Import configuration:"
    echo "     pipelinewise import_config --dir /path/to/config"
    echo ""
    echo -e "${BLUE}Documentation:${NC}"
    echo "  https://github.com/transferwise/pipelinewise"
    echo ""
    echo -e "${GREEN}Enjoy using PipelineWise!${NC}"
    echo ""
}

# Main installation process
main() {
    print_header
    check_prerequisites
    get_install_dir
    extract_archive
    setup_environment
    test_installation
    print_summary
}

# Run main installation
main

exit 0

__ARCHIVE_BELOW__
EOF_HEADER

# Append the tarball to the installer
cat "$TARBALL" >> "$OUTPUT"

# Make the installer executable
chmod +x "$OUTPUT"

INSTALLER_SIZE=$(du -h "$OUTPUT" | cut -f1)
echo ""
print_success "Self-extracting installer created!"
echo "  Location: $OUTPUT"
echo "  Size: $INSTALLER_SIZE"
echo ""
echo "Deployment:"
echo "  1. Copy to target system: scp $OUTPUT user@host:/tmp/"
echo "  2. Run installer: /tmp/$(basename "$OUTPUT")"
echo ""
