#!/bin/bash

# ==============================================================================
#                      System Troubleshooting Utility
# ==============================================================================
# This script contains fixes for common system configuration issues that may
# be encountered while using the proxy tunnel scripts.

# --- Pre-flight Checks ---
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root. Please use 'sudo ./troubleshoot.sh'"
   exit 1
fi

# --- Fix 1: Comment out problematic repositories ---
# ------------------------------------------------------------------------------
# Problem: 'apt update' fails for a specific repository that is incompatible
#          with the proxy server.
# Cause: The proxy cannot establish a connection to certain servers.
# Solution: Comment out the source line for the problematic repository.
# ------------------------------------------------------------------------------
fix_problematic_repos() {
    echo "--- Checking for and disabling problematic APT repositories ---"
    
    local mint_repo="packages.linuxmint.com"
    local sources_files=("/etc/apt/sources.list" "/etc/apt/sources.list.d/"*.list)
    
    for file in "${sources_files[@]}"; do
        if [ -f "$file" ] && grep -q -E "^[^#]*$mint_repo" "$file"; then
            echo "Found problematic repository '$mint_repo' in $file. Commenting it out."
            sed -i "s|^deb.*$mint_repo.*|# & # Disabled by troubleshoot.sh due to proxy incompatibility|" "$file"
        fi
    done

    echo "Problematic repositories have been disabled."
    echo "---------------------------------------------------------"
}


# --- Fix 2: Force APT repositories to use HTTPS ---
# ------------------------------------------------------------------------------
# Problem: 'apt update' fails with "Connection failed" for HTTP repositories.
# Cause: Some proxies are configured to reject plain HTTP requests.
# Solution: Upgrade official repository URLs from 'http://' to 'https://'.
# ------------------------------------------------------------------------------
force_https_for_apt() {
    echo "--- Forcing APT repositories to use HTTPS ---"
    
    local source_files=("/etc/apt/sources.list" "/etc/apt/sources.list.d/"*.list)
    local repos_to_upgrade=(
        "http://archive.ubuntu.com/ubuntu"
        "http://security.ubuntu.com/ubuntu"
    )

    for file in ${source_files[@]}; do
        if [ -f "$file" ]; then
             for repo in "${repos_to_upgrade[@]}"; do
                sed -i "s|${repo}|$(echo ${repo} | sed 's|http|https|')|g" "$file"
            done
        fi
    done

    echo "APT sources have been updated to use HTTPS."
    echo "---------------------------------------------"
}


# --- Fix 3: Missing GPG Key for Microsoft Repositories ---
# ------------------------------------------------------------------------------
# Problem: When running 'apt update', you see "NO_PUBKEY EB3E94ADBE1229CF"
# Cause: Your system does not have the public key to verify Microsoft's packages.
# Solution: Download and install the key using the official, recommended method.
# ------------------------------------------------------------------------------
fix_microsoft_gpg_key() {
    echo "--- Fixing missing GPG key for Microsoft repositories ---"

    wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /etc/apt/keyrings/packages.microsoft.gpg
    chmod 644 /etc/apt/keyrings/packages.microsoft.gpg

    local vscode_list="/etc/apt/sources.list.d/vscode.list"
    if [ ! -f "$vscode_list" ]; then
        echo "Microsoft (vscode) source list not found. Creating it."
        echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" > "$vscode_list"
    else
        echo "Microsoft (vscode) source list found. Ensuring it uses the correct keyring."
        sed -i 's|\[arch=amd64,arm64,armhf\]|\[arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg\]|' "$vscode_list"
        sed -i 's|\[arch=amd64\]|\[arch=amd64 signed-by=/etc/apt/keyrings/packages.microsoft.gpg\]|' "$vscode_list"
    fi

    echo "Microsoft GPG key has been installed and configured."
    echo "---------------------------------------------------------"
}

# --- Main Script Logic ---
echo "Running system troubleshooters..."
echo ""

fix_problematic_repos
force_https_for_apt
fix_microsoft_gpg_key

echo ""
echo "Applying all fixes by running 'apt-get update'..."
apt-get update

echo ""
echo "Troubleshooting script finished."
