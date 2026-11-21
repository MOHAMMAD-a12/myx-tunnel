#!/usr/bin/env bash
# ============================================================
#   ███╗   ███╗██╗   ██╗██╗  ██╗   ████████╗██╗   ██╗███╗   ██╗
#   ████╗ ████║╚██╗ ██╔╝╚██╗╚██╗  ╚══██╔══╝╚██╗ ██╔╝████╗ ██║
#   ██╔████╔██║ ╚████╔╝  ╚██╗╚██╗    ██║    ╚████╔╝ ██╔██╗██║
#   ██║╚██╔╝██║  ╚██╔╝   ██╔╝██╔╝    ██║     ╚██╔╝  ██║╚████║
#   ██║ ╚═╝ ██║   ██║   ██╔╝██╔╝     ██║      ██║   ██║ ╚███║
#   ╚═╝     ╚═╝   ╚═╝   ╚═╝╚═╝      ╚═╝      ╚═╝   ╚═╝  ╚═══╝
#
#   MyX Tunnel - High Speed Reverse Tunnel (Iran <-> Kharej)
#   Protocols: FRP | Realm | Gost | IPTables | Socat
#   Compatible: Ubuntu 22.04 / 24.04 (Debian 11/12)
# ============================================================

MYX_VERSION="1.0.0"
MYX_DIR="/etc/myx"
MYX_TUN_DIR="$MYX_DIR/tunnels"
MYX_BIN="/usr/local/bin"
MYX_SYS="/etc/systemd/system"

# ---------- Colors ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; PURPLE='\033[0;35m'; CYAN='\033[0;36m'
WHITE='\033[1;37m'; GRAY='\033[0;90m'; NC='\033[0m'

# ---------- Helpers ----------
msg_info()  { echo -e "${CYAN}[MyX]${NC} $1"; }
msg_ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
msg_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
msg_err()   { echo -e "${RED}[FAIL]${NC} $1"; }

banner() {
echo -e "${PURPLE}"
cat << 'EOF'
  ███╗   ███╗██╗   ██╗██╗  ██╗   ████████╗██╗   ██╗███╗   ██╗███╗   ██╗███████╗██╗
  ████╗ ████║╚██╗ ██╔╝╚██╗╚██╗  ╚══██╔══╝╚██╗ ██╔╝████╗ ██║████╗ ██║██╔════╝██║
  ██╔████╔██║ ╚████╔╝  ╚██╗╚██╗    ██║    ╚████╔╝ ██╔██╗██║██╔██╗██║█████╗  ██║
  ██║╚██╔╝██║  ╚██╔╝   ██╔╝██╔╝    ██║     ╚██╔╝  ██║╚████║██║╚████║██╔══╝  ██║
  ██║ ╚═╝ ██║   ██║   ██╔╝██╔╝     ██║      ██║   ██║ ╚███║██║ ╚███║███████╗███████╗
  ╚═╝     ╚═╝   ╚═╝   ╚═╝╚═╝      ╚═╝      ╚═╝   ╚═╝  ╚═══╝╚═╝  ╚═══╝╚══════╝╚══════╝
EOF
echo -e "${NC} ${WHITE}High Speed Reverse Tunnel${NC} ${GRAY}| v${MYX_VERSION} | Iran <-> Kharej${NC}"
echo -e "${GRAY}--------------------------------------------------------------${NC}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        msg_err "Please run as root:  sudo bash myx-tunnel.sh"
        exit 1
    fi
}

rand_token() { tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24; }
rand_pass()  { tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 12; }

