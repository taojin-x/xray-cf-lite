#!/usr/bin/env bash
set -euo pipefail

# ── 常量 ──────────────────────────────────────────────
XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG_PATH="$XRAY_CONFIG_DIR/config.json"
XRAY_BINARY="/usr/local/bin/xray"
STATE_DIR="/etc/xray-cf-lite"
STATE_PATH="$STATE_DIR/state.json"
CF_ACCOUNT_PATH="$STATE_DIR/cf_account.json"
LAST_LINKS_PATH="$(pwd)/cf_lite_last_links.txt"

CF_API="https://api.cloudflare.com/client/v4"
MANAGED_PREFIX="xray-cf-lite "
XRAY_INSTALL_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
SUB_BASE="https://yx-auto.pages.dev"

declare -A PROTO_SUFFIX=([vless]="vl" [trojan]="tr" [vmess]="vm")
declare -A PROTO_LABEL=([vless]="VLESS" [trojan]="TROJAN" [vmess]="VMESS")
declare -A PROTO_FLAG=([vless]="ev" [trojan]="et" [vmess]="evm")

# ── 工具 ──────────────────────────────────────────────
die()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
ok()      { printf '\033[32m✓\033[0m %s\n' "$*"; }
info()    { printf '\033[36m·\033[0m %s\n' "$*"; }
need_cmd(){ command -v "$1" &>/dev/null || die "缺少依赖: $1"; }

