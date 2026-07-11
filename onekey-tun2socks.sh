#!/bin/bash
set -Eeuo pipefail

# ==============================================================================
# Constants
# ==============================================================================
VERSION="1.2.1"
SCRIPT_URL="https://raw.githubusercontent.com/BakaNoble/onekey-tun2socks/main/onekey-tun2socks.sh"
TUN2SOCKS_DOWNLOAD_URL="https://github.com/heiher/hev-socks5-tunnel/releases/latest/download/hev-socks5-tunnel-linux-x86_64"

ALICE_ADDRESS="2a14:67c0:116::1"
ALICE_USERNAME="alice"
ALICE_PASSWORD="alicefofo123..OVO"
ALICE_PORTS=(10001 10002 10003 10004 10005 10006 10007 10008)

SERVICE_FILE="/etc/systemd/system/tun2socks.service"
HEALTHCHECK_SERVICE_FILE="/etc/systemd/system/tun2socks-healthcheck.service"
HEALTHCHECK_TIMER_FILE="/etc/systemd/system/tun2socks-healthcheck.timer"
CONFIG_DIR="/etc/tun2socks"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
HEALTHCHECK_ENV_FILE="$CONFIG_DIR/healthcheck.env"
BINARY_PATH="/usr/local/bin/tun2socks"
HEALTHCHECK_SCRIPT="/usr/local/bin/tun2socks-healthcheck"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

ACTION=""
ACTIVE_SOCKS_PORT=""

# ==============================================================================
# Output helpers
# ==============================================================================
info() { echo -e "${BLUE}[信息]${NC} $1"; }
success() { echo -e "${GREEN}[成功]${NC} $1"; }
warning() { echo -e "${YELLOW}[警告]${NC} $1"; }
error() { echo -e "${RED}[错误]${NC} $1"; }
step() { echo -e "${PURPLE}[步骤]${NC} $1"; }

require_root() {
    if [ "$EUID" -ne 0 ]; then
        error "请使用 root 权限运行此脚本，例如: sudo $0"
        exit 1
    fi
}

show_usage() {
    echo -e "${CYAN}使用方法:${NC} $0 [选项]"
    echo -e "${CYAN}选项:${NC}"
    echo -e "  ${GREEN}-i, --install${NC}    安装 Alice tun2socks（兼容参数: alice）"
    echo -e "  ${GREEN}-r, --remove${NC}     卸载 tun2socks 及健康检查"
    echo -e "  ${GREEN}-s, --switch${NC}     手动切换 Alice Socks5 出口"
    echo -e "  ${GREEN}-u, --update${NC}     检查并更新脚本"
    echo -e "  ${GREEN}-h, --help${NC}       显示帮助"
    echo
    echo -e "${CYAN}示例:${NC}"
    echo "  sudo $0 -i"
    echo "  sudo $0 -i alice"
    echo "  sudo $0 -s"
    echo "  sudo $0 -r"
}

# ==============================================================================
# Alice selection and routing
# ==============================================================================
select_alice_port() {
    echo >&2
    info "请选择 Alice Socks5 出口端口:" >&2

    local index
    for index in "${!ALICE_PORTS[@]}"; do
        printf "  %s) ${GREEN}台湾家宽 #%s (端口: %s)${NC}\n" \
            "$((index + 1))" "$((index + 1))" "${ALICE_PORTS[$index]}" >&2
    done

    local choice
    while true; do
        read -r -p "请输入选项 (1-${#ALICE_PORTS[@]}，默认为1): " choice
        choice=${choice:-1}

        if [[ "$choice" =~ ^[0-9]+$ ]] &&
            [ "$choice" -ge 1 ] &&
            [ "$choice" -le "${#ALICE_PORTS[@]}" ]; then
            echo "${ALICE_PORTS[$((choice - 1))]}"
            return 0
        fi

        error "无效选择，请输入 1 到 ${#ALICE_PORTS[@]}。" >&2
    done
}

delete_rule_until_absent() {
    while "$@" >/dev/null 2>&1; do :; done
}

