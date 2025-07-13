#!/bin/bash
set -euo pipefail

# Check if GITHUB_TOKEN is set
if [ -z "${GITHUB_TOKEN:-}" ]; then
    echo "Warning: GITHUB_TOKEN not set, skipping aida-cli installation"
    exit 0
fi

# Clean the token (remove any quotes)
CLEAN_TOKEN="${GITHUB_TOKEN//\"/}"
CLEAN_TOKEN="${CLEAN_TOKEN//\'/}"

# Debug: Check token format (hide actual token)
echo "Token length: ${#CLEAN_TOKEN}"
echo "Token starts with: ${CLEAN_TOKEN:0:10}..."

# Validate token format
if [[ ! "${CLEAN_TOKEN}" =~ ^github_pat_[a-zA-Z0-9_]+$ ]] && [[ ! "${CLEAN_TOKEN}" =~ ^ghp_[a-zA-Z0-9]+$ ]]; then
    echo "Error: Invalid GitHub token format"
    echo "Token should start with 'github_pat_' or 'ghp_' and contain only alphanumeric characters and underscores"
    echo ""
    echo "Note: Both classic and fine-grained personal access tokens are supported."
    echo "Fine-grained tokens start with 'github_pat_' and classic tokens start with 'ghp_'"
    exit 1
fi

# Test GitHub API access with the token
echo "Testing GitHub API access..."
API_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: token ${CLEAN_TOKEN}" https://api.github.com/user)

if [ "$API_RESPONSE" != "200" ]; then
    echo "Error: GitHub API returned status $API_RESPONSE"
    echo "Possible causes:"
    echo "  - Invalid or expired token"
    echo "  - Token lacks necessary permissions"
    echo "  - Network connectivity issues"
    echo ""
    echo "Please check your token has the 'repo' scope for accessing private repositories."
    exit 1
fi

echo "GitHub API access successful"

# Check if the repository exists and is accessible
echo "Checking repository access..."
REPO_CHECK=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: token ${CLEAN_TOKEN}" https://api.github.com/repos/clearclown/aida-cli)

if [ "$REPO_CHECK" = "404" ]; then
    echo "Error: Repository 'clearclown/aida-cli' not found or not accessible"
    echo "Please ensure:"
    echo "  - The repository exists"
    echo "  - You have access to the repository"
    echo "  - The token has 'repo' scope if it's a private repository"
    exit 1
elif [ "$REPO_CHECK" != "200" ]; then
    echo "Error: Unable to access repository (HTTP status: $REPO_CHECK)"
    exit 1
fi

echo "Repository access confirmed"

# Configure git to use the token
git config --global url."https://oauth2:${CLEAN_TOKEN}@github.com/".insteadOf "https://github.com/"

# Configure cargo to use git CLI for better authentication handling
mkdir -p ~/.cargo
if ! grep -q "git-fetch-with-cli" ~/.cargo/config.toml 2>/dev/null; then
    cat >> ~/.cargo/config.toml << EOF

[net]
git-fetch-with-cli = true
EOF
fi

# Set environment variables for GitHub authentication
export GITHUB_TOKEN="${CLEAN_TOKEN}"
export GH_TOKEN="${CLEAN_TOKEN}"

# Create ~/.local/bin directory if it doesn't exist
mkdir -p ~/.local/bin

# Add ~/.local/bin to PATH if not already present
if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
    export PATH="$HOME/.local/bin:$PATH"
fi

# Install orchestrobot
echo "Installing orchestrobot..."

# Method 1: Try to download from GitHub Releases first
echo "Checking for latest release..."

# Get the latest release info
LATEST_RELEASE=$(gh api repos/clearclown/aida-cli/releases/latest --jq '.tag_name' 2>/dev/null || echo "")

