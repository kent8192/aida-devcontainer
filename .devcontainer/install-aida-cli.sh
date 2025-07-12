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
cat >> ~/.cargo/config.toml << EOF
[net]
git-fetch-with-cli = true
EOF

# Install aida-cli
echo "Installing orchestrobot..."
TMP_DIR=$(mktemp -d)
git clone --depth 1 "https://github.com/clearclown/aida-cli" "$TMP_DIR"
(cd "$TMP_DIR/repos/orchestrobot" && cargo install --path .)
rm -rf "$TMP_DIR"

echo "orchestrobot installation completed successfully"