urlencode() {
    local s="$1" c
    local -i i
    for ((i=0; i<${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) printf '%s' "$c" ;;
            *) printf '%%%02X' "'$c" ;;
        esac
    done
}

gen_uuid() { cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen | tr '[:upper:]' '[:lower:]'; }

# ── init 系统检测 ─────────────────────────────────────
INIT_SYSTEM=""
detect_init() {
    if command -v systemctl &>/dev/null && systemctl --version &>/dev/null 2>&1; then
        INIT_SYSTEM="systemd"
    elif command -v rc-service &>/dev/null; then
        INIT_SYSTEM="openrc"
    else
        die "不支持的 init 系统（需要 systemd 或 OpenRC）"
    fi
}

# ── 包管理器 ──────────────────────────────────────────
install_deps() {
    local missing=()
    command -v curl  &>/dev/null || missing+=(curl)
    command -v jq    &>/dev/null || missing+=(jq)
    command -v unzip &>/dev/null || missing+=(unzip)
    [[ ${#missing[@]} -eq 0 ]] && return

    echo "安装依赖: ${missing[*]}"
    if command -v apk &>/dev/null; then
        apk add --no-cache "${missing[@]}"
    elif command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq "${missing[@]}"
    elif command -v yum &>/dev/null; then
        yum install -y "${missing[@]}"
    else
        die "无法安装依赖 ${missing[*]}，请手动安装"
    fi
}

# ── xray 服务管理 ────────────────────────────────────
XRAY_OPENRC_SCRIPT="/etc/init.d/xray"

write_openrc_script() {
    cat > "$XRAY_OPENRC_SCRIPT" << 'INITEOF'
#!/sbin/openrc-run
name="xray"
description="Xray proxy server"
command="/usr/local/bin/xray"
command_args="run -config /usr/local/etc/xray/config.json"
command_background=true
pidfile="/run/xray.pid"
output_log="/var/log/xray.log"
error_log="/var/log/xray.log"
respawn_delay=1
respawn_max=0
respawn_period=86400
supervise_daemon_args="--respawn-delay ${respawn_delay} --respawn-max ${respawn_max} --respawn-period ${respawn_period}"
supervisor=supervise-daemon
depend() { need net; after firewall; }
INITEOF
    chmod +x "$XRAY_OPENRC_SCRIPT"
}

svc_enable()    { if [[ "$INIT_SYSTEM" == "systemd" ]]; then systemctl enable xray &>/dev/null; else rc-update add xray default &>/dev/null; fi; true; }
svc_start()     { if [[ "$INIT_SYSTEM" == "systemd" ]]; then systemctl restart xray; else [[ -f "$XRAY_OPENRC_SCRIPT" ]] || write_openrc_script; rc-service xray restart; fi; }
svc_stop()      { if [[ "$INIT_SYSTEM" == "systemd" ]]; then systemctl stop xray &>/dev/null; systemctl disable xray &>/dev/null; else rc-service xray stop &>/dev/null; rc-update del xray default &>/dev/null; fi; true; }
svc_is_active() { if [[ "$INIT_SYSTEM" == "systemd" ]]; then systemctl is-active xray &>/dev/null; else rc-service xray status &>/dev/null 2>&1; fi; }

ensure_systemd_restart() {
    # 确保 systemd 下 xray 崩溃自动重启
    local drop="/etc/systemd/system/xray.service.d"
    if [[ "$INIT_SYSTEM" == "systemd" && ! -f "$drop/restart.conf" ]]; then
        mkdir -p "$drop"
        cat > "$drop/restart.conf" << 'SDEOF'
[Service]
Restart=on-failure
RestartSec=1
SDEOF
        systemctl daemon-reload
    fi
}

restart_xray() {
    [[ "$INIT_SYSTEM" == "systemd" ]] && ensure_systemd_restart
    svc_enable
    svc_start || die "xray 重启失败"
    sleep 1
    svc_is_active || die "xray 未正常启动，请查看日志"
    ok "xray 服务已启动"
}

stop_xray() { svc_stop; }

# ── 网络检测 ─────────────────────────────────────────
get_public_ip() {
    local ip
    for url in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
        ip=$(curl -sf --max-time 8 "$url" 2>/dev/null) && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$ip" && return
    done
    die "获取公网 IPv4 失败"
}

detect_nat() {
    local public_ip
    public_ip=$(get_public_ip)
    if ip addr show 2>/dev/null | grep -q "inet ${public_ip}/"; then
        echo "direct"
    else
        echo "nat"
    fi
}

get_listening_ports() {
    ss -tlnH 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]+$' | sort -un | tr '\n' ' '
}

rand_port() {
    local existing="$1" p
    while true; do
        p=$(( RANDOM % 50000 + 10000 ))
        echo "$existing" | grep -qw "$p" || { echo "$p"; return; }
    done
}

# ── CF API ────────────────────────────────────────────
cf_call() {
    local method="$1" endpoint="$2" data="${3:-}"
    local args=(-s -f -X "$method" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json")
    [[ -n "$data" ]] && args+=(-d "$data")
    curl "${args[@]}" "${CF_API}${endpoint}"
}

cf_call_raw() {
    local method="$1" endpoint="$2" data="${3:-}"
    local args=(-s -X "$method" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json")
    [[ -n "$data" ]] && args+=(-d "$data")
    curl "${args[@]}" "${CF_API}${endpoint}"
}

# ── CF 凭据 ───────────────────────────────────────────
CF_EMAIL="" CF_KEY=""

load_cf_account() {
    [[ -f "$CF_ACCOUNT_PATH" ]] || return 1
    CF_EMAIL=$(jq -r '.email // ""' "$CF_ACCOUNT_PATH")
    CF_KEY=$(jq -r '.api_key // ""' "$CF_ACCOUNT_PATH")
    [[ -n "$CF_EMAIL" && -n "$CF_KEY" ]]
}

save_cf_account() {
    mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
    jq -n --arg e "$CF_EMAIL" --arg k "$CF_KEY" '{email:$e,api_key:$k}' > "$CF_ACCOUNT_PATH"
    chmod 600 "$CF_ACCOUNT_PATH"
}

prompt_cf() {
    if load_cf_account; then
        local masked="${CF_KEY:0:6}...${CF_KEY: -4}"
        read -rp "复用已保存 CF 凭据 ($CF_EMAIL, Key=$masked)? (Y/n): " ans
        [[ "${ans,,}" =~ ^(|y|yes)$ ]] && return
    fi
    read -rp "Cloudflare 邮箱: " CF_EMAIL
    read -rsp "Cloudflare Global API Key: " CF_KEY; echo
    [[ -n "$CF_EMAIL" && -n "$CF_KEY" ]] || die "邮箱和 API Key 不能为空"
    save_cf_account
}

# ── CF DNS / SSL / Origin Rules ───────────────────────
cf_find_zone() {
    local domain="$1" zones best_name="" best_id=""
    zones=$(cf_call GET "/zones?per_page=100" | jq -r '.result[] | "\(.name) \(.id)"')
    while IFS=' ' read -r zone_name zone_id; do
        if [[ "$domain" == "$zone_name" || "$domain" == *".$zone_name" ]]; then
            [[ ${#zone_name} -gt ${#best_name} ]] && best_name="$zone_name" && best_id="$zone_id"
        fi
    done <<< "$zones"
    [[ -n "$best_id" ]] || die "无法匹配 Zone: $domain"
    echo "$best_id"
}

cf_get_dns() {
    cf_call GET "/zones/$1/dns_records?type=A&name=$2" | jq '.result[0] // empty'
}

cf_upsert_dns() {
    local zone_id="$1" domain="$2" ip="$3"
    local payload existing
    payload=$(jq -n --arg n "$domain" --arg c "$ip" '{type:"A",name:$n,content:$c,proxied:true,ttl:1}')
    existing=$(cf_get_dns "$zone_id" "$domain")
    if [[ -n "$existing" ]]; then
        local rid; rid=$(echo "$existing" | jq -r '.id')
        cf_call PUT "/zones/${zone_id}/dns_records/${rid}" "$payload" | jq -r '.result.id'
    else
        cf_call POST "/zones/${zone_id}/dns_records" "$payload" | jq -r '.result.id'
    fi
}

cf_get_ssl()  { cf_call GET "/zones/$1/settings/ssl" | jq -r '.result.value'; }
cf_set_ssl()  { cf_call PATCH "/zones/$1/settings/ssl" "$(jq -n --arg v "$2" '{value:$v}')" >/dev/null; }

# ── CF 安全规则 ───────────────────────────────────────
cf_get_security_level() { cf_call GET "/zones/$1/settings/security_level" | jq -r '.result.value'; }
cf_set_security_level() { cf_call PATCH "/zones/$1/settings/security_level" "$(jq -n --arg v "$2" '{value:$v}')" >/dev/null; }

cf_get_browser_check() { cf_call GET "/zones/$1/settings/browser_check" | jq -r '.result.value'; }
cf_set_browser_check() { cf_call PATCH "/zones/$1/settings/browser_check" "$(jq -n --arg v "$2" '{value:$v}')" >/dev/null; }

cf_get_bot_management() { cf_call_raw GET "/zones/$1/bot_management" | jq '.result // {}'; }

cf_set_bot_fight_off() {
    local zone_id="$1"
    cf_call_raw PUT "/zones/${zone_id}/bot_management" "$(jq -n '{
        enable_js: false,
        sbfm_likely_automated: "allow",
        sbfm_definitely_automated: "allow",
        sbfm_verified_bots: "allow",
        sbfm_static_resource_protection: false
    }')" | jq -e '.success' &>/dev/null
}

cf_restore_bot_management() {
    local zone_id="$1" backup="$2"
    # 只恢复我们改过的字段
    local payload
    payload=$(echo "$backup" | jq '{
        enable_js: .enable_js,
        sbfm_likely_automated: .sbfm_likely_automated,
        sbfm_definitely_automated: .sbfm_definitely_automated,
        sbfm_verified_bots: .sbfm_verified_bots,
        sbfm_static_resource_protection: .sbfm_static_resource_protection
    }')
    cf_call_raw PUT "/zones/${zone_id}/bot_management" "$payload" | jq -e '.success' &>/dev/null
}

# 安装时：备份安全设置 -> 关闭拦截
cf_relax_security() {
    local zone_id="$1"
    local sec_level bot_mgmt browser_check

    sec_level=$(cf_get_security_level "$zone_id")
    browser_check=$(cf_get_browser_check "$zone_id")
    bot_mgmt=$(cf_get_bot_management "$zone_id")

    # 降低 security level
    if [[ "$sec_level" != "essentially_off" ]]; then
        cf_set_security_level "$zone_id" "essentially_off"
        ok "Security Level: essentially_off"
    fi

    # 关闭 Browser Integrity Check
    if [[ "$browser_check" != "off" ]]; then
        cf_set_browser_check "$zone_id" "off"
        ok "Browser Check: off"
    fi

    # 关闭 Bot Fight Mode
    local sbfm_likely
    sbfm_likely=$(echo "$bot_mgmt" | jq -r '.sbfm_likely_automated // ""')
    if [[ "$sbfm_likely" != "allow" ]]; then
        cf_set_bot_fight_off "$zone_id"
        ok "Bot Fight Mode: 已关闭"
    fi

    # 返回备份 JSON
    jq -n --arg sl "$sec_level" --arg bc "$browser_check" --argjson bm "$bot_mgmt"         '{security_level:$sl, browser_check:$bc, bot_management:$bm}'
}

# 卸载时：恢复安全设置
cf_restore_security() {
    local zone_id="$1" backup="$2"
    [[ -z "$backup" || "$backup" == "null" ]] && return

    local sl bc bm
    sl=$(echo "$backup" | jq -r '.security_level // ""')
    bc=$(echo "$backup" | jq -r '.browser_check // ""')
    bm=$(echo "$backup" | jq '.bot_management // null')

    [[ -n "$sl" ]] && cf_set_security_level "$zone_id" "$sl" && ok "Security Level 已恢复: $sl"
    [[ -n "$bc" ]] && cf_set_browser_check "$zone_id" "$bc" && ok "Browser Check 已恢复: $bc"
    [[ "$bm" != "null" ]] && cf_restore_bot_management "$zone_id" "$bm" && ok "Bot Fight Mode 已恢复"
}

cf_get_origin_rules() {
    local r; r=$(cf_call_raw GET "/zones/$1/rulesets/phases/http_request_origin/entrypoint")
    echo "$r" | jq -r 'if .success then .result.rules // [] else [] end' 2>/dev/null || echo '[]'
}

cf_put_origin_rules() {
    local r; r=$(cf_call_raw PUT "/zones/$1/rulesets/phases/http_request_origin/entrypoint" \
        "$(jq -n --argjson r "$2" '{rules:$r}')")
    echo "$r" | jq -e '.success' &>/dev/null || die "Origin Rules 写入失败: $(echo "$r" | jq -c '.errors')"
}

# cf_port = 外部端口（CF Origin Rules 转发的目标端口）
build_new_origin_rules() {
    local domain="$1" routes_json="$2"
    echo "$routes_json" | jq --arg d "$domain" --arg pfx "$MANAGED_PREFIX" '[
        .[] | {
            description: ($pfx + .protocol + " " + .path),
            enabled: true,
            expression: ("(http.host eq \"" + $d + "\" and http.request.uri.path eq \"" + .path + "\")"),
            action: "route",
            action_parameters: { origin: { port: .cf_port } }
        }
    ]'
}

apply_origin_rules() {
    local zone_id="$1" domain="$2" routes_json="$3"
    local existing kept new_managed merged
    existing=$(cf_get_origin_rules "$zone_id")
    kept=$(echo "$existing" | jq --arg d "$domain" --arg pfx "$MANAGED_PREFIX" '[
        .[] | select(
            (.description | startswith($pfx) | not) or
            (.expression | ascii_downcase | contains("http.host eq \"" + ($d|ascii_downcase) + "\"") | not)
        )
    ]')
    new_managed=$(build_new_origin_rules "$domain" "$routes_json")
    merged=$(jq -n --argjson a "$kept" --argjson b "$new_managed" '$a + $b')
    cf_put_origin_rules "$zone_id" "$merged"
}

# ── xray 安装 ─────────────────────────────────────────
install_xray() {
    echo "正在安装 xray-core ..."

    # 优先尝试官方安装脚本（需要 systemd）
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        if bash -c "curl -fsSL $XRAY_INSTALL_URL | bash -s -- install" 2>/dev/null; then
            [[ -f "$XRAY_BINARY" ]] && { ok "xray-core 安装完成"; return; }
        fi
    fi

    # 回退：手动下载二进制
    info "使用手动安装方式"
    local arch
    case "$(uname -m)" in
        x86_64|amd64) arch="64" ;;
        aarch64|arm64) arch="arm64-v8a" ;;
        armv7*)        arch="arm32-v7a" ;;
        *)             die "不支持的架构: $(uname -m)" ;;
    esac

    local ver
    ver=$(curl -sf "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | jq -r '.tag_name') || die "获取 xray 版本失败"
    info "xray $ver ($arch)"

    local tmp="/tmp/xray-install-$$"
    mkdir -p "$tmp"
    curl -fsSL -o "$tmp/xray.zip" "https://github.com/XTLS/Xray-core/releases/download/${ver}/Xray-linux-${arch}.zip" || die "下载失败"

    command -v unzip &>/dev/null || {
        command -v apk &>/dev/null && apk add --no-cache unzip
        command -v apt-get &>/dev/null && apt-get install -y -qq unzip
    }

    unzip -o "$tmp/xray.zip" xray -d /usr/local/bin/ || die "解压失败"
    chmod +x "$XRAY_BINARY"
    rm -rf "$tmp"

    # 下载 geodata
    local geo_dir="/usr/local/share/xray"
    mkdir -p "$geo_dir"
    for f in geoip.dat geosite.dat; do
        [[ -f "$geo_dir/$f" ]] || curl -fsSL -o "$geo_dir/$f" "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/$f" 2>/dev/null || true
    done

    [[ -f "$XRAY_BINARY" ]] || die "安装后未找到 xray"
    ok "xray-core 安装完成: $($XRAY_BINARY version | head -1)"
}

# ── xray 配置生成 ─────────────────────────────────────
gen_xray_config() {
    local routes_json="$1" uid="$2"
    local inbounds
    inbounds=$(echo "$routes_json" | jq --arg uid "$uid" '[
        .[] | {
            tag: ("in-" + .protocol + "-" + (.listen_port|tostring)),
            listen: "0.0.0.0",
            port: .listen_port,
            protocol: .protocol,
            settings: (
                if .protocol == "vless" then {clients:[{id:$uid,flow:""}],decryption:"none"}
                elif .protocol == "trojan" then {clients:[{password:$uid}]}
                else {clients:[{id:$uid,alterId:0}]}
                end
            ),
            streamSettings: { network:"ws", security:"none", wsSettings:{path:.path} },
            sniffing: { enabled:true, destOverride:["http","tls"] }
        }
    ]')
    jq -n --argjson inb "$inbounds" '{
        log:{loglevel:"warning"},
        inbounds:$inb,
        outbounds:[{tag:"direct",protocol:"freedom"},{tag:"block",protocol:"blackhole"}],
        routing:{domainStrategy:"AsIs",rules:[{type:"field",outboundTag:"block",protocol:["bittorrent"]}]}
    }'
}

write_xray_config() {
    mkdir -p "$XRAY_CONFIG_DIR"
    echo "$1" > "$XRAY_CONFIG_PATH"
    chmod 644 "$XRAY_CONFIG_PATH"
    ok "xray 配置已写入 $XRAY_CONFIG_PATH"
}

# ── 订阅链接 ─────────────────────────────────────────
build_link() {
    local uid="$1" domain="$2" proto="$3" path="$4"
    local ev="no" et="no" evm="no"
    case "$proto" in vless) ev="yes";; trojan) et="yes";; vmess) evm="yes";; esac
    echo "${SUB_BASE}/${uid}/sub?domain=${domain}&epd=yes&epi=yes&egi=no&dkby=yes&ev=${ev}&et=${et}&evm=${evm}&path=$(urlencode "$path")"
}