if [ -n "$LATEST_RELEASE" ]; then
    echo "Found latest release: $LATEST_RELEASE"
    # Determine the platform and architecture
    ARCH=$(uname -m)
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    # Map architecture names
    case "$ARCH" in
        x86_64)
            ARCH="x86_64"
            ;;
        aarch64|arm64)
            ARCH="aarch64"
            ;;
        *)
            echo "Unsupported architecture: $ARCH"
            ARCH=""
            ;;
    esac
    # Try common naming patterns for the binary
    BINARY_PATTERNS=(
        "orchestrobot-${OS}-${ARCH}"
        "orchestrobot-${ARCH}-${OS}"
        "orchestrobot_${OS}_${ARCH}"
        "orchestrobot-${LATEST_RELEASE}-${OS}-${ARCH}"
        "orchestrobot"
    )
    DOWNLOAD_SUCCESS=false
    for PATTERN in "${BINARY_PATTERNS[@]}"; do
        echo "Trying to download: $PATTERN"
        # Try to download the asset
        if gh release download "$LATEST_RELEASE" \
            --repo clearclown/aida-cli \
            --pattern "*${PATTERN}*" \
            --dir /tmp 2>/dev/null; then
            # Find the downloaded file
            DOWNLOADED_FILE=$(find /tmp -name "*${PATTERN}*" -type f -print -quit)
            if [ -n "$DOWNLOADED_FILE" ]; then
                echo "Downloaded: $DOWNLOADED_FILE"
                # Make it executable and move to ~/.local/bin directory
                chmod +x "$DOWNLOADED_FILE"
                mv "$DOWNLOADED_FILE" ~/.local/bin/orchestrobot
                DOWNLOAD_SUCCESS=true
                break
            fi
        fi
    done
    if [ "$DOWNLOAD_SUCCESS" = false ]; then
        echo "No pre-built binary found for $OS-$ARCH in release $LATEST_RELEASE"
        echo "Available assets:"
        gh release view "$LATEST_RELEASE" --repo clearclown/aida-cli --json assets --jq '.assets[].name'
    fi
else
    echo "No releases found or unable to access releases"
    DOWNLOAD_SUCCESS=false
fi

# Method 2: If download from releases failed, build from source
if [ "$DOWNLOAD_SUCCESS" = false ]; then
    echo "Falling back to building from source..."
    # Try using cargo install with git URL directly
    if ! cargo install --git "https://github.com/clearclown/aida-cli" --root ~/.cargo orchestrobot 2>/dev/null; then
        echo "Direct git installation failed, trying with manual clone..."
        # Clone and install from specific path
        TMP_DIR=$(mktemp -d)
        echo "Cloning repository to temporary directory..."
        if git clone --depth 1 "https://github.com/clearclown/aida-cli" "$TMP_DIR"; then
            echo "Repository cloned successfully"
            # Check if the orchestrobot directory exists
            if [ -d "$TMP_DIR/repos/orchestrobot" ]; then
                echo "Found orchestrobot in repos/orchestrobot, installing..."
                (cd "$TMP_DIR/repos/orchestrobot" && cargo install --path . --root ~/.cargo)
            elif [ -f "$TMP_DIR/Cargo.toml" ]; then
                # Check if it's in the root
                if grep -q "name = \"orchestrobot\"" "$TMP_DIR/Cargo.toml"; then
                    echo "Found orchestrobot in root, installing..."
                    (cd "$TMP_DIR" && cargo install --path . --root ~/.cargo)
                else
                    echo "Error: orchestrobot not found in expected locations"
                    rm -rf "$TMP_DIR"
                    exit 1
                fi
            else
                echo "Error: Cannot find orchestrobot package in the repository"
                rm -rf "$TMP_DIR"
                exit 1
            fi
            rm -rf "$TMP_DIR"
        else
            echo "Error: Failed to clone repository"
            exit 1
        fi
    fi
fi

# Verify installation
if command -v orchestrobot &> /dev/null; then
    echo "orchestrobot installation completed successfully"
    echo "Installed at: $(which orchestrobot)"
    orchestrobot --version || echo "Version information not available"
else
    echo "Error: orchestrobot installation verification failed"
    exit 1
fi
