#!/usr/bin/env bash
# realmm.sh - Realm 转发管理面板
# 支持 systemd / OpenRC；规则保存在 /etc/realm/rules.list

umask 077

RULE_DIR="/etc/realm"
RULES="$RULE_DIR/rules.list"
CONF="$RULE_DIR/config.toml"
SET="$RULE_DIR/realmm.conf"
BIN="/usr/local/bin/realm"
MANAGER="/usr/local/bin/realmm"

# 上传 GitHub 后，将“你的用户名”替换成实际 GitHub 用户名。
# 也可以通过环境变量 REALMM_SCRIPT_URL 覆盖此地址。
SCRIPT_URL="${REALMM_SCRIPT_URL:-https://raw.githubusercontent.com/Withxxy/Realmm/main/realmm.sh}"

UDP=false
INIT=""
IPS_DONE=""
V4=""
V6=""
FW_WARNED=""

R=$'\033[31m'
G=$'\033[32m'
Y=$'\033[33m'
B=$'\033[36m'
W=$'\033[1m'
N=$'\033[0m'

# ---------- 基础检查 ----------
if [[ "$(id -u)" != "0" ]]; then
  echo "请使用 root 用户运行：sudo bash realmm.sh"
  exit 1
fi

if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
  INIT="systemd"
elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
  INIT="openrc"
else
  echo "未识别服务管理器：目前支持 systemd 和 OpenRC。"
  exit 1
fi

mkdir -p "$RULE_DIR"
touch "$RULES"
chmod 600 "$RULES" 2>/dev/null || true

# 不使用 source 读取配置，避免把配置文件当成 shell 代码执行。
if [[ -r "$SET" ]] && grep -qx 'UDP=true' "$SET" 2>/dev/null; then
  UDP=true
fi

# ---------- 输出 ----------
ok()   { printf '%s✔ %s%s\n' "$G" "$*" "$N"; }
err()  { printf '%s✘ %s%s\n' "$R" "$*" "$N"; }
warn() { printf '%s! %s%s\n' "$Y" "$*" "$N"; }
pause() {
  echo
  read -r -p "按回车返回菜单..." _ || {
    echo
    exit 0
  }
}

# ---------- 下载 ----------
download_file() {
  local url="$1" output="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 2 --connect-timeout 10 --max-time 180 \
      -o "$output" "$url" 2>/dev/null && [[ -s "$output" ]] && return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -q --tries=2 --timeout=20 -O "$output" "$url" 2>/dev/null \
      && [[ -s "$output" ]] && return 0
  fi
  return 1
}

# ---------- 安装/同步管理器快捷命令 ----------
install_manager() {
  local src resolved tmp
  src="${BASH_SOURCE[0]:-$0}"

  # 从本地脚本文件运行：直接复制当前脚本。
  if [[ -f "$src" ]]; then
    resolved="$(readlink -f "$src" 2>/dev/null || printf '%s' "$src")"
    if [[ "$resolved" != "$MANAGER" ]]; then
      if install -m 755 "$resolved" "$MANAGER" 2>/dev/null; then
        ok "管理命令已同步：输入 realmm 即可启动"
      else
        warn "无法写入 $MANAGER，检查 /usr/local/bin 权限"
      fi
    fi
    return
  fi

  # bash <(curl ...) 时脚本来自管道，无法直接复制；从配置的 Raw 地址重新下载。
  if [[ "$SCRIPT_URL" == *"你的用户名"* ]]; then
    warn "当前通过管道运行，尚未配置 GitHub 用户名，暂不能自动安装 realmm 快捷命令"
    return
  fi

  tmp="$(mktemp 2>/dev/null)" || {
    warn "无法创建临时文件，未安装 realmm 快捷命令"
    return
  }
  if download_file "$SCRIPT_URL" "$tmp" && bash -n "$tmp" >/dev/null 2>&1; then
    if install -m 755 "$tmp" "$MANAGER" 2>/dev/null; then
      ok "管理命令已从 GitHub 同步：输入 realmm 即可启动"
    else
      warn "无法写入 $MANAGER，检查目录权限"
    fi
  else
    warn "无法从 GitHub 下载管理脚本，主程序仍可继续运行"
  fi
  rm -f "$tmp"
}

# ---------- 最小依赖 ----------
install_minimal_deps() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq &&
      apt-get install -y -qq ca-certificates curl wget tar iproute2 coreutils
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache ca-certificates curl wget tar iproute2 coreutils
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q ca-certificates curl wget tar iproute coreutils
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q ca-certificates curl wget tar iproute coreutils
  else
    return 1
  fi
}

ensure_tools() {
  local missing=""
  command -v ss >/dev/null 2>&1 || missing="$missing iproute2(ss)"
  command -v tar >/dev/null 2>&1 || missing="$missing tar"
  command -v timeout >/dev/null 2>&1 || missing="$missing timeout(coreutils)"
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    missing="$missing curl/wget"
  fi

  [[ -z "$missing" ]] && return 0

  warn "缺少必要工具：$missing"
  read -r -p "是否尝试安装最小依赖？[Y/n] " answer
  case "$answer" in
    n|N) return 1 ;;
  esac

  if install_minimal_deps; then
    ok "依赖安装完成"
    return 0
  fi

  err "依赖安装失败，请检查包管理器或手动安装 curl、tar、iproute2"
  return 1
}

