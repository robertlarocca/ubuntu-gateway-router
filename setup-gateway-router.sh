#!/bin/bash

# Copyright (c) 2026 Robert LaRocca

# Setup an Ubuntu 26.04 LTS host as a dual-stack gateway router.
#
# Components:
#  - netplan: Interface addressing, VLAN sub-interfaces and WAN DHCP, SLAAC, DHCPv6 client
#  - nftables: Stateful firewall, NAT44, per-VLAN forwarding policy
#  - kea: DHCPv4 and DHCPv6 (stateful) with dynamic DNS (DDNS) updates
#  - bind9: Validating recursive resolver with authoritative internal zones
#  - frr: OSPFv2 and OSPFv3 with IPv6 router advertisement dynamic routing
#
# Topology assumed by the defaults below:
#  Internet
#     |
#  [ WAN_IF ] DHCPv4, SLAAC, DHCPv6 from ISP
#     |
#  +--------------- ROUTER ----------------+
#  | lo / loopback / dum0 / OSPF router-id |
#  +---------------------------------------+
#     |
#  [ LAN_TRUNK_IF ] 802.1Q trunk to switch
#     |
#  +--- vlan1    usr    10.11.1.0/24    fd01:10:11:1::/64
#  +--- vlan2    iot    10.11.2.0/24    fd01:10:11:2::/64
#  +--- vlan3    dmz    10.11.3.0/24    fd01:10:11:3::/64
#  +--- vlan100  adm    10.11.100.0/24  fd01:10:11:100::/64
#
# IPv4 is NAT'ed (masquerade) out of WAN_IF. IPv6 is routed, not NAT'ed, and
# is filtered statefully instead.
#
# Usage:
#  sudo ./setup-gateway-router.sh              # Rednder, validate, only
#  sudo ./setup-gateway-router.sh --dry-run    # Rednder and validate only, skip setup
#  sudo ./setup-gateway-router.sh --yes        # non-interactive, render, validate, setup
#
# IMPORTANT: applying netplan/nftables over SSH can lock you out. Run from a
# console, or from the admin VLAN, or keep a `sleep 600; netplan revert`
# safety net running in another session.
#

set -euo pipefail
IFS=$'\n\t'
umask 022

# -----------------------------------------------------------------------------
# SECTION 1 - SITE CONFIGURATION
# Everything an operator normally needs to change lives in this block.
# -----------------------------------------------------------------------------

## Identity
# Set hostname and internal DNS zone name.
ROUTER_HOSTNAME="gateway1"
# Use a registered or reserved domain. Do not invent a TLD like private or lan
DOMAIN="larocca.io"

## Physical interfaces
# Find real network interface names with command: ip -br link
# Set WAN interface (uplink to ISP gateway or modem)
WAN_IF="enp1s0f0"
# Set LAN interface for 802.1Q trunk (uplink to access switch)
LAN_TRUNK_IF="enp1s0f2"
# Set VLAN or virtual local area network prefix (eg. vlan1, vlan10, vlan20, etc)
# Note: The (prefix + number) is limited to 15 total characters
VLAN_IF_PREFIX="vlan"

## Loopback (stable router-id and administrator IPv4 address)
# Set DUM (dummy) interface used so address will survive physical link failure
LOOPBACK_IF="lo"
# Set loopback (dummy) IPv4 address using CIDR notation
LOOPBACK_V4="10.11.0.1/32"
# Set OSPF ID  to above loopback (dummy) IPv4 address
OSPF_ROUTER_ID="10.11.0.1"

## IPv6 address prefixes
# Note: Replace 2001:db8::/32 it will not route (See: RFC 3849)
# Set GUA prefix (/48 or /56) assigned by ISP or RIR delegate
# IPV6_GUA_PREFIX="2001:db8:1000::/48"
# Generate random /48 prefox with command: openssl rand -hex 5  # or
# echo "fd$(openssl rand -hex 1):$(openssl rand -hex 2):$(openssl rand -hex 2)"
# Set ULA prefix for stable internal addresses that survive ISP changes
IPV6_ULA_PREFIX="fd09:10:11::/48"
# Set loopback (dummy) IPv6 address using CIDR notation (either GUA or ULA)
LOOPBACK_V6="fd09:10:11:0::1/128"

# Set to "yes" if ISP or RIR delegates prefixs dynamically using DHCPv6-PD
# instead of statically assigned. Netplan does not have native key for prefix
# delegation, so a systemd-networkd override in also used beside the netplam
# generated unit (see configure_dhcpv6_pd). The DHCPv6-PD /64 prefixes below
# are not stable, so plan to use ULA for internal addresses and treat GUA
# as ephemeral.
ENABLE_DHCPV6_PD="yes"

## VLAN definitions
# Colon-delimited fields:
#  - 1 vlan-id
#  - 2 short name (used in DNS names, nft comments, kea subnet names)
#  - 3 router IPv4 address in CIDR form (the default gateway for that VLAN)
#  - 4 DHCPv4 dynamic pool  (start-end)
#  - 5 IPv6 subnet id, i.e. the 4th hextet appended to the /48 -> :<id>::/64
#  - 6 zone class: trusted | restricted | dmz | admin  (drives firewall policy)
VLAN_DEFS=(
  "1:default:10.11.1.1/24:10.11.1.100-10.11.1.199:0001:trusted"
  "2:wifi:10.11.2.1/24:10.11.2.100-10.11.2.199:0002:trusted"
  "3:iot:10.11.3.1/24:10.11.3.100-10.11.3.199:0003:restricted"
  "4:dmz:10.11.4.1/24:10.11.4.100-10.11.4.199:0004:dmz"
  "5:guest:10.11.5.1/24:10.11.5.100-10.11.5.199:0005:dmz"
  "99:admin:10.11.99.1/24:10.11.99.100-10.11.99.199:0099:admin"
)

# Set VLAN for managment (hosts may connect via SSH and talk OSPF to router).
ADMIN_VLAN_ID="99"

## DHCPv4 and DHCPv6 timers (seconds)
DHCP4_VALID_LIFETIME="3600"
DHCP4_RENEW_TIMER="1800"
DHCP4_REBIND_TIMER="2700"
DHCP6_VALID_LIFETIME="7200"
DHCP6_PREFERRED_LIFETIME="3600"

## Published services (reachable from the Internet)
# IPv4 sets DNAT rule. IPv6 does not need or use NAT rule, just a forward
# permit to real host global IPv6 address. Use "-" to skip IPv4 or IPv6 family.
# Leave the below array empty to not publish services nor configure.
# Pipe-delimited fields:
#  - 1 proto
#  - 2 external-port
#  - 3 internal-v4
#  - 4 internal-v6
#  - 5 internal-port
PUBLISHED_SERVICES=(
  # "tcp|443|10.11.4.10|fd09:10:11:4::10|443"
)

## OSPF
OSPF_AREA="0.0.0.0"
# Set random MD5 HMAC auth key for OSPFv2
OSPF_AUTH_KEY="$(openssl rand -hex 16)"
# Set to "yes" and edit SECTION 9
ENABLE_BGP="no"

## Behaviour flags
DRY_RUN="no"
ASSUME_YES="no"
# Set filesystem prefix used with --dry-run option
ROOT=""
BACKUP_DIR="/root/gateway-router-config-backup-$(date +%Y%m%d-%H%M%S)"

# -----------------------------------------------------------------------------
# SECTION 2 - ARGUMENT PARSING AND HELPERS
# -----------------------------------------------------------------------------

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \?//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN="yes"; ROOT="/tmp/gateway-router-config" ;;
    --yes | -y) ASSUME_YES="yes" ;;
    --help | -h) usage 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage 2 ;;
  esac
  shift
done

# Coloured, timestamped logging so a long run is easy to follow.
log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fatal]\033[0m %s\n' "$*" >&2; exit 1; }

# Ask before doing something that can sever remote access.
confirm() {
  [ "$ASSUME_YES" = "yes" ] && return 0
  [ "$DRY_RUN" = "yes" ] && return 0
  printf '\033[1;33m?\033[0m %s [y/N] ' "$1"
  read -r reply < /dev/tty
  case "$reply" in [yY]*) return 0 ;; *) die "aborted by operator" ;; esac
}

# Run a command, or just print it when --dry-run is active.
run() {
  if [ "$DRY_RUN" = "yes" ]; then
    # IFS is newline/tab globally, so force spaces just for this join.
    local IFS=' '
    printf '  \033[2m(dry-run) %s\033[0m\n' "$*"
  else
    "$@"
  fi
}

# Copy a file we are about to overwrite into the backup directory, preserving
# its path so the tree can be restored wholesale with `cp -a`.
backup_file() {
  local f="$1"
  [ "$DRY_RUN" = "yes" ] && return 0
  [ -e "$f" ] || return 0
  local dest="${BACKUP_DIR}${f}"
  mkdir -p "$(dirname "$dest")"
  cp -a "$f" "$dest"
}

# Create the parent directory of a target file (respecting $ROOT for dry runs)
# and back up whatever is already there.
prepare() {
  local target="$1"
  mkdir -p "$(dirname "${ROOT}${target}")"
  backup_file "$target"
}

## Address arithmetic helpers
# Python's ipaddress module is used rather than hand-rolled bit twiddling:
# it is in the base install, and it is correct for both address families.

# 10.10.10.1/24 -> 10.10.10.0/24
v4_network() {
  python3 -c 'import sys,ipaddress;print(ipaddress.ip_interface(sys.argv[1]).network)' "$1"
}

# 10.10.10.1/24 -> 10.10.10.1
v4_addr() { printf '%s\n' "${1%%/*}"; }

# 10.10.10.0/24 -> 10.10.10.in-addr.arpa   (only valid for /24, /16, /8)
v4_arpa_zone() {
  python3 - "$1" <<'PY'
import sys, ipaddress
net = ipaddress.IPv4Network(sys.argv[1])
if net.prefixlen % 8:
    sys.exit("classless reverse zones need RFC 2317 delegation; use /8,/16,/24")
octets = str(net.network_address).split('.')[: net.prefixlen // 8]
print('.'.join(reversed(octets)) + '.in-addr.arpa')
PY
}

# 2001:db8:1000::/48 -> 0.0.0.1.8.b.d.0.1.0.0.2.ip6.arpa
v6_arpa_zone() {
  python3 - "$1" <<'PY'
import sys, ipaddress
net = ipaddress.IPv6Network(sys.argv[1], strict=False)
if net.prefixlen % 4:
    sys.exit("ip6.arpa zone cut requires a prefix length that is a multiple of 4")
nibbles = net.network_address.exploded.replace(':', '')
print('.'.join(reversed(nibbles[: net.prefixlen // 4])) + '.ip6.arpa')
PY
}

# ("2001:db8:1000::/48", "0010") -> 2001:db8:1000:10::/64
# Builds a per-VLAN /64 out of the site prefix plus a subnet id.
v6_subnet() {
  python3 - "$1" "$2" <<'PY'
import sys, ipaddress
base = ipaddress.IPv6Network(sys.argv[1], strict=False)
if base.prefixlen > 64:
    sys.exit("site prefix must be /64 or shorter")
sid = int(sys.argv[2], 16)
shift = 64 - base.prefixlen
if sid >= 1 << shift:
    sys.exit(f"subnet id {sys.argv[2]} does not fit in a /{base.prefixlen}")
net = ipaddress.IPv6Network((int(base.network_address) | (sid << 64), 64))
print(net)
PY
}

# ("2001:db8:1000:10::/64", 1) -> 2001:db8:1000:10::1
v6_host() {
  python3 - "$1" "$2" <<'PY'
import sys, ipaddress
net = ipaddress.IPv6Network(sys.argv[1], strict=False)
print(net.network_address + int(sys.argv[2]))
PY
}

## Convenience lists derived from VLAN_DEFS
# Populated once here so later sections can iterate cheaply.
VLAN_IFACES=()                          # vl10 vl20 ...
for _def in "${VLAN_DEFS[@]}"; do
  IFS=':' read -r _id _name _v4 _pool _sid _class <<<"$_def"
  VLAN_IFACES+=("${VLAN_IF_PREFIX}${_id}")
done
# Space-separated form for nftables set literals, e.g. "vl10", "vl20"
NFT_LAN_IF_SET=$(printf '"%s", ' "${VLAN_IFACES[@]}"); NFT_LAN_IF_SET="${NFT_LAN_IF_SET%, }"
ADMIN_IF="${VLAN_IF_PREFIX}${ADMIN_VLAN_ID}"
# The administrator VLAN's own IPv4 CIDR, pulled out once for the BIND ACL below.
ADMIN_V4_CIDR=""
for _def in "${VLAN_DEFS[@]}"; do
  IFS=':' read -r _id _name _v4 _pool _sid _class <<<"$_def"
  [ "$_id" = "$ADMIN_VLAN_ID" ] && ADMIN_V4_CIDR="$_v4"
done

# -----------------------------------------------------------------------------
# SECTION 3 - PREFLIGHT CHECKS
# Fail early and loudly rather than half-configuring a router.
# -----------------------------------------------------------------------------

preflight() {
  log "Preflight checks"

  [ "$(id -u)" -eq 0 ] || die "must run as root (try: sudo $0)"

  # Confirm the distribution. The script targets 26.04 but will run on any
  # release that ships nftables >= 1.0 and kea >= 2.4; warn instead of abort.
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    ok "detected ${PRETTY_NAME:-unknown}"
    case "${VERSION_ID:-}" in
      26.04) : ;;
      *) warn "script was written for Ubuntu 26.04 LTS; found '${VERSION_ID:-?}'" ;;
    esac
  else
    warn "/etc/os-release missing - cannot verify distribution"
  fi

  # Physical interfaces must exist, otherwise netplan will silently produce a
  # config that never comes up.
  for iface in "$WAN_IF" "$LAN_TRUNK_IF"; do
    if ip link show "$iface" >/dev/null 2>&1; then
      ok "interface $iface present"
    else
      if [ "$DRY_RUN" = "yes" ]; then
        warn "interface $iface not present (tolerated in --dry-run)"
      else
        die "interface $iface not found - fix WAN_IF/LAN_TRUNK_IF and re-run"
      fi
    fi
  done

  [ "$WAN_IF" != "$LAN_TRUNK_IF" ] || die "WAN_IF and LAN_TRUNK_IF must differ"

  # Sanity-check the prefixes and every VLAN row before writing anything.
  v6_arpa_zone "$IPV6_GUA_PREFIX" >/dev/null || die "bad IPV6_GUA_PREFIX"
  v6_arpa_zone "$IPV6_ULA_PREFIX" >/dev/null || die "bad IPV6_ULA_PREFIX"

  local seen_ids=" " seen_admin="no"
  for def in "${VLAN_DEFS[@]}"; do
    IFS=':' read -r id name v4 pool sid class <<<"$def"
    [ -n "$id" ] && [ -n "$name" ] && [ -n "$v4" ] && [ -n "$pool" ] \
      && [ -n "$sid" ] && [ -n "$class" ] || die "malformed VLAN_DEFS row: $def"
    [ "$id" -ge 1 ] && [ "$id" -le 4094 ] || die "VLAN id out of range: $id"
    case "$seen_ids" in *" $id "*) die "duplicate VLAN id $id" ;; esac
    seen_ids="${seen_ids}${id} "
    case "$class" in
      trusted|restricted|dmz|admin) : ;;
      *) die "unknown zone class '$class' for VLAN $id" ;;
    esac
    v4_network "$v4" >/dev/null || die "bad IPv4 CIDR for VLAN $id"
    v6_subnet "$IPV6_GUA_PREFIX" "$sid" >/dev/null || die "bad v6 sid for VLAN $id"
    [ "$id" = "$ADMIN_VLAN_ID" ] && seen_admin="yes"
    ok "VLAN ${id} (${name}/${class}) validated"
  done
  [ "$seen_admin" = "yes" ] || die "ADMIN_VLAN_ID=$ADMIN_VLAN_ID has no VLAN_DEFS entry"

  if [ "$DRY_RUN" = "yes" ]; then
    rm -rf "$ROOT"
    mkdir -p "$ROOT"
    warn "DRY RUN: configs render under $ROOT, nothing is installed or applied"
  else
    mkdir -p "$BACKUP_DIR"
    ok "backups will be written to $BACKUP_DIR"
  fi
}

