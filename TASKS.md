# Proxy Tunnel Scripts Task List

## Core Functionality
- [x] Create `start_proxy.sh` to establish a system-wide tunnel with `tun2socks`.
- [x] Create `stop_proxy.sh` for a clean shutdown and restoration of network settings.
- [x] Configure DNS-over-TLS to prevent DNS leaks through the proxy.

## Bug Fixes & Robustness
- [x] Fix DNS traffic being incorrectly routed via the proxy by implementing policy-based routing.
- [x] Fix application hangs (e.g., `apt`) by enabling the `tun2socks` DNS fallback proxy.
- [x] Add pre-run cleanup to `start_proxy.sh` to make it robust against previous failures.
- [x] Ensure the virtual `tun` device is properly deleted on both start and stop to prevent "device busy" errors.
- [x] Improve script idempotency to prevent "duplicate route" errors on subsequent runs.

## Features & Utilities
- [x] Configure `apt` to be proxy-aware when the tunnel is active.
- [x] Add detailed comments and variables to improve script readability and maintainability.
- [x] Create a troubleshooting script to fix common `apt` GPG key errors, force HTTPS, and disable incompatible repositories.