# ---------- 配置与规则 ----------
init_dir() {
  mkdir -p "$RULE_DIR"
  touch "$RULES"
  chmod 600 "$RULES" 2>/dev/null || true
}

save_set() {
  local tmp
  init_dir
  tmp="$(mktemp "$SET.XXXXXX")" || return 1
  printf 'UDP=%s\n' "$UDP" > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$SET"
}

count_rules() {
  awk 'NF { n++ } END { print n+0 }' "$RULES" 2>/dev/null
}

valid_port() {
  [[ "$1" =~ ^[0-9]{1,5}$ ]] || return 1
  local p=$((10#$1))
  (( p >= 1 && p <= 65535 ))
}

normalize_host() {
  local h="$1"
  if [[ "$h" == \[*\] ]]; then
    h="${h:1:${#h}-2}"
  fi
  printf '%s' "$h"
}

valid_host() {
  local h
  h="$(normalize_host "$1")"
  [[ -n "$h" ]] || return 1
  # 允许 IPv4、IPv6 和普通域名；拒绝空格、引号、斜杠等配置注入字符。
  [[ "$h" =~ ^[a-zA-Z0-9._:-]+$ ]] || return 1
  [[ "$h" != .* && "$h" != *..* && "$h" != *: ]]
  local last="${h: -1}"
  [[ "$last" != "." ]]
}

format_remote() {
  local h
  h="$(normalize_host "$1")"
  if [[ "$h" == *:* ]]; then
    printf '[%s]:%s' "$h" "$2"
  else
    printf '%s:%s' "$h" "$2"
  fi
}

clean_name() {
  printf '%s' "$1" |
    tr -d '\000-\037\177' |
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

name_used() {
  local wanted="$1" ignore="${2:-0}"
  awk -v wanted="$wanted" -v ignore="$ignore" '
    NF {
      i++
      name=$4
      for (j=5; j<=NF; j++) name=name " " $j
      if (i != ignore && name == wanted) found=1
    }
    END { exit !found }
  ' "$RULES"
}

default_name() {
  local n
  n=$(( $(count_rules) + 1 ))
  while name_used "规则$n"; do
    n=$((n+1))
  done
  printf '规则%s' "$n"
}

fix_names() {
  local tmp lp host tp nm n=0
  tmp="$(mktemp "$RULES.XXXXXX")" || return 1

  while read -r lp host tp nm || [[ -n "$lp$host$tp$nm" ]]; do
    [[ -z "$lp" ]] && continue
    n=$((n+1))
    [[ -z "$nm" ]] && nm="规则$n"
    printf '%s %s %s %s\n' "$lp" "$host" "$tp" "$nm" >> "$tmp"
  done < "$RULES"

  chmod 600 "$tmp"
  mv -f "$tmp" "$RULES"
}

replace_rule() {
  local wanted="$1" new_lp="$2" new_host="$3" new_tp="$4" new_name="$5"
  local tmp lp host tp nm i=0
  tmp="$(mktemp "$RULES.XXXXXX")" || return 1

  while read -r lp host tp nm || [[ -n "$lp$host$tp$nm" ]]; do
    [[ -z "$lp" ]] && continue
    i=$((i+1))
    if [[ "$i" == "$wanted" ]]; then
      printf '%s %s %s %s\n' "$new_lp" "$new_host" "$new_tp" "$new_name" >> "$tmp"
    else
      printf '%s %s %s %s\n' "$lp" "$host" "$tp" "$nm" >> "$tmp"
    fi
  done < "$RULES"

  chmod 600 "$tmp"
  mv -f "$tmp" "$RULES"
}

# 端口冲突检查：同时检查已有规则和系统 TCP/UDP 监听。
port_used() {
  local port="$1" ignore="${2:-0}"

  if awk -v p="$port" -v ignore="$ignore" '
    NF { i++; if ($1 == p && i != ignore) found=1 }
    END { exit !found }
  ' "$RULES"; then
    return 0
  fi

  if command -v ss >/dev/null 2>&1; then
    ss -H -lntu 2>/dev/null |
      awk -v p="$port" '
        {
          addr=$5
          sub(/^.*:/, "", addr)
          if (addr == p) found=1
        }
        END { exit !found }
      '
    return $?
  fi

  return 1
}

rand_port() {
  local p tries=0
  while (( tries < 500 )); do
    p=$((20000 + RANDOM % 40000))
    if ! port_used "$p"; then
      printf '%s' "$p"
      return 0
    fi
    tries=$((tries+1))
  done
  return 1
}

# ---------- 网络检测 ----------
tcp_ok() {
  local host="$1" port="$2"
  command -v timeout >/dev/null 2>&1 || return 2
  timeout 5 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$host" "$port" \
    >/dev/null 2>&1
}

myip() {
  local family="$1" url result
  local -a urls

  if [[ "$family" == "4" ]]; then
    urls=("https://api.ipify.org" "https://ipv4.icanhazip.com" "https://ifconfig.me/ip")
  else
    urls=("https://api64.ipify.org" "https://ipv6.icanhazip.com" "https://ifconfig.me/ip")
  fi

  for url in "${urls[@]}"; do
    result=""
    if command -v curl >/dev/null 2>&1; then
      result="$(curl "-$family" -fsS --connect-timeout 4 --max-time 6 "$url" 2>/dev/null)"
    elif command -v wget >/dev/null 2>&1; then
      result="$(wget "-$family" -qO- -T 6 "$url" 2>/dev/null)"
    fi
    result="$(printf '%s' "$result" | tr -d '[:space:]')"

    if [[ "$family" == "4" && "$result" =~ ^[0-9.]+$ ]]; then
      printf '%s' "$result"
      return 0
    elif [[ "$family" == "6" && "$result" == *:* && "$result" =~ ^[0-9a-fA-F:]+$ ]]; then
      printf '%s' "$result"
      return 0
    fi
  done
  return 1
}

get_ips() {
  [[ -n "$IPS_DONE" ]] && return
  echo "正在检测本机公网出口 IP..."
  V4="$(myip 4 2>/dev/null || true)"
  V6="$(myip 6 2>/dev/null || true)"
  IPS_DONE=1
}

print_entry() {
  [[ -n "$V4" ]] && echo "      IPv4 入口参考：$V4:$1"
  [[ -n "$V6" ]] && echo "      IPv6 入口参考：[$V6]:$1"
  if [[ -z "$V4" && -z "$V6" ]]; then
    warn "未检测到公网出口 IP；NAT VPS 请以服务商面板提供的映射地址为准"
  fi
}

is_listening() {
  local port="$1"
  command -v ss >/dev/null 2>&1 || return 1
  ss -H -ltn 2>/dev/null |
    awk -v p="$port" '
      {
        addr=$4
        sub(/^.*:/, "", addr)
        if (addr == p) found=1
      }
      END { exit !found }
    '
}

# ---------- 防火墙 ----------
# 只管理带 realmm:<端口> 注释的规则，绝不删除无注释的用户规则。
fw_rule_add() {
  local ipt="$1" proto="$2" port="$3" tag="realmm:$3"
  "$ipt" -C INPUT -p "$proto" --dport "$port" \
    -m comment --comment "$tag" -j ACCEPT 2>/dev/null ||
    "$ipt" -I INPUT 1 -p "$proto" --dport "$port" \
      -m comment --comment "$tag" -j ACCEPT 2>/dev/null
}

fw_rule_del() {
  local ipt="$1" proto="$2" port="$3" tag="realmm:$3"
  while "$ipt" -D INPUT -p "$proto" --dport "$port" \
    -m comment --comment "$tag" -j ACCEPT 2>/dev/null; do
    :
  done
}

fw_save() {
  local s
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1 || true
  elif [[ "$INIT" == "openrc" ]]; then
    for s in iptables ip6tables; do
      if [[ -f "/etc/init.d/$s" ]]; then
        rc-service "$s" save >/dev/null 2>&1 || true
      fi
    done
  elif [[ -z "$FW_WARNED" ]]; then
    warn "未检测到防火墙持久化组件；手动添加的 iptables 规则可能在重启后丢失"
    FW_WARNED=1
  fi
}

fw_open() {
  local port="$1" ipt proto

  # 不擅自修改 UFW/firewalld 的规则，避免与其规则管理发生冲突。
  if command -v ufw >/dev/null 2>&1 &&
     ufw status 2>/dev/null | grep -q 'Status: active'; then
    warn "检测到 UFW 已启用，请按提示手动放行端口 $port"
    echo "      ufw allow $port/tcp"
    [[ "$UDP" == "true" ]] && echo "      ufw allow $port/udp"
    return
  fi
  if command -v firewall-cmd >/dev/null 2>&1 &&
     firewall-cmd --state >/dev/null 2>&1; then
    warn "检测到 firewalld 已启用，请在 firewalld 中手动放行端口 $port"
    return
  fi

  local found=0
  for ipt in iptables ip6tables; do
    command -v "$ipt" >/dev/null 2>&1 || continue
    found=1
    fw_rule_add "$ipt" tcp "$port" || warn "$ipt 添加 TCP $port 规则失败"
    if [[ "$UDP" == "true" ]]; then
      fw_rule_add "$ipt" udp "$port" || warn "$ipt 添加 UDP $port 规则失败"
    else
      fw_rule_del "$ipt" udp "$port"
    fi
  done

  if (( found == 0 )); then
    warn "未找到 iptables/ip6tables，未自动修改本机防火墙"
    return
  fi
  fw_save
}

fw_close() {
  local port="$1" ipt proto
  for ipt in iptables ip6tables; do
    command -v "$ipt" >/dev/null 2>&1 || continue
    for proto in tcp udp; do
      fw_rule_del "$ipt" "$proto" "$port"
    done
  done
  fw_save
}

fw_sync_all() {
  local lp host tp nm
  while read -r lp host tp nm; do
    [[ -n "$lp" ]] && fw_open "$lp"
  done < "$RULES"
}

# ---------- Realm 配置生成 / 旧配置导入 ----------
gen_conf() {
  local lp host tp nm remote tmp backup
  init_dir
  tmp="$(mktemp "$CONF.XXXXXX")" || {
    err "无法创建临时配置文件"
    return 1
  }

  # 第一次接管已有配置时先备份，避免覆盖用户手工添加的 Realm 参数。
  if [[ -s "$CONF" ]] && ! grep -q '^# Managed by realmm' "$CONF"; then
    backup="$CONF.bak.$(date +%Y%m%d%H%M%S)"
    if cp -p "$CONF" "$backup" 2>/dev/null; then
      warn "原配置已备份：$backup"
    else
      rm -f "$tmp"
      err "无法备份原配置，已取消覆盖"
      return 1
    fi
  fi

  {
    printf '# Managed by realmm - edit forwarding rules in the menu.\n'
    printf '[log]\n'
    printf 'level = "warn"\n'
    printf 'output = "stdout"\n\n'
    printf '[network]\n'
    printf 'no_tcp = false\n'
    printf 'use_udp = %s\n' "$UDP"
    printf 'ipv6_only = false\n\n'

    while read -r lp host tp nm; do
      [[ -z "$lp" ]] && continue
      remote="$(format_remote "$host" "$tp")"
      printf '# %s\n' "$nm"
      printf '[[endpoints]]\n'
      printf 'listen = "[::]:%s"\n' "$lp"
      printf 'remote = "%s"\n\n' "$remote"
    done < "$RULES"
  } > "$tmp"

  chmod 600 "$tmp"
  if ! mv -f "$tmp" "$CONF"; then
    rm -f "$tmp"
    err "写入 Realm 配置失败"
    return 1
  fi
}

import_existing() {
  [[ -s "$RULES" ]] && return 0
  [[ -f "$CONF" ]] || return 0

  if [[ ! -f "$CONF.bak.premgr" ]]; then
    cp -p "$CONF" "$CONF.bak.premgr" 2>/dev/null || true
  fi

  awk '
    function value(line) {
      sub(/^[^"]*"/, "", line)
      sub(/".*$/, "", line)
      return line
    }
    function get_port(addr, pos) {
      if (substr(addr,1,1) == "[") {
        pos=index(addr,"]")
        if (pos) return substr(addr,pos+2)
      }
      pos=match(addr, /:[^:]*$/)
      if (pos) return substr(addr,pos+1)
      return ""
    }
    function get_host(addr, pos) {
      if (substr(addr,1,1) == "[") {
        pos=index(addr,"]")
        if (pos) return substr(addr,2,pos-2)
      }
      pos=match(addr, /:[^:]*$/)
      if (pos) return substr(addr,1,pos-1)
      return ""
    }
    /^[[:space:]]*#[[:space:]]*/ {
      comment=$0
      sub(/^[[:space:]]*#[[:space:]]*/, "", comment)
      next
    }
    /^[[:space:]]*listen[[:space:]]*=/ {
      addr=value($0)
      lp=get_port(addr)
      next
    }
    /^[[:space:]]*remote[[:space:]]*=/ {
      addr=value($0)
      host=get_host(addr)
      port=get_port(addr)
      if (lp ~ /^[0-9]+$/ && host != "" && port ~ /^[0-9]+$/) {
        if (comment == "") comment="规则"
        printf "%s %s %s %s\n", lp, host, port, comment
      }
      lp=""
      comment=""
    }
  ' "$CONF" > "$RULES"

  if grep -Eq '^[[:space:]]*use_udp[[:space:]]*=[[:space:]]*true' "$CONF"; then
    UDP=true
    save_set
  fi

  if [[ -s "$RULES" ]]; then
    ok "已从原有 config.toml 导入转发规则"
    warn "原配置备份在：$CONF.bak.premgr"
  fi
}

# ---------- 服务管理 ----------
svc() {
  local action="$1"
  if [[ "$INIT" == "systemd" ]]; then
    case "$action" in
      enable)  systemctl enable realm >/dev/null 2>&1 ;;
      disable) systemctl disable realm >/dev/null 2>&1 ;;
      *)       systemctl "$action" realm ;;
    esac
  else
    case "$action" in
      enable)  rc-update add realm default >/dev/null 2>&1 ;;
      disable) rc-update del realm default >/dev/null 2>&1 ;;
      *)       rc-service realm "$action" ;;
    esac
  fi
}