# -----------------------------------------------------------------------------
# SECTION 4 - PACKAGE INSTALLATION
# -----------------------------------------------------------------------------

install_packages() {
  log "Installing packages"

  # Package set, grouped by role:
  #   netplan.io           - declarative front end to systemd-networkd
  #   nftables             - firewall engine + nft CLI + nftables.service
  #   kea-*                - ISC Kea DHCP servers and the DDNS forwarder
  #   bind9*               - named plus dig/nsupdate/named-check* tooling
  #   frr, frr-pythontools - routing daemons and frr-reload.py
  #   conntrack/tcpdump    - troubleshooting a router without these is painful
  local pkgs=(
    netplan.io
    nftables
    kea kea-admin kea-common kea-ctrl-agent kea-dhcp-ddns-server kea-dhcp4-server kea-dhcp6-server
    bind9 bind9-dnsutils bind9-utils
    frr frr-pythontools
    ca-certificates conntrack ethtool iperf3 mtr-tiny openssl python3 tcpdump
  )

  if [ "$DRY_RUN" = "yes" ]; then
    ( IFS=' '; printf '  \033[2m(dry-run) apt install -y %s\033[0m\n' "${pkgs[*]}" )
    return 0
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt update -qq
  # --no-install-recommends keeps the router lean; add recommends deliberately.
  apt install -y --no-install-recommends "${pkgs[@]}"
  ok "packages installed"

  # Kea and BIND start with vendor defaults that may bind to the wrong
  # interfaces. Stop them while we rewrite their configuration.
  systemctl stop kea-dhcp4-server kea-dhcp6-server kea-dhcp-ddns-server \
                 named 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# SECTION 5 - KERNEL TUNING (sysctl)
# Forwarding, anti-spoofing, and the RA quirk that bites every IPv6 router.
# -----------------------------------------------------------------------------

configure_sysctl() {
  log "Writing kernel network parameters"
  local f="/etc/sysctl.d/99-router.conf"
  prepare "$f"

  {
    cat <<EOF_XYZ_XYZ
# Managed by setup-gateway-router.sh

#--- Forwarding --------------------------------------------------------------
# The single switch that turns a host into a router, per address family.
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

#--- IPv6 router advertisements ---------------------------------------------
# Linux ignores incoming RAs once forwarding is enabled, UNLESS accept_ra=2.
# We need the ISP's RA on the WAN side for the default route, while refusing
# RAs on every internal interface (we are the one sending them there).
net.ipv6.conf.${WAN_IF}.accept_ra = 2
net.ipv6.conf.${WAN_IF}.autoconf = 1
net.ipv6.conf.${WAN_IF}.accept_ra_defrtr = 1
# Do not let the uplink inject more specific routes into our table.
net.ipv6.conf.${WAN_IF}.accept_ra_rtr_pref = 0
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0

#--- Anti-spoofing ----------------------------------------------------------
# rp_filter=1 is strict reverse-path filtering: drop packets arriving on an
# interface the reply would not leave by. Set to 2 (loose) if you ever run
# asymmetric/multipath routing, otherwise leave strict.
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1

#--- ICMP redirects ---------------------------------------------------------
# A router with a complete routing table neither needs nor should emit these.
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0

#--- Connection tracking ----------------------------------------------------
# Size the table for the number of concurrent flows you expect; each entry is
# roughly 300 bytes. 262144 entries is a sane small-site default.
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 86400
net.ipv4.tcp_syncookies = 1

#--- Neighbour tables -------------------------------------------------------
# Defaults (128/512/1024) overflow on flat networks with many hosts.
net.ipv4.neigh.default.gc_thresh1 = 1024
net.ipv4.neigh.default.gc_thresh2 = 4096
net.ipv4.neigh.default.gc_thresh3 = 8192
net.ipv6.neigh.default.gc_thresh1 = 1024
net.ipv6.neigh.default.gc_thresh2 = 4096
net.ipv6.neigh.default.gc_thresh3 = 8192

#--- Multicast / OSPF -------------------------------------------------------
# FRR needs to send to link-local multicast groups on internal links.
net.ipv4.conf.all.mc_forwarding = 0
net.ipv6.conf.all.mc_forwarding = 0
EOF_XYZ_XYZ

    # Per-VLAN hardening, emitted in a loop so adding a VLAN needs no edits.
    printf '\n#--- Per-VLAN interface hardening -----------------------------------------\n'
    for def in "${VLAN_DEFS[@]}"; do
      IFS=':' read -r id name v4 pool sid class <<<"$def"
      local ifn="${VLAN_IF_PREFIX}${id}"
      cat <<EOF_XYZ
# VLAN ${id} (${name})
net.ipv6.conf.${ifn}.accept_ra = 0
net.ipv6.conf.${ifn}.autoconf = 0
net.ipv6.conf.${ifn}.accept_redirects = 0
net.ipv4.conf.${ifn}.send_redirects = 0
EOF_XYZ
    done
  } > "${ROOT}${f}"

  ok "wrote ${f}"

  # conntrack sysctls only exist once nf_conntrack is loaded, so ensure the
  # module is present at boot before sysctl runs.
  local m="/etc/modules-load.d/router.conf"
  prepare "$m"
  cat > "${ROOT}${m}" <<'EOF_XYZ'
# Loaded early so /etc/sysctl.d/99-router.conf can set nf_conntrack_* keys.
nf_conntrack
nf_conntrack_ftp
dummy
8021q
EOF_XYZ
  ok "wrote ${m}"

  run modprobe nf_conntrack
  run modprobe dummy
  run modprobe 8021q
  # --system reads every /etc/sysctl.d file in order; ignore keys for
  # interfaces that do not exist yet (they apply after netplan brings them up).
  run sysctl --system -q || warn "some sysctl keys deferred until interfaces exist"
}

# -----------------------------------------------------------------------------
# SECTION 6 - NETPLAN: ADDRESSING, VLANs, WAN CLIENT
# -----------------------------------------------------------------------------

configure_netplan() {
  log "Writing netplan configuration"

  # cloud-init re-generates its own netplan file on every boot and would fight
  # with ours. Disable its network module first.
  local ci="/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg"
  if [ -d /etc/cloud ] || [ "$DRY_RUN" = "yes" ]; then
    prepare "$ci"
    printf 'network: {config: disabled}\n' > "${ROOT}${ci}"
    ok "disabled cloud-init network administrator"
  fi

  # Move any pre-existing netplan YAML out of the way. Two files that both
  # claim the same interface produce a merged, usually broken, result.
  if [ "$DRY_RUN" != "yes" ]; then
    shopt -s nullglob
    local stale=(/etc/netplan/*.yaml /etc/netplan/*.yml)
    shopt -u nullglob
    if [ ${#stale[@]} -gt 0 ]; then
      confirm "Move ${#stale[@]} existing netplan file(s) to ${BACKUP_DIR}?"
      for f in "${stale[@]}"; do
        backup_file "$f"
        rm -f "$f"
      done
      ok "cleared previous netplan files (copies in backup dir)"
    fi
  fi

  local f="/etc/netplan/10-router.yaml"
  prepare "$f"

  {
    cat <<EOF_XYZ
# Managed by setup-gateway-router.sh

# Apply with:  netplan try   (auto-reverts after 120s if you lose the link)
network:
  version: 2
  # systemd-networkd, not NetworkManager: this is a headless router.
  renderer: networkd

  ethernets:
    # ---------------------------------------------------------------------
    # WAN uplink. IPv4 by DHCP, IPv6 by router advertisement from the ISP.
    # ---------------------------------------------------------------------
    ${WAN_IF}:
      dhcp4: true
      dhcp4-overrides:
        # We run our own validating resolver, so ignore the ISP's servers
        # and search domain rather than letting them into resolv.conf.
        use-dns: false
        use-domains: false
        use-ntp: false
        # Do accept the default route - that is the point of the uplink.
        use-routes: true
        # Slightly lower metric than the LAN so it wins as the default path.
        route-metric: 100
      # Stateful DHCPv6 is only needed if the ISP's RA sets the M flag;
      # accept-ra covers the common SLAAC + default-route case. If your ISP
      # requires DHCPv6 (or you enable PD below), set dhcp6: true.
      dhcp6: false
      accept-ra: true
      # Stable addressing on a router; privacy extensions would churn the
      # source address used for its own outbound traffic.
      ipv6-privacy: false
      link-local: [ipv6]
      # 'optional' stops boot from blocking for 2 minutes if the ISP link
      # happens to be down.
      optional: true

    # ---------------------------------------------------------------------
    # LAN trunk. No addresses of its own - it only carries tagged frames.
    # ---------------------------------------------------------------------
    ${LAN_TRUNK_IF}:
      dhcp4: false
      dhcp6: false
      accept-ra: false
      link-local: []
      optional: true
      # Raise the MTU here (and on the switch) if you want 802.1Q frames to
      # carry a full 1500-byte payload: mtu: 1504

  # -----------------------------------------------------------------------
  # Dummy interface holding the router's stable identity. Unlike a physical
  # address, this never goes down, which is exactly what OSPF wants for its
  # router-id and what monitoring wants as a target.
  # -----------------------------------------------------------------------
  dummy-devices:
    ${LOOPBACK_IF}:
      addresses:
        - ${LOOPBACK_V4}
        - ${LOOPBACK_V6}
      accept-ra: false
      link-local: []

  # -----------------------------------------------------------------------
  # Per-VLAN downstream interfaces. Each is a routed L3 gateway: static v4,
  # static IPv6 GUA and ULA. No 'gateway4/6' keys - a router's default route
  # comes from the WAN side only.
  # -----------------------------------------------------------------------
  vlans:
EOF_XYZ

    for def in "${VLAN_DEFS[@]}"; do
      IFS=':' read -r id name v4 pool sid class <<<"$def"
      local ifn="${VLAN_IF_PREFIX}${id}"
      local gua ula
      gua=$(v6_host "$(v6_subnet "$IPV6_GUA_PREFIX" "$sid")" 1)
      ula=$(v6_host "$(v6_subnet "$IPV6_ULA_PREFIX" "$sid")" 1)
      cat <<EOF_XYZ
    ${ifn}:
      # VLAN ${id} - ${name} (${class} zone)
      id: ${id}
      link: ${LAN_TRUNK_IF}
      dhcp4: false
      dhcp6: false
      accept-ra: false
      # Link-local IPv6 is required: OSPFv3 peers over fe80:: and our own
      # router advertisements are sourced from it.
      link-local: [ipv6]
      addresses:
        - ${v4}
        - ${gua}/64
        - ${ula}/64
EOF_XYZ
    done
  } > "${ROOT}${f}"

  # netplan refuses to read world-readable files (they can contain WiFi keys).
  chmod 600 "${ROOT}${f}"
  ok "wrote ${f}"

  # Validate before applying: 'netplan generate' renders the networkd units
  # and exits non-zero on any schema error.
  if [ "$DRY_RUN" = "yes" ]; then
    printf '  \033[2m(dry-run) netplan generate\033[0m\n'
  else
    netplan generate || die "netplan configuration is invalid - nothing applied"
    ok "netplan syntax validated"
  fi
}

# Optional: DHCPv6 prefix delegation. Netplan exposes no key for this, but the
# units it generates are ordinary systemd-networkd files, and networkd reads
# drop-ins from <unit>.d/. That gives us PD without abandoning netplan.
configure_dhcpv6_pd() {
  [ "$ENABLE_DHCPV6_PD" = "yes" ] || { ok "DHCPv6-PD disabled, skipping"; return 0; }
  log "Configuring DHCPv6 prefix delegation on ${WAN_IF}"

  local d="/etc/systemd/network/10-netplan-${WAN_IF}.network.d"
  mkdir -p "${ROOT}${d}"
  cat > "${ROOT}${d}/prefix-delegation.conf" <<EOF_XYZ
# Managed by setup-gateway-router.sh

# Request a prefix from the ISP and hand /64s out of it to the VLANs.
[Network]
DHCP=ipv4
IPv6AcceptRA=yes

[DHCPv6]
# Ask for the prefix, not just an address.
PrefixDelegationHint=::/56
UseDNS=no
WithoutRA=solicit

[DHCPPrefixDelegation]
UplinkInterface=:self
Announce=no
EOF_XYZ

  # Each downstream interface claims one subnet out of the delegated prefix.
  local subnet_index=0
  for def in "${VLAN_DEFS[@]}"; do
    IFS=':' read -r id name v4 pool sid class <<<"$def"
    local ifn="${VLAN_IF_PREFIX}${id}"
    local dd="/etc/systemd/network/10-netplan-${ifn}.network.d"
    mkdir -p "${ROOT}${dd}"
    cat > "${ROOT}${dd}/prefix-delegation.conf" <<EOF_XYZ
# Managed by setup-gateway-router.sh

# VLAN ${id} (${name})

[Network]
DHCPPrefixDelegation=yes

[DHCPPrefixDelegation]
UplinkInterface=${WAN_IF}
SubnetId=${subnet_index}
Announce=no
EOF_XYZ
    subnet_index=$((subnet_index + 1))
  done

  warn "with PD active the static GUA /64s in netplan become redundant;"
  warn "FRR's 'ipv6 nd prefix' lines and Kea's subnet6 entries will need to"
  warn "track the delegated prefix (see the notes at the end of this script)"
  ok "prefix delegation drop-ins written"
}

# -----------------------------------------------------------------------------
# SECTION 7 - RESOLVER HAND-OFF
# BIND wants to own port 53. systemd-resolved's stub listener already has it.
# -----------------------------------------------------------------------------

configure_resolved() {
  log "Handing port 53 over to BIND"

  # Two viable approaches:
  #   (a) mask systemd-resolved entirely and write a static /etc/resolv.conf
  #   (b) keep resolved but disable its stub listener (DNSStubListener=no)
  # We use (a): on a router BIND is the resolver, and one fewer moving part in
  # the DNS path is worth more than resolved's per-link features.
  local d="/etc/systemd/resolved.conf.d"
  mkdir -p "${ROOT}${d}"
  cat > "${ROOT}${d}/99-router.conf" <<'EOF_XYZ'
# Managed by setup-gateway-router.sh

# Keep for reference in case systemd-resolved gets enabled. This will
# free 127.0.0.53:53 so named.service can bind to the wildcard address.
[Resolve]
DNSStubListener=no
DNS=127.0.0.1
EOF_XYZ

  local rc="/etc/resolv.conf"
  backup_file "$rc"
  if [ "$DRY_RUN" = "yes" ]; then
    mkdir -p "${ROOT}/etc"
    printf '  \033[2m(dry-run) unlink + rewrite %s\033[0m\n' "$rc"
  else
    systemctl disable --now systemd-resolved 2>/dev/null || true
    systemctl mask systemd-resolved 2>/dev/null || true
    # /etc/resolv.conf is normally a symlink into /run; replace it with a real
    # file pointing at our own named instance.
    rm -f "$rc"
  fi
  cat > "${ROOT}${rc}" <<EOF_XYZ
# Managed by setup-gateway-router.sh

# The router resolves through its own BIND instance on the loopback.
nameserver 127.0.0.1
nameserver ::1
search ${DOMAIN}
options edns0 trust-ad timeout:2 attempts:2
EOF_XYZ
  ok "resolv.conf points at local named"
}

# -----------------------------------------------------------------------------
# SECTION 8 - NFTABLES FIREWALL
#
# Design notes:
#   * One 'inet' table handles IPv4 and IPv6 with shared rules; family-specific
#     matches (icmp vs icmpv6) are split where they must be.
#   * Default policy is drop on input and forward, accept on output.
#   * IPv4 is masqueraded. IPv6 is routed with no address translation - the
#     firewall, not NAT, is what provides isolation.
#   * Zone classes from VLAN_DEFS drive the inter-VLAN matrix.
# -----------------------------------------------------------------------------

# Decide whether traffic from one zone class to another is permitted.
# Returns the string "accept" or "drop".
interzone_policy() {
  local src="$1" dst="$2"
  case "$src" in
    admin) echo accept ;;            # administrator reaches all
    trusted)
      case "$dst" in
        admin) echo drop ;;          # users cannot reach admin
        *) echo accept ;;           # users reach iot and dmz
      esac ;;
    restricted) echo drop ;;        # iot is fully isolated
    dmz) echo drop ;;               # dmz never initiates in
    *) echo drop ;;
  esac
}

configure_nftables() {
  log "Writing nftables ruleset"
  local f="/etc/nftables.conf"
  prepare "$f"

  # Build the prefix lists once, as nft "define" variables. Defines are file
  # scoped, so unlike named sets they can be referenced from every table -
  # which matters because the filter, nat and anti-spoof rules all need them.
  local v4_list="" v6_list=""
  for def in "${VLAN_DEFS[@]}"; do
    IFS=':' read -r id name v4 pool sid class <<<"$def"
    v4_list+="$(v4_network "$v4"), "
  done
  v4_list="${v4_list%, }"
  v6_list="${IPV6_GUA_PREFIX}, ${IPV6_ULA_PREFIX}"

  {
    cat <<EOF_XYZ
#!/usr/sbin/nft -f
# Managed by setup-gateway-router.sh

# Reload with:  nft -f /etc/nftables.conf   (validate first: nft -c -f ...)

# Start from a clean slate so a reload is idempotent.
flush ruleset

# ---------------------------------------------------------------------------
# Symbolic names. Changing an interface or a prefix here updates every rule
# below. Defines are textual substitutions, so they work in any table.
# ---------------------------------------------------------------------------
define WAN_IF      = "${WAN_IF}"
define ADMIN_IF     = "${ADMIN_IF}"
define LAN_IFS     = { ${NFT_LAN_IF_SET} }
define LAN_V4_NETS = { ${v4_list} }
define LAN_V6_NETS = { ${v6_list} }

table inet filter {

    # -----------------------------------------------------------------------
    # Named sets. Built from the defines above, but named so that they can be
    # inspected and amended at runtime:
    #   nft list set inet filter lan_v4
    #   nft add element inet filter lan_v4 { 10.10.40.0/24 }
    # -----------------------------------------------------------------------
    set lan_v4 {
        type ipv4_addr
        flags interval
        elements = \$LAN_V4_NETS
    }

    set lan_v6 {
        type ipv6_addr
        flags interval
        elements = \$LAN_V6_NETS
    }
EOF_XYZ

    cat <<'EOF_XYZ'

    # Source addresses that must never arrive from the uplink.
    set bogon_v4 {
        type ipv4_addr
        flags interval
        elements = {
            0.0.0.0/8,          # "this host on this network"
            10.0.0.0/8,         # private (RFC 1918)
            100.64.0.0/10,      # cgnat (Remove if ISP uses)
            127.0.0.0/8,        # loopback
            169.254.0.0/16,     # link-local
            172.16.0.0/12,      # private (RFC 1918)
            192.0.2.0/24,       # documentation
            192.168.0.0/16,     # private (RFC 1918)
            198.18.0.0/15,      # benchmarking
            224.0.0.0/4,        # multicast (never a valid source)
            240.0.0.0/4         # reserved
        }
    }

    # Per-source SSH rate limiters. A source is added on its first new
    # connection and its limiter state is kept for an hour; only sources that
    # exceed the rate are dropped, so ordinary logins are unaffected.
    set ssh_flood4 {
        type ipv4_addr
        flags dynamic, timeout
        timeout 1h
        size 65535
    }

    set ssh_flood6 {
        type ipv6_addr
        flags dynamic, timeout
        timeout 1h
        size 65535
    }

    # -----------------------------------------------------------------------
    # ICMP handling. ICMPv6 is NOT optional: blocking it breaks neighbour
    # discovery, address autoconfiguration and path MTU discovery. RFC 4890
    # is the reference for what has to be permitted.
    # -----------------------------------------------------------------------
    chain icmp_common {
        # --- IPv6 neighbour discovery -------------------------------------
        # hoplimit 255 proves the packet was not routed, i.e. that it really
        # is on-link. This is the check RFC 4861 mandates.
        icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert,
                      nd-router-solicit, nd-router-advert } \
            ip6 hoplimit 255 counter accept \
            comment "IPv6 neighbour discovery"

        icmpv6 type { mld-listener-query, mld-listener-report,
                      mld-listener-done, mld2-listener-report } \
            ip6 saddr fe80::/10 counter accept \
            comment "multicast listener discovery"

        # --- Error signalling, both families ------------------------------
        icmpv6 type { destination-unreachable, packet-too-big,
                      time-exceeded, parameter-problem } \
            counter accept comment "ICMPv6 errors - required for PMTUD"

        icmp type { destination-unreachable, time-exceeded,
                    parameter-problem } \
            counter accept comment "ICMPv4 errors - required for PMTUD"

        # --- Echo, rate limited so the router stays pingable without
        #     becoming a useful reflector.
        icmpv6 type echo-request limit rate 10/second burst 20 packets \
            counter accept comment "ping6"
        icmp type echo-request limit rate 10/second burst 20 packets \
            counter accept comment "ping"
    }

    # -----------------------------------------------------------------------
    # Services the router offers to internal clients.
    # -----------------------------------------------------------------------
    chain lan_services {
        # DNS - BIND serves the internal zones and recurses for clients.
        udp dport 53 counter accept comment "DNS/UDP"
        tcp dport 53 counter accept comment "DNS/TCP (large answers, AXFR)"

        # DHCPv4. A client with no address yet sends from 0.0.0.0, so these
        # packets cannot be matched on source address.
        udp sport 68 udp dport 67 counter accept comment "DHCPv4 to Kea"

        # DHCPv6. Clients send to ff02::1:2 from their link-local address.
        udp sport 546 udp dport 547 counter accept comment "DHCPv6 to Kea"
    }

    # -----------------------------------------------------------------------
    # Traffic arriving on the uplink and addressed to the router itself.
    # -----------------------------------------------------------------------
    chain wan_input {
        # DHCPv4 client: the server's offer comes back to port 68.
        udp sport 67 udp dport 68 counter accept comment "DHCPv4 client"

        # DHCPv6 client / prefix delegation replies arrive on port 546.
        udp sport 547 udp dport 546 counter accept comment "DHCPv6 client"

        # Everything else from the Internet is unsolicited. Log a sample so
        # the drop is diagnosable, then drop.
        limit rate 5/minute burst 10 packets \
            log prefix "nft wan-input-drop " level info
        counter drop
    }

    # -----------------------------------------------------------------------
    # Anti-spoofing, in the prerouting hook so it runs before conntrack does
    # any work. This chain lives in the filter table (not a separate raw
    # table) because nftables sets are scoped to their table.
    # -----------------------------------------------------------------------
    chain prerouting {
        type filter hook prerouting priority raw; policy accept;

        # --- Exemptions that must come first ------------------------------
        # A DHCPv4 client has no address yet and legitimately sends from
        # 0.0.0.0 to 255.255.255.255. Without this, the spoof check below
        # would silently break DHCP for the whole site.
        iifname $LAN_IFS udp sport 68 udp dport 67 counter accept \
            comment "DHCPv4 discover has no source address"
        # Duplicate address detection sends from the unspecified address.
        iifname $LAN_IFS ip6 saddr ::/128 counter accept comment "IPv6 DAD"

        # --- Forged sources from the Internet -----------------------------
        iifname $WAN_IF ip saddr @bogon_v4 counter drop comment "bogon source"
        iifname $WAN_IF ip saddr @lan_v4 counter drop comment "spoofed internal v4"
        iifname $WAN_IF ip6 saddr @lan_v6 counter drop comment "spoofed internal v6"
        iifname $WAN_IF ip6 saddr { ::1/128, ::/128, ::ffff:0:0/96 } \
            counter drop comment "reserved v6 source"

        # --- Forged sources from inside -----------------------------------
        # An internal interface may only source its own prefixes (plus
        # link-local, which every IPv6 host needs).
        iifname $LAN_IFS ip saddr != @lan_v4 counter drop comment "LAN v4 spoof"
        iifname $LAN_IFS ip6 saddr != @lan_v6 ip6 saddr != fe80::/10 \
            counter drop comment "LAN v6 spoof"
    }
EOF_XYZ

    cat <<EOF_XYZ

    # -----------------------------------------------------------------------
    # INPUT - packets terminating on the router.
    # -----------------------------------------------------------------------
    chain input {
        type filter hook input priority filter; policy drop;

        # Malformed or untrackable packets: cheapest possible discard, first.
        ct state invalid counter drop comment "invalid conntrack state"

        # The fast path. Almost everything accepted matches here.
        ct state { established, related } counter accept

        # Loopback is trusted; anything claiming to be loopback from the wire
        # is forged.
        iif lo counter accept
        iifname != lo ip saddr 127.0.0.0/8 counter drop comment "spoofed loopback"
        iifname != lo ip6 saddr ::1/128 counter drop comment "spoofed loopback6"

        jump icmp_common

        # Internal VLANs get DNS and DHCP.
        iifname \$LAN_IFS jump lan_services

        # --- Administrator VLAN only ------------------------------------------
        # OSPF adjacencies are confined to the administrator VLAN, matching the
        # FRR configuration where every other VLAN is passive.
        iifname \$ADMIN_IF ip protocol 89 counter accept comment "OSPFv2"
        iifname \$ADMIN_IF meta l4proto 89 ip6 saddr fe80::/10 \\
            counter accept comment "OSPFv3"

        # SSH with a per-source rate limiter. The 'add @set { ... limit rate
        # over ... }' form only drops sources that exceed the rate, so normal
        # logins pass straight through to the accept below.
        iifname \$ADMIN_IF tcp dport 22 ct state new \\
            add @ssh_flood4 { ip saddr limit rate over 6/minute burst 6 packets } \\
            counter drop comment "SSH brute force (v4)"
        iifname \$ADMIN_IF tcp dport 22 ct state new \\
            add @ssh_flood6 { ip6 saddr limit rate over 6/minute burst 6 packets } \\
            counter drop comment "SSH brute force (v6)"
        iifname \$ADMIN_IF tcp dport 22 counter accept comment "SSH from admin"

        # The uplink has its own, much narrower, policy.
        iifname \$WAN_IF jump wan_input

        # Fall through to the drop policy, with sampled logging.
        limit rate 5/minute burst 10 packets \\
            log prefix "nft input-drop " level info
        counter comment "hits the drop policy"
    }

    # -----------------------------------------------------------------------
    # FORWARD - the actual routing policy.
    # -----------------------------------------------------------------------
    chain forward {
        type filter hook forward priority filter; policy drop;

        ct state invalid counter drop
        ct state { established, related } counter accept

        # Clamp TCP MSS to the real path MTU. Without this, PPPoE uplinks
        # (MTU 1492) and tunnels silently black-hole large packets whenever
        # ICMP is filtered somewhere upstream.
        tcp flags syn tcp option maxseg size set rt mtu \\
            counter comment "MSS clamp to PMTU"

        # ICMP errors must be able to transit in both directions or PMTUD
        # breaks for everything behind the router.
        icmpv6 type { destination-unreachable, packet-too-big,
                      time-exceeded, parameter-problem } counter accept
        icmp type { destination-unreachable, time-exceeded,
                    parameter-problem } counter accept

        # Echo requests are allowed outbound only. Internal hosts are not
        # pingable from the Internet - notable for IPv6, where they have
        # globally routable addresses and no NAT hiding them. To allow it
        # (RFC 4890 suggests you should), add:
        #   iifname \$WAN_IF icmpv6 type echo-request \\
        #       limit rate 10/second counter accept
        iifname \$LAN_IFS icmpv6 type echo-request counter accept
        iifname \$LAN_IFS icmp type echo-request counter accept

        # --- Egress to the Internet ---------------------------------------
        # IPv4 leaves NAT'ed, IPv6 leaves routed; the rule is the same.
        iifname \$LAN_IFS oifname \$WAN_IF counter accept comment "LAN to Internet"

EOF_XYZ

    # ---- Inter-VLAN matrix, generated from the zone classes ---------------
    printf '        # --- Inter-VLAN policy (generated from VLAN_DEFS zone classes) ----\n'
    printf '        # Return traffic is already handled by the conntrack rule above,\n'
    printf '        # so these rules only govern who may *initiate* a connection.\n'
    for src in "${VLAN_DEFS[@]}"; do
      IFS=':' read -r sid_ sname s_v4 s_pool s_sid sclass <<<"$src"
      for dst in "${VLAN_DEFS[@]}"; do
        IFS=':' read -r did_ dname d_v4 d_pool d_sid dclass <<<"$dst"
        [ "$sid_" = "$did_" ] && continue
        local verdict
        verdict=$(interzone_policy "$sclass" "$dclass")
        printf '        iifname "%s%s" oifname "%s%s" counter %s comment "%s(%s) -> %s(%s)"\n' \
          "$VLAN_IF_PREFIX" "$sid_" "$VLAN_IF_PREFIX" "$did_" \
          "$verdict" "$sname" "$sclass" "$dname" "$dclass"
      done
    done

    # ---- Inbound published services ---------------------------------------
    printf '\n        # --- Published services reachable from the Internet --------------\n'
    if [ ${#PUBLISHED_SERVICES[@]} -eq 0 ]; then
      printf '        # (none configured)\n'
    else
      for svc in "${PUBLISHED_SERVICES[@]}"; do
        IFS='|' read -r proto eport v4dst v6dst iport <<<"$svc"
        if [ "$v4dst" != "-" ]; then
          # The nat table's DNAT has already rewritten the destination by the
          # time the packet reaches forward, so match the internal address.
          printf '        iifname $WAN_IF ip daddr %s %s dport %s counter accept comment "published %s/%s -> v4"\n' \
            "$v4dst" "$proto" "$iport" "$proto" "$eport"
        fi
        if [ "$v6dst" != "-" ]; then
          # No NAT for IPv6: the client connects straight to the host's real
          # global address and the firewall alone decides whether that is
          # allowed. This is the whole point of running IPv6 without NAT.
          printf '        iifname $WAN_IF ip6 daddr %s %s dport %s counter accept comment "published %s/%s -> v6"\n' \
            "$v6dst" "$proto" "$iport" "$proto" "$eport"
        fi
      done
    fi

    cat <<'EOF_XYZ'

        # Anything not matched above is denied. Sample the drops.
        limit rate 5/minute burst 10 packets \
            log prefix "nft forward-drop " level info
        counter comment "hits the drop policy"
    }

    # -----------------------------------------------------------------------
    # OUTPUT - the router's own traffic. Accepted, but counted so that the
    # ruleset gives a complete picture of what the box is doing.
    # -----------------------------------------------------------------------
    chain output {
        type filter hook output priority filter; policy accept;
        counter comment "router-originated"
    }
}

# ---------------------------------------------------------------------------
# IPv4 NAT. Deliberately an 'ip' table, not 'inet': there is no IPv6 NAT here
# and there should not be. IPv6 hosts keep their real addresses end to end,
# which is what makes the published-service rules above so much simpler.
# ---------------------------------------------------------------------------
table ip nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
EOF_XYZ

    if [ ${#PUBLISHED_SERVICES[@]} -eq 0 ]; then
      printf '        # (no DNAT rules configured)\n'
    else
      for svc in "${PUBLISHED_SERVICES[@]}"; do
        IFS='|' read -r proto eport v4dst v6dst iport <<<"$svc"
        [ "$v4dst" = "-" ] && continue
        printf '        iifname $WAN_IF %s dport %s counter dnat to %s:%s comment "publish %s/%s"\n' \
          "$proto" "$eport" "$v4dst" "$iport" "$proto" "$eport"
      done
    fi

    cat <<'EOF_XYZ'
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;

        # masquerade rather than snat: the WAN address comes from DHCP and can
        # change, and masquerade picks up the current one automatically.
        # $LAN_V4_NETS is a define, so it works here even though the named
        # 'lan_v4' set belongs to the filter table.
        oifname $WAN_IF ip saddr $LAN_V4_NETS counter masquerade comment "NAT44"

        # Hairpin (loopback) NAT would let internal clients reach a published
        # service by its public address. Not needed here: BIND serves the
        # internal view, so internal clients get the internal address.
        # iifname $LAN_IFS oifname $LAN_IFS ip daddr $LAN_V4_NETS counter masquerade
    }
}
EOF_XYZ
  } > "${ROOT}${f}"

  chmod 600 "${ROOT}${f}"
  ok "wrote ${f}"

  # 'nft -c' parses and checks the ruleset without committing it. This is the
  # single most valuable safety step in the whole script.
  if command -v nft >/dev/null 2>&1; then
    nft -c -f "${ROOT}${f}" || die "nftables ruleset failed validation"
    ok "nftables ruleset validated"
  else
    warn "nft not installed yet - skipping validation"
  fi
}

# -----------------------------------------------------------------------------
# SECTION 9 - SHARED TSIG KEY
# Kea's DDNS forwarder and BIND authenticate to each other with a symmetric
# key. Generate it once, then embed it in both configurations.
# -----------------------------------------------------------------------------

DDNS_KEY_NAME="ddns-key"
DDNS_KEY_ALGO="HMAC-SHA256"
DDNS_KEY_SECRET=""

generate_tsig_key() {
  log "Generating TSIG key for dynamic DNS updates"

  local keyfile="/etc/bind/keys/${DDNS_KEY_NAME}.key"

  # Reuse an existing key if one is already deployed, so re-running the script
  # does not break a working Kea/BIND pairing.
  if [ "$DRY_RUN" != "yes" ] && [ -r "$keyfile" ]; then
    DDNS_KEY_SECRET=$(sed -n 's/.*secret *"\([^"]*\)".*/\1/p' "$keyfile" | head -n1)
    if [ -n "$DDNS_KEY_SECRET" ]; then
      ok "reusing existing TSIG key from ${keyfile}"
      return 0
    fi
    warn "existing key file is unparseable - generating a new key"
  fi

  # 32 random bytes is the natural key length for HMAC-SHA256.
  DDNS_KEY_SECRET=$(openssl rand -base64 32)

  mkdir -p "${ROOT}/etc/bind/keys"
  prepare "$keyfile"
  cat > "${ROOT}${keyfile}" <<EOF_XYZ
// Managed by setup-gateway-router.sh

// Shared with /etc/kea/kea-dhcp-ddns.conf. Both files must be kept private.
key "${DDNS_KEY_NAME}" {
    algorithm ${DDNS_KEY_ALGO};
    secret "${DDNS_KEY_SECRET}";
};
EOF_XYZ
  chmod 640 "${ROOT}${keyfile}"
  # named must read it; nothing else should.
  if [ "$DRY_RUN" != "yes" ] && getent passwd bind >/dev/null 2>&1; then
    chown root:bind "${ROOT}${keyfile}"
  fi
  ok "wrote ${keyfile} (mode 640)"
}

# Locate Kea's hook libraries. The path is multiarch-dependent, so glob for it
# rather than hard-coding x86_64.
kea_hooks_dir() {
  local d
  for d in /usr/lib/*/kea/hooks /usr/lib/kea/hooks; do
    [ -d "$d" ] && { printf '%s\n' "$d"; return 0; }
  done
  return 1
}

# Apply the ownership Kea's systemd units expect. Ubuntu runs the daemons as
# the unprivileged '_kea' user where available.
kea_own() {
  local path="$1"
  [ "$DRY_RUN" = "yes" ] && return 0
  if getent passwd _kea >/dev/null 2>&1; then
    chown _kea:_kea "$path" 2>/dev/null || true
  fi
}

# -----------------------------------------------------------------------------
# SECTION 10 - KEA DHCPv4
#
# Kea's parser accepts // and /* */ comments, so the deployed file stays
# self-documenting. Note that `kea-dhcp4 -t <file>` will validate it.
# -----------------------------------------------------------------------------

configure_kea_dhcp4() {
  log "Writing Kea DHCPv4 configuration"
  local f="/etc/kea/kea-dhcp4.conf"
  prepare "$f"

  local hooks_dir=""
  hooks_dir=$(kea_hooks_dir || true)

  {
    cat <<EOF_XYZ
// Managed by setup-gateway-router.sh

// Validate with:  kea-dhcp4 -t /etc/kea/kea-dhcp4.conf
{
"Dhcp4": {

    // -------------------------------------------------------------------
    // Listening interfaces. Kea is bound explicitly to the VLAN interfaces
    // and never to the WAN - a DHCP server answering on the uplink is a
    // serious misconfiguration.
    // -------------------------------------------------------------------
    "interfaces-config": {
        "interfaces": [ $(printf '"%s", ' "${VLAN_IFACES[@]}" | sed 's/, $//') ],
        // "raw" lets Kea answer clients that have no address yet by talking
        // directly to the link layer.
        "dhcp-socket-type": "raw",
        // Refuse to start if any listed interface is missing, rather than
        // silently serving a subset of the VLANs.
        "service-sockets-require-all": true
    },

    // Unix socket used by kea-shell / the control agent for lease queries
    // and runtime reconfiguration.
    "control-socket": {
        "socket-type": "unix",
        "socket-name": "/run/kea/kea4-ctrl-socket"
    },

    // -------------------------------------------------------------------
    // Lease storage. memfile is a CSV journal that is replayed at startup;
    // lfc-interval controls how often it is compacted so it does not grow
    // without bound.
    // -------------------------------------------------------------------
    "lease-database": {
        "type": "memfile",
        "persist": true,
        "name": "/var/lib/kea/kea-leases4.csv",
        "lfc-interval": 3600
    },

    // Reclaim expired leases promptly, but keep them long enough that a
    // returning client usually gets the same address back.
    "expired-leases-processing": {
        "reclaim-timer-wait-time": 10,
        "flush-reclaimed-timer-wait-time": 25,
        "hold-reclaimed-time": 3600,
        "max-reclaim-leases": 100,
        "max-reclaim-time": 250,
        "unwarned-reclaim-cycles": 5
    },

    // -------------------------------------------------------------------
    // Global timers. renew-timer (T1) and rebind-timer (T2) are the points
    // at which a client starts trying to extend its lease.
    // -------------------------------------------------------------------
    "renew-timer": ${DHCP4_RENEW_TIMER},
    "rebind-timer": ${DHCP4_REBIND_TIMER},
    "valid-lifetime": ${DHCP4_VALID_LIFETIME},

    // Kea is single-threaded per packet by default; the thread pool matters
    // once you are past a few hundred leases. 0 = auto-size to the CPU.
    "multi-threading": {
        "enable-multi-threading": true,
        "thread-pool-size": 0,
        "packet-queue-size": 64
    },

    // Drop rather than answer requests relayed from unknown networks.
    "authoritative": true,
EOF_XYZ

    # The lease_cmds hook is what makes `kea-shell lease4-get-all` work. Only
    # reference it if the library is actually present on this architecture.
    if [ -n "$hooks_dir" ] && { [ -f "${hooks_dir}/libdhcp_lease_cmds.so" ] || [ "$DRY_RUN" = "yes" ]; }; then
      cat <<EOF_XYZ

    // Runtime lease inspection and manipulation over the control socket.
    "hooks-libraries": [
        { "library": "${hooks_dir}/libdhcp_lease_cmds.so" }
    ],
EOF_XYZ
    fi

    cat <<EOF_XYZ

    // -------------------------------------------------------------------
    // Dynamic DNS. Kea does not talk to BIND directly: it hands change
    // requests to kea-dhcp-ddns, which owns the TSIG key and performs the
    // actual UPDATE. See SECTION 12.
    // -------------------------------------------------------------------
    "dhcp-ddns": {
        "enable-updates": true,
        "server-ip": "127.0.0.1",
        "server-port": 53001,
        "sender-ip": "127.0.0.1",
        "max-queue-size": 1024,
        "ncr-protocol": "UDP",
        "ncr-format": "JSON"
    },
    "ddns-send-updates": true,
    // Clients often send a bare hostname; qualify it into our zone.
    "ddns-qualifying-suffix": "${DOMAIN}",
    // Update the forward record even when the client says it will do so
    // itself - most clients do not follow through.
    "ddns-override-client-update": true,
    "ddns-override-no-update": true,
    // Invent a name from the address for clients that send none at all.
    "ddns-replace-client-name": "when-not-present",
    "ddns-generated-prefix": "host",
    // Sanitise anything that is not a legal DNS label.
    "hostname-char-set": "[^A-Za-z0-9.-]",
    "hostname-char-replacement": "-",

    // -------------------------------------------------------------------
    // Options handed to every client unless a subnet overrides them.
    // -------------------------------------------------------------------
    "option-data": [
        { "name": "domain-name",   "data": "${DOMAIN}" },
        { "name": "domain-search", "data": "${DOMAIN}" },
        // Clients that ignore DHCP MTU will still be fine thanks to the
        // nftables MSS clamp; this just saves a round trip.
        { "name": "interface-mtu", "data": "1500" }
    ],

    // -------------------------------------------------------------------
    // Per-VLAN subnets. Each subnet is pinned to its interface so a request
    // arriving on the wrong VLAN cannot be answered from the wrong pool.
    // -------------------------------------------------------------------
    "subnet4": [
EOF_XYZ

    local sep=""
    for def in "${VLAN_DEFS[@]}"; do
      IFS=':' read -r id name v4 pool sid class <<<"$def"
      local ifn="${VLAN_IF_PREFIX}${id}"
      local net gw pool_start pool_end
      net=$(v4_network "$v4")
      gw=$(v4_addr "$v4")
      pool_start="${pool%%-*}"
      pool_end="${pool##*-}"

      printf '%s' "$sep"; sep=$',\n'
      cat <<EOF_XYZ
        {
            // ---- VLAN ${id} : ${name} (${class}) ----
            // Subnet ids are stable identifiers used in logs, host
            // reservations and the lease file. Never renumber them.
            "id": ${id},
            "subnet": "${net}",
            "interface": "${ifn}",
            "pools": [ { "pool": "${pool_start} - ${pool_end}" } ],
            "option-data": [
                { "name": "routers", "data": "${gw}" },
                // The router is also the resolver: BIND answers here.
                { "name": "domain-name-servers", "data": "${gw}" },
                { "name": "domain-name", "data": "${DOMAIN}" },
                { "name": "domain-search", "data": "${DOMAIN}" }
            ],
            // Reservations pin an address to a MAC (or client-id, or a
            // circuit-id from a relay). Static servers belong here rather
            // than in the dynamic pool.
            "reservations": [
                // {
                //     "hw-address": "52:54:00:aa:bb:cc",
                //     "ip-address": "${net%%/*}",
                //     "hostname": "example-host"
                // }
            ]
        }
EOF_XYZ
    done

    cat <<'EOF_XYZ'

    ],

    // -------------------------------------------------------------------
    // Logging. syslog goes to the journal; the file target is easier to
    // grep when chasing a specific client's DORA exchange.
    // -------------------------------------------------------------------
    "loggers": [
        {
            "name": "kea-dhcp4",
            "output_options": [
                { "output": "syslog", "pattern": "%-5p %m\n" },
                {
                    "output": "/var/log/kea/kea-dhcp4.log",
                    "maxsize": 10485760,
                    "maxver": 5,
                    "flush": true
                }
            ],
            // Raise severity to DEBUG and debuglevel to 55 when troubleshooting.
            "severity": "INFO",
            "debuglevel": 0
        },
        {
            "name": "kea-dhcp4.leases",
            "output_options": [ { "output": "/var/log/kea/kea-leases4.log" } ],
            "severity": "INFO"
        }
    ]
}
}
EOF_XYZ
  } > "${ROOT}${f}"

  chmod 640 "${ROOT}${f}"
  kea_own "${ROOT}${f}"
  ok "wrote ${f}"
}

# -----------------------------------------------------------------------------
# SECTION 11 - KEA DHCPv6
#
# Division of labour on the IPv6 side:
#   * FRR sends the router advertisements (default route, prefix flags, MTU).
#   * Kea hands out addresses out of the GUA /64 statefully.
#   * SLAAC covers the ULA /64 and any client that ignores DHCPv6 entirely -
#     notably Android, which has never implemented it.
# -----------------------------------------------------------------------------

configure_kea_dhcp6() {
  log "Writing Kea DHCPv6 configuration"
  local f="/etc/kea/kea-dhcp6.conf"
  prepare "$f"

  local hooks_dir=""
  hooks_dir=$(kea_hooks_dir || true)

  {
    cat <<EOF_XYZ
// Managed by setup-gateway-router.sh

// Validate with:  kea-dhcp6 -t /etc/kea/kea-dhcp6.conf
{
"Dhcp6": {

    "interfaces-config": {
        "interfaces": [ $(printf '"%s", ' "${VLAN_IFACES[@]}" | sed 's/, $//') ],
        "service-sockets-require-all": true
    },

    "control-socket": {
        "socket-type": "unix",
        "socket-name": "/run/kea/kea6-ctrl-socket"
    },

    "lease-database": {
        "type": "memfile",
        "persist": true,
        "name": "/var/lib/kea/kea-leases6.csv",
        "lfc-interval": 3600
    },

    "expired-leases-processing": {
        "reclaim-timer-wait-time": 10,
        "flush-reclaimed-timer-wait-time": 25,
        "hold-reclaimed-time": 3600,
        "max-reclaim-leases": 100,
        "max-reclaim-time": 250
    },

    // IPv6 distinguishes preferred (still usable for new connections) from
    // valid (existing connections may continue) lifetimes.
    "preferred-lifetime": ${DHCP6_PREFERRED_LIFETIME},
    "valid-lifetime": ${DHCP6_VALID_LIFETIME},
    "renew-timer": $((DHCP6_PREFERRED_LIFETIME / 2)),
    "rebind-timer": $((DHCP6_PREFERRED_LIFETIME * 4 / 5)),

    "multi-threading": {
        "enable-multi-threading": true,
        "thread-pool-size": 0,
        "packet-queue-size": 64
    },

    // Kea must know how clients are identified. DUID is the IPv6 norm;
    // MAC-based identifiers are derived where the transport allows it.
    "server-id": {
        "type": "LLT",
        "htype": 0,
        "identifier": "",
        "time": 0,
        "persist": true
    },
EOF_XYZ

    if [ -n "$hooks_dir" ] && { [ -f "${hooks_dir}/libdhcp_lease_cmds.so" ] || [ "$DRY_RUN" = "yes" ]; }; then
      cat <<EOF_XYZ

    "hooks-libraries": [
        { "library": "${hooks_dir}/libdhcp_lease_cmds.so" }
    ],
EOF_XYZ
    fi

    cat <<EOF_XYZ

    // Same DDNS forwarder as DHCPv4, so a dual-stack host ends up with
    // matching A and AAAA records under one name.
    "dhcp-ddns": {
        "enable-updates": true,
        "server-ip": "127.0.0.1",
        "server-port": 53001,
        "sender-ip": "127.0.0.1",
        "max-queue-size": 1024,
        "ncr-protocol": "UDP",
        "ncr-format": "JSON"
    },
    "ddns-send-updates": true,
    "ddns-qualifying-suffix": "${DOMAIN}",
    "ddns-override-client-update": true,
    "ddns-override-no-update": true,
    "ddns-replace-client-name": "when-not-present",
    "ddns-generated-prefix": "host6",
    "hostname-char-set": "[^A-Za-z0-9.-]",
    "hostname-char-replacement": "-",

    "option-data": [
        { "name": "domain-search", "data": "${DOMAIN}" }
    ],

    "subnet6": [
EOF_XYZ

    local sep=""
    for def in "${VLAN_DEFS[@]}"; do
      IFS=':' read -r id name v4 pool sid class <<<"$def"
      local ifn="${VLAN_IF_PREFIX}${id}"
      local gua_net gua_gw p_start p_end
      gua_net=$(v6_subnet "$IPV6_GUA_PREFIX" "$sid")
      gua_gw=$(v6_host "$gua_net" 1)
      # Keep the stateful pool in a narrow, memorable window. SLAAC and
      # privacy addresses are spread randomly across the /64, so the chance
      # of overlap with ::1000-::1fff is negligible - and Kea performs its
      # own conflict check before handing an address out.
      p_start=$(v6_host "$gua_net" 4096)
      p_end=$(v6_host "$gua_net" 8191)

      printf '%s' "$sep"; sep=$',\n'
      cat <<EOF_XYZ
        {
            // ---- VLAN ${id} : ${name} (${class}) ----
            // Reuse the DHCPv4 subnet id so the two families line up in logs.
            "id": ${id},
            "subnet": "${gua_net}",
            "interface": "${ifn}",
            "pools": [ { "pool": "${p_start} - ${p_end}" } ],
            // rapid-commit collapses the four-message exchange into two.
            "rapid-commit": true,
            "option-data": [
                // Point clients at the router's own global address. The ULA
                // address would also work and survives an ISP renumber.
                { "name": "dns-servers", "data": "${gua_gw}" },
                { "name": "domain-search", "data": "${DOMAIN}" }
            ],
            // Prefix delegation to downstream routers would go here:
            // "pd-pools": [ { "prefix": "...", "prefix-len": 56,
            //                 "delegated-len": 60 } ],
            "reservations": [
                // {
                //     "duid": "01:02:03:04:05:06:07:08",
                //     "ip-addresses": [ "${gua_gw}" ],
                //     "hostname": "example-host"
                // }
            ]
        }
EOF_XYZ
    done

    cat <<'EOF_XYZ'

    ],

    "loggers": [
        {
            "name": "kea-dhcp6",
            "output_options": [
                { "output": "syslog", "pattern": "%-5p %m\n" },
                {
                    "output": "/var/log/kea/kea-dhcp6.log",
                    "maxsize": 10485760,
                    "maxver": 5,
                    "flush": true
                }
            ],
            "severity": "INFO",
            "debuglevel": 0
        }
    ]
}
}
EOF_XYZ
  } > "${ROOT}${f}"

  chmod 640 "${ROOT}${f}"
  kea_own "${ROOT}${f}"
  ok "wrote ${f}"
}

# -----------------------------------------------------------------------------
# SECTION 12 - KEA DDNS FORWARDER
# Translates Kea's internal "name change requests" into signed DNS UPDATEs.
# -----------------------------------------------------------------------------

configure_kea_ddns() {
  log "Writing Kea DDNS configuration"
  local f="/etc/kea/kea-dhcp-ddns.conf"
  prepare "$f"

  {
    cat <<EOF_XYZ
// Managed by setup-gateway-router.sh

// Contains the TSIG secret: keep mode 640.
{
"DhcpDdns": {

    // Listen only on the loopback - the DHCP servers are on the same host.
    "ip-address": "127.0.0.1",
    "port": 53001,
    "control-socket": {
        "socket-type": "unix",
        "socket-name": "/run/kea/kea-ddns-ctrl-socket"
    },

    // Drop update requests for names outside our zones rather than
    // forwarding them somewhere unexpected.
    "dns-server-timeout": 500,
    "ncr-protocol": "UDP",
    "ncr-format": "JSON",

    // -------------------------------------------------------------------
    // The key must match /etc/bind/keys/${DDNS_KEY_NAME}.key exactly.
    // -------------------------------------------------------------------
    "tsig-keys": [
        {
            "name": "${DDNS_KEY_NAME}",
            "algorithm": "${DDNS_KEY_ALGO}",
            "secret": "${DDNS_KEY_SECRET}"
        }
    ],

    // -------------------------------------------------------------------
    // Forward zone: A and AAAA records for leased hosts.
    // -------------------------------------------------------------------
    "forward-ddns": {
        "ddns-domains": [
            {
                "name": "${DOMAIN}.",
                "key-name": "${DDNS_KEY_NAME}",
                "dns-servers": [ { "ip-address": "127.0.0.1", "port": 53 } ]
            }
        ]
    },

    // -------------------------------------------------------------------
    // Reverse zones: one per IPv4 /24 plus the IPv6 /48 cuts. Kea matches
    // the longest suffix, so listing the /48s covers every VLAN /64.
    // -------------------------------------------------------------------
    "reverse-ddns": {
        "ddns-domains": [
EOF_XYZ

    local sep=""
    for def in "${VLAN_DEFS[@]}"; do
      IFS=':' read -r id name v4 pool sid class <<<"$def"
      local zone
      zone=$(v4_arpa_zone "$(v4_network "$v4")")
      printf '%s' "$sep"; sep=$',\n'
      cat <<EOF_XYZ
            {
                // VLAN ${id} (${name})
                "name": "${zone}.",
                "key-name": "${DDNS_KEY_NAME}",
                "dns-servers": [ { "ip-address": "127.0.0.1", "port": 53 } ]
            }
EOF_XYZ
    done

    for prefix in "$IPV6_GUA_PREFIX" "$IPV6_ULA_PREFIX"; do
      local zone6
      zone6=$(v6_arpa_zone "$prefix")
      printf '%s' "$sep"; sep=$',\n'
      cat <<EOF_XYZ
            {
                // ${prefix}
                "name": "${zone6}.",
                "key-name": "${DDNS_KEY_NAME}",
                "dns-servers": [ { "ip-address": "127.0.0.1", "port": 53 } ]
            }
EOF_XYZ
    done

    cat <<'EOF_XYZ'

        ]
    },

    "loggers": [
        {
            "name": "kea-dhcp-ddns",
            "output_options": [
                { "output": "syslog", "pattern": "%-5p %m\n" },
                {
                    "output": "/var/log/kea/kea-ddns.log",
                    "maxsize": 10485760,
                    "maxver": 5
                }
            ],
            "severity": "INFO",
            "debuglevel": 0
        }
    ]
}
}
EOF_XYZ
  } > "${ROOT}${f}"

  chmod 640 "${ROOT}${f}"
  kea_own "${ROOT}${f}"
  ok "wrote ${f}"

  # Runtime directories that the packages do not always pre-create.
  for d in /var/lib/kea /var/log/kea /run/kea; do
    if [ "$DRY_RUN" = "yes" ]; then
      printf '  \033[2m(dry-run) mkdir -p %s\033[0m\n' "$d"
    else
      mkdir -p "$d"
      kea_own "$d"
    fi
  done

  # Validate all three files if the binaries are present.
  if [ "$DRY_RUN" != "yes" ] || [ -d /usr/sbin ]; then
    for pair in "kea-dhcp4:/etc/kea/kea-dhcp4.conf" \
                "kea-dhcp6:/etc/kea/kea-dhcp6.conf" \
                "kea-dhcp-ddns:/etc/kea/kea-dhcp-ddns.conf"; do
      local bin="${pair%%:*}" cfg="${pair##*:}"
      if command -v "$bin" >/dev/null 2>&1; then
        "$bin" -t "${ROOT}${cfg}" >/dev/null \
          || die "$bin rejected ${cfg}"
        ok "validated ${cfg}"
      else
        warn "$bin not installed - skipping validation of ${cfg}"
      fi
    done
  fi
}

# Any address (v4 or v6) -> its fully qualified reverse-pointer name.
# Used to write PTR records with absolute owner names, which avoids having to
# compute names relative to each zone cut.
ptr_name() {
  python3 -c 'import sys,ipaddress;print(ipaddress.ip_address(sys.argv[1]).reverse_pointer + ".")' "$1"
}

# -----------------------------------------------------------------------------
# SECTION 13 - BIND9
#
# One named instance wearing two hats:
#   1. A validating, recursive resolver for internal clients only.
#   2. The authoritative server for the internal forward and reverse zones,
#      accepting TSIG-signed dynamic updates from kea-dhcp-ddns.
#
# Dynamic zones live under /var/lib/bind because named must be able to write
# their journal (.jnl) files next to them.
# -----------------------------------------------------------------------------

ZONE_DIR="/var/lib/bind"
ZONE_SERIAL="$(date +%Y%m%d)01"

configure_bind_options() {
  log "Writing BIND options"
  local f="/etc/bind/named.conf.options"
  prepare "$f"

  # Build the listen lists and the internal ACL from the VLAN table.
  local listen4="127.0.0.1;" listen6="::1;" acl_body=""
  acl_body+="        127.0.0.1; ::1;"$'\n'
  for def in "${VLAN_DEFS[@]}"; do
    IFS=':' read -r id name v4 pool sid class <<<"$def"
    local gw gua ula net
    gw=$(v4_addr "$v4")
    net=$(v4_network "$v4")
    gua=$(v6_host "$(v6_subnet "$IPV6_GUA_PREFIX" "$sid")" 1)
    ula=$(v6_host "$(v6_subnet "$IPV6_ULA_PREFIX" "$sid")" 1)
    listen4+=" ${gw};"
    listen6+=" ${gua}; ${ula};"
    acl_body+="        ${net};                    // VLAN ${id} ${name}"$'\n'
  done
  acl_body+="        ${IPV6_GUA_PREFIX};"$'\n'
  acl_body+="        ${IPV6_ULA_PREFIX};"$'\n'

  cat > "${ROOT}${f}" <<EOF_XYZ
// Managed by setup-gateway-router.sh

// Validate with:  named-checkconf -z

// ---------------------------------------------------------------------------
// Access control lists. Defining these once keeps the options block readable
// and means adding a VLAN is a one-line change.
// ---------------------------------------------------------------------------
acl "internal" {
${acl_body}};

acl "admin" {
        127.0.0.1; ::1;
        $(v4_network "$ADMIN_V4_CIDR");   // administrator VLAN ${ADMIN_VLAN_ID}
};

options {
        directory "/var/cache/bind";

        // -------------------------------------------------------------------
        // Sockets. named is bound to explicit addresses so it can never
        // answer on the WAN interface, even if a rule is later removed from
        // the firewall. Defence in depth: an open resolver is abused within
        // hours of appearing on the Internet.
        // -------------------------------------------------------------------
        listen-on port 53 { ${listen4} };
        listen-on-v6 port 53 { ${listen6} };

        // -------------------------------------------------------------------
        // Who may ask what.
        // -------------------------------------------------------------------
        allow-query       { internal; };
        allow-query-cache { internal; };
        allow-recursion   { internal; };
        recursion yes;
        // Zone transfers and updates are granted per-zone, never globally.
        allow-transfer    { none; };
        allow-update      { none; };
        allow-notify      { none; };

        // -------------------------------------------------------------------
        // Resolution behaviour.
        // -------------------------------------------------------------------
        // Full recursion from the root servers by default. If you must use
        // the ISP's or a public resolver instead, uncomment below - but note
        // that you then trust them for every answer.
        // forwarders { 9.9.9.9; 2620:fe::fe; };
        // forward only;

        // Validate DNSSEC using the root trust anchor shipped and maintained
        // by the bind9 package (RFC 5011 rollover included).
        dnssec-validation auto;

        // Send only the minimum necessary query name to each authoritative
        // server. "strict" refuses to fall back to sending the full name.
        qname-minimization strict;

        // Omit authority/additional sections clients rarely use - smaller
        // responses, less amplification potential.
        minimal-responses yes;

        // Refresh popular records shortly before they expire so clients
        // rarely wait on an upstream lookup.
        prefetch 2 9;

        max-cache-size 25%;
        max-cache-ttl 86400;
        max-ncache-ttl 3600;

        // Response rate limiting: caps the damage if the resolver is ever
        // exposed or used as a reflector by an internal host.
        rate-limit {
                responses-per-second 20;
                referrals-per-second 5;
                nodata-per-second 5;
                nxdomains-per-second 5;
                errors-per-second 5;
                window 5;
                // Do not throttle our own clients.
                exempt-clients { internal; };
        };

        // Do not advertise the software version to probes.
        version none;
        hostname none;
        server-id none;

        // We are authoritative for these zones and answer NXDOMAIN properly.
        auth-nxdomain no;

        // Ignore upstream notify traffic; nothing is a secondary of ours.
        notify no;

        // EDNS buffer sized to avoid IP fragmentation, which firewalls and
        // middleboxes handle badly (see DNS flag day 2020).
        edns-udp-size 1232;
        max-udp-size 1232;
};

// ---------------------------------------------------------------------------
// Logging. The default is almost nothing; these channels make DNS problems
// diagnosable without turning on full query logging permanently.
// ---------------------------------------------------------------------------
logging {
        channel default_log {
                file "/var/log/named/named.log" versions 5 size 20m;
                severity info;
                print-time yes;
                print-severity yes;
                print-category yes;
        };
        channel update_log {
                file "/var/log/named/update.log" versions 3 size 10m;
                severity info;
                print-time yes;
        };
        channel security_log {
                file "/var/log/named/security.log" versions 3 size 10m;
                severity info;
                print-time yes;
        };
        category default          { default_log; };
        category dnssec           { default_log; };
        category resolver         { default_log; };
        category lame-servers     { null; };   // noisy and rarely actionable
        category update           { update_log; };
        category update-security  { update_log; };
        category security         { security_log; };
        // Uncomment temporarily to log every query - very high volume.
        // category queries       { default_log; };
};
EOF_XYZ
  ok "wrote ${f}"

  # Log directory, owned by named.
  if [ "$DRY_RUN" != "yes" ]; then
    mkdir -p /var/log/named
    getent passwd bind >/dev/null 2>&1 && chown bind:bind /var/log/named
    chmod 750 /var/log/named
  fi
}

configure_bind_zones() {
  log "Writing BIND zone declarations and zone files"

  local f="/etc/bind/named.conf.local"
  prepare "$f"

  {
    cat <<EOF_XYZ
// Managed by setup-gateway-router.sh

// The TSIG key kea-dhcp-ddns uses to authenticate its DNS UPDATEs.
include "/etc/bind/keys/${DDNS_KEY_NAME}.key";

// ---------------------------------------------------------------------------
// Forward zone.
//
// 'update-policy' is preferred over 'allow-update': it authorises by key
// rather than by source address, and 'zonesub' scopes the grant to names at
// or below the zone apex, so a compromised DHCP server cannot rewrite the
// SOA or NS records.
// ---------------------------------------------------------------------------
zone "${DOMAIN}" {
        type primary;
        file "${ZONE_DIR}/db.${DOMAIN}";
        update-policy {
                grant ${DDNS_KEY_NAME} zonesub ANY;
        };
        // Keep the journal small; changes are folded back into the zone file.
        // 'nsupdate -l' or rndc sync -clean will flush it manually.
        allow-transfer { none; };
        notify no;
};
EOF_XYZ

    # --- IPv4 reverse zones, one per VLAN ---------------------------------
    printf '\n// --- IPv4 reverse zones ---------------------------------------------------\n'
    for def in "${VLAN_DEFS[@]}"; do
      IFS=':' read -r id name v4 pool sid class <<<"$def"
      local zone
      zone=$(v4_arpa_zone "$(v4_network "$v4")")
      cat <<EOF_XYZ
zone "${zone}" {
        // VLAN ${id} (${name})
        type primary;
        file "${ZONE_DIR}/db.${zone}";
        update-policy { grant ${DDNS_KEY_NAME} zonesub ANY; };
        allow-transfer { none; };
        notify no;
};
EOF_XYZ
    done

    # --- IPv6 reverse zones, one per /48 ----------------------------------
    printf '\n// --- IPv6 reverse zones ---------------------------------------------------\n'
    printf '// One zone per site prefix covers every VLAN /64 beneath it.\n'
    for prefix in "$IPV6_GUA_PREFIX" "$IPV6_ULA_PREFIX"; do
      local zone6
      zone6=$(v6_arpa_zone "$prefix")
      cat <<EOF_XYZ
zone "${zone6}" {
        // ${prefix}
        type primary;
        file "${ZONE_DIR}/db.${zone6}";
        update-policy { grant ${DDNS_KEY_NAME} zonesub ANY; };
        allow-transfer { none; };
        notify no;
};
EOF_XYZ
    done

    cat <<'EOF_XYZ'

// ---------------------------------------------------------------------------
// Note on leakage: BIND already serves the RFC 6303 / RFC 8375 empty zones
// automatically (10.in-addr.arpa, d.f.ip6.arpa, home.arpa and friends), so
// reverse lookups for private space we do not own are answered locally
// instead of being sent to the root servers. Our own /48 zone above is more
// specific than d.f.ip6.arpa, so it still wins. Do not redeclare the empty
// zones here - use "empty-zones-enable no" only if you have a reason to.
EOF_XYZ
  } > "${ROOT}${f}"
  ok "wrote ${f}"

  mkdir -p "${ROOT}${ZONE_DIR}"

  # -------------------------------------------------------------------------
  # Forward zone file.
  #
  # Note the escaped \$TTL / \$ORIGIN: the heredoc is unquoted so that shell
  # variables expand, which means literal dollar signs must be protected.
  # -------------------------------------------------------------------------
  local fz="${ZONE_DIR}/db.${DOMAIN}"
  prepare "$fz"
  {
    local ns_v4 ns_v6
    ns_v4=$(v4_addr "$LOOPBACK_V4")
    ns_v6="${LOOPBACK_V6%%/*}"
    cat <<EOF_XYZ
\$TTL 3600
\$ORIGIN ${DOMAIN}.
;
; Managed by setup-gateway-router.sh
; THIS FILE IS DYNAMIC: named rewrites it from the journal. Edit it only
; via 'nsupdate', or stop named, edit, and delete the matching .jnl file
; before starting again.
;
@       IN SOA  ns1.${DOMAIN}. hostmaster.${DOMAIN}. (
                ${ZONE_SERIAL}   ; serial (dynamic updates bump this)
                3600             ; refresh
                600              ; retry
                1209600          ; expire  (14 days)
                3600 )           ; minimum

        IN NS   ns1.${DOMAIN}.

; --- The router itself ----------------------------------------------------
; ns1 points at the loopback address, which stays up even if a physical
; interface goes down.
EOF_XYZ
    printf '%-24s IN A     %s\n' "ns1" "$ns_v4"
    printf '%-24s IN AAAA  %s\n' "ns1" "$ns_v6"
    printf '%-24s IN A     %s\n' "$ROUTER_HOSTNAME" "$ns_v4"
    printf '%-24s IN AAAA  %s\n' "$ROUTER_HOSTNAME" "$ns_v6"
    cat <<'EOF_XYZ'

; --- Per-VLAN gateway addresses -------------------------------------------
; Handy for monitoring and for pinning a test to one specific interface.
EOF_XYZ
    for def in "${VLAN_DEFS[@]}"; do
      IFS=':' read -r id name v4 pool sid class <<<"$def"
      local gw gua ula
      gw=$(v4_addr "$v4")
      gua=$(v6_host "$(v6_subnet "$IPV6_GUA_PREFIX" "$sid")" 1)
      ula=$(v6_host "$(v6_subnet "$IPV6_ULA_PREFIX" "$sid")" 1)
      printf '%-24s IN A     %s\n' "gw-${name}" "$gw"
      printf '%-24s IN AAAA  %s\n' "gw-${name}" "$gua"
      printf '%-24s IN AAAA  %s\n' "gw-${name}-ula" "$ula"
    done
  } > "${ROOT}${fz}"
  ok "wrote ${fz}"

  # -------------------------------------------------------------------------
  # IPv4 reverse zone files.
  # -------------------------------------------------------------------------
  for def in "${VLAN_DEFS[@]}"; do
    IFS=':' read -r id name v4 pool sid class <<<"$def"
    local zone gw rz
    zone=$(v4_arpa_zone "$(v4_network "$v4")")
    gw=$(v4_addr "$v4")
    rz="${ZONE_DIR}/db.${zone}"
    prepare "$rz"
    cat > "${ROOT}${rz}" <<EOF_XYZ
\$TTL 3600
\$ORIGIN ${zone}.
;
; VLAN ${id} (${name}) reverse zone - dynamic, see note in db.${DOMAIN}.
;
@       IN SOA  ns1.${DOMAIN}. hostmaster.${DOMAIN}. (
                ${ZONE_SERIAL} 3600 600 1209600 3600 )

        IN NS   ns1.${DOMAIN}.

; The gateway's own PTR, written with an absolute owner name.
$(ptr_name "$gw")  IN PTR  gw-${name}.${DOMAIN}.
EOF_XYZ
    ok "wrote ${rz}"
  done

  # -------------------------------------------------------------------------
  # IPv6 reverse zone files, one per site prefix.
  # -------------------------------------------------------------------------
  for prefix in "$IPV6_GUA_PREFIX" "$IPV6_ULA_PREFIX"; do
    local zone6 rz6
    zone6=$(v6_arpa_zone "$prefix")
    rz6="${ZONE_DIR}/db.${zone6}"
    prepare "$rz6"
    {
      cat <<EOF_XYZ
\$TTL 3600
\$ORIGIN ${zone6}.
;
; Reverse zone for ${prefix} - covers every VLAN /64 inside it.
; Dynamic; see the note in db.${DOMAIN}.
;
@       IN SOA  ns1.${DOMAIN}. hostmaster.${DOMAIN}. (
                ${ZONE_SERIAL} 3600 600 1209600 3600 )

        IN NS   ns1.${DOMAIN}.

; --- Gateway PTRs ---------------------------------------------------------
EOF_XYZ
      for def in "${VLAN_DEFS[@]}"; do
        IFS=':' read -r id name v4 pool sid class <<<"$def"
        local addr
        addr=$(v6_host "$(v6_subnet "$prefix" "$sid")" 1)
        printf '%s IN PTR gw-%s.%s.\n' "$(ptr_name "$addr")" "$name" "$DOMAIN"
      done
      # The loopback PTR only belongs in the zone that actually contains it.
      if [ "$prefix" = "$IPV6_GUA_PREFIX" ]; then
        printf '%s IN PTR %s.%s.\n' \
          "$(ptr_name "${LOOPBACK_V6%%/*}")" "$ROUTER_HOSTNAME" "$DOMAIN"
      fi
    } > "${ROOT}${rz6}"
    ok "wrote ${rz6}"
  done

  # Ownership: named needs write access to the zone directory so it can
  # create journal files when Kea sends an update.
  if [ "$DRY_RUN" != "yes" ] && getent passwd bind >/dev/null 2>&1; then
    chown -R bind:bind "$ZONE_DIR"
    chmod 775 "$ZONE_DIR"
    ok "zone directory owned by bind"
  fi

  # ---- Validation --------------------------------------------------------
  # named-checkzone is self-contained, so it works on staged files too.
  if command -v named-checkzone >/dev/null 2>&1; then
    named-checkzone -q "$DOMAIN" "${ROOT}${fz}" \
      || die "forward zone ${DOMAIN} failed validation"
    for def in "${VLAN_DEFS[@]}"; do
      IFS=':' read -r id name v4 pool sid class <<<"$def"
      local z; z=$(v4_arpa_zone "$(v4_network "$v4")")
      named-checkzone -q "$z" "${ROOT}${ZONE_DIR}/db.${z}" \
        || die "reverse zone ${z} failed validation"
    done
    for prefix in "$IPV6_GUA_PREFIX" "$IPV6_ULA_PREFIX"; do
      local z6; z6=$(v6_arpa_zone "$prefix")
      named-checkzone -q "$z6" "${ROOT}${ZONE_DIR}/db.${z6}" \
        || die "reverse zone ${z6} failed validation"
    done
    ok "all zone files validated"
  else
    warn "named-checkzone unavailable - skipping zone validation"
  fi

  # named-checkconf follows absolute include paths, so it is only meaningful
  # against the real /etc/bind tree.
  if [ "$DRY_RUN" != "yes" ] && command -v named-checkconf >/dev/null 2>&1; then
    named-checkconf -z || die "named-checkconf rejected the configuration"
    ok "named.conf validated"
  fi
}

# -----------------------------------------------------------------------------
# SECTION 14 - FRR
#
# FRR does two jobs here:
#   1. OSPFv2 + OSPFv3 for dynamic routing. On a single-router site this is
#      inert, but it is what lets you add a second router, a VPN concentrator
#      or a downstream L3 switch without hand-maintaining static routes.
#   2. IPv6 router advertisements. zebra has a full RA implementation, so no
#      separate radvd is needed - one fewer daemon and one fewer config file
#      to keep in sync with the addressing plan.
# -----------------------------------------------------------------------------

configure_frr() {
  log "Writing FRR configuration"

  # --- Which daemons to run ------------------------------------------------
  local d="/etc/frr/daemons"
  prepare "$d"
  cat > "${ROOT}${d}" <<EOF_XYZ
# Managed by setup-gateway-router.sh

# Only enable what is actually used: every daemon is another listening
# process and another config surface.

zebra=yes            # kernel routing table interface, plus IPv6 RA
mgmtd=yes            # configuration manager (required on FRR 9+)
staticd=yes          # static routes configured in frr.conf
ospfd=yes            # OSPFv2 (IPv4)
ospf6d=yes           # OSPFv3 (IPv6)
bgpd=${ENABLE_BGP}
ripd=no
ripngd=no
isisd=no
pimd=no
pim6d=no
ldpd=no
nhrpd=no
eigrpd=no
babeld=no
sharpd=no
pbrd=no
bfdd=no              # set to yes for sub-second failure detection
fabricd=no
vrrpd=no
pathd=no

# -A 127.0.0.1 binds each daemon's vty to the loopback only.
zebra_options="  -A 127.0.0.1 -s 90000000"
mgmtd_options="  -A 127.0.0.1"
staticd_options="-A 127.0.0.1"
ospfd_options="  -A 127.0.0.1"
ospf6d_options=" -A 127.0.0.1"
bgpd_options="   -A 127.0.0.1"
bfdd_options="   -A 127.0.0.1"

vtysh_enable=yes
# Watchfrr restarts any daemon that dies.
watchfrr_enable=yes
watchfrr_options=""
EOF_XYZ
  ok "wrote ${d}"

  # --- vtysh: one integrated config file, not per-daemon files -------------
  local v="/etc/frr/vtysh.conf"
  prepare "$v"
  cat > "${ROOT}${v}" <<EOF_XYZ
# Managed by setup-gateway-router.sh

# 'integrated-vtysh-config' makes "write memory" save everything to
# /etc/frr/frr.conf instead of scattering zebra.conf, ospfd.conf and friends.
service integrated-vtysh-config
hostname ${ROUTER_HOSTNAME}
EOF_XYZ
  ok "wrote ${v}"

  # --- The routing configuration itself ------------------------------------
  local f="/etc/frr/frr.conf"
  prepare "$f"

  {
    cat <<EOF_XYZ
! Managed by setup-gateway-router.sh

! Reload without dropping adjacencies:
!   /usr/lib/frr/frr-reload.py --reload /etc/frr/frr.conf
!
frr defaults traditional
hostname ${ROUTER_HOSTNAME}
log syslog informational
log timestamp precision 3
service integrated-vtysh-config
!
! Forwarding is also set via sysctl; stating it here keeps FRR from
! reverting it on startup.
ip forwarding
ipv6 forwarding
!
! ==========================================================================
! Interfaces
! ==========================================================================
!
interface ${LOOPBACK_IF}
 description router-id and stable administrator address
 ! Advertised into OSPF but never forms adjacencies - there is no neighbour
 ! on a dummy interface.
 ip ospf area ${OSPF_AREA}
 ip ospf passive
 ipv6 ospf6 area ${OSPF_AREA}
 ipv6 ospf6 passive
!
interface ${WAN_IF}
 description uplink to ISP
 ! The uplink must never advertise itself as an IPv6 router to the ISP, and
 ! is deliberately absent from every OSPF area below - OSPF membership is
 ! opt-in per interface, so silence here is all that is required.
 ipv6 nd suppress-ra
!
EOF_XYZ

    for def in "${VLAN_DEFS[@]}"; do
      IFS=':' read -r id name v4 pool sid class <<<"$def"
      local ifn="${VLAN_IF_PREFIX}${id}"
      local gua_net ula_net gua_gw
      gua_net=$(v6_subnet "$IPV6_GUA_PREFIX" "$sid")
      ula_net=$(v6_subnet "$IPV6_ULA_PREFIX" "$sid")
      gua_gw=$(v6_host "$gua_net" 1)

      cat <<EOF_XYZ
interface ${ifn}
 description VLAN ${id} ${name} (${class})
 !
 ! --- IPv6 router advertisements ---------------------------------------
 ! RAs are what actually make this a router as far as IPv6 hosts are
 ! concerned: they carry the default route, the on-link prefixes and the
 ! flags that tell clients whether to ask DHCPv6 for an address.
 no ipv6 nd suppress-ra
 ipv6 nd ra-interval 30
 ! Lifetime must exceed the interval by a comfortable margin, or clients
 ! will briefly lose their default route between advertisements.
 ipv6 nd ra-lifetime 1800
 ipv6 nd reachable-time 3600000
 !
 ! M flag: "addresses are available via DHCPv6" -> clients talk to Kea.
 ipv6 nd managed-config-flag
 ! O flag: "other configuration is available via DHCPv6" (DNS, domain).
 ipv6 nd other-config-flag
 !
 ! Prefixes. The A (autonomous) flag is left on deliberately: Android has
 ! never implemented DHCPv6, so SLAAC is the only way those clients get an
 ! address. Dual-stack hosts simply end up with both a SLAAC and a Kea
 ! address, which is harmless.
 ! Arguments are valid-lifetime then preferred-lifetime, in seconds.
 ipv6 nd prefix ${gua_net} 2592000 604800
 ipv6 nd prefix ${ula_net} 2592000 604800
 !
 ! RDNSS/DNSSL (RFC 8106) so hosts that ignore DHCPv6 still get a resolver.
 ipv6 nd rdnss ${gua_gw} 1800
 ipv6 nd dnssl ${DOMAIN} 1800
 !
 ipv6 nd mtu 1500
 !
 ! --- OSPF -------------------------------------------------------------
 ip ospf area ${OSPF_AREA}
 ipv6 ospf6 area ${OSPF_AREA}
EOF_XYZ
      if [ "$id" = "$ADMIN_VLAN_ID" ]; then
        cat <<EOF_XYZ
 ! Administrator VLAN: adjacencies are allowed here, so a second router or an
 ! L3 switch can peer with us. Authenticated so a random host on the VLAN
 ! cannot inject routes.
 ip ospf authentication message-digest
 ip ospf message-digest-key 1 md5 ${OSPF_AUTH_KEY}
 ip ospf network broadcast
 ! Higher priority than the default 1 so this router wins the DR election.
 ip ospf priority 100
 ip ospf hello-interval 5
 ip ospf dead-interval 20
 ipv6 ospf6 network broadcast
 ipv6 ospf6 priority 100
 ipv6 ospf6 hello-interval 5
 ipv6 ospf6 dead-interval 20
EOF_XYZ
      else
        cat <<EOF_XYZ
 ! Client VLAN: the prefix is advertised into OSPF, but no hellos are sent,
 ! so an untrusted host cannot become an OSPF neighbour.
 ip ospf passive
 ipv6 ospf6 passive
EOF_XYZ
      fi
      printf '!\n'
    done

    cat <<EOF_XYZ
! ==========================================================================
! OSPFv2 (IPv4)
!
! Interface membership is declared above with "ip ospf area", which is the
! current FRR idiom. The older equivalent inside this block would be:
!   network 10.10.99.0/24 area ${OSPF_AREA}
! ==========================================================================
router ospf
 ospf router-id ${OSPF_ROUTER_ID}
 ! Advertise a default route to downstream routers. "always" originates it
 ! even when our own default is missing - drop "always" if you would rather
 ! stop attracting traffic during an uplink outage.
 default-information originate always metric 10
 ! Log adjacency transitions: the single most useful OSPF diagnostic.
 log-adjacency-changes detail
 ! Never install a default route learned from a neighbour: ours comes from
 ! the WAN DHCP lease, and accepting someone else's would black-hole all
 ! outbound traffic if a downstream device started originating one.
 distribute-list DENY-DEFAULT in ${ADMIN_IF}
!
ip prefix-list DENY-DEFAULT seq 5 deny 0.0.0.0/0
ip prefix-list DENY-DEFAULT seq 10 permit 0.0.0.0/0 le 32
!
! ==========================================================================
! OSPFv3 (IPv6)
! ==========================================================================
router ospf6
 ospf6 router-id ${OSPF_ROUTER_ID}
 default-information originate always metric 10
 log-adjacency-changes detail
!
EOF_XYZ

    if [ "$ENABLE_BGP" = "yes" ]; then
      cat <<EOF_XYZ
! ==========================================================================
! BGP - fill in ASNs and neighbours before enabling in production.
! ==========================================================================
router bgp 65000
 bgp router-id ${OSPF_ROUTER_ID}
 no bgp default ipv4-unicast
 bgp log-neighbor-changes
 !
 ! neighbor UPSTREAM peer-group
 ! neighbor UPSTREAM remote-as external
 ! neighbor 192.0.2.1 peer-group UPSTREAM
 !
 address-family ipv4 unicast
  ! network ${IPV6_GUA_PREFIX}
 exit-address-family
 address-family ipv6 unicast
  ! network ${IPV6_GUA_PREFIX}
 exit-address-family
!
EOF_XYZ
    else
      cat <<'EOF_XYZ'
! BGP is disabled (ENABLE_BGP=no). Set it to yes and edit this section if you
! need to peer with an upstream or a tunnel broker.
!
EOF_XYZ
    fi

    cat <<'EOF_XYZ'
! ==========================================================================
! Access control for the vty. FRR is configured from files here, so remote
! vty access is refused outright.
! ==========================================================================
line vty
 exec-timeout 15 0
!
end
EOF_XYZ
  } > "${ROOT}${f}"

  # FRR runs as the 'frr' user and reads these at startup.
  chmod 640 "${ROOT}${f}" "${ROOT}${d}" "${ROOT}${v}"
  if [ "$DRY_RUN" != "yes" ] && getent passwd frr >/dev/null 2>&1; then
    chown frr:frr "$f" "$d" "$v"
  fi
  ok "wrote ${f}"

  # vtysh can parse a config without applying it. Treat failure as a warning
  # rather than fatal: syntax accepted by FRR varies across versions, and a
  # false negative here should not block the rest of the run.
  if command -v vtysh >/dev/null 2>&1; then
    if vtysh --dryrun --inputfile "${ROOT}${f}" >/dev/null 2>&1; then
      ok "FRR configuration parsed cleanly"
    else
      warn "vtysh --dryrun reported problems; review with:"
      warn "  vtysh --dryrun --inputfile ${f}"
    fi
  fi
}

# -----------------------------------------------------------------------------
# SECTION 15 - HOSTNAME AND /etc/hosts
# -----------------------------------------------------------------------------

configure_identity() {
  log "Setting hostname and static hosts entries"

  local fqdn="${ROUTER_HOSTNAME}.${DOMAIN}"
  run hostnamectl set-hostname "$fqdn"

  local f="/etc/hosts"
  prepare "$f"
  cat > "${ROOT}${f}" <<EOF_XYZ
# Managed by setup-gateway-router.sh

127.0.0.1   localhost

# The following lines are desirable for IPv6 capable hosts
# ::1         ip6-localhost ip6-loopback
::1         localhost ip6-localhost ip6-loopback
fe00::0     ip6-localnet
ff00::0     ip6-mcastprefix
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters

# The following stable DNS router addresses will resolve even if named is not running
$(v4_addr "$LOOPBACK_V4")   ${fqdn} ${ROUTER_HOSTNAME}
${LOOPBACK_V6%%/*}   ${fqdn} ${ROUTER_HOSTNAME}
EOF_XYZ
  ok "wrote ${f}"
}

# -----------------------------------------------------------------------------
# SECTION 16 - SERVICE ACTIVATION
#
# Order matters: interfaces and the firewall come up before any daemon that
# needs to bind to a specific address.
# -----------------------------------------------------------------------------

enable_services() {
  log "Enabling and starting services"

  if [ "$DRY_RUN" = "yes" ]; then
    printf '  \033[2m(dry-run) would enable: nftables systemd-networkd named\033[0m\n'
    printf '  \033[2m(dry-run) kea-dhcp4-server kea-dhcp6-server kea-dhcp-ddns-server frr\033[0m\n'
    return 0
  fi

  # 1. Firewall first, so there is never a window where the box forwards
  #    traffic with no policy in place.
  systemctl enable --now nftables
  ok "nftables active"

  # 2. Networking. 'netplan apply' reloads networkd and brings up the VLANs.
  confirm "Apply netplan now? This may interrupt the network."
  netplan apply
  # Give networkd a moment to create the VLAN and dummy interfaces.
  sleep 3
  systemctl enable systemd-networkd
  ok "netplan applied"

  # Re-run sysctl: the per-interface keys could not be set before the
  # interfaces existed.
  sysctl --system -q || warn "some sysctl keys still unset - check interface names"

  # 3. DNS before DHCP, because kea-dhcp-ddns needs a server to update.
  systemctl enable --now named
  ok "named active"

  # 4. DHCP. The DDNS forwarder starts first so the servers have somewhere
  #    to send name change requests.
  systemctl enable --now kea-dhcp-ddns-server
  systemctl enable --now kea-dhcp4-server
  systemctl enable --now kea-dhcp6-server
  ok "kea active"

  # 5. Routing last: it should only start advertising once forwarding,
  #    filtering and addressing are all settled.
  systemctl enable --now frr
  ok "frr active"
}

# -----------------------------------------------------------------------------
# SECTION 17 - POST-INSTALL VERIFICATION
# -----------------------------------------------------------------------------

verify() {
  log "Verification"

  if [ "$DRY_RUN" = "yes" ]; then
    printf '\nRendered configuration tree under %s:\n\n' "$ROOT"
    find "$ROOT" -type f | sort | sed 's/^/  /'
    printf '\n'
    ok "dry run complete - nothing was applied"
    return 0
  fi

  local failed=0

  # Service states.
  for svc in nftables systemd-networkd named kea-dhcp4-server \
             kea-dhcp6-server kea-dhcp-ddns-server frr; do
    if systemctl is-active --quiet "$svc"; then
      ok "$svc running"
    else
      warn "$svc NOT running - journalctl -u $svc -n 50"
      failed=$((failed + 1))
    fi
  done

  # Interfaces and addresses.
  for iface in "$WAN_IF" "$LOOPBACK_IF" "${VLAN_IFACES[@]}"; do
    if ip link show "$iface" >/dev/null 2>&1; then
      ok "$iface up: $(ip -br -4 addr show "$iface" | awk '{$1=$2="";print}' | xargs)"
    else
      warn "$iface missing"
      failed=$((failed + 1))
    fi
  done

  # Forwarding actually enabled.
  [ "$(sysctl -n net.ipv4.ip_forward)" = "1" ] \
    && ok "IPv4 forwarding on" || { warn "IPv4 forwarding OFF"; failed=$((failed+1)); }
  [ "$(sysctl -n net.ipv6.conf.all.forwarding)" = "1" ] \
    && ok "IPv6 forwarding on" || { warn "IPv6 forwarding OFF"; failed=$((failed+1)); }

  # Default routes, one per family.
  ip -4 route show default | grep -q . \
    && ok "IPv4 default: $(ip -4 route show default | head -1)" \
    || warn "no IPv4 default route (is the WAN DHCP lease up?)"
  ip -6 route show default | grep -q . \
    && ok "IPv6 default: $(ip -6 route show default | head -1)" \
    || warn "no IPv6 default route (is the ISP sending RAs?)"

  # Resolver answering for both a local and an external name.
  if command -v dig >/dev/null 2>&1; then
    dig +short +timeout=3 @127.0.0.1 "ns1.${DOMAIN}" A >/dev/null 2>&1 \
      && ok "named answers for ${DOMAIN}" \
      || { warn "named did not answer for ${DOMAIN}"; failed=$((failed+1)); }
    if dig +short +timeout=5 @127.0.0.1 dnssec-failed.org A 2>/dev/null | grep -q .; then
      warn "resolver returned an answer for a known-bad DNSSEC name"
    else
      ok "DNSSEC validation appears to be rejecting bad signatures"
    fi
  fi

  # Firewall loaded.
  local rules
  rules=$(nft list ruleset 2>/dev/null | grep -c 'counter' || true)
  [ "${rules:-0}" -gt 0 ] \
    && ok "nftables ruleset loaded (${rules} counted rules)" \
    || { warn "nftables ruleset looks empty"; failed=$((failed+1)); }

  # OSPF is up, even if it has no neighbours yet.
  if command -v vtysh >/dev/null 2>&1; then
    vtysh -c 'show ip ospf' >/dev/null 2>&1 \
      && ok "ospfd responding" || warn "ospfd not responding"
    vtysh -c 'show ipv6 ospf6' >/dev/null 2>&1 \
      && ok "ospf6d responding" || warn "ospf6d not responding"
  fi

  printf '\n'
  if [ "$failed" -eq 0 ]; then
    log "All checks passed."
  else
    warn "${failed} check(s) failed - see the hints above"
  fi
}

# -----------------------------------------------------------------------------
# SECTION 18 - OPERATOR CHEAT SHEET
# -----------------------------------------------------------------------------

print_summary() {
  cat <<EOF_XYZ

===========================================================================
 ${ROUTER_HOSTNAME}.${DOMAIN} - dual-stack router
===========================================================================

 WAN            ${WAN_IF}          (DHCPv4 + RA/SLAAC from ISP)
 Trunk          ${LAN_TRUNK_IF}    (802.1Q, no L3 addresses)
 Loopback       ${LOOPBACK_IF}     ${LOOPBACK_V4} / ${LOOPBACK_V6}
 IPv6 GUA       ${IPV6_GUA_PREFIX}
 IPv6 ULA       ${IPV6_ULA_PREFIX}
 Backups        ${BACKUP_DIR}

 VLANs
$(for def in "${VLAN_DEFS[@]}"; do
    IFS=':' read -r id name v4 pool sid class <<<"$def"
    printf '   %-6s %-8s %-18s %s\n' "${VLAN_IF_PREFIX}${id}" "$name" "$v4" \
      "$(v6_subnet "$IPV6_GUA_PREFIX" "$sid")"
  done)

---------------------------------------------------------------------------
 Everyday commands
---------------------------------------------------------------------------
 Interfaces      networkctl status; ip -br addr
 Netplan         netplan get; netplan try   (auto-reverts in 120s)
 Firewall        nft list ruleset
                 nft -c -f /etc/nftables.conf && systemctl reload nftables
 Counters        nft list ruleset | grep -B2 'counter packets [1-9]'
 Conntrack       conntrack -L -n | head
 DHCPv4 leases   cat /var/lib/kea/kea-leases4.csv
                 kea-shell --service dhcp4 lease4-get-all <<< '{}'
 DHCPv6 leases   cat /var/lib/kea/kea-leases6.csv
 DHCP logs       journalctl -u kea-dhcp4-server -f
 DNS             dig @127.0.0.1 <name>; rndc status
 DNS zone dump   rndc sync -clean && cat ${ZONE_DIR}/db.${DOMAIN}
 DDNS trace      journalctl -u kea-dhcp-ddns-server -f
 Routing         vtysh -c 'show ip route'; vtysh -c 'show ipv6 route'
 OSPF            vtysh -c 'show ip ospf neighbor'
                 vtysh -c 'show ipv6 ospf6 neighbor'
 RA sanity       radvdump  (or: tcpdump -ni ${ADMIN_IF} icmp6)
 FRR reload      /usr/lib/frr/frr-reload.py --reload /etc/frr/frr.conf

---------------------------------------------------------------------------
 Before you call this done
---------------------------------------------------------------------------
 1. Replace the example prefixes. 2001:db8::/32 is documentation-only
    (RFC 3849) and will not route. Put your delegated GUA in
    IPV6_GUA_PREFIX and generate your own ULA:  openssl rand -hex 5
 2. Change OSPF_AUTH_KEY, and remove the admin-VLAN OSPF adjacency entirely
    if there is no second router to peer with.
 3. Confirm the ISP's IPv6 handoff. If they use DHCPv6-PD rather than a
    static delegation, set ENABLE_DHCPV6_PD=yes - and be aware that the
    static /64s in netplan, the Kea subnet6 blocks and the FRR
    "ipv6 nd prefix" lines all need to follow the delegated prefix. That
    normally means a networkd-dispatcher or systemd hook that rewrites
    them on lease change, which is beyond this script.
 4. Harden SSH separately (keys only, no root login). The firewall limits
    SSH to the administrator VLAN, but that is not a substitute.
 5. Set up monitoring on the loopback address and alerting on the
    "nft *-drop" log prefixes.
 6. Test failure modes before you rely on them: unplug the WAN, reboot,
    and confirm the box comes back with both families working.

===========================================================================
EOF_XYZ
}

# -----------------------------------------------------------------------------
# MAIN
# -----------------------------------------------------------------------------

main() {
  printf '\n\033[1mUbuntu 26.04 dual-stack router provisioning\033[0m\n'
  [ "$DRY_RUN" = "yes" ] && printf '\033[1;33mDRY RUN MODE\033[0m\n'
  printf '\n'

  preflight
  install_packages
  configure_sysctl
  configure_netplan
  configure_dhcpv6_pd
  configure_resolved
  configure_nftables
  generate_tsig_key
  configure_kea_dhcp4
  configure_kea_dhcp6
  configure_kea_ddns
  configure_bind_options
  configure_bind_zones
  configure_frr
  configure_identity
  enable_services
  verify
  print_summary
}

main "$@"

# code: language=sh
# vi: syntax=sh ts=4 sw=4 sts=4 noexpandtab
# vim: set filetype=sh ts=4 sw=4 sts=4 noexpandtab
