# Tasks

- [x] Fix bug in `start_proxy.sh` where DB host resolution fails for hostnames that return a CNAME record.
- [x] Fix network connectivity failure by disabling Reverse Path Filtering (`rp_filter`) while the proxy is active.
- [x] Fix exempted UDP/ICMP traffic by using a private IP for the virtual TUN device and removing the `-interface` flag from `tun2socks`.
      