is_active() {
  if [[ "$INIT" == "systemd" ]]; then
    systemctl is-active --quiet realm 2>/dev/null
  else
    rc-service realm status >/dev/null 2>&1
  fi
}

write_service() {
  if [[ "$INIT" == "systemd" ]]; then
    cat > /etc/systemd/system/realm.service <<SVC
[Unit]
Description=Realm TCP/UDP Relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$RULE_DIR
ExecStart=$BIN -c $CONF
Restart=on-failure
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SVC
    systemctl daemon-reload
  else
    cat > /etc/init.d/realm <<SVC
#!/sbin/openrc-run
name="realm"
description="Realm TCP/UDP Relay"
command="$BIN"
command_args="-c $CONF"
command_user="root:root"
supervisor="supervise-daemon"
respawn_delay=3
respawn_max=0
rc_ulimit="-n 65535"
output_log="/var/log/realm.log"
error_log="/var/log/realm.log"

depend() {
  need net
}
SVC
    chmod 755 /etc/init.d/realm
  fi
}

service_exists() {
  if [[ "$INIT" == "systemd" ]]; then
    [[ -f /etc/systemd/system/realm.service ]]
  else
    [[ -f /etc/init.d/realm ]]
  fi
}

apply() {
  if ! gen_conf; then
    return 1
  fi
  service_exists || write_service

  if [[ "$(count_rules)" == "0" ]]; then
    svc stop >/dev/null 2>&1 || true
    svc disable >/dev/null 2>&1 || true
    warn "没有转发规则，Realm 服务已停止并取消开机启动"
    return 0
  fi

  fw_sync_all
  if ! svc enable; then
    warn "设置 Realm 开机启动失败"
  fi
  if ! svc restart >/dev/null 2>&1; then
    err "Realm 服务重启命令失败"
    return 1
  fi

  sleep 1
  if is_active; then
    ok "Realm 配置已应用，服务正在运行"
    return 0
  fi

  err "Realm 启动失败，请进入 [10] 查看日志"
  return 1
}