valid_ip() {
    [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || [[ $1 =~ ^[0-9a-fA-F:]+$ ]] && return 0
    return 1
}

valid_port() { [[ $1 =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

my_public_ip() {
    local ip
    ip=$(timeout 5 curl -s4 ip.sb 2>/dev/null) || ip=$(hostname -I | awk '{print $1}')
    echo "$ip"
}

is_installed() { [ -f "$MYX_DIR/.installed" ]; }

# ---------- System ----------
install_deps() {
    msg_info "Checking dependencies..."
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq curl wget tar unzip socat net-tools iptables-persistent jq speedtest-cli >/dev/null 2>&1
    fi
    for c in curl wget tar socat iptables; do
        command -v $c >/dev/null 2>&1 || msg_warn "$c not found!"
    done
    msg_ok "Dependencies ready"
}

detect_arch() {
    case "$(uname -m)" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        *) echo "amd64" ;;
    esac
}

enable_ip_forward() {
    if [ ! "$(sysctl -n net.ipv4.ip_forward)" = "1" ]; then
        echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-myx.conf
        sysctl -p /etc/sysctl.d/99-myx.conf >/dev/null 2>&1
        msg_ok "IP Forward enabled"
    fi
}

# ============================================================
#                    BINARY INSTALLERS
# ============================================================
install_frp() {
    if [ -x "$MYX_BIN/frps" ] && [ -x "$MYX_BIN/frpc" ]; then return 0; fi
    local ver="0.61.1" arch; arch=$(detect_arch)
    msg_info "Downloading FRP v${ver}..."
    local url="https://github.com/fatedier/frp/releases/download/v${ver}/frp_${ver}_linux_${arch}.tar.gz"
    local tmp="/tmp/myx-frp.tgz"
    if ! curl -sL --connect-timeout 15 "$url" -o "$tmp"; then
        msg_err "Download failed! Check server internet access to GitHub."
        return 1
    fi
    tar -xzf "$tmp" -C /tmp
    cp "/tmp/frp_${ver}_linux_${arch}/frps" "$MYX_BIN/frps"
    cp "/tmp/frp_${ver}_linux_${arch}/frpc" "$MYX_BIN/frpc"
    chmod +x "$MYX_BIN/frps" "$MYX_BIN/frpc"
    rm -rf /tmp/frp_${ver}_linux_${arch} "$tmp"
    msg_ok "FRP installed"
}

install_realm() {
    [ -x "$MYX_BIN/realm" ] && return 0
    local ver="2.7.0" arch; arch=$(detect_arch)
    local f="x86_64-unknown-linux-musl"; [ "$arch" = "arm64" ] && f="aarch64-unknown-linux-musl"
    msg_info "Downloading Realm v${ver}..."
    local url="https://github.com/zhboner/realm/releases/download/v${ver}/realm-${f}.tar.gz"
    local tmp="/tmp/myx-realm.tgz"
    if ! curl -sL --connect-timeout 15 "$url" -o "$tmp"; then
        msg_err "Download failed!"; return 1
    fi
    tar -xzf "$tmp" -C /tmp
    mv /tmp/realm "$MYX_BIN/realm"; chmod +x "$MYX_BIN/realm"
    rm -f "$tmp"
    msg_ok "Realm installed"
}

install_gost() {
    [ -x "$MYX_BIN/gost" ] && return 0
    local ver="2.12.0" arch; arch=$(detect_arch)
    msg_info "Downloading Gost v${ver}..."
    local url="https://github.com/go-gost/gost/releases/download/v${ver}/gost-linux-${arch}-${ver}.gz"
    local tmp="/tmp/myx-gost.gz"
    if ! curl -sL --connect-timeout 15 "$url" -o "$tmp"; then
        msg_err "Download failed!"; return 1
    fi
    gunzip -f "$tmp"
    mv /tmp/myx-gost "$MYX_BIN/gost"; chmod +x "$MYX_BIN/gost"
    msg_ok "Gost installed"
}

# ============================================================
#                    TUNNEL REGISTRY
# ============================================================
save_tunnel() { # $1 = name, rest = KEY=VALUE lines
    local name="$1"; shift
    mkdir -p "$MYX_TUN_DIR"
    : > "$MYX_TUN_DIR/${name}.env"
    for kv in "$@"; do echo "$kv" >> "$MYX_TUN_DIR/${name}.env"; done
}

load_tunnel() { # $1 = name -> prints vars into environment
    [ -f "$MYX_TUN_DIR/$1.env" ] || return 1
    # shellcheck disable=SC1090
    . "$MYX_TUN_DIR/$1.env"
}

tunnel_list() { ls "$MYX_TUN_DIR" 2>/dev/null | sed 's/\.env$//'; }

create_service() { # $1 = unit name, $2 = description, $3 = ExecStart, $4 = extra (ExecStop...)
    cat > "$MYX_SYS/$1" << EOF
[Unit]
Description=$2
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
User=root
ExecStart=$3
$4
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# ============================================================
#                    PROTOCOL SETUPS
# ============================================================

# ---------- FRP ----------
setup_frp_kharej() {
    install_frp || return 1
    local token port dash user pass
    token=$(rand_token)
    read -rp "FRP bind port [default: 7000]: " port
    port=${port:-7000}
    dash=7500; user="myx"; pass=$(rand_pass)

    mkdir -p "$MYX_DIR/frp"
    cat > "$MYX_DIR/frp/frps.toml" << EOF
bindAddr = "0.0.0.0"
bindPort = ${port}
auth.token = "${token}"

webServer.addr = "0.0.0.0"
webServer.port = ${dash}
webServer.user = "${user}"
webServer.password = "${pass}"

transport.maxPoolCount = 20
EOF

    create_service "myx-frps.service" "MyX Tunnel - FRP Server (Kharej)" \
        "$MYX_BIN/frps -c $MYX_DIR/frp/frps.toml" ""
    systemctl enable --now myx-frps.service >/dev/null 2>&1

    save_tunnel "frp-server" "proto=frp" "role=kharej" "bind=$port" "dash=$dash" "token=$token"
    my_ip=$(my_public_ip)
    echo ""
    echo -e "${GREEN}================= FRP KHAREJ INSTALLED =================${NC}"
    echo -e " ${WHITE}Kharej IP   :${NC} $my_ip"
    echo -e " ${WHITE}Bind Port   :${NC} $port"
    echo -e " ${WHITE}Token       :${NC} ${YELLOW}$token${NC}"
    echo -e " ${WHITE}Dashboard   :${NC} http://$my_ip:$dash  ( $user / $pass )"
    echo -e "${GRAY}>>> Now run MyX Tunnel on IRAN server and use this Token <<<${NC}"
    echo -e "${GREEN}=========================================================${NC}"
    echo -e "$token" > "$MYX_DIR/.frp-token"
}

setup_frp_iran() {
    install_frp || return 1
    local kip port token lname lport rport
    read -rp "Kharej (Foreign) server IP: " kip
    valid_ip "$kip" || { msg_err "Invalid IP"; return 1; }
    read -rp "FRP bind port on kharej [default: 7000]: " port
    port=${port:-7000}
    read -rp "FRP token (from kharej server): " token
    [ -z "$token" ] && { msg_err "Token required!"; return 1; }
    read -rp "Local service port on IRAN (e.g. 443): " lport
    valid_port "$lport" || { msg_err "Invalid port"; return 1; }
    read -rp "Remote port on KHAREJ users connect to (e.g. 8443): " rport
    valid_port "$rport" || { msg_err "Invalid port"; return 1; }
    read -rp "Protocol type (tcp/udp) [default: tcp]: " ptype
    ptype=${ptype:-tcp}
    lname="myx-frp-${rport}"

    mkdir -p "$MYX_DIR/frp"
    if [ -f "$MYX_DIR/frp/frpc.toml" ]; then
        cat >> "$MYX_DIR/frp/frpc.toml" << EOF

[[proxies]]
name = "${lname}"
type = "${ptype}"
localIP = "127.0.0.1"
localPort = ${lport}
remotePort = ${rport}
EOF
    else
        cat > "$MYX_DIR/frp/frpc.toml" << EOF
serverAddr = "${kip}"
serverPort = ${port}
auth.token = "${token}"

[[proxies]]
name = "${lname}"
type = "${ptype}"
localIP = "127.0.0.1"
localPort = ${lport}
remotePort = ${rport}
EOF
    fi

    create_service "myx-frpc.service" "MyX Tunnel - FRP Client (Iran)" \
        "$MYX_BIN/frpc -c $MYX_DIR/frp/frpc.toml" ""
    systemctl enable --now myx-frpc.service >/dev/null 2>&1

    save_tunnel "$lname" "proto=frp" "role=iran" "kharej_ip=$kip" "bind=$port" \
        "token=$token" "local_port=$lport" "remote_port=$rport" "ptype=$ptype"
    msg_ok "FRP tunnel '$lname' created"
    echo -e " Users connect to: ${GREEN}${kip}:${rport}${NC}  -->  IRAN:${lport}"
}

# ---------- Realm ----------
setup_realm_kharej() {
    install_realm || return 1
    enable_ip_forward
    local lip tip tport
    read -rp "Listen port on KHAREJ (users connect, e.g. 8443): " lip
    valid_port "$lip" || { msg_err "Invalid port"; return 1; }
    read -rp "IRAN server IP: " tip
    valid_ip "$tip" || { msg_err "Invalid IP"; return 1; }
    read -rp "Target port on IRAN (e.g. 443): " tport
    valid_port "$tport" || { msg_err "Invalid port"; return 1; }

    mkdir -p "$MYX_DIR/realm"
    if [ -f "$MYX_DIR/realm/config.toml" ]; then
        cat >> "$MYX_DIR/realm/config.toml" << EOF

[[endpoints]]
listen = "0.0.0.0:${lip}"
remote = "${tip}:${tport}"
EOF
    else
        cat > "$MYX_DIR/realm/config.toml" << EOF
[network]
no_tcp = false
use_udp = true

[[endpoints]]
listen = "0.0.0.0:${lip}"
remote = "${tip}:${tport}"
EOF
    fi

    local unit="myx-realm.service"
    create_service "$unit" "MyX Tunnel - Realm (Kharej)" \
        "$MYX_BIN/realm -c $MYX_DIR/realm/config.toml" ""
    systemctl enable --now "$unit" >/dev/null 2>&1

    save_tunnel "realm-${lip}" "proto=realm" "role=kharej" "listen=$lip" "target_ip=$tip" "target_port=$tport"
    msg_ok "Realm tunnel created"
    echo -e " Users connect to: ${GREEN}$(my_public_ip):${lip}${NC}  -->  ${tip}:${tport}"
}

# ---------- Gost (true reverse: iran dials out to kharej) ----------
setup_gost_kharej() {
    install_gost || return 1
    local port transport
    read -rp "Gost relay port on KHAREJ [default: 27000]: " port
    port=${port:-27000}
    read -rp "Transport (tls / ws / wss) [default: tls]: " transport
    transport=${transport:-tls}

    local unit="myx-gost-relay.service"
    create_service "$unit" "MyX Tunnel - Gost Relay (Kharej)" \
        "$MYX_BIN/gost -L relay+${transport}://:${port}" ""
    systemctl enable --now "$unit" >/dev/null 2>&1

    save_tunnel "gost-relay" "proto=gost" "role=kharej" "port=$port" "transport=$transport"
    my_ip=$(my_public_ip)
    echo ""
    echo -e "${GREEN}================= GOST KHAREJ INSTALLED =================${NC}"
    echo -e " ${WHITE}Kharej IP   :${NC} $my_ip"
    echo -e " ${WHITE}Relay Port  :${NC} $port"
    echo -e " ${WHITE}Transport   :${NC} $transport"
    echo -e "${GRAY}>>> Now run MyX Tunnel on IRAN server (Gost -> Iran) <<<${NC}"
    echo -e "${GREEN}=========================================================${NC}"
}

setup_gost_iran() {
    install_gost || return 1
    local kip kport lport rport transport udp
    read -rp "Kharej server IP: " kip
    valid_ip "$kip" || { msg_err "Invalid IP"; return 1; }
    read -rp "Gost relay port on kharej [default: 27000]: " kport
    kport=${kport:-27000}
    read -rp "Transport (tls / ws / wss) [default: tls]: " transport
    transport=${transport:-tls}
    read -rp "Local service port on IRAN (e.g. 443): " lport
    valid_port "$lport" || { msg_err "Invalid port"; return 1; }
    read -rp "Remote port on KHAREJ users connect to (e.g. 8443): " rport
    valid_port "$rport" || { msg_err "Invalid port"; return 1; }
    read -rp "Enable UDP too? (y/n) [default: n]: " udp
    [[ "$udp" =~ ^[Yy] ]] && udp="y" || udp="n"

    local listeners="rtcp://:${rport}/127.0.0.1:${lport}"
    [ "$udp" = "y" ] && listeners="$listeners -L rudp://:${rport}/127.0.0.1:${lport}"

    local unit="myx-gost-iran.service"
    create_service "$unit" "MyX Tunnel - Gost Client (Iran)" \
        "$MYX_BIN/gost -L $listeners -F relay+${transport}://${kip}:${kport}" ""
    systemctl enable --now "$unit" >/dev/null 2>&1

    save_tunnel "gost-${rport}" "proto=gost" "role=iran" "kharej_ip=$kip" "kharej_port=$kport" \
        "transport=$transport" "local_port=$lport" "remote_port=$rport" "udp=$udp"
    msg_ok "Gost tunnel created"
    echo -e " Users connect to: ${GREEN}${kip}:${rport}${NC}  -->  IRAN:${lport}"
}

# ---------- IPTables ----------
setup_iptables_kharej() {
    enable_ip_forward
    local lip tip tport ptype
    read -rp "Listen port on KHAREJ (users connect, e.g. 8443): " lip
    valid_port "$lip" || { msg_err "Invalid port"; return 1; }
    read -rp "IRAN server IP: " tip
    valid_ip "$tip" || { msg_err "Invalid IP"; return 1; }
    read -rp "Target port on IRAN (e.g. 443): " tport
    valid_port "$tport" || { msg_err "Invalid port"; return 1; }
    read -rp "Protocol (tcp/udp/both) [default: tcp]: " ptype
    ptype=${ptype:-tcp}

    local unit="myx-ipt-${lip}.service"
    local extra="[Service]
Type=oneshot
RemainAfterExit=yes"
    case "$ptype" in
        tcp) extra="$extra
ExecStop=/sbin/iptables -t nat -D PREROUTING -p tcp --dport ${lip} -j DNAT --to-destination ${tip}:${tport} 2>/dev/null || true
ExecStop=/sbin/iptables -t nat -D POSTROUTING -d ${tip} -p tcp --dport ${tport} -j MASQUERADE 2>/dev/null || true" ;;
        udp) extra="$extra
ExecStop=/sbin/iptables -t nat -D PREROUTING -p udp --dport ${lip} -j DNAT --to-destination ${tip}:${tport} 2>/dev/null || true
ExecStop=/sbin/iptables -t nat -D POSTROUTING -d ${tip} -p udp --dport ${tport} -j MASQUERADE 2>/dev/null || true" ;;
        both) extra="$extra
ExecStop=/sbin/iptables -t nat -D PREROUTING -p tcp --dport ${lip} -j DNAT --to-destination ${tip}:${tport} 2>/dev/null || true
ExecStop=/sbin/iptables -t nat -D PREROUTING -p udp --dport ${lip} -j DNAT --to-destination ${tip}:${tport} 2>/dev/null || true
ExecStop=/sbin/iptables -t nat -D POSTROUTING -d ${tip} -j MASQUERADE 2>/dev/null || true" ;;
    esac

    cat > "$MYX_SYS/$unit" << EOF
[Unit]
Description=MyX Tunnel - IPTables Forward ${lip} -> ${tip}:${tport}
After=network.target
Wants=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/iptables -t nat -A PREROUTING -p ${ptype} --dport ${lip} -j DNAT --to-destination ${tip}:${tport}
ExecStart=/sbin/iptables -t nat -A POSTROUTING -d ${tip} -p ${ptype} --dport ${tport} -j MASQUERADE
$( [ "$ptype" = "both" ] && echo "ExecStart=/sbin/iptables -t nat -A PREROUTING -p udp --dport ${lip} -j DNAT --to-destination ${tip}:${tport}" )
$( [ "$ptype" = "both" ] && echo "ExecStart=/sbin/iptables -t nat -A POSTROUTING -d ${tip} -p udp --dport ${tport} -j MASQUERADE" )
${extra}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "$unit" >/dev/null 2>&1

    iptables-save > /etc/iptables/rules.v4 2>/dev/null
    save_tunnel "ipt-${lip}" "proto=iptables" "role=kharej" "listen=$lip" "target_ip=$tip" "target_port=$tport" "ptype=$ptype"
    msg_ok "IPTables tunnel created"
    echo -e " Users connect to: ${GREEN}$(my_public_ip):${lip}${NC}  -->  ${tip}:${tport} (${ptype})"
}

# ---------- Socat ----------
setup_socat_kharej() {
    local lip tip tport udp
    read -rp "Listen port on KHAREJ (users connect, e.g. 8443): " lip
    valid_port "$lip" || { msg_err "Invalid port"; return 1; }
    read -rp "IRAN server IP: " tip
    valid_ip "$tip" || { msg_err "Invalid IP"; return 1; }
    read -rp "Target port on IRAN (e.g. 443): " tport
    valid_port "$tport" || { msg_err "Invalid port"; return 1; }
    read -rp "Protocol (tcp/udp) [default: tcp]: " udp
    udp=${udp:-tcp}

    local unit="myx-socat-${lip}.service" exec
    if [ "$udp" = "udp" ]; then
        exec="/usr/bin/socat -T 30 UDP4-RECVFROM:${lip},fork,reuseaddr UDP4-SENDTO:${tip}:${tport}"
    else
        exec="/usr/bin/socat TCP4-LISTEN:${lip},fork,reuseaddr TCP4:${tip}:${tport}"
    fi
    create_service "$unit" "MyX Tunnel - Socat ${lip} -> ${tip}:${tport}" "$exec" ""
    systemctl enable --now "$unit" >/dev/null 2>&1

    save_tunnel "socat-${lip}" "proto=socat" "role=kharej" "listen=$lip" "target_ip=$tip" "target_port=$tport" "ptype=$udp"
    msg_ok "Socat tunnel created"
    echo -e " Users connect to: ${GREEN}$(my_public_ip):${lip}${NC}  -->  ${tip}:${tport} (${udp})"
}

# ============================================================
#                     INSTALL WIZARD
# ============================================================
wizard() {
    clear; banner
    echo -e " ${WHITE}[ 1 ]${NC} Install on ${CYAN}IRAN${NC} server"
    echo -e " ${WHITE}[ 2 ]${NC} Install on ${YELLOW}KHAREJ${NC} (Foreign) server"
    echo -e " ${WHITE}[ 0 ]${NC} Exit"
    echo ""
    read -rp " Select role: " role
    case "$role" in
        1) local srole="iran" ;;
        2) local srole="kharej" ;;
        0) exit 0 ;;
        *) msg_err "Invalid choice"; return 1 ;;
    esac

    clear; banner
    echo -e " ${WHITE}[ 1 ]${NC} ${GREEN}FRP${NC}      - Reverse Tunnel (best for heavy filtering)"
    echo -e " ${WHITE}[ 2 ]${NC} ${GREEN}Realm${NC}    - Fast direct forward (low CPU)"
    echo -e " ${WHITE}[ 3 ]${NC} ${GREEN}Gost${NC}     - Encrypted relay tunnel (anti-DPI)"
    echo -e " ${WHITE}[ 4 ]${NC} ${GREEN}IPTables${NC} - Kernel NAT forward (fastest, no encryption)"
    echo -e " ${WHITE}[ 5 ]${NC} ${GREEN}Socat${NC}    - Simple forward"
    echo ""
    read -rp " Select protocol: " p
    case "$p" in
        1) local sproto="frp" ;;
        2) local sproto="realm" ;;
        3) local sproto="gost" ;;
        4) local sproto="iptables" ;;
        5) local sproto="socat" ;;
        *) msg_err "Invalid choice"; return 1 ;;
    esac

    # Validation combos
    if [ "$srole" = "iran" ]; then
        case "$sproto" in
            frp)  setup_frp_iran ;;
            gost) setup_gost_iran ;;
            *)    msg_err "${sproto} on IRAN server is not needed (only kharej side)."; return 1 ;;
        esac
    else
        case "$sproto" in
            frp)      setup_frp_kharej ;;
            realm)    setup_realm_kharej ;;
            gost)     setup_gost_kharej ;;
            iptables) setup_iptables_kharej ;;
            socat)    setup_socat_kharej ;;
        esac
    fi
    echo ""
    read -rp " Press Enter to continue..."
}