cleanup_ip_rules() {
    step "清理本项目的策略路由..."

    delete_rule_until_absent ip rule del fwmark 438 lookup main pref 10
    delete_rule_until_absent ip -6 rule del fwmark 438 lookup main pref 10
    delete_rule_until_absent ip route del default dev tun0 table 20
    delete_rule_until_absent ip rule del lookup 20 pref 20

    local cidr
    for cidr in 127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
        delete_rule_until_absent ip rule del to "$cidr" lookup main pref 16
    done

    local main_ip main_ip6
    main_ip=$(ip -4 route get 1.1.1.1 2>/dev/null |
        awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' || true)
    main_ip6=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null |
        awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' || true)

    if [ -n "$main_ip" ]; then
        delete_rule_until_absent ip rule del from "$main_ip" lookup main pref 15
    fi
    if [ -n "$main_ip6" ]; then
        delete_rule_until_absent ip -6 rule del from "$main_ip6" lookup main pref 15
    fi
}

write_tun2socks_config() {
    local port=$1

    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<EOF
tunnel:
  name: tun0
  mtu: 8500
  multi-queue: true
  ipv4: 198.18.0.1

socks5:
  port: $port
  address: '$ALICE_ADDRESS'
  udp: 'udp'
  username: '$ALICE_USERNAME'
  password: '$ALICE_PASSWORD'
  mark: 438
EOF
    chmod 600 "$CONFIG_FILE"
}

write_tun2socks_service() {
    local main_ip main_ip6
    local add_main_ip="" del_main_ip=""
    local add_main_ip6="" del_main_ip6=""

    main_ip=$(ip -4 route get 1.1.1.1 2>/dev/null |
        awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' || true)
    main_ip6=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null |
        awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' || true)

    if [ -n "$main_ip" ]; then
        info "检测到 IPv4 地址 $main_ip，将保留其入站连接回程。"
        add_main_ip="ExecStartPost=-/sbin/ip rule add from $main_ip lookup main pref 15"
        del_main_ip="ExecStop=-/sbin/ip rule del from $main_ip lookup main pref 15"
    fi

    if [ -n "$main_ip6" ]; then
        info "检测到 IPv6 地址 $main_ip6，将保留其入站连接回程。"
        add_main_ip6="ExecStartPost=-/sbin/ip -6 rule add from $main_ip6 lookup main pref 15"
        del_main_ip6="ExecStop=-/sbin/ip -6 rule del from $main_ip6 lookup main pref 15"
    fi

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Alice Tun2Socks Tunnel Service
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=$BINARY_PATH $CONFIG_FILE
ExecStartPost=/bin/sleep 1
ExecStartPost=-/sbin/ip rule add fwmark 438 lookup main pref 10
ExecStartPost=-/sbin/ip -6 rule add fwmark 438 lookup main pref 10
ExecStartPost=-/sbin/ip route add default dev tun0 table 20
ExecStartPost=-/sbin/ip rule add lookup 20 pref 20
$add_main_ip
$add_main_ip6
ExecStartPost=-/sbin/ip rule add to 127.0.0.0/8 lookup main pref 16
ExecStartPost=-/sbin/ip rule add to 10.0.0.0/8 lookup main pref 16
ExecStartPost=-/sbin/ip rule add to 172.16.0.0/12 lookup main pref 16
ExecStartPost=-/sbin/ip rule add to 192.168.0.0/16 lookup main pref 16

ExecStop=-/sbin/ip rule del fwmark 438 lookup main pref 10
ExecStop=-/sbin/ip -6 rule del fwmark 438 lookup main pref 10
ExecStop=-/sbin/ip route del default dev tun0 table 20
ExecStop=-/sbin/ip rule del lookup 20 pref 20
$del_main_ip
$del_main_ip6
ExecStop=-/sbin/ip rule del to 127.0.0.0/8 lookup main pref 16
ExecStop=-/sbin/ip rule del to 10.0.0.0/8 lookup main pref 16
ExecStop=-/sbin/ip rule del to 172.16.0.0/12 lookup main pref 16
ExecStop=-/sbin/ip rule del to 192.168.0.0/16 lookup main pref 16

Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

# ==============================================================================
# Health check
# ==============================================================================
write_healthcheck_files() {
    cat > "$HEALTHCHECK_ENV_FILE" <<EOF
SOCKS_ADDRESS='$ALICE_ADDRESS'
SOCKS_USERNAME='$ALICE_USERNAME'
SOCKS_PASSWORD='$ALICE_PASSWORD'
SOCKS_PORTS='${ALICE_PORTS[*]}'
HEALTHCHECK_URL='https://www.gstatic.com/generate_204'
CONNECT_TIMEOUT=5
MAX_TIME=12
CHECK_RETRIES=2
EOF
    chmod 600 "$HEALTHCHECK_ENV_FILE"

    cat > "$HEALTHCHECK_SCRIPT" <<'HEALTHCHECK'
#!/bin/bash
set -uo pipefail

CONFIG_FILE="/etc/tun2socks/config.yaml"
ENV_FILE="/etc/tun2socks/healthcheck.env"
LOCK_FILE="/run/tun2socks-healthcheck.lock"

log() {
    echo "[tun2socks-healthcheck] $*"
    logger -t tun2socks-healthcheck -- "$*" 2>/dev/null || true
}

if [ ! -r "$CONFIG_FILE" ] || [ ! -r "$ENV_FILE" ]; then
    log "配置文件不存在，跳过健康检查。"
    exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log "已有健康检查正在运行，本次跳过。"
    exit 0
fi

current_port=$(
    awk '
        /^socks5:/ { in_socks=1; next }
        in_socks && /^[^[:space:]]/ { in_socks=0 }
        in_socks && $1 == "port:" { print $2; exit }
    ' "$CONFIG_FILE"
)

if ! [[ "$current_port" =~ ^[0-9]+$ ]]; then
    log "无法读取当前 Socks5 端口。"
    exit 1
fi

check_port() {
    local port=$1
    local attempt

    for ((attempt = 1; attempt <= CHECK_RETRIES; attempt++)); do
        if curl --silent --show-error --fail --output /dev/null \
            --connect-timeout "$CONNECT_TIMEOUT" \
            --max-time "$MAX_TIME" \
            --socks5-hostname "[$SOCKS_ADDRESS]:$port" \
            --proxy-user "$SOCKS_USERNAME:$SOCKS_PASSWORD" \
            "$HEALTHCHECK_URL"; then
            return 0
        fi
    done

    return 1
}

if check_port "$current_port"; then
    log "当前端口 $current_port 健康。"
    exit 0
fi

log "当前端口 $current_port 不可用，开始寻找健康节点。"

for candidate in $SOCKS_PORTS; do
    [ "$candidate" = "$current_port" ] && continue

    if ! check_port "$candidate"; then
        log "候选端口 $candidate 不可用。"
        continue
    fi

    backup=$(mktemp /tmp/tun2socks-config.XXXXXX)
    cp "$CONFIG_FILE" "$backup"

    sed -i -E "/^socks5:/,/^[^[:space:]]/ s/^  port: [0-9]+/  port: $candidate/" "$CONFIG_FILE"

    if systemctl restart tun2socks.service; then
        rm -f "$backup"
        log "已从端口 $current_port 自动切换到健康端口 $candidate。"
        exit 0
    fi

    log "切换到端口 $candidate 后服务启动失败，恢复端口 $current_port。"
    cp "$backup" "$CONFIG_FILE"
    rm -f "$backup"
    systemctl restart tun2socks.service || true
    exit 1
done

log "端口 10001-10008 当前均不可用，保留原配置等待下次检查。"
exit 1
HEALTHCHECK
    chmod 750 "$HEALTHCHECK_SCRIPT"

    cat > "$HEALTHCHECK_SERVICE_FILE" <<EOF
[Unit]
Description=Alice Socks5 Health Check
Wants=network-online.target
After=network-online.target tun2socks.service

[Service]
Type=oneshot
ExecStart=$HEALTHCHECK_SCRIPT
EOF

    cat > "$HEALTHCHECK_TIMER_FILE" <<EOF
[Unit]
Description=Run Alice Socks5 health check every minute

[Timer]
OnBootSec=90s
OnUnitActiveSec=60s
RandomizedDelaySec=10s
Persistent=true
Unit=tun2socks-healthcheck.service

[Install]
WantedBy=timers.target
EOF
}

# ==============================================================================
# Installation and removal
# ==============================================================================
download_tun2socks() {
    local preferred_port=$1
    local temp_file candidate magic
    local downloaded=false
    local candidates=("$preferred_port")

    temp_file=$(mktemp /tmp/tun2socks-download.XXXXXX)
    trap 'rm -f "$temp_file"' INT TERM ERR

    for candidate in "${ALICE_PORTS[@]}"; do
        if [ "$candidate" != "$preferred_port" ]; then
            candidates+=("$candidate")
        fi
    done

    step "尝试直连 GitHub 下载 tun2socks..."
    if curl -fL --connect-timeout 5 --max-time 30 --retry 1 \
        -o "$temp_file" "$TUN2SOCKS_DOWNLOAD_URL"; then
        downloaded=true
        success "已通过当前网络直连下载 tun2socks。"
    else
        warning "直连 GitHub 下载失败，改用 Alice Socks5 兜底。"
        rm -f "$temp_file"

        for candidate in "${candidates[@]}"; do
            step "尝试通过 Alice 端口 $candidate 下载..."
            if curl -fL --connect-timeout 5 --max-time 30 \
                --socks5-hostname "[$ALICE_ADDRESS]:$candidate" \
                --proxy-user "$ALICE_USERNAME:$ALICE_PASSWORD" \
                -o "$temp_file" "$TUN2SOCKS_DOWNLOAD_URL"; then
                ACTIVE_SOCKS_PORT="$candidate"
                downloaded=true
                success "已通过 Alice 端口 $candidate 下载 tun2socks。"
                break
            fi
            rm -f "$temp_file"
        done
    fi

    if [ "$downloaded" != true ]; then
        trap - INT TERM ERR
        rm -f "$temp_file"
        error "直连和全部 Alice Socks5 端口均无法下载 tun2socks。"
        return 1
    fi

    magic=$(od -An -tx1 -N4 "$temp_file" | tr -d ' \n')
    if [ "$magic" != "7f454c46" ]; then
        trap - INT TERM ERR
        rm -f "$temp_file"
        error "下载结果不是有效的 ELF 程序，安装已中止。"
        return 1
    fi

    mkdir -p "$(dirname "$BINARY_PATH")"
    install -m 755 "$temp_file" "$BINARY_PATH"

    trap - INT TERM ERR
    rm -f "$temp_file"
}

install_tun2socks() {
    local socks_port
    socks_port=$(select_alice_port)
    ACTIVE_SOCKS_PORT="$socks_port"

    download_tun2socks "$socks_port"

    step "停止旧服务并清理旧规则..."
    systemctl stop tun2socks-healthcheck.timer 2>/dev/null || true
    systemctl stop tun2socks.service 2>/dev/null || true
    cleanup_ip_rules

    step "生成 Alice 配置和 systemd 服务..."
    write_tun2socks_config "$ACTIVE_SOCKS_PORT"
    write_tun2socks_service
    write_healthcheck_files

    systemctl daemon-reload
    systemctl enable --now tun2socks.service
    systemctl enable --now tun2socks-healthcheck.timer

    success "安装完成，当前 Alice 端口为 $ACTIVE_SOCKS_PORT。"
    info "健康检查每分钟运行一次，当前端口异常时会自动切换。"
    info "立即检查：systemctl start tun2socks-healthcheck.service"
    info "查看日志：journalctl -u tun2socks-healthcheck.service"
}

uninstall_tun2socks() {
    step "停止并禁用服务..."
    systemctl disable --now tun2socks-healthcheck.timer 2>/dev/null || true
    systemctl stop tun2socks-healthcheck.service 2>/dev/null || true
    systemctl disable --now tun2socks.service 2>/dev/null || true

    cleanup_ip_rules

    rm -f "$SERVICE_FILE"
    rm -f "$HEALTHCHECK_SERVICE_FILE"
    rm -f "$HEALTHCHECK_TIMER_FILE"
    rm -f "$BINARY_PATH"
    rm -f "$HEALTHCHECK_SCRIPT"
    rm -rf "$CONFIG_DIR"

    systemctl daemon-reload
    systemctl reset-failed tun2socks.service tun2socks-healthcheck.service 2>/dev/null || true

    success "tun2socks 及健康检查已卸载。"
}

switch_alice_port() {
    if [ ! -f "$CONFIG_FILE" ]; then
        error "未找到 $CONFIG_FILE，请先安装。"
        exit 1
    fi

    exec 9>/run/tun2socks-healthcheck.lock
    if ! flock -w 30 9; then
        error "健康检查正在切换节点，请稍后重试。"
        exit 1
    fi

    local current_port new_port backup
    current_port=$(awk '/^socks5:/{f=1;next} f && $1=="port:"{print $2;exit}' "$CONFIG_FILE")
    info "当前 Alice 端口: $current_port"

    new_port=$(select_alice_port)
    if [ "$new_port" = "$current_port" ]; then
        info "端口未变化。"
        return 0
    fi

    backup=$(mktemp /tmp/tun2socks-config.XXXXXX)
    cp "$CONFIG_FILE" "$backup"
    sed -i -E "/^socks5:/,/^[^[:space:]]/ s/^  port: [0-9]+/  port: $new_port/" "$CONFIG_FILE"

    if systemctl restart tun2socks.service; then
        rm -f "$backup"
        success "Alice 端口已切换为 $new_port。"
        return 0
    fi

    cp "$backup" "$CONFIG_FILE"
    rm -f "$backup"
    systemctl restart tun2socks.service || true
    error "新端口启动失败，已恢复端口 $current_port。"
    exit 1
}

# ==============================================================================
# Self-update and CLI
# ==============================================================================
check_for_updates() {
    step "检查脚本更新..."

    local remote_content remote_version
    remote_content=$(curl -fsSL "$SCRIPT_URL")
    remote_version=$(grep -m 1 '^VERSION=' <<< "$remote_content" |
        cut -d '"' -f 2 |
        tr -d '\r')

    if [ -z "$remote_version" ]; then
        error "无法从远程脚本读取版本号。"
        return 1
    fi

    info "当前版本: $VERSION"
    info "远程版本: $remote_version"

    if [ "$remote_version" = "$VERSION" ] ||
        [ "$(printf '%s\n' "$remote_version" "$VERSION" | sort -V | head -n 1)" = "$remote_version" ]; then
        success "当前脚本无需更新。"
        return 0
    fi

    read -r -p "发现新版本 $remote_version，是否更新? (y/N): " response
    if [[ ! "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        info "更新已取消。"
        return 0
    fi

    local temp_file script_path
    temp_file=$(mktemp /tmp/onekey-tun2socks.XXXXXX)
    script_path=$(realpath "$0")

    curl -fL -o "$temp_file" "$SCRIPT_URL"
    head -n 1 "$temp_file" | grep -q 'bin/bash'
    chmod 755 "$temp_file"
    mv "$temp_file" "$script_path"

    success "脚本已更新到 $remote_version，请重新运行。"
}

parse_options() {
    local option_count=0

    if [ "$#" -eq 0 ]; then
        error "请指定操作，使用 -h 查看帮助。"
        exit 1
    fi

    while [ "$#" -gt 0 ]; do
        case "$1" in
            -i|--install)
                option_count=$((option_count + 1))
                ACTION="install"

                if [ -n "${2:-}" ] && [[ "${2:-}" != -* ]]; then
                    if [ "$2" != "alice" ]; then
                        error "-i 仅支持 alice，当前参数为: $2"
                        exit 1
                    fi
                    shift 2
                else
                    shift
                fi
                ;;
            -r|--remove)
                option_count=$((option_count + 1))
                ACTION="uninstall"
                shift
                ;;
            -s|--switch)
                option_count=$((option_count + 1))
                ACTION="switch"
                shift
                ;;
            -u|--update)
                option_count=$((option_count + 1))
                ACTION="update"
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                error "未知选项: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    if [ "$option_count" -ne 1 ]; then
        error "请仅指定一个操作。"
        exit 1
    fi
}

main() {
    require_root
    parse_options "$@"

    case "$ACTION" in
        install) install_tun2socks ;;
        uninstall) uninstall_tun2socks ;;
        switch) switch_alice_port ;;
        update) check_for_updates ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