# ---------- 安装 / 更新 Realm ----------
install_realm() {
  local version arch asset_url work candidate old_backup
  ensure_tools || return 1

  read -r -p "Realm 版本（回车=latest，例如 v2.9.5）： " version
  version="${version:-latest}"

  case "$(uname -m)" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *)
      err "暂不支持当前架构：$(uname -m)（支持 x86_64、aarch64）"
      return 1
      ;;
  esac

  if [[ "$version" == "latest" ]]; then
    asset_url="https://github.com/zhboner/realm/releases/latest/download/realm-${arch}-unknown-linux-musl.tar.gz"
  else
    if [[ ! "$version" =~ ^v?[0-9A-Za-z._-]+$ ]]; then
      err "版本号格式不正确"
      return 1
    fi
    asset_url="https://github.com/zhboner/realm/releases/download/${version}/realm-${arch}-unknown-linux-musl.tar.gz"
  fi

  work="$(mktemp -d /tmp/realmm-install.XXXXXX)" || {
    err "无法创建临时目录"
    return 1
  }

  echo "下载：$asset_url"
  if ! download_file "$asset_url" "$work/realm.tar.gz"; then
    err "下载失败，请检查 GitHub 连通性或版本号"
    rm -rf "$work"
    return 1
  fi

  if ! tar -tzf "$work/realm.tar.gz" >/dev/null 2>&1; then
    err "下载文件不是有效的 tar.gz 压缩包"
    rm -rf "$work"
    return 1
  fi

  if ! tar -xzf "$work/realm.tar.gz" -C "$work"; then
    err "Realm 压缩包解压失败"
    rm -rf "$work"
    return 1
  fi

  candidate="$(find "$work" -type f -name realm -print -quit 2>/dev/null)"
  if [[ -z "$candidate" || ! -s "$candidate" ]]; then
    err "压缩包中没有找到 realm 可执行文件"
    rm -rf "$work"
    return 1
  fi

  if ! chmod 755 "$candidate" || ! "$candidate" --version >/dev/null 2>&1; then
    err "Realm 二进制文件无法正常运行，未替换当前版本"
    rm -rf "$work"
    return 1
  fi

  old_backup=""
  if [[ -x "$BIN" ]]; then
    old_backup="$BIN.bak.$(date +%Y%m%d%H%M%S)"
    cp -p "$BIN" "$old_backup" 2>/dev/null || old_backup=""
  fi

  if ! install -m 755 "$candidate" "$BIN.new"; then
    err "写入新版本失败，原版本未变更"
    rm -rf "$work"
    return 1
  fi

  if ! mv -f "$BIN.new" "$BIN"; then
    err "替换 Realm 二进制文件失败"
    rm -f "$BIN.new"
    rm -rf "$work"
    return 1
  fi

  rm -rf "$work"
  ok "Realm 安装完成：$("$BIN" --version 2>&1 | head -n 1)"
  [[ -n "$old_backup" ]] && echo "旧版本备份：$old_backup"

  write_service
  if [[ "$(count_rules)" != "0" ]]; then
    apply
  else
    svc stop >/dev/null 2>&1 || true
    svc disable >/dev/null 2>&1 || true
    echo "目前没有转发规则；添加规则后会自动启动服务。"
  fi
}