# ============================================================
#                     MENU ACTIONS
# ============================================================
status_tunnels() {
    clear; banner
    echo -e "${WHITE}>> System Status${NC}"
    echo -e " Server IP : ${GREEN}$(my_public_ip)${NC}"
    echo -e " BBR       : $( [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ] && echo -e "${GREEN}Enabled${NC}" || echo -e "${RED}Disabled${NC}" )"
    echo -e " IP Forward: $( [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = "1" ] && echo -e "${GREEN}Enabled${NC}" || echo -e "${RED}Disabled${NC}" )"
    echo ""
    echo -e "${WHITE}>> Tunnels${NC}"
    local any=0 name dot u
    while read -r name; do
        [ -z "$name" ] && continue
        any=1
        load_tunnel "$name"
        case "$proto" in
            frp)      [ "$role" = "kharej" ] && u="myx-frps.service" || u="myx-frpc.service" ;;
            realm)    u="myx-realm.service" ;;
            gost)     [ "$role" = "kharej" ] && u="myx-gost-relay.service" || u="myx-gost-iran.service" ;;
            iptables) u="myx-ipt-${listen}.service" ;;
            socat)    u="myx-socat-${listen}.service" ;;
        esac
        if systemctl is-active --quiet "$u" 2>/dev/null; then
            dot="${GREEN}[● RUNNING]${NC}"
        else
            dot="${RED}[○ STOPPED]${NC}"
        fi
        echo -e "  $dot ${WHITE}${name}${NC} ${GRAY}(${proto}/${role})${NC}"
    done < <(tunnel_list)
    [ "$any" = "0" ] && echo -e "  ${GRAY}No tunnels installed yet.${NC}"
    echo ""
    echo -e "${WHITE}>> Listening Ports${NC}"
    ss -tulpn 2>/dev/null | grep -E "frps|frpc|realm|gost|socat" | awk '{print "  "$1" "$5" "$6" "$7}' | head -15
    echo ""
    read -rp " Press Enter to continue..."
}

remove_tunnel_menu() {
    clear; banner
    local names; names=$(tunnel_list)
    [ -z "$names" ] && { msg_warn "No tunnels to remove."; sleep 2; return; }
    echo -e "${WHITE}>> Installed Tunnels${NC}"
    local i=1
    while read -r n; do echo -e " ${WHITE}[ $i ]${NC} $n"; i=$((i+1)); done <<< "$names"
    echo -e " ${WHITE}[ 0 ]${NC} Back"
    echo ""
    read -rp " Select tunnel to remove: " c
    [ "$c" = "0" ] && return
    local name; name=$(echo "$names" | sed -n "${c}p")
    [ -z "$name" ] && { msg_err "Invalid"; sleep 1; return; }
    load_tunnel "$name"
    local u
    case "$proto" in
        frp)      [ "$role" = "kharej" ] && u="myx-frps.service" || u="myx-frpc.service" ;;
        realm)    u="myx-realm.service" ;;
        gost)     [ "$role" = "kharej" ] && u="myx-gost-relay.service" || u="myx-gost-iran.service" ;;
        iptables) u="myx-ipt-${listen}.service" ;;
        socat)    u="myx-socat-${listen}.service" ;;
    esac
    systemctl stop "$u" 2>/dev/null; systemctl disable "$u" 2>/dev/null
    rm -f "$MYX_SYS/$u"
    systemctl daemon-reload
    rm -f "$MYX_TUN_DIR/${name}.env"
    msg_ok "Tunnel '$name' removed"
    sleep 1
}

control_menu() {
    clear; banner
    echo -e " ${WHITE}[ 1 ]${NC} Restart all tunnels"
    echo -e " ${WHITE}[ 2 ]${NC} Stop all tunnels"
    echo -e " ${WHITE}[ 3 ]${NC} Start all tunnels"
    echo -e " ${WHITE}[ 0 ]${NC} Back"
    echo ""
    read -rp " Select: " c
    local units
    units=$(systemctl list-units --type=service --all 2>/dev/null | grep -oP 'myx-[\w.-]+\.service' | sort -u)
    case "$c" in
        1) for u in $units; do systemctl restart "$u"; done; msg_ok "All tunnels restarted" ;;
        2) for u in $units; do systemctl stop "$u"; done; msg_ok "All tunnels stopped" ;;
        3) for u in $units; do systemctl start "$u"; done; msg_ok "All tunnels started" ;;
        0) return ;;
    esac
    sleep 1
}

optimize_speed() {
    clear; banner
    msg_info "Applying High-Speed network optimization..."
    cat > /etc/sysctl.d/99-myx.conf << 'EOF'
# ===== MyX Tunnel - Speed Optimization =====
net.ipv4.ip_forward = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 16384 33554432
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_slow_start_after_idle = 0
EOF
    sysctl -p /etc/sysctl.d/99-myx.conf >/dev/null 2>&1
    local bbr; bbr=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [ "$bbr" = "bbr" ]; then
        msg_ok "BBR + FQ enabled - Maximum speed mode active!"
    else
        msg_warn "BBR not supported by kernel, buffers optimized anyway."
    fi
    sleep 2
}

speedtest_run() {
    clear; banner
    msg_info "Running speed test (this takes ~30 seconds)..."
    if command -v speedtest-cli >/dev/null 2>&1; then
        speedtest-cli --simple
    else
        bash <(curl -sL https://raw.githubusercontent.com/sivel/speedtest-cli/master/speedtest.py) --simple 2>/dev/null \
            || msg_err "speedtest not available"
    fi
    echo ""
    read -rp " Press Enter to continue..."
}

anti_dpi_menu() {
    clear; banner
    echo -e "${WHITE}>> Anti-DPI / Anti-Filtering Mode${NC}"
    echo ""
    echo -e " ${WHITE}[ 1 ]${NC} Switch Gost transport to ${GREEN}WSS${NC} (WebSocket+TLS - best camouflage)"
    echo -e " ${WHITE}[ 2 ]${NC} Switch Gost transport to ${GREEN}WS${NC} (plain WebSocket)"
    echo -e " ${WHITE}[ 3 ]${NC} Switch Gost transport to ${GREEN}TLS${NC} (default, faster)"
    echo -e " ${WHITE}[ 4 ]${NC} Change listening port (port rotation)"
    echo -e " ${WHITE}[ 5 ]${NC} Apply TCP MSS clamp (helps broken MTU paths)"
    echo -e " ${WHITE}[ 0 ]${NC} Back"
    echo ""
    read -rp " Select: " c
    case "$c" in
        1|2|3)
            local t="tls"; [ "$c" = "1" ] && t="wss"; [ "$c" = "2" ] && t="ws"
            local changed=0
            for f in "$MYX_TUN_DIR"/gost-*.env; do
                [ -f "$f" ] || continue
                sed -i "s/^transport=.*/transport=$t/" "$f"
                changed=1
            done
            if [ "$changed" = "1" ]; then
                for f in "$MYX_TUN_DIR"/gost-*.env; do
                    [ -f "$f" ] || continue
                    # shellcheck disable=SC1090
                    . "$f"
                    if [ "$role" = "kharej" ]; then
                        create_service "myx-gost-relay.service" "MyX Tunnel - Gost Relay (Kharej)" \
                            "$MYX_BIN/gost -L relay+${t}://:${port}" ""
                        systemctl restart myx-gost-relay.service
                    else
                        local listeners="rtcp://:${remote_port}/127.0.0.1:${local_port}"
                        [ "$udp" = "y" ] && listeners="$listeners -L rudp://:${remote_port}/127.0.0.1:${local_port}"
                        create_service "myx-gost-iran.service" "MyX Tunnel - Gost Client (Iran)" \
                            "$MYX_BIN/gost -L $listeners -F relay+${t}://${kharej_ip}:${kharej_port}" ""
                        systemctl restart myx-gost-iran.service
                    fi
                done
                msg_ok "Transport switched to $t - restarted"
            else
                msg_warn "No Gost tunnels found."
            fi
            sleep 1 ;;
        4)
            read -rp "Enter NEW listening port: " np
            valid_port "$np" || { msg_err "Invalid port"; sleep 1; return; }
            local names; names=$(tunnel_list)
            for n in $names; do
                load_tunnel "$n"
                if [ -n "$listen" ] && [ "$listen" != "$np" ]; then
                    sed -i "s/^listen=.*/listen=$np/" "$MYX_TUN_DIR/$n.env"
                    sed -i "s/:${listen}/:${np}/g" "$MYX_SYS/myx-$proto-$listen.service" 2>/dev/null
                    mv "$MYX_SYS/myx-ipt-${listen}.service" "$MYX_SYS/myx-ipt-${np}.service" 2>/dev/null
                    mv "$MYX_SYS/myx-socat-${listen}.service" "$MYX_SYS/myx-socat-${np}.service" 2>/dev/null
                    systemctl daemon-reload
                    systemctl restart "myx-ipt-${np}.service" 2>/dev/null || systemctl restart "myx-socat-${np}.service" 2>/dev/null
                fi
            done
            msg_ok "Port rotated to $np"; sleep 1 ;;
        5)
            local wan; wan=$(ip route | grep default | awk '{print $5}' | head -1)
            iptables -t mangle -C FORWARD -o "$wan" -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
            iptables -t mangle -A FORWARD -o "$wan" -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
            msg_ok "TCP MSS clamp applied on $wan"; sleep 1 ;;
        0) return ;;
    esac
}

update_myx() {
    clear; banner
    msg_info "Updating binaries..."
    rm -f "$MYX_BIN/frps" "$MYX_BIN/frpc" "$MYX_BIN/realm" "$MYX_BIN/gost"
    install_deps
    local units; units=$(systemctl list-units --type=service --all 2>/dev/null | grep -oP 'myx-[\w.-]+\.service' | sort -u)
    for u in $units; do systemctl restart "$u" 2>/dev/null; done
    msg_ok "Update complete - services restarted"
    sleep 2
}

uninstall_myx() {
    clear; banner
    echo -e "${RED}This will REMOVE all MyX tunnels, binaries and configs!${NC}"
    read -rp "Type 'YES' to confirm: " c
    [ "$c" != "YES" ] && { msg_warn "Cancelled."; sleep 1; return; }
    local units; units=$(systemctl list-units --type=service --all 2>/dev/null | grep -oP 'myx-[\w.-]+\.service' | sort -u)
    for u in $units; do systemctl stop "$u" 2>/dev/null; systemctl disable "$u" 2>/dev/null; rm -f "$MYX_SYS/$u"; done
    systemctl daemon-reload
    rm -rf "$MYX_DIR" "$MYX_BIN/myx" "$MYX_BIN/frps" "$MYX_BIN/frpc" "$MYX_BIN/realm" "$MYX_BIN/gost"
    msg_ok "MyX Tunnel completely uninstalled"
    sleep 2
    exit 0
}

