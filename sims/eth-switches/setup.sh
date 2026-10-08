#!/usr/bin/env bash
# Configures a debian:trixie container as a managed L3 switch.
#
# Runs at boot through the topology's `exec`, and is safe to re-run by hand:
#   bash /lab/setup.sh
#
# Every per-switch value comes from environment variables set in the topology
# file (`env` on each node). Unset variables mean "feature not used":
#   LOOPBACK           loopback /32, also the OSPF and BGP router ID
#   STP_PRIORITY       bridge priority (default 32768)
#   ROUTED             "port=ip/31 ..."
#   TRUNK              "port=vlan,vlan ..."
#   ACCESS             "port=vlan ..."
#   SVI                "vlan=ip/prefix ..."
#   VRRP               "vlan=virtual-ip/prefix ..."
#   VRRP_PRIORITY      VRRP priority for every group on this switch
#   OSPF_PORTS         "port ..." routed ports in OSPF area 0
#   OSPF_DEFAULT       "yes" to originate a default route into OSPF
#   OSPF_REDISTRIBUTE  "bgp static ..."
#   BGP_ASN            local AS number, enables BGP
#   BGP_PORTS          "port ..." routed ports to peer on (peer = other end of the /31)
#   BGP_NETWORKS       "prefix ..." advertised with `network`
#   BGP_AGGREGATES     "prefix ..." advertised with `aggregate-address ... summary-only`
#   BGP_REDISTRIBUTE   "ospf connected static ..."
#   STATIC_ROUTES      "prefix=next-hop[@distance] ..."

set -euo pipefail
exec > >(tee -a /var/log/switch-setup.log) 2>&1

LOOPBACK=${LOOPBACK:-}
STP_PRIORITY=${STP_PRIORITY:-32768}
ROUTED=${ROUTED:-}
TRUNK=${TRUNK:-}
ACCESS=${ACCESS:-}
SVI=${SVI:-}
VRRP=${VRRP:-}
VRRP_PRIORITY=${VRRP_PRIORITY:-100}
OSPF_PORTS=${OSPF_PORTS:-}
OSPF_DEFAULT=${OSPF_DEFAULT:-}
OSPF_REDISTRIBUTE=${OSPF_REDISTRIBUTE:-}
BGP_ASN=${BGP_ASN:-}
BGP_PORTS=${BGP_PORTS:-}
BGP_NETWORKS=${BGP_NETWORKS:-}
BGP_AGGREGATES=${BGP_AGGREGATES:-}
BGP_REDISTRIBUTE=${BGP_REDISTRIBUTE:-}
STATIC_ROUTES=${STATIC_ROUTES:-}

# swp1 to swp10 are 1G RJ45, swp11 and up are 10G SFP+
LAST_1G_PORT=10

PACKAGES=(iproute2 ethtool lldpd tcpdump nftables procps iputils-ping kmod openssh-server frr)

log() { echo "[setup $(date +%T)] $*"; }

install_packages() {
  if dpkg -s "${PACKAGES[@]}" >/dev/null 2>&1; then
    log "packages already installed"
    return
  fi
  log "installing packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends "${PACKAGES[@]}" >/dev/null
}

setup_management() {
  log "management: removing eth0 default routes, starting sshd"
  ip -4 route del default dev eth0 2>/dev/null || true
  ip -6 route del default dev eth0 2>/dev/null || true
  echo 'root:clab' | chpasswd
  echo 'PermitRootLogin yes' > /etc/ssh/sshd_config.d/lab.conf
  mkdir -p /run/sshd
  pgrep -x sshd >/dev/null || /usr/sbin/sshd
}