# ---------- 规则选择 ----------
show_brief() {
  local n=0 lp host tp nm
  while read -r lp host tp nm; do
    [[ -z "$lp" ]] && continue
    n=$((n+1))
    echo "  [$n] $nm   :$lp -> $host:$tp"
  done < "$RULES"
}

pick_rule() {
  local total
  total="$(count_rules)"
  [[ "$total" == "0" ]] && {
    warn "还没有转发规则"
    return 1
  }

  show_brief
  echo
  read -r -p "$1（回车取消）： " IDX
  [[ "$IDX" =~ ^[0-9]+$ ]] || return 1
  (( IDX >= 1 && IDX <= total )) || {
    err "编号无效"
    return 1
  }
}

# ---------- 添加规则 ----------
add_rule() {
  local target target_port listen_port name default a

  init_dir
  if [[ ! -x "$BIN" ]]; then
    warn "尚未安装 Realm"
    read -r -p "现在安装？[Y/n] " a
    case "$a" in n|N) return ;; esac
    install_realm || return
    [[ -x "$BIN" ]] || return
  fi

  default="$(default_name)"
  while :; do
    read -r -p "规则名称（可选，回车=$default）： " name
    name="$(clean_name "$name")"
    [[ -z "$name" ]] && name="$default"
    if (( ${#name} > 60 )); then
      err "名称不能超过 60 个字符"
      continue
    fi
    if name_used "$name"; then
      err "名称「$name」已存在，请换一个"
      continue
    fi
    break
  done

  read -r -p "目标地址（IPv4/IPv6/域名）： " target
  target="$(normalize_host "$target")"
  valid_host "$target" || {
    err "目标地址格式不正确"
    return
  }

  read -r -p "目标端口： " target_port
  valid_port "$target_port" || {
    err "目标端口无效（范围 1-65535）"
    return
  }
  target_port=$((10#$target_port))

  read -r -p "本机监听端口（回车=随机）： " listen_port
  if [[ -z "$listen_port" ]]; then
    listen_port="$(rand_port)" || {
      err "无法找到可用随机端口"
      return
    }
    echo "分配端口：$listen_port"
  fi

  valid_port "$listen_port" || {
    err "监听端口无效（范围 1-65535）"
    return
  }
  listen_port=$((10#$listen_port))

  if ! command -v ss >/dev/null 2>&1; then
    warn "缺少 ss，无法检查系统中其他程序是否占用该端口"
    read -r -p "仍然继续？[y/N] " a
    [[ "$a" == "y" || "$a" == "Y" ]] || return
  elif port_used "$listen_port"; then
    err "端口 $listen_port 已被规则占用或系统程序监听"
    return
  fi

  echo "正在检测目标 TCP 连通性..."
  if tcp_ok "$target" "$target_port"; then
    ok "本机到目标 $target:$target_port 的 TCP 连接正常"
  else
    warn "暂时无法连接目标；可能是目标端口未开放、目标防火墙拦截或网络不通"
    read -r -p "仍然添加规则？[y/N] " a
    [[ "$a" == "y" || "$a" == "Y" ]] || return
  fi

  printf '%s %s %s %s\n' "$listen_port" "$target" "$target_port" "$name" >> "$RULES"
  chmod 600 "$RULES"
  fw_open "$listen_port"
  apply

  get_ips
  echo
  echo "名称：$name"
  echo "转发：:$listen_port -> $target:$target_port"
  print_entry "$listen_port"
  echo "请同时检查云厂商安全组/面板端口映射，至少放行 TCP $listen_port。"
  [[ "$UDP" == "true" ]] && echo "当前 UDP 已启用，还需放行 UDP $listen_port。"
}

# ---------- 查看规则 ----------
list_rules() {
  local n=0 lp host tp nm status
  [[ "$(count_rules)" == "0" ]] && {
    warn "还没有转发规则，请选择 2 添加"
    return
  }

  get_ips
  echo
  while read -r lp host tp nm; do
    [[ -z "$lp" ]] && continue
    n=$((n+1))
    if is_listening "$lp"; then
      status="${G}TCP监听中${N}"
    else
      status="${R}TCP未监听${N}"
    fi
    echo "[$n] $nm  :$lp -> $host:$tp  ($status)"
    print_entry "$lp"
  done < "$RULES"
}

# ---------- 修改规则 ----------
edit_rule() {
  local old_lp old_host old_tp old_name new_host new_tp new_lp

  pick_rule "要修改的规则编号" || return
  read -r old_lp old_host old_tp old_name <<< "$(sed -n "${IDX}p" "$RULES")"

  read -r -p "新目标地址（回车保持 $old_host）： " new_host
  new_host="${new_host:-$old_host}"
  new_host="$(normalize_host "$new_host")"
  valid_host "$new_host" || {
    err "目标地址格式不正确"
    return
  }

  read -r -p "新目标端口（回车保持 $old_tp）： " new_tp
  new_tp="${new_tp:-$old_tp}"
  valid_port "$new_tp" || {
    err "目标端口无效"
    return
  }
  new_tp=$((10#$new_tp))

  read -r -p "新监听端口（回车保持 $old_lp）： " new_lp
  new_lp="${new_lp:-$old_lp}"
  valid_port "$new_lp" || {
    err "监听端口无效"
    return
  }
  new_lp=$((10#$new_lp))

  if [[ "$new_lp" != "$old_lp" ]]; then
    if port_used "$new_lp" "$IDX"; then
      err "端口 $new_lp 已被规则占用或系统程序监听"
      return
    fi
    if ! command -v ss >/dev/null 2>&1; then
      warn "缺少 ss，无法确认系统中其他程序是否占用新端口"
      read -r -p "仍然继续修改？[y/N] " answer
      [[ "$answer" == "y" || "$answer" == "Y" ]] || return
    fi
  fi

  replace_rule "$IDX" "$new_lp" "$new_host" "$new_tp" "$old_name" || {
    err "更新规则文件失败"
    return
  }

  if [[ "$new_lp" != "$old_lp" ]]; then
    fw_close "$old_lp"
    fw_open "$new_lp"
  fi

  apply
  get_ips
  echo "[$old_name] :$new_lp -> $new_host:$new_tp"
  print_entry "$new_lp"
}

# ---------- 规则改名 ----------
rename_rule() {
  local lp host tp old_name new_name tmp

  pick_rule "要改名的规则编号" || return
  read -r lp host tp old_name <<< "$(sed -n "${IDX}p" "$RULES")"

  read -r -p "新名称（回车保持「$old_name」）： " new_name
  new_name="$(clean_name "$new_name")"
  [[ -z "$new_name" ]] && {
    echo "未修改"
    return
  }

  (( ${#new_name} <= 60 )) || {
    err "名称不能超过 60 个字符"
    return
  }
  name_used "$new_name" "$IDX" && {
    err "名称「$new_name」已存在"
    return
  }

  replace_rule "$IDX" "$lp" "$host" "$tp" "$new_name" || {
    err "更新规则文件失败"
    return
  }

  gen_conf
  ok "已改名：$old_name -> $new_name（无需重启服务）"
}

# ---------- 删除规则 ----------
delete_rule() {
  local lp host tp name answer tmp

  pick_rule "要删除的规则编号" || return
  read -r lp host tp name <<< "$(sed -n "${IDX}p" "$RULES")"

  read -r -p "确认删除「$name」 :$lp -> $host:$tp？[y/N] " answer
  [[ "$answer" == "y" || "$answer" == "Y" ]] || {
    echo "已取消"
    return
  }

  tmp="$(mktemp "$RULES.XXXXXX")" || return
  awk -v n="$IDX" 'NF { i++; if (i != n) print }' "$RULES" > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$RULES"

  fw_close "$lp"
  apply
  ok "规则已删除"
}

# ---------- 服务操作 ----------
do_start() {
  [[ -x "$BIN" ]] || {
    err "尚未安装 Realm"
    return
  }
  [[ "$(count_rules)" != "0" ]] || {
    err "没有转发规则，请先添加"
    return
  }

  gen_conf || return
  service_exists || write_service
  svc enable
  svc start >/dev/null 2>&1
  sleep 1
  if is_active; then
    ok "Realm 已启动"
  else
    err "启动失败，请查看 [10] 状态/日志"
  fi
}

do_stop() {
  svc stop >/dev/null 2>&1
  sleep 1
  if is_active; then
    err "停止失败"
  else
    ok "Realm 已停止"
  fi
}

do_restart() {
  [[ -x "$BIN" ]] || {
    err "尚未安装 Realm"
    return
  }
  [[ "$(count_rules)" != "0" ]] || {
    err "没有转发规则，请先添加"
    return
  }

  gen_conf || return
  service_exists || write_service
  svc enable
  svc restart >/dev/null 2>&1
  sleep 1
  if is_active; then
    ok "Realm 已重启"
  else
    err "重启失败，请查看 [10] 状态/日志"
  fi
}

show_status() {
  echo
  echo "服务管理器：$INIT"
  echo "配置文件：$CONF"
  echo "转发规则：$(count_rules) 条"
  echo "UDP 转发：$([[ "$UDP" == "true" ]] && echo 开启 || echo 关闭)"

  if [[ -x "$BIN" ]]; then
    echo "Realm 版本：$("$BIN" --version 2>&1 | head -n 1)"
  else
    echo "Realm 版本：未安装"
  fi

  if is_active; then
    ok "服务运行中"
  else
    err "服务未运行"
  fi

  echo
  echo "--- Realm 相关监听（TCP/UDP）---"
  if command -v ss >/dev/null 2>&1; then
    ss -lntup 2>/dev/null | grep -E 'realm|State|Netid' || echo "未发现 realm 进程监听信息"
  else
    echo "缺少 ss 命令"
  fi

  echo
  echo "--- 最近日志 ---"
  if [[ "$INIT" == "systemd" ]]; then
    journalctl -u realm -n 25 --no-pager 2>/dev/null || true
  else
    tail -n 25 /var/log/realm.log 2>/dev/null || echo "暂无日志"
  fi
}

# ---------- 连通性测试 ----------
test_rules() {
  local n=0 lp host tp name

  [[ "$(count_rules)" != "0" ]] || {
    warn "还没有转发规则"
    return
  }

  echo
  while read -r lp host tp name; do
    [[ -z "$lp" ]] && continue
    n=$((n+1))
    echo "[$n] $name  :$lp -> $host:$tp"

    if is_listening "$lp"; then
      ok "本机 TCP 端口 $lp 正在监听"
    else
      err "本机 TCP 端口 $lp 未监听"
    fi

    if tcp_ok "$host" "$tp"; then
      ok "本机到目标 $host:$tp 的 TCP 连接正常"
    else
      err "本机到目标 $host:$tp 的 TCP 连接失败"
    fi

    if tcp_ok 127.0.0.1 "$lp"; then
      ok "本机回环地址可以连接监听端口"
      warn "这只验证本地 TCP 接入，不代表代理业务数据已成功转发"
    else
      err "本机回环地址无法连接监听端口"
    fi

    if command -v ping >/dev/null 2>&1; then
      echo -n "目标 ICMP 延迟："
      ping -c 2 -W 2 "$host" 2>/dev/null | tail -n 1
    fi
    echo
  done < "$RULES"

  if [[ "$UDP" == "true" ]]; then
    warn "UDP 已启用；本菜单不做 UDP 业务层验证，请使用对应 UDP 客户端实际测试"
  fi
}

# ---------- UDP 开关 ----------
toggle_udp() {
  if [[ "$UDP" == "true" ]]; then
    UDP=false
  else
    UDP=true
  fi

  save_set
  ok "UDP 转发已切换为：$UDP"
  fw_sync_all
  [[ "$(count_rules)" != "0" ]] && apply
}

# ---------- 卸载 ----------
uninstall_realm() {
  local answer lp host tp name

  read -r -p "确认卸载 Realm 并移除服务？输入 yes 确认： " answer
  [[ "$answer" == "yes" ]] || {
    echo "已取消"
    return
  }

  svc stop >/dev/null 2>&1 || true
  svc disable >/dev/null 2>&1 || true

  while read -r lp host tp name; do
    [[ -n "$lp" ]] && fw_close "$lp"
  done < "$RULES"

  if [[ "$INIT" == "systemd" ]]; then
    rm -f /etc/systemd/system/realm.service
    systemctl daemon-reload
  else
    rm -f /etc/init.d/realm
  fi

  rm -f "$BIN" "$BIN.new"

  read -r -p "同时删除配置和规则（$RULE_DIR）？[y/N] " answer
  case "$answer" in
    y|Y) rm -rf "$RULE_DIR" ;;
  esac

  ok "Realm 已卸载"
  echo "管理器命令 realmm 保留；如需删除，请手动执行：rm -f $MANAGER"
}

# ---------- 菜单 ----------
header() {
  local version status
  printf '\033[H\033[2J'
  echo "${B}================================================${N}"
  echo "${W}              Realm 转发管理面板${N}"
  echo "${B}================================================${N}"

  if [[ -x "$BIN" ]]; then
    version="$("$BIN" --version 2>/dev/null | head -n 1)"
    version="${G}${version}${N}"
  else
    version="${R}未安装${N}"
  fi

  if is_active; then
    status="${G}运行中${N}"
  else
    status="${R}未运行${N}"
  fi

  echo " Realm：$version"
  echo " 服务：$status    管理器：$INIT    规则：$(count_rules) 条"
  echo " UDP：$([[ "$UDP" == "true" ]] && echo 开启 || echo 关闭)    快捷命令：realmm"
  echo "${B}------------------------------------------------${N}"
}

# ---------- 主程序 ----------
install_manager
ensure_tools || warn "部分检测功能可能不可用；仍可继续使用菜单"
import_existing
fix_names

while true; do
  header
  echo "  1) 安装 / 更新 Realm"
  echo "  2) 添加转发规则"
  echo "  3) 查看转发规则和入口地址"
  echo "  4) 修改转发规则"
  echo "  5) 规则改名"
  echo "  6) 删除转发规则"
  echo "  7) 启动服务"
  echo "  8) 停止服务"
  echo "  9) 重启服务"
  echo " 10) 状态 / 日志"
  echo " 11) 连通性测试"
  echo " 12) UDP 转发开关"
  echo " 13) 卸载 Realm"
  echo "  0) 退出"
  echo "${B}------------------------------------------------${N}"
  if ! read -r -p "请选择 [0-13]： " choice; then
    echo
    echo "检测到输入结束，退出。"
    exit 0
  fi
  echo

  case "$choice" in
    1)  install_realm ;;
    2)  add_rule ;;
    3)  list_rules ;;
    4)  edit_rule ;;
    5)  rename_rule ;;
    6)  delete_rule ;;
    7)  do_start ;;
    8)  do_stop ;;
    9)  do_restart ;;
    10) show_status ;;
    11) test_rules ;;
    12) toggle_udp ;;
    13) uninstall_realm ;;
    0)  echo "再见"; exit 0 ;;
    *)  warn "无效选择" ;;
  esac

  pause
done