# ============================================================
#                     MAIN MENU
# ============================================================
show_menu() {
    clear; banner
    echo -e "  ${WHITE}[ 1 ]${NC} Install Tunnel (Wizard)      ${GRAY}- Iran / Kharej setup${NC}"
    echo -e "  ${WHITE}[ 2 ]${NC} Tunnels Status               ${GRAY}- list & health check${NC}"
    echo -e "  ${WHITE}[ 3 ]${NC} Remove Tunnel"
    echo -e "  ${WHITE}[ 4 ]${NC} Start / Stop / Restart"
    echo -e "  ${WHITE}[ 5 ]${NC} Speed Optimization (BBR)     ${GRAY}- maximum throughput${NC}"
    echo -e "  ${WHITE}[ 6 ]${NC} Speed Test"
    echo -e "  ${WHITE}[ 7 ]${NC} Anti-DPI Mode                ${GRAY}- ws/wss/port rotation${NC}"
    echo -e "  ${WHITE}[ 8 ]${NC} Update MyX Tunnel"
    echo -e "  ${WHITE}[ 9 ]${NC} Uninstall"
    echo -e "  ${WHITE}[ 0 ]${NC} Exit"
    echo ""
    echo -e "${GRAY}--------------------------------------------------------------${NC}"
    read -rp "  Select option: " opt
    case "$opt" in
        1) wizard ;;
        2) status_tunnels ;;
        3) remove_tunnel_menu ;;
        4) control_menu ;;
        5) optimize_speed ;;
        6) speedtest_run ;;
        7) anti_dpi_menu ;;
        8) update_myx ;;
        9) uninstall_myx ;;
        0) clear; exit 0 ;;
        *) msg_err "Invalid option"; sleep 1 ;;
    esac
}

# ============================================================
#                     INSTALL SELF
# ============================================================
install_myx_self() {
    install_deps
    mkdir -p "$MYX_DIR/tunnels"
    cp -f "$0" "$MYX_BIN/myx"
    chmod +x "$MYX_BIN/myx"
    touch "$MYX_DIR/.installed"
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-myx.conf
    sysctl -p /etc/sysctl.d/99-myx.conf >/dev/null 2>&1
}

# ============================================================
#                     ENTRY POINT
# ============================================================
main() {
    check_root
    case "${1:-}" in
        menu)  install_myx_self 2>/dev/null; while true; do show_menu; done ;;
        version) echo "MyX Tunnel v${MYX_VERSION}"; exit 0 ;;
        "") ;;
        *) echo "Usage: bash myx-tunnel.sh [menu]"; exit 1 ;;
    esac

    if is_installed; then
        while true; do show_menu; done
    else
        clear; banner
        msg_info "Welcome to MyX Tunnel - first run detected"
        install_myx_self
        msg_ok "Installed! Command 'myx' is now available anywhere."
        sleep 1
        wizard || true
        while true; do show_menu; done
    fi
}

main "$@"