setup_ports() {
  log "ports: aliases, egress qdiscs"
  local dev port num alias rate limit
  for dev in /sys/class/net/swp*; do
    port=${dev##*/}
    num=${port#swp}
    if (( num <= LAST_1G_PORT )); then
      alias=1G-RJ45 rate=1gbit limit=1000
    else
      alias=10G-SFP+ rate=10gbit limit=10000
    fi
    ip link set "$port" alias "$alias"
    tc qdisc replace dev "$port" root netem rate "$rate" limit "$limit"
    ip link set "$port" up
  done
}

setup_bridge() {
  log "bridge: br0, trunk and access ports"
  if ! ip link show br0 >/dev/null 2>&1; then
    ip link add br0 type bridge vlan_filtering 1 stp_state 1 priority "$STP_PRIORITY" \
      fdb_max_learned 16384 ageing_time 30000 vlan_stats_enabled 1
  fi
  ip link set br0 type bridge priority "$STP_PRIORITY"
  ip link set br0 mtu 9216

  local entry port vlans vid
  for entry in $TRUNK; do
    port=${entry%%=*} vlans=${entry#*=}
    ip link set "$port" master br0
    bridge vlan del dev "$port" vid 1 2>/dev/null || true
    for vid in ${vlans//,/ }; do
      bridge vlan add dev "$port" vid "$vid"
    done
  done
  for entry in $ACCESS; do
    port=${entry%%=*} vid=${entry#*=}
    ip link set "$port" master br0
    bridge vlan del dev "$port" vid 1 2>/dev/null || true
    bridge vlan add dev "$port" vid "$vid" pvid untagged
  done
  for entry in $SVI; do
    bridge vlan add dev br0 vid "${entry%%=*}" self
  done
  ip link set br0 up
}

setup_l3() {
  log "l3: loopback, routed ports, SVIs, VRRP interfaces"
  [[ -n $LOOPBACK ]] && ip addr replace "$LOOPBACK" dev lo

  local entry vid dev
  for entry in $ROUTED; do
    ip addr replace "${entry#*=}" dev "${entry%%=*}"
  done
  for entry in $SVI; do
    vid=${entry%%=*}
    ip link show "vlan$vid" >/dev/null 2>&1 || ip link add link br0 name "vlan$vid" type vlan id "$vid"
    ip addr replace "${entry#*=}" dev "vlan$vid"
    ip link set "vlan$vid" up
  done
  for entry in $VRRP; do
    vid=${entry%%=*} dev=vrrp4-${entry%%=*}
    if ! ip link show "$dev" >/dev/null 2>&1; then
      ip link add "$dev" link "vlan$vid" type macvlan mode bridge
      ip link set "$dev" addrgenmode random
    fi
    ip link set "$dev" address "$(printf '00:00:5e:00:01:%02x' "$vid")"
    ip addr replace "${entry#*=}" dev "$dev"
    ip link set "$dev" up
  done
}

peer_of() {
  local ip=${1%/*}
  echo "${ip%.*}.$(( ${ip##*.} ^ 1 ))"
}

routed_addr() {
  local entry
  for entry in $ROUTED; do
    [[ ${entry%%=*} == "$1" ]] && { echo "${entry#*=}"; return; }
  done
  echo "setup: $1 is in BGP_PORTS but not in ROUTED" >&2
  return 1
}

vrrp_vip() {
  local entry
  for entry in $VRRP; do
    [[ ${entry%%=*} == "$1" ]] && { echo "${entry#*=}"; return; }
  done
}

generate_frr_conf() {
  local rid=${LOOPBACK%/*} port entry vid vip item prefix nexthop distance peer

  echo "frr defaults datacenter"
  echo "hostname $(hostname)"
  echo "service integrated-vtysh-config"
  echo "!"

  for port in $OSPF_PORTS; do
    printf 'interface %s\n ip ospf area 0\n ip ospf network point-to-point\n ip ospf bfd\nexit\n!\n' "$port"
  done
  if [[ -n $OSPF_PORTS && -n $LOOPBACK ]]; then
    printf 'interface lo\n ip ospf area 0\nexit\n!\n'
  fi

  for entry in $SVI; do
    vid=${entry%%=*}
    vip=$(vrrp_vip "$vid")
    [[ -z $OSPF_PORTS && -z $vip ]] && continue
    echo "interface vlan$vid"
    if [[ -n $OSPF_PORTS ]]; then
      echo " ip ospf area 0"
      echo " ip ospf passive"
    fi
    if [[ -n $vip ]]; then
      echo " vrrp $vid version 3"
      echo " vrrp $vid priority $VRRP_PRIORITY"
      echo " vrrp $vid ip ${vip%/*}"
    fi
    printf 'exit\n!\n'
  done

  local seq=5
  for item in $BGP_AGGREGATES; do
    echo "ip prefix-list LOCAL-AGGREGATES seq $seq permit $item"
    seq=$(( seq + 5 ))
  done
  printf 'route-map REDIST deny 10\n match interface eth0\nexit\n'
  if [[ -n $BGP_AGGREGATES ]]; then
    printf 'route-map REDIST deny 20\n match ip address prefix-list LOCAL-AGGREGATES\nexit\n'
  fi
  printf 'route-map REDIST permit 100\nexit\n!\n'

  if [[ -n $OSPF_PORTS ]]; then
    echo "router ospf"
    [[ -n $rid ]] && echo " ospf router-id $rid"
    [[ $OSPF_DEFAULT == yes ]] && echo " default-information originate"
    for item in $OSPF_REDISTRIBUTE; do echo " redistribute $item route-map REDIST"; done
    printf 'exit\n!\n'
  fi

  if [[ -n $BGP_ASN ]]; then
    echo "router bgp $BGP_ASN"
    [[ -n $rid ]] && echo " bgp router-id $rid"
    echo " no bgp ebgp-requires-policy"
    for port in $BGP_PORTS; do
      peer=$(peer_of "$(routed_addr "$port")")
      echo " neighbor $peer remote-as external"
      echo " neighbor $peer bfd"
    done
    echo " address-family ipv4 unicast"
    echo "  maximum-paths 8"
    for item in $BGP_NETWORKS; do echo "  network $item"; done
    for item in $BGP_AGGREGATES; do echo "  aggregate-address $item summary-only"; done
    for item in $BGP_REDISTRIBUTE; do echo "  redistribute $item route-map REDIST"; done
    echo " exit-address-family"
    printf 'exit\n!\n'
  fi

  for entry in $STATIC_ROUTES; do
    prefix=${entry%%=*} nexthop=${entry#*=} distance=
    if [[ $nexthop == *@* ]]; then
      distance=${nexthop#*@} nexthop=${nexthop%@*}
    fi
    echo "ip route $prefix $nexthop${distance:+ $distance}"
  done
  echo "!"
}

setup_frr() {
  log "frr: config, daemons, start"
  if [[ -f /lab/frr.conf ]]; then
    cp /lab/frr.conf /etc/frr/frr.conf
  else
    generate_frr_conf > /etc/frr/frr.conf
  fi
  chown frr:frr /etc/frr/frr.conf

  local daemon
  for daemon in ospfd bgpd vrrpd bfdd staticd; do
    sed -i "s/^${daemon}=no/${daemon}=yes/" /etc/frr/daemons
  done
  if pgrep -x watchfrr >/dev/null; then
    /usr/lib/frr/frrinit.sh restart
  else
    /usr/lib/frr/frrinit.sh start
  fi
}

setup_lldp() {
  log "lldp: starting lldpd on front-panel ports"
  pgrep -x lldpd >/dev/null || lldpd -I 'swp*'
}

install_packages
setup_management
setup_ports
setup_bridge
setup_l3
setup_frr
setup_lldp
log "done"