gen_all_links() {
    local uid="$1" domain="$2" routes_json="$3"
    local links_json='{}'
    local proto path link
    while IFS=$'\t' read -r proto path; do
        link=$(build_link "$uid" "$domain" "$proto" "$path")
        links_json=$(echo "$links_json" | jq --arg p "$proto" --arg l "$link" '. + {($p):$l}')
    done < <(echo "$routes_json" | jq -r '.[] | [.protocol, .path] | @tsv')
    echo "$links_json"
}

# ── 状态 ──────────────────────────────────────────────
load_state() { [[ -f "$STATE_PATH" ]] && cat "$STATE_PATH"; }
save_state() { mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"; echo "$1" > "$STATE_PATH"; chmod 600 "$STATE_PATH"; }
remove_state() { rm -f "$STATE_PATH"; }

save_links_snapshot() {
    local domain="$1" uid="$2" links_json="$3"
    { echo "域名: $domain"; echo "UUID: $uid"; echo
      echo "$links_json" | jq -r 'to_entries[] | "\(.key) \(.value)"'
    } > "$LAST_LINKS_PATH"
    chmod 600 "$LAST_LINKS_PATH"
}

print_links() {
    local links_json="$1"
    local proto link
    while IFS=$'\t' read -r proto link; do
        echo "  ${PROTO_LABEL[$proto]:-$proto}订阅 $link"
    done < <(echo "$links_json" | jq -r 'to_entries[] | [.key, .value] | @tsv')
}

# ── 交互辅助 ─────────────────────────────────────────
prompt_protocols() {
    read -rp "创建协议(1=vless,2=trojan,3=vmess，逗号分隔，留空=全部): " proto_raw
    local protocols=()
    if [[ -z "$proto_raw" ]]; then
        protocols=(vless trojan vmess)
    else
        local -A pmap=([1]=vless [2]=trojan [3]=vmess [vless]=vless [trojan]=trojan [vmess]=vmess)
        IFS=',' read -ra tokens <<< "$proto_raw"
        for t in "${tokens[@]}"; do
            t="${t,,}"; t="${t// /}"
            [[ -n "${pmap[$t]:-}" ]] || die "未知协议: $t"
            protocols+=("${pmap[$t]}")
        done
    fi
    echo "${protocols[@]}"
}

prompt_uuid() {
    local uid
    read -rp "UUID(留空=自动生成): " custom_uuid
    if [[ -n "$custom_uuid" ]]; then
        [[ "$custom_uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || die "UUID 格式不正确"
        uid="${custom_uuid,,}"
    else
        uid=$(gen_uuid)
    fi
    echo "$uid"
}

prompt_path_prefix() {
    local default="$1"
    read -rp "WS 路径前缀(留空=/${default}): " pfx
    [[ -z "$pfx" ]] && pfx="/${default}"
    [[ "$pfx" == /* ]] || pfx="/${pfx}"
    echo "$pfx"
}

# 生成路由 JSON，NAT 和直连通用
# NAT 时 xray 监听 listen_port(内部)，CF 转发到 cf_port(外部)
# 直连时 listen_port == cf_port
build_routes() {
    local net_mode="$1" path_prefix="$2" proto_count="$3"
    shift 3
    local protocols=("$@")

    local routes_json='[]'

    if [[ "$net_mode" == "nat" ]]; then
        echo >&2
        info "NAT 模式: 逐个配置每个协议的端口映射" >&2
        echo >&2

        for proto in "${protocols[@]}"; do
            local int_port ext_port
            read -rp "${proto} 内部监听端口(xray监听): " int_port
            [[ "$int_port" =~ ^[0-9]+$ ]] || die "无效端口: $int_port"
            read -rp "${proto} 外部映射端口(对外暴露): " ext_port
            [[ "$ext_port" =~ ^[0-9]+$ ]] || die "无效端口: $ext_port"
            local path="${path_prefix}-${PROTO_SUFFIX[$proto]}"
            routes_json=$(echo "$routes_json" | jq \
                --arg p "$proto" --argjson lp "$((int_port))" --argjson cp "$((ext_port))" --arg pa "$path" \
                '. + [{protocol:$p, listen_port:$lp, cf_port:$cp, path:$pa}]')
        done
    else
        read -rp "自定义端口?(逗号分隔，留空=随机): " custom_ports_raw
        local existing_ports
        existing_ports=$(get_listening_ports)
        local custom_ports=()
        if [[ -n "$custom_ports_raw" ]]; then
            IFS=',' read -ra custom_ports <<< "$custom_ports_raw"
            [[ ${#custom_ports[@]} -eq $proto_count ]] || die "端口数量与协议数不一致"
        fi

        local pi=0
        for proto in "${protocols[@]}"; do
            local port
            if [[ ${#custom_ports[@]} -gt 0 ]]; then
                port="${custom_ports[$pi]// /}"
                [[ "$port" =~ ^[0-9]+$ ]] || die "无效端口: $port"
            else
                port=$(rand_port "$existing_ports")
            fi
            existing_ports="$existing_ports $port"
            local path="${path_prefix}-${PROTO_SUFFIX[$proto]}"
            routes_json=$(echo "$routes_json" | jq \
                --arg p "$proto" --argjson lp "$((port))" --arg pa "$path" \
                '. + [{protocol:$p, listen_port:$lp, cf_port:$lp, path:$pa}]')
            pi=$((pi + 1))
        done
    fi

    echo "$routes_json"
}

# ── 1. 安装 ──────────────────────────────────────────
do_install() {
    local state
    state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] && die "检测到上次配置($(echo "$state" | jq -r '.domain // "?"'))，请先卸载"

    [[ -f "$XRAY_BINARY" ]] && ok "xray-core 已安装" || install_xray

    local net_mode
    net_mode=$(detect_nat)
    [[ "$net_mode" == "nat" ]] && info "检测到 NAT 环境（内网 IP）" || info "直连环境"

    read -rp "绑定域名: " domain
    [[ -n "$domain" ]] || die "域名不能为空"
    prompt_cf

    local protocols_str
    protocols_str=$(prompt_protocols)
    read -ra protocols <<< "$protocols_str"

    local uid
    uid=$(prompt_uuid)
    local short_id="${uid:0:8}"
    local path_prefix
    path_prefix=$(prompt_path_prefix "$short_id")

    local routes_json
    routes_json=$(build_routes "$net_mode" "$path_prefix" "${#protocols[@]}" "${protocols[@]}")

    # 预览
    echo
    echo "配置预览:"
    echo "  域名:  $domain"
    echo "  UUID:  $uid"
    echo "  模式:  $net_mode"
    echo "$routes_json" | jq -r '.[] | "  \(.protocol)  监听:\(.listen_port)  CF端口:\(.cf_port)  路径:\(.path)"'
    echo
    read -rp "确认部署? (Y/n): " confirm
    [[ "${confirm,,}" =~ ^(|y|yes)$ ]] || die "已取消"

    # xray
    local config
    config=$(gen_xray_config "$routes_json" "$uid")
    write_xray_config "$config"
    [[ "$INIT_SYSTEM" == "openrc" && ! -f "$XRAY_OPENRC_SCRIPT" ]] && write_openrc_script && ok "OpenRC 服务脚本已创建"
    restart_xray

    # CF
    local zone_id public_ip dns_before ssl_before origin_rules_before dns_record_id
    zone_id=$(cf_find_zone "$domain")
    public_ip=$(get_public_ip)
    dns_before=$(cf_get_dns "$zone_id" "$domain" || echo "null")
    [[ "$dns_before" == "" ]] && dns_before="null"
    ssl_before=$(cf_get_ssl "$zone_id")
    origin_rules_before=$(cf_get_origin_rules "$zone_id")

    dns_record_id=$(cf_upsert_dns "$zone_id" "$domain" "$public_ip")
    ok "DNS A 记录: $domain -> $public_ip (已代理)"
    cf_set_ssl "$zone_id" "flexible"
    ok "SSL 模式: flexible"
    apply_origin_rules "$zone_id" "$domain" "$routes_json"
    ok "Origin Rules: ${#protocols[@]} 条"

    # 安全规则：关闭可能拦截 WS 的设置
    local security_backup
    security_backup=$(cf_relax_security "$zone_id")

    # 订阅
    local links_json
    links_json=$(gen_all_links "$uid" "$domain" "$routes_json")
    save_links_snapshot "$domain" "$uid" "$links_json"

    # 状态
    local dns_existed="false"
    [[ "$dns_before" != "null" ]] && dns_existed="true"
    save_state "$(jq -n \
        --arg d "$domain" --arg z "$zone_id" --arg u "$uid" --arg s "$short_id" --arg mode "$net_mode" \
        --argjson routes "$routes_json" \
        --arg drid "$dns_record_id" --argjson dex "$dns_existed" --argjson drec "$dns_before" \
        --arg ssl "$ssl_before" --argjson orbk "$origin_rules_before" --argjson links "$links_json" \
        --argjson secbk "$security_backup" \
        '{domain:$d,zone_id:$z,uuid:$u,short_id:$s,net_mode:$mode,routes:$routes,
          managed_dns_record_id:$drid,dns_backup:{existed:$dex,record:$drec},
          ssl_backup:$ssl,origin_rules_backup:$orbk,security_backup:$secbk,links:$links}')"

    echo
    ok "部署完成"
    print_links "$links_json"
    echo
    echo "订阅已保存到 $LAST_LINKS_PATH"
}

# ── 2. 卸载 ──────────────────────────────────────────
do_uninstall() {
    local state
    state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] || die "未检测到上次配置"

    local domain; domain=$(echo "$state" | jq -r '.domain')
    echo "正在卸载: $domain"

    stop_xray; rm -f "$XRAY_CONFIG_PATH"
    ok "xray 已停止"

    if load_cf_account; then
        local zone_id; zone_id=$(echo "$state" | jq -r '.zone_id // ""')
        if [[ -n "$zone_id" ]]; then
            cf_put_origin_rules "$zone_id" "$(echo "$state" | jq '.origin_rules_backup // []')"
            ok "Origin Rules 已恢复"

            local ssl_bk; ssl_bk=$(echo "$state" | jq -r '.ssl_backup // ""')
            [[ -n "$ssl_bk" ]] && cf_set_ssl "$zone_id" "$ssl_bk" && ok "SSL: $ssl_bk"

            local dns_existed record_id
            dns_existed=$(echo "$state" | jq -r '.dns_backup.existed')
            record_id=$(echo "$state" | jq -r '.managed_dns_record_id // ""')
            if [[ "$dns_existed" == "true" ]]; then
                local rp; rp=$(echo "$state" | jq '.dns_backup.record | {type:(.type//"A"),name:(.name//""),content:(.content//""),proxied:(.proxied//false),ttl:(.ttl//1)}')
                cf_call PUT "/zones/${zone_id}/dns_records/${record_id}" "$rp" >/dev/null
                ok "DNS 已恢复"
            elif [[ -n "$record_id" ]]; then
                cf_call_raw DELETE "/zones/${zone_id}/dns_records/${record_id}" >/dev/null 2>&1 || true
                ok "DNS 已删除"
            fi
            # 恢复安全规则
            local sec_bk; sec_bk=$(echo "$state" | jq '.security_backup // null')
            cf_restore_security "$zone_id" "$sec_bk"
        fi
    else
        echo "无 CF 凭据，跳过恢复"
    fi

    remove_state
    ok "卸载完成"
}

# ── 3. 查看订阅 ──────────────────────────────────────
do_show() {
    if [[ -f "$LAST_LINKS_PATH" ]]; then cat "$LAST_LINKS_PATH"; return; fi
    local state; state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] || die "无历史订阅"
    echo "域名: $(echo "$state" | jq -r '.domain')"
    echo "UUID: $(echo "$state" | jq -r '.uuid')"
    echo "$state" | jq -r '.links | to_entries[] | "\(.key) \(.value)"'
}

# ── 4. 修改配置 ──────────────────────────────────────
do_modify() {
    local state; state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] || die "未检测到部署"

    local domain uid routes_json net_mode
    domain=$(echo "$state" | jq -r '.domain')
    uid=$(echo "$state" | jq -r '.uuid')
    routes_json=$(echo "$state" | jq '.routes')
    net_mode=$(echo "$state" | jq -r '.net_mode // "direct"')

    echo
    echo "当前配置 ($net_mode):"
    echo "  域名: $domain  UUID: $uid"
    echo "$routes_json" | jq -r '.[] | "  \(.protocol)  监听:\(.listen_port)  CF端口:\(.cf_port)  路径:\(.path)"'
    echo
    echo "  1. 修改 UUID"
    echo "  2. 修改端口"
    echo "  3. 修改 WS 路径"
    echo "  4. 全部修改"
    echo "  0. 返回"
    echo
    read -rp "请选择 [0-4]: " mc

    local new_uid="$uid" new_routes="$routes_json" changed=false

    [[ "$mc" =~ ^[0-4]$ ]] || die "无效选项"
    [[ "$mc" == "0" ]] && return

    if [[ "$mc" == "1" || "$mc" == "4" ]]; then
        read -rp "新 UUID(留空=重新生成): " iu
        if [[ -n "$iu" ]]; then
            [[ "$iu" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || die "UUID 格式不正确"
            new_uid="${iu,,}"
        else
            new_uid=$(gen_uuid)
        fi
        changed=true; ok "UUID: $new_uid"
    fi

    if [[ "$mc" == "2" || "$mc" == "4" ]]; then
        local pc; pc=$(echo "$new_routes" | jq 'length')
        if [[ "$net_mode" == "nat" ]]; then
            echo "当前映射: $(echo "$new_routes" | jq -r '[.[] | "\(.listen_port):\(.cf_port)"] | join(",")')"
            read -rp "新端口映射(内部:外部，共${pc}组，留空=不改): " mr
            if [[ -n "$mr" ]]; then
                IFS=',' read -ra maps <<< "$mr"
                [[ ${#maps[@]} -eq $pc ]] || die "数量不匹配"
                local idx=0
                for m in "${maps[@]}"; do
                    m="${m// /}"; local lp="${m%%:*}" cp="${m##*:}"
                    [[ "$lp" =~ ^[0-9]+$ && "$cp" =~ ^[0-9]+$ ]] || die "无效: $m"
                    new_routes=$(echo "$new_routes" | jq --argjson i $idx --argjson l "$((lp))" --argjson c "$((cp))" '.[$i].listen_port=$l|.[$i].cf_port=$c')
                    idx=$((idx+1))
                done
                changed=true; ok "端口已更新"
            fi
        else
            echo "当前端口: $(echo "$new_routes" | jq -r '[.[].listen_port|tostring] | join(",")')"
            read -rp "新端口(逗号分隔，共${pc}个，留空=不改): " pr
            if [[ -n "$pr" ]]; then
                IFS=',' read -ra nps <<< "$pr"
                [[ ${#nps[@]} -eq $pc ]] || die "数量不匹配"
                local idx=0
                for np in "${nps[@]}"; do
                    np="${np// /}"; [[ "$np" =~ ^[0-9]+$ ]] || die "无效: $np"
                    new_routes=$(echo "$new_routes" | jq --argjson i $idx --argjson p "$((np))" '.[$i].listen_port=$p|.[$i].cf_port=$p')
                    idx=$((idx+1))
                done
                changed=true; ok "端口已更新"
            fi
        fi
    fi

    if [[ "$mc" == "3" || "$mc" == "4" ]]; then
        echo "当前路径: $(echo "$new_routes" | jq -r '[.[].path] | join(", ")')"
        read -rp "新 WS 路径前缀(留空=不改): " np
        if [[ -n "$np" ]]; then
            [[ "$np" == /* ]] || np="/${np}"
            new_routes=$(echo "$new_routes" | jq --arg pfx "$np" '[.[]|.path=($pfx+"-"+(if .protocol=="vless" then "vl" elif .protocol=="trojan" then "tr" else "vm" end))]')
            changed=true; ok "路径已更新"
        fi
    fi

    [[ "$changed" == "true" ]] || { echo "无修改"; return; }

    write_xray_config "$(gen_xray_config "$new_routes" "$new_uid")"
    restart_xray

    if load_cf_account; then
        apply_origin_rules "$(echo "$state" | jq -r '.zone_id')" "$domain" "$new_routes"
        ok "Origin Rules 已更新"
    fi

    local links_json; links_json=$(gen_all_links "$new_uid" "$domain" "$new_routes")
    save_links_snapshot "$domain" "$new_uid" "$links_json"
    save_state "$(echo "$state" | jq --arg u "$new_uid" --argjson r "$new_routes" --argjson l "$links_json" --arg s "${new_uid:0:8}" \
        '.uuid=$u|.short_id=$s|.routes=$r|.links=$l')"

    echo; ok "配置已更新"; print_links "$links_json"
}

# ── 5. 查看当前配置 ──────────────────────────────────
do_show_config() {
    local state; state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] || die "未检测到部署"

    echo
    echo "域名:  $(echo "$state" | jq -r '.domain')"
    echo "UUID:  $(echo "$state" | jq -r '.uuid')"
    echo "模式:  $(echo "$state" | jq -r '.net_mode // "direct"')"
    echo
    echo "入站:"
    echo "$state" | jq -r '.routes[] | "  \(.protocol)  监听:\(.listen_port)  CF端口:\(.cf_port)  路径:\(.path)"'
    echo
    echo -n "xray: "; svc_is_active && echo "运行中" || echo "未运行"
    echo
    echo "订阅:"
    print_links "$(echo "$state" | jq '.links')"
    echo
}

# ── 6. 更新外部端口（NAT 快捷操作）──────────────────
do_update_ports() {
    local state; state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] || die "未检测到部署"

    local domain routes_json net_mode
    domain=$(echo "$state" | jq -r '.domain')
    routes_json=$(echo "$state" | jq '.routes')
    net_mode=$(echo "$state" | jq -r '.net_mode // "direct"')

    echo
    echo "当前端口映射:"
    echo "$routes_json" | jq -r '.[] | "  \(.protocol)  监听:\(.listen_port) -> 外部:\(.cf_port)"'
    echo

    local pc; pc=$(echo "$routes_json" | jq 'length')

    if [[ "$net_mode" == "nat" ]]; then
        info "NAT 模式: 只更新外部端口(CF Origin Rules)，xray 监听端口不变"
        echo

        local new_routes="$routes_json" idx=0
        while IFS=$'\t' read -r proto old_cp; do
            read -rp "${proto} 新外部端口(当前=${old_cp}): " ne
            [[ -n "$ne" ]] || die "不能为空"
            [[ "$ne" =~ ^[0-9]+$ ]] || die "无效端口: $ne"
            new_routes=$(echo "$new_routes" | jq --argjson i $idx --argjson p "$((ne))" '.[$i].cf_port=$p')
            idx=$((idx+1))
        done < <(echo "$routes_json" | jq -r '.[] | [.protocol, (.cf_port|tostring)] | @tsv')

        echo
        echo "更新预览:"
        echo "$new_routes" | jq -r '.[] | "  \(.protocol)  监听:\(.listen_port) -> 外部:\(.cf_port)"'
        read -rp "确认? (Y/n): " confirm
        [[ "${confirm,,}" =~ ^(|y|yes)$ ]] || die "已取消"

        # 只更新 CF Origin Rules，不动 xray
        load_cf_account || die "未找到 CF 凭据"
        apply_origin_rules "$(echo "$state" | jq -r '.zone_id')" "$domain" "$new_routes"
        ok "Origin Rules 已更新"

        # 同时更新 DNS（公网 IP 可能也变了）
        local public_ip; public_ip=$(get_public_ip)
        local zone_id; zone_id=$(echo "$state" | jq -r '.zone_id')
        local current_dns; current_dns=$(cf_get_dns "$zone_id" "$domain")
        local current_ip; current_ip=$(echo "$current_dns" | jq -r '.content // ""')
        if [[ "$current_ip" != "$public_ip" ]]; then
            cf_upsert_dns "$zone_id" "$domain" "$public_ip" >/dev/null
            ok "DNS 已更新: $domain -> $public_ip"
        fi

        local uid; uid=$(echo "$state" | jq -r '.uuid')
        local links_json; links_json=$(gen_all_links "$uid" "$domain" "$new_routes")
        save_links_snapshot "$domain" "$uid" "$links_json"
        save_state "$(echo "$state" | jq --argjson r "$new_routes" --argjson l "$links_json" '.routes=$r|.links=$l')"

        echo; ok "外部端口已更新"; print_links "$links_json"
    else
        info "直连模式: 端口变更需要同时修改 xray 监听，请使用 [4.修改配置]"
    fi
}

# ── 7. 重启 xray ─────────────────────────────────────
do_restart() {
    if ! svc_is_active; then
        echo "xray 当前未运行，正在启动..."
    else
        echo "正在重启 xray..."
    fi
    restart_xray
}

# ── 主入口 ────────────────────────────────────────────
ensure_shortcut() {
    local target="/usr/local/bin/x"
    [[ -f "$target" ]] && return
    cat > "$target" << 'SCEOF'
#!/bin/sh
exec bash <(curl -fsSL https://raw.githubusercontent.com/byJoey/xray-cf-lite/main/xray_cf_lite.sh) "$@"
SCEOF
    chmod +x "$target"
}

main() {
    [[ "$(id -u)" == "0" ]] || die "请使用 root 运行此脚本"
    detect_init
    install_deps
    need_cmd curl; need_cmd jq
    ensure_shortcut

    local state current_domain="" net_mode=""
    state=$(load_state 2>/dev/null || true)
    if [[ -n "$state" ]]; then
        current_domain=$(echo "$state" | jq -r '.domain // ""')
        net_mode=$(echo "$state" | jq -r '.net_mode // ""')
    fi

    echo
    echo "  xray-cf-lite ($INIT_SYSTEM)"
    echo
    echo "  1. 安装节点"
    echo "  2. 卸载"
    echo "  3. 查看订阅"
    echo "  4. 修改配置(UUID/端口/路径)"
    echo "  5. 查看当前配置"
    echo "  6. 更新外部端口(NAT换端口)"
    echo "  7. 重启 xray"
    [[ -n "$current_domain" ]] && echo "     (当前: $current_domain${net_mode:+ [$net_mode]})"
    echo

    read -rp "请选择 [1-7]: " choice
    case "$choice" in
        1) do_install ;; 2) do_uninstall ;; 3) do_show ;;
        4) do_modify ;; 5) do_show_config ;; 6) do_update_ports ;;
        7) do_restart ;;
        *) die "无效选项: $choice" ;;
    esac
}

main "$@"
