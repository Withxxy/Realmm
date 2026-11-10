#!/usr/bin/env bash
# Realmm 2.0 - Realm 配置管理 / AI 配置 / 旧版迁移
# 配置唯一数据源：/etc/realm/config.toml
# 不再通过 rules.list 重建配置，避免覆盖 AI 写入的自定义 TOML 参数。

VERSION="2.2.0"
umask 077

RULE_DIR="/etc/realm"
CONF="$RULE_DIR/config.toml"
BACKUP_DIR="$RULE_DIR/backups"
BIN="/usr/local/bin/realm"
MANAGER="/usr/local/bin/realmm"
LEGACY_DIR="/opt/realm"
LEGACY_CONF="$LEGACY_DIR/config.toml"
LEGACY_RULES="$LEGACY_DIR/endpoints.dat"
LEGACY_BIN="$LEGACY_DIR/realm"
SCRIPT_URL="${REALMM_SCRIPT_URL:-https://raw.githubusercontent.com/Withxxy/Realmm/main/realmm.sh}"

INIT=""
V4=""
V6=""
IPS_DONE=""
FW_WARNED=""

# Endpoint fields are loaded from config.toml; no separate rules.list is authoritative.
declare -a EP_NAMES=() EP_LISTENS=() EP_REMOTES=() EP_TYPES=() EP_FIELDS=() PAUSED_NAMES=() PAUSED_LISTENS=() PAUSED_REMOTES=() PAUSED_TYPES=() PAUSED_FIELDS=()

R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[36m'; W=$'\033[1m'; N=$'\033[0m'

ok()   { printf '%s✔ %s%s\n' "$G" "$*" "$N"; }
err()  { printf '%s✘ %s%s\n' "$R" "$*" "$N"; }
warn() { printf '%s! %s%s\n' "$Y" "$*" "$N"; }
pause() { echo; read -r -p "按回车返回菜单..." _ || exit 0; }

if [[ "${1:-}" == "--self-test" ]]; then
  INIT="systemd"
else
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
fi

mkdir -p "$RULE_DIR" "$BACKUP_DIR"
chmod 700 "$RULE_DIR" "$BACKUP_DIR" 2>/dev/null || true

# ---------- Manager self-install / update ----------
download_file() {
  local url="$1" output="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fLsS --retry 2 --connect-timeout 10 --max-time 180 -o "$output" "$url" 2>/dev/null && [[ -s "$output" ]] && return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -q --tries=2 --timeout=20 -O "$output" "$url" 2>/dev/null && [[ -s "$output" ]] && return 0
  fi
  return 1
}

install_manager() {
  local src resolved tmp
  src="${BASH_SOURCE[0]:-$0}"

  # Process substitution paths (/dev/fd/N) are streams, not persistent source files.
  if [[ -f "$src" && "$src" != /dev/fd/* && "$src" != /proc/* && "$src" != /dev/stdin ]]; then
    resolved="$(readlink -f "$src" 2>/dev/null || printf '%s' "$src")"
    if [[ "$resolved" != "$MANAGER" ]]; then
      if install -m 755 "$resolved" "$MANAGER" 2>/dev/null; then
        ok "管理命令已同步：以后输入 realmm 即可启动"
      else
        warn "无法写入 $MANAGER；不影响本次运行"
      fi
    fi
    return 0
  fi

  tmp="$(mktemp 2>/dev/null)" || return 1
  if download_file "$SCRIPT_URL" "$tmp" && bash -n "$tmp" >/dev/null 2>&1; then
    if install -m 755 "$tmp" "$MANAGER" 2>/dev/null; then
      ok "已从 GitHub 同步 realmm 快捷命令"
    else
      warn "无法写入 $MANAGER；不影响本次运行"
    fi
  else
    warn "无法从 GitHub 同步快捷命令；不影响本次运行"
  fi
  rm -f "$tmp"
}

# ---------- Script self-update ----------
update_script() {
  local tmp remote_ver stamp backup="" ans
  echo "当前脚本版本：$VERSION"
  echo "更新源：$SCRIPT_URL"
  tmp="$(mktemp /tmp/realmm-update.XXXXXX)" || { err "无法创建临时文件"; return 1; }
  echo "正在检查更新..."
  if ! download_file "$SCRIPT_URL" "$tmp"; then
    err "下载失败：请检查网络能否访问 GitHub；当前脚本未修改"
    rm -f "$tmp"; return 1
  fi
  if ! head -n 1 "$tmp" | grep -q '^#!.*bash' || ! grep -q '^VERSION="' "$tmp"; then
    err "下载内容不像 realmm 脚本（可能是错误页面或链接失效）；当前脚本未修改"
    rm -f "$tmp"; return 1
  fi
  if ! bash -n "$tmp" >/dev/null 2>&1; then
    err "新脚本语法检查未通过，已放弃更新；当前脚本未修改"
    rm -f "$tmp"; return 1
  fi
  remote_ver="$(sed -n 's/^VERSION="\([^"]*\)".*/\1/p' "$tmp" | head -n 1)"
  echo "最新版本：${remote_ver:-未知}"
  if [[ -f "$MANAGER" ]] && cmp -s "$tmp" "$MANAGER"; then
    ok "已是最新版本，无需更新"
    rm -f "$tmp"; return 0
  fi
  [[ "$remote_ver" == "$VERSION" ]] && warn "版本号相同，但文件内容有差异（可能是小修订）"
  read -r -p "更新到 ${remote_ver:-最新版}？[Y/n] " ans
  case "$ans" in n|N) echo "已取消"; rm -f "$tmp"; return 0 ;; esac

  stamp="$(date +%Y%m%d-%H%M%S)"
  if [[ -f "$MANAGER" ]]; then
    backup="$BACKUP_DIR/realmm-script-$stamp"
    cp -p "$MANAGER" "$backup" || { err "备份当前脚本失败，已放弃更新"; rm -f "$tmp"; return 1; }
  fi
  if ! install -m 755 "$tmp" "$MANAGER.new" || ! mv -f "$MANAGER.new" "$MANAGER"; then
    err "写入 $MANAGER 失败；当前脚本未修改"
    rm -f "$tmp" "$MANAGER.new"; return 1
  fi
  rm -f "$tmp"
  ok "脚本已更新为 ${remote_ver:-最新版}"
  [[ -n "$backup" ]] && echo "旧版本备份：$backup（如有问题：cp -p $backup $MANAGER）"
  echo "提示：Realm 服务与转发配置不受影响。"
  read -r -p "立即用新版重新启动？[Y/n] " ans
  case "$ans" in n|N) echo "下次输入 realmm 即为新版"; return 0 ;; esac
  exec "$MANAGER"
}

# ---------- Dependencies / TOML parser ----------
toml_module_available() {
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - <<'PY' >/dev/null 2>&1
try:
    import tomllib
except ImportError:
    import tomli
PY
}

ensure_toml_parser() {
  if toml_module_available; then return 0; fi
  warn "需要 Python 3.11+ 的 tomllib，或安装 tomli，才能安全解析 TOML。"
  read -r -p "是否尝试安装 Python TOML 解析依赖？[Y/n] " ans
  case "$ans" in n|N) return 1 ;; esac
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y -qq python3 python3-tomli >/dev/null 2>&1 || apt-get install -y -qq python3 >/dev/null 2>&1 || true
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache python3 py3-tomli >/dev/null 2>&1 || apk add --no-cache python3 >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q python3 >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q python3 >/dev/null 2>&1 || true
  fi
  if toml_module_available; then ok "TOML 解析依赖已就绪"; return 0; fi
  err "仍未找到 tomllib/tomli。请安装 Python 3.11+ 或 tomli 后重试。"
  return 1
}

ensure_tools() {
  local missing=()
  command -v python3 >/dev/null 2>&1 || missing+=(python3)
  command -v tar >/dev/null 2>&1 || missing+=(tar)
  command -v ss >/dev/null 2>&1 || missing+=(iproute2/ss)
  command -v timeout >/dev/null 2>&1 || missing+=(timeout)
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then missing+=(curl/wget); fi
  if ((${#missing[@]})); then
    warn "缺少依赖：${missing[*]}"
    read -r -p "是否尝试安装？[Y/n] " ans
    case "$ans" in n|N) return 1 ;; esac
    if command -v apt-get >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq && apt-get install -y python3 tar iproute2 coreutils ca-certificates curl wget
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache python3 tar iproute2 coreutils ca-certificates curl wget
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y python3 tar iproute coreutils ca-certificates curl wget
    elif command -v yum >/dev/null 2>&1; then
      yum install -y python3 tar iproute coreutils ca-certificates curl wget
    else
      err "无法识别包管理器，请手动安装缺少的依赖"
      return 1
    fi || return 1
  fi
  ensure_toml_parser
}

# ---------- TOML helper ----------
# All config operations preserve unrelated TOML sections and endpoint-specific options.
toml_tool() {
  python3 - "$@" <<'PY'
import base64
import json
import os
import re
import sys
import tempfile

try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib
    except ImportError:
        print("缺少 tomllib/tomli", file=sys.stderr)
        sys.exit(20)

op = sys.argv[1]
path = sys.argv[2]


def read_config(p):
    with open(p, "rb") as f:
        data = tomllib.load(f)
    if not isinstance(data, dict):
        raise ValueError("TOML 根节点必须是表")
    eps = data.get("endpoints", [])
    if eps is None:
        eps = []
    if not isinstance(eps, list):
        raise ValueError("endpoints 必须是数组表 [[endpoints]]")
    for n, ep in enumerate(eps, 1):
        if not isinstance(ep, dict):
            raise ValueError(f"第 {n} 条 endpoint 不是有效表")
        if "listen" not in ep or "remote" not in ep:
            raise ValueError(f"第 {n} 条 endpoint 缺少 listen 或 remote")
    return data, eps


def read_lines(p):
    with open(p, "r", encoding="utf-8", newline="") as f:
        return f.read().splitlines(keepends=True)


def write_lines(p, lines):
    directory = os.path.dirname(os.path.abspath(p)) or "."
    fd, tmp = tempfile.mkstemp(prefix=".realmm-", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
            f.writelines(lines)
        os.chmod(tmp, 0o600)
        os.replace(tmp, p)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def endpoint_headers(lines):
    return [i for i, line in enumerate(lines) if re.match(r"^\s*\[\[endpoints\]\]\s*(?:#.*)?$", line.rstrip("\r\n"))]


def is_root_header(line):
    s = line.strip()
    if not (s.startswith("[") and s.endswith("]")):
        return False
    if re.match(r"^\[\[endpoints\]\]\s*(?:#.*)?$", s):
        return True
    if re.match(r"^\[+endpoints\.[^]]+\]+", s):
        return False
    inner = s.strip("[]")
    if "." in inner:
        return False
    return True


def endpoint_block(lines, index):
    starts = endpoint_headers(lines)
    if index < 1 or index > len(starts):
        raise ValueError("规则编号无效")
    start = starts[index - 1]
    end = len(lines)
    for j in range(start + 1, len(lines)):
        s = lines[j].strip()
        if re.match(r"^\[\[endpoints\]\]\s*(?:#.*)?$", s):
            end = j
            break
        if is_root_header(s):
            end = j
            break
    return start, end


def marker_name_map(lines):
    result = {}
    pending = None
    number = 0
    in_disabled = False
    for line in lines:
        token = line.strip()
        if token == "# realmm-disabled-begin":
            in_disabled = True
            pending = None
            continue
        if token == "# realmm-disabled-end":
            in_disabled = False
            pending = None
            continue
        if in_disabled:
            continue
        m = re.match(r"^\s*#\s*realmm-name-b64:\s*([A-Za-z0-9_+/=-]+)\s*$", line.rstrip("\r\n"))
        if m:
            pending = m.group(1)
            continue
        if re.match(r"^\s*\[\[endpoints\]\]\s*(?:#.*)?$", line.rstrip("\r\n")):
            number += 1
            if pending is not None:
                try:
                    result[number] = base64.b64decode(pending).decode("utf-8")
                except Exception:
                    pass
            pending = None
        elif is_root_header(line) and not line.strip().startswith("[[endpoints]]"):
            pending = None
    return result


def disabled_ranges(lines):
    ranges = []
    start = None
    for i, line in enumerate(lines):
        token = line.strip()
        if token == "# realmm-disabled-begin":
            if start is not None:
                raise ValueError("发现嵌套的暂停规则标记")
            start = i
        elif token == "# realmm-disabled-end":
            if start is None:
                raise ValueError("发现没有开始标记的暂停规则")
            ranges.append((start, i + 1))
            start = None
    if start is not None:
        raise ValueError("暂停规则缺少结束标记")
    return ranges


def uncomment_disabled(lines):
    result = []
    for line in lines:
        if line.startswith("# "):
            result.append(line[2:])
        elif line.startswith("#"):
            result.append(line[1:])
        else:
            result.append(line)
    text = "".join(result)
    data = tomllib.loads(text)
    eps = data.get("endpoints", [])
    if not isinstance(eps, list) or len(eps) != 1:
        raise ValueError("暂停规则块必须且只能包含一条 [[endpoints]]")
    ep = eps[0]
    if "listen" not in ep or "remote" not in ep:
        raise ValueError("暂停规则缺少 listen 或 remote")
    return ep


def disabled_entries(lines):
    entries = []
    for start, end in disabled_ranges(lines):
        block = lines[start + 1:end - 1]
        ep = uncomment_disabled(block)
        name = None
        for line in block:
            m = re.match(r"^\s*#\s*#?\s*realmm-name-b64:\s*([A-Za-z0-9_+/=-]+)\s*$", line.rstrip("\r\n"))
            if m:
                try:
                    name = base64.b64decode(m.group(1)).decode("utf-8")
                except Exception:
                    pass
        if not name:
            name = ep.get("name") or f"暂停规则{len(entries)+1}"
        entries.append((start, end, name, ep))
    return entries


def encode_name(name):
    return base64.b64encode(name.encode("utf-8")).decode("ascii")


def toml_string(value):
    return json.dumps(str(value), ensure_ascii=False)


def set_endpoint_field(lines, index, key, value):
    start, end = endpoint_block(lines, index)
    field_end = end
    for j in range(start + 1, end):
        if re.match(r"^\s*\[+endpoints\.[^]]+\]+", lines[j].strip()):
            field_end = j
            break
    pattern = re.compile(r"^(\s*)" + re.escape(key) + r"\s*=")
    found = False
    for j in range(start + 1, field_end):
        m = pattern.match(lines[j])
        if m:
            newline = "\r\n" if lines[j].endswith("\r\n") else "\n"
            lines[j] = f"{m.group(1)}{key} = {toml_string(value)}{newline}"
            found = True
            break
    if not found:
        lines.insert(start + 1, f"{key} = {toml_string(value)}\n")
    return lines


if op == "validate":
    data, eps = read_config(path)
    print(f"TOML 语法正常；检测到 {len(eps)} 条有效 endpoint")
elif op == "count":
    _, eps = read_config(path)
    print(len(eps))
elif op == "list":
    data, eps = read_config(path)
    lines = read_lines(path)
    names = marker_name_map(lines)
    out = sys.stdout.buffer
    for i, ep in enumerate(eps, 1):
        name = names.get(i) or ep.get("name") or f"规则{i}"
        fields = [str(name), str(ep.get("listen", "")), str(ep.get("remote", "")), str(ep.get("type", ""))]
        for field in fields:
            out.write(field.encode("utf-8", "replace") + b"\0")
elif op == "paused-list":
    lines = read_lines(path)
    out = sys.stdout.buffer
    for _, _, name, ep in disabled_entries(lines):
        fields = [str(name), str(ep.get("listen", "")), str(ep.get("remote", "")), str(ep.get("type", ""))]
        for field in fields:
            out.write(field.encode("utf-8", "replace") + b"\0")
elif op == "paused-count":
    print(len(disabled_entries(read_lines(path))))
elif op == "pause":
    _, eps = read_config(path)
    index = int(sys.argv[3])
    lines = read_lines(path)
    start, end = endpoint_block(lines, index)
    block_start = start
    if start > 0 and re.match(r"^\s*#\s*realmm-name-b64:", lines[start - 1]):
        block_start = start - 1
    block = lines[block_start:end]
    wrapped = ["# realmm-disabled-begin\n"] + ["# " + line if line.strip() else "#\n" for line in block] + ["# realmm-disabled-end\n"]
    lines[block_start:end] = wrapped
    write_lines(path, lines)
    read_config(path)
    disabled_entries(read_lines(path))
elif op == "resume":
    lines = read_lines(path)
    entries = disabled_entries(lines)
    index = int(sys.argv[3])
    if index < 1 or index > len(entries):
        raise ValueError("暂停规则编号无效")
    start, end, _, _ = entries[index - 1]
    block = lines[start + 1:end - 1]
    active = []
    for line in block:
        if line.startswith("# "):
            active.append(line[2:])
        elif line.startswith("#"):
            active.append(line[1:])
        else:
            active.append(line)
    lines[start:end] = active
    write_lines(path, lines)
    read_config(path)
elif op == "add":
    _, eps = read_config(path)
    name, listen, remote = sys.argv[3:6]
    lines = read_lines(path)
    if lines and not lines[-1].endswith(("\n", "\r")):
        lines[-1] += "\n"
    if lines and lines[-1].strip():
        lines.append("\n")
    lines.extend([
        f"# realmm-name-b64: {encode_name(name)}\n",
        "[[endpoints]]\n",
        f"listen = {toml_string(listen)}\n",
        f"remote = {toml_string(remote)}\n",
        "\n",
    ])
    write_lines(path, lines)
    read_config(path)
elif op == "set":
    _, eps = read_config(path)
    index, key, value = int(sys.argv[3]), sys.argv[4], sys.argv[5]
    if key not in ("listen", "remote"):
        raise ValueError("仅允许修改 listen 或 remote")
    lines = read_lines(path)
    lines = set_endpoint_field(lines, index, key, value)
    write_lines(path, lines)
    read_config(path)
elif op == "rename":
    _, eps = read_config(path)
    index, name = int(sys.argv[3]), sys.argv[4]
    lines = read_lines(path)
    start, _ = endpoint_block(lines, index)
    marker_re = re.compile(r"^\s*#\s*realmm-name-b64:")
    marker = f"# realmm-name-b64: {encode_name(name)}\n"
    if start > 0 and marker_re.match(lines[start - 1]):
        lines[start - 1] = marker
    else:
        lines.insert(start, marker)
    write_lines(path, lines)
    read_config(path)
elif op == "delete":
    _, eps = read_config(path)
    index = int(sys.argv[3])
    lines = read_lines(path)
    start, end = endpoint_block(lines, index)
    if start > 0 and re.match(r"^\s*#\s*realmm-name-b64:", lines[start - 1]):
        start -= 1
    del lines[start:end]
    write_lines(path, lines)
    read_config(path)
elif op == "udp":
    _, eps = read_config(path)
    value = "true" if sys.argv[3].lower() in ("1", "true", "yes", "on") else "false"
    lines = read_lines(path)
    network_start = None
    network_end = len(lines)
    for i, line in enumerate(lines):
        s = line.strip()
        if re.match(r"^\[network\]\s*(?:#.*)?$", s):
            network_start = i
            for j in range(i + 1, len(lines)):
                if is_root_header(lines[j]):
                    network_end = j
                    break
            break
    if network_start is None:
        if lines and lines[-1].strip():
            lines.append("\n")
        lines.extend(["[network]\n", f"use_udp = {value}\n"])
    else:
        found = False
        for j in range(network_start + 1, network_end):
            m = re.match(r"^(\s*)use_udp\s*=", lines[j])
            if m:
                newline = "\r\n" if lines[j].endswith("\r\n") else "\n"
                lines[j] = f"{m.group(1)}use_udp = {value}{newline}"
                found = True
                break
        if not found:
            lines.insert(network_start + 1, f"use_udp = {value}\n")
    write_lines(path, lines)
    read_config(path)
elif op == "append-legacy":
    _, eps = read_config(path)
    legacy_path = sys.argv[3]
    if eps:
        raise ValueError("当前配置已有 endpoint，不会从 endpoints.dat 重复导入")
    lines = read_lines(path)
    added = 0
    with open(legacy_path, "r", encoding="utf-8", errors="replace") as f:
        for raw in f:
            raw = raw.strip()
            if not raw or "|" not in raw:
                continue
            listen, remote = raw.split("|", 1)
            listen, remote = listen.strip(), remote.strip()
            if not listen or not remote:
                continue
            if lines and not lines[-1].endswith(("\n", "\r")):
                lines[-1] += "\n"
            if lines and lines[-1].strip():
                lines.append("\n")
            name = f"规则{added + 1}"
            lines.extend([
                f"# realmm-name-b64: {encode_name(name)}\n",
                "[[endpoints]]\n",
                f"listen = {toml_string(listen)}\n",
                f"remote = {toml_string(remote)}\n",
                "\n",
            ])
            added += 1
    if added == 0:
        raise ValueError("endpoints.dat 中没有可识别的 listen|remote 记录")
    write_lines(path, lines)
    read_config(path)
    print(added)
else:
    raise ValueError(f"未知 TOML 操作：{op}")
PY
}

toml_validate() { toml_tool validate "$1"; }
toml_count() { toml_tool count "$1"; }

load_endpoints() {
  EP_NAMES=(); EP_LISTENS=(); EP_REMOTES=(); EP_TYPES=(); EP_FIELDS=()
  [[ -s "$CONF" ]] || return 0
  mapfile -d '' -t EP_FIELDS < <(toml_tool list "$CONF" 2>/dev/null)
  local i=0
  while (( i + 3 < ${#EP_FIELDS[@]} )); do
    EP_NAMES+=("${EP_FIELDS[i]}")
    EP_LISTENS+=("${EP_FIELDS[i+1]}")
    EP_REMOTES+=("${EP_FIELDS[i+2]}")
    EP_TYPES+=("${EP_FIELDS[i+3]}")
    i=$((i+4))
  done
}

load_paused_endpoints() {
  PAUSED_NAMES=(); PAUSED_LISTENS=(); PAUSED_REMOTES=(); PAUSED_TYPES=(); PAUSED_FIELDS=()
  [[ -s "$CONF" ]] || return 0
  mapfile -d '' -t PAUSED_FIELDS < <(toml_tool paused-list "$CONF" 2>/dev/null)
  local i=0
  while (( i + 3 < ${#PAUSED_FIELDS[@]} )); do
    PAUSED_NAMES+=("${PAUSED_FIELDS[i]}")
    PAUSED_LISTENS+=("${PAUSED_FIELDS[i+1]}")
    PAUSED_REMOTES+=("${PAUSED_FIELDS[i+2]}")
    PAUSED_TYPES+=("${PAUSED_FIELDS[i+3]}")
    i=$((i+4))
  done
}

backup_config() {
  local ts dest
  [[ -s "$CONF" ]] || return 0
  mkdir -p "$BACKUP_DIR"
  ts="$(date +%Y%m%d-%H%M%S)"
  dest="$BACKUP_DIR/config-$ts.toml"
  [[ -e "$dest" ]] && dest="$BACKUP_DIR/config-$ts-$$.toml"
  cp -p "$CONF" "$dest" || return 1
  chmod 600 "$dest" 2>/dev/null || true
  printf '%s' "$dest"
}

restore_config_file() {
  local source="$1"
  [[ -s "$source" ]] || return 1
  cp -p "$source" "$CONF"
  chmod 600 "$CONF" 2>/dev/null || true
}

ensure_config_file() {
  if [[ ! -s "$CONF" ]]; then
    cat > "$CONF" <<'TOML'
[network]
no_tcp = false
use_udp = false

TOML
    chmod 600 "$CONF"
  fi
}

# ---------- Service detection ----------
service_execstart() {
  if [[ "$INIT" == "systemd" ]]; then
    systemctl show realm -p ExecStart --value 2>/dev/null
  elif [[ -f /etc/init.d/realm ]]; then
    grep -E '^(command|command_args)=' /etc/init.d/realm 2>/dev/null || true
  fi
}

service_exists() {
  if [[ "$INIT" == "systemd" ]]; then
    [[ -f /etc/systemd/system/realm.service ]] || [[ "$(systemctl show realm -p LoadState --value 2>/dev/null)" == "loaded" ]]
  else
    [[ -f /etc/init.d/realm ]]
  fi
}

service_active() {
  if [[ "$INIT" == "systemd" ]]; then
    systemctl is-active --quiet realm 2>/dev/null
  else
    rc-service realm status >/dev/null 2>&1
  fi
}

is_legacy_service() {
  local exec
  [[ "$INIT" == "systemd" ]] || return 1
  exec="$(service_execstart)"
  [[ -n "$exec" && "$exec" != *"$BIN"* ]]
}

legacy_detected() {
  [[ -x "$LEGACY_BIN" && -s "$LEGACY_CONF" ]]
}

refuse_if_legacy() {
  if is_legacy_service; then
    err "检测到旧版 Realm 服务：$(service_execstart)"
    warn "请先执行菜单 [15] 旧版迁移；迁移前不会修改或重启旧服务。"
    return 0
  fi
  return 1
}

svc() {
  local action="$1"
  if [[ "$INIT" == "systemd" ]]; then
    case "$action" in
      enable) systemctl enable realm >/dev/null 2>&1 ;;
      disable) systemctl disable realm >/dev/null 2>&1 ;;
      *) systemctl "$action" realm ;;
    esac
  else
    case "$action" in
      enable) rc-update add realm default >/dev/null 2>&1 ;;
      disable) rc-update del realm default >/dev/null 2>&1 ;;
      *) rc-service realm "$action" ;;
    esac
  fi
}

write_service() {
  if [[ "$INIT" == "systemd" ]]; then
    local tmp
    tmp="$(mktemp /etc/systemd/system/realm.service.XXXXXX)" || return 1
    cat > "$tmp" <<SERVICE
[Unit]
Description=Realm TCP/UDP Relay (managed by Realmm)
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
SERVICE
    chmod 644 "$tmp"
    mv -f "$tmp" /etc/systemd/system/realm.service || return 1
    systemctl daemon-reload
  else
    cat > /etc/init.d/realm <<SERVICE
#!/sbin/openrc-run
name="realm"
description="Realm TCP/UDP Relay (managed by Realmm)"
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
SERVICE
    chmod 755 /etc/init.d/realm
  fi
}

# ---------- Network / firewall helpers ----------
valid_port() {
  [[ "$1" =~ ^[0-9]{1,5}$ ]] || return 1
  local p=$((10#$1))
  (( p >= 1 && p <= 65535 ))
}

valid_hostport() {
  python3 - "$1" <<'PY' >/dev/null 2>&1
import ipaddress, re, sys
s=sys.argv[1]
if s.startswith('['):
    m=re.fullmatch(r'\[([0-9A-Fa-f:.]+)\]:(\d{1,5})', s)
    if not m: raise SystemExit(1)
    ipaddress.IPv6Address(m.group(1)); port=int(m.group(2))
else:
    if s.count(':') != 1: raise SystemExit(1)
    host, p=s.rsplit(':',1)
    if not host or not p.isdigit(): raise SystemExit(1)
    port=int(p)
    try: ipaddress.ip_address(host)
    except ValueError:
        if len(host)>253 or not re.fullmatch(r'[A-Za-z0-9.-]+', host): raise SystemExit(1)
        if host.startswith('.') or host.endswith('.') or '..' in host: raise SystemExit(1)
if not 1 <= port <= 65535: raise SystemExit(1)
PY
}

endpoint_port() { printf '%s' "${1##*:}"; }

port_in_config() {
  local wanted="$1" ignore="${2:-0}" i p
  load_endpoints
  for ((i=0; i<${#EP_LISTENS[@]}; i++)); do
    (( i + 1 == ignore )) && continue
    p="$(endpoint_port "${EP_LISTENS[i]}")"
    [[ "$p" == "$wanted" ]] && return 0
  done
  return 1
}

port_in_system() {
  local port="$1"
  command -v ss >/dev/null 2>&1 || return 1
  ss -H -lntu 2>/dev/null | awk -v p="$port" '{a=$5; sub(/^.*:/,"",a); if(a==p) found=1} END{exit !found}'
}

random_port() {
  local p n=0
  while (( n < 500 )); do
    p=$((20000 + RANDOM % 40000))
    if ! port_in_config "$p" && ! port_in_system "$p"; then printf '%s' "$p"; return 0; fi
    n=$((n+1))
  done
  return 1
}

network_udp_enabled() {
  [[ -s "$CONF" ]] || return 1
  python3 - "$CONF" <<'PY' >/dev/null 2>&1
try:
 import tomllib
except ImportError:
 import tomli as tomllib
import sys
with open(sys.argv[1], 'rb') as f: d=tomllib.load(f)
sys.exit(0 if d.get('network', {}).get('use_udp', False) else 1)
PY
}

fw_add_one() {
  local ipt="$1" proto="$2" port="$3" tag="realmm:$3"
  "$ipt" -C INPUT -p "$proto" --dport "$port" -m comment --comment "$tag" -j ACCEPT 2>/dev/null ||
    "$ipt" -I INPUT 1 -p "$proto" --dport "$port" -m comment --comment "$tag" -j ACCEPT 2>/dev/null
}

fw_del_one() {
  local ipt="$1" proto="$2" port="$3" tag="realmm:$3"
  while "$ipt" -D INPUT -p "$proto" --dport "$port" -m comment --comment "$tag" -j ACCEPT 2>/dev/null; do :; done
}

fw_open_port() {
  local port="$1" ipt
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    warn "检测到 UFW 已启用，请手动放行 TCP $port；UDP 是否放行取决于配置。"
    return 0
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    warn "检测到 firewalld 已启用，请在 firewalld 中手动放行端口 $port。"
    return 0
  fi
  for ipt in iptables ip6tables; do
    command -v "$ipt" >/dev/null 2>&1 || continue
    fw_add_one "$ipt" tcp "$port" || warn "$ipt 添加 TCP $port 规则失败"
    if network_udp_enabled; then
      fw_add_one "$ipt" udp "$port" || warn "$ipt 添加 UDP $port 规则失败"
    else
      fw_del_one "$ipt" udp "$port"
    fi
  done
  if command -v netfilter-persistent >/dev/null 2>&1; then netfilter-persistent save >/dev/null 2>&1 || true; fi
}

fw_close_port() {
  local port="$1" ipt proto
  for ipt in iptables ip6tables; do
    command -v "$ipt" >/dev/null 2>&1 || continue
    for proto in tcp udp; do fw_del_one "$ipt" "$proto" "$port"; done
  done
  command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true
}

fw_sync_config() {
  local i port
  load_endpoints
  for ((i=0; i<${#EP_LISTENS[@]}; i++)); do
    port="$(endpoint_port "${EP_LISTENS[i]}")"
    [[ "$port" =~ ^[0-9]+$ ]] && fw_open_port "$port"
  done
}

# ---------- Config application / rollback ----------
apply_config() {
  local backup="${1:-}" was_active=0
  [[ -s "$CONF" ]] || { err "配置文件不存在：$CONF"; return 1; }
  if ! toml_validate "$CONF"; then
    err "TOML 校验失败"
    if [[ -n "$backup" && -s "$backup" ]]; then
      restore_config_file "$backup"
      warn "已恢复修改前配置：$backup"
    fi
    return 1
  fi

  if is_legacy_service; then
    err "当前仍由旧版服务运行，拒绝直接应用新版配置。请先执行 [15] 迁移。"
    return 1
  fi

  if [[ ! -x "$BIN" ]]; then
    ok "配置已保存；Realm 尚未安装，暂未应用到服务"
    return 0
  fi

  if [[ "$(toml_count "$CONF")" == "0" ]]; then
    if service_exists; then
      svc stop >/dev/null 2>&1 || true
      svc disable >/dev/null 2>&1 || true
    fi
    warn "配置中没有启用的 [[endpoints]]；配置已保存，Realm 服务已停止并取消开机启动"
    return 0
  fi

  service_exists || write_service || return 1
  svc enable >/dev/null 2>&1 || true
  service_active && was_active=1
  if [[ "$INIT" == "systemd" ]]; then systemctl daemon-reload; fi

  if (( was_active )); then
    svc restart >/dev/null 2>&1
  else
    svc start >/dev/null 2>&1
  fi
  sleep 2
  if service_active; then
    ok "配置已应用，Realm 服务运行正常"
    fw_sync_config
    return 0
  fi

  err "Realm 应用配置后未能正常启动"
  if [[ -n "$backup" && -s "$backup" ]]; then
    cp -p "$backup" "$CONF"
    chmod 600 "$CONF" 2>/dev/null || true
    warn "已回滚到修改前配置，正在尝试恢复服务"
    if (( was_active )); then svc restart >/dev/null 2>&1 || true; else svc start >/dev/null 2>&1 || true; fi
    sleep 1
    service_active && ok "旧配置已恢复，服务重新运行" || err "旧配置已恢复，但服务仍未运行，请检查日志"
  else
    warn "没有可用的修改前备份，请手动检查配置和日志"
  fi
  return 1
}

# ---------- Endpoint display / management ----------
show_rules() {
  local i
  load_endpoints
  if ((${#EP_NAMES[@]} == 0)); then
    warn "配置中没有有效的 [[endpoints]] 转发规则"
    return 1
  fi
  echo
  for ((i=0; i<${#EP_NAMES[@]}; i++)); do
    printf '  [%d] %s\n' "$((i+1))" "${EP_NAMES[i]}"
    printf '      监听：%s\n' "${EP_LISTENS[i]}"
    printf '      目标：%s\n' "${EP_REMOTES[i]}"
    [[ -n "${EP_TYPES[i]}" ]] && printf '      type：%s（配置中已有字段，保持原样）\n' "${EP_TYPES[i]}"
  done
}

pick_endpoint() {
  local prompt="$1" total
  load_endpoints
  total="${#EP_NAMES[@]}"
  (( total > 0 )) || { warn "没有可管理的转发规则"; return 1; }
  show_rules
  echo
  read -r -p "$prompt（回车取消）：" IDX
  [[ "$IDX" =~ ^[0-9]+$ ]] || return 1
  (( IDX >= 1 && IDX <= total )) || { err "编号无效"; return 1; }
}

name_used() {
  local wanted="$1" i
  load_endpoints
  load_paused_endpoints
  for ((i=0; i<${#EP_NAMES[@]}; i++)); do
    [[ "${EP_NAMES[i]}" == "$wanted" ]] && return 0
  done
  for ((i=0; i<${#PAUSED_NAMES[@]}; i++)); do
    [[ "${PAUSED_NAMES[i]}" == "$wanted" ]] && return 0
  done
  return 1
}

next_rule_name() {
  local n i found
  load_endpoints
  load_paused_endpoints
  n=$((${#EP_NAMES[@]} + ${#PAUSED_NAMES[@]} + 1))
  while :; do
    found=0
    for ((i=0; i<${#EP_NAMES[@]}; i++)); do
      [[ "${EP_NAMES[i]}" == "规则$n" ]] && found=1
    done
    for ((i=0; i<${#PAUSED_NAMES[@]}; i++)); do
      [[ "${PAUSED_NAMES[i]}" == "规则$n" ]] && found=1
    done
    (( found == 0 )) && { printf '规则%s' "$n"; return; }
    n=$((n+1))
  done
}

add_rule() {
  local name default listen remote answer port
  refuse_if_legacy && return
  ensure_toml_parser || return
  ensure_config_file
  toml_validate "$CONF" || return

  default="$(next_rule_name)"
  while :; do
    read -r -p "规则名称（回车=$default）：" name
    name="${name:-$default}"
    name="$(printf '%s' "$name" | tr -d '\000-\037\177')"
    [[ -n "$name" && ${#name} -le 80 ]] || { err "名称不能为空且不能超过 80 个字符"; continue; }
    name_used "$name" && { err "名称已存在，请换一个"; continue; }
    break
  done

  read -r -p '监听地址（例如 0.0.0.0:10081 或 [::]:10081）：' listen
  valid_hostport "$listen" || { err "监听地址格式不正确"; return; }
  port="$(endpoint_port "$listen")"
  if port_in_config "$port" || port_in_system "$port"; then
    err "端口 $port 已被现有规则或系统进程占用"
    return
  fi

  read -r -p '目标地址（例如 82.22.31.58:10081 或 [2001:db8::1]:443）：' remote
  valid_hostport "$remote" || { err "目标地址格式不正确"; return; }

  local backup
  backup="$(backup_config)" || { err "配置备份失败，已取消添加"; return; }
  toml_tool add "$CONF" "$name" "$listen" "$remote" || {
    err "添加规则失败"
    [[ -n "$backup" ]] && restore_config_file "$backup"
    return
  }
  if apply_config "$backup"; then
    ok "已添加规则：$name"
    echo "提醒：还需在云厂商安全组/NAT 端口映射中放行监听端口 $port。"
  fi
}

edit_rule() {
  local field value old_port new_port backup
  refuse_if_legacy && return
  pick_endpoint "要修改的规则编号" || return
  local idx="$IDX"
  local old_listen="${EP_LISTENS[idx-1]}"
  echo
  echo "1) 修改规则名称"
  echo "2) 修改监听地址"
  echo "3) 修改目标地址"
  echo "0) 返回"
  read -r -p '请选择 [0-3]：' field
  case "$field" in
    1)
      read -r -p '新名称：' value
      [[ -n "$value" && ${#value} -le 80 ]] || { err "名称不能为空且不能超过 80 个字符"; return; }
      name_used "$value" && { err "名称已存在"; return; }
      backup="$(backup_config)" || return
      toml_tool rename "$CONF" "$idx" "$value" || { [[ -n "$backup" ]] && restore_config_file "$backup"; err "改名失败"; return; }
      ;;
    2)
      read -r -p '新的监听地址：' value
      valid_hostport "$value" || { err "监听地址格式不正确"; return; }
      new_port="$(endpoint_port "$value")"
      old_port="$(endpoint_port "$old_listen")"
      if [[ "$new_port" != "$old_port" ]] && { port_in_config "$new_port" "$idx" || port_in_system "$new_port"; }; then
        err "新端口 $new_port 已被占用"
        return
      fi
      backup="$(backup_config)" || return
      toml_tool set "$CONF" "$idx" listen "$value" || { [[ -n "$backup" ]] && restore_config_file "$backup"; err "修改监听地址失败"; return; }
      ;;
    3)
      read -r -p '新的目标地址：' value
      valid_hostport "$value" || { err "目标地址格式不正确"; return; }
      backup="$(backup_config)" || return
      toml_tool set "$CONF" "$idx" remote "$value" || { [[ -n "$backup" ]] && restore_config_file "$backup"; err "修改目标地址失败"; return; }
      ;;
    0) return ;;
    *) err "无效选项"; return ;;
  esac
  if apply_config "$backup"; then
    [[ "$field" == "2" && "$new_port" != "$old_port" ]] && fw_close_port "$old_port"
    ok "规则修改完成"
  fi
}

rename_rule() {
  refuse_if_legacy && return
  pick_endpoint "要改名的规则编号" || return
  local idx="$IDX" name backup
  read -r -p '新名称：' name
  [[ -n "$name" && ${#name} -le 80 ]] || { err "名称不能为空且不能超过 80 个字符"; return; }
  name_used "$name" && { err "名称已存在"; return; }
  backup="$(backup_config)" || return
  toml_tool rename "$CONF" "$idx" "$name" || { [[ -n "$backup" ]] && restore_config_file "$backup"; err "改名失败"; return; }
  ok "已改名。规则名称保存在 TOML 注释中，不会写入 Realm 未定义的配置字段。"
}

delete_rule() {
  refuse_if_legacy && return
  pick_endpoint "要删除的规则编号" || return
  local idx="$IDX" old_listen old_port backup answer
  old_listen="${EP_LISTENS[idx-1]}"
  old_port="$(endpoint_port "$old_listen")"
  read -r -p "确认删除「${EP_NAMES[idx-1]}」？[y/N] " answer
  [[ "$answer" == y || "$answer" == Y ]] || { echo "已取消"; return; }
  backup="$(backup_config)" || return
  toml_tool delete "$CONF" "$idx" || { [[ -n "$backup" ]] && restore_config_file "$backup"; err "删除失败"; return; }
  if apply_config "$backup"; then
    if ! port_in_config "$old_port"; then fw_close_port "$old_port"; fi
    ok "规则已删除"
  fi
}

show_paused_rules() {
  local i
  load_paused_endpoints
  if ((${#PAUSED_NAMES[@]} == 0)); then warn "没有已暂停的规则"; return 1; fi
  echo
  echo "已暂停规则："
  for ((i=0; i<${#PAUSED_NAMES[@]}; i++)); do
    printf '  [%d] %s\n' "$((i+1))" "${PAUSED_NAMES[i]}"
    printf '      监听：%s\n' "${PAUSED_LISTENS[i]}"
    printf '      目标：%s\n' "${PAUSED_REMOTES[i]}"
  done
}

pause_rule() {
  refuse_if_legacy && return
  pick_endpoint "要暂停的规则编号" || return
  local idx="$IDX" rule_name="${EP_NAMES[IDX-1]}" old_port backup
  old_port="$(endpoint_port "${EP_LISTENS[IDX-1]}")"
  backup="$(backup_config)" || { err "配置备份失败"; return; }
  if toml_tool pause "$CONF" "$idx"; then
    if apply_config "$backup"; then
      if ! port_in_config "$old_port"; then fw_close_port "$old_port"; fi
      ok "规则已暂停：$rule_name"
    fi
  else
    restore_config_file "$backup"
    err "暂停规则失败，已恢复原配置"
  fi
}

resume_rule() {
  refuse_if_legacy && return
  show_paused_rules || return
  local idx rule_name backup
  read -r -p '要恢复的规则编号（回车取消）：' idx
  [[ "$idx" =~ ^[0-9]+$ ]] || return
  (( idx >= 1 && idx <= ${#PAUSED_NAMES[@]} )) || { err "编号无效"; return; }
  rule_name="${PAUSED_NAMES[idx-1]}"
  backup="$(backup_config)" || { err "配置备份失败"; return; }
  if toml_tool resume "$CONF" "$idx"; then
    if apply_config "$backup"; then ok "规则已恢复：$rule_name"; fi
  else
    restore_config_file "$backup"
    err "恢复规则失败，已恢复原配置"
  fi
}

manage_rule_state() {
  echo "1) 暂停一条正在使用的规则"
  echo "2) 恢复一条已暂停的规则"
  echo "3) 查看已暂停规则"
  echo "0) 返回"
  read -r -p '请选择 [0-3]：' state_choice
  case "$state_choice" in
    1) pause_rule ;;
    2) resume_rule ;;
    3) show_paused_rules ;;
    0) return ;;
    *) err "无效选项" ;;
  esac
}

# ---------- Full AI config management ----------
view_config() {
  local file="$CONF"
  if [[ ! -s "$file" && -s "$LEGACY_CONF" ]]; then file="$LEGACY_CONF"; fi
  if [[ -s "$file" ]]; then
    echo "配置文件：$file"
    echo "------------------------------------------------"
    cat "$file"
  else
    warn "尚无 config.toml。"
  fi
}

edit_config() {
  refuse_if_legacy && return
  ensure_toml_parser || return
  ensure_config_file
  local backup editor
  backup="$(backup_config)" || { err "无法备份当前配置"; return; }
  if command -v nano >/dev/null 2>&1; then
    nano "$CONF"
  elif command -v vi >/dev/null 2>&1; then
    vi "$CONF"
  else
    err "未安装 nano 或 vi；请先安装编辑器"
    return
  fi
  apply_config "$backup"
}

import_config() {
  refuse_if_legacy && return
  ensure_toml_parser || return
  local source tmp backup
  read -r -p '请输入 AI 生成的 TOML 文件路径：' source
  [[ -s "$source" ]] || { err "文件不存在或为空"; return; }
  tmp="$(mktemp "$RULE_DIR/import.XXXXXX")" || return
  cp "$source" "$tmp" || { rm -f "$tmp"; return; }
  if ! toml_validate "$tmp"; then
    err "导入文件 TOML 校验失败，原配置未改动"
    rm -f "$tmp"
    return
  fi
  echo "导入会替换当前 config.toml，但不会删除备份目录。"
  read -r -p '确认导入？[y/N] ' answer
  [[ "$answer" == y || "$answer" == Y ]] || { rm -f "$tmp"; echo "已取消"; return; }
  backup="$(backup_config)" || { rm -f "$tmp"; err "当前配置备份失败"; return; }
  chmod 600 "$tmp"
  mv -f "$tmp" "$CONF"
  apply_config "$backup"
}

export_config() {
  [[ -s "$CONF" ]] || { err "当前配置不存在"; return; }
  local out
  read -r -p "导出路径（回车默认 /root/realm-config-$(date +%Y%m%d-%H%M%S).toml）：" out
  out="${out:-/root/realm-config-$(date +%Y%m%d-%H%M%S).toml}"
  cp -p "$CONF" "$out" && chmod 600 "$out" && ok "配置已导出：$out"
}

restore_config() {
  local -a files=()
  local i source backup
  mapfile -t files < <(python3 - "$BACKUP_DIR" <<'PY'
import glob, os, sys
for path in sorted(glob.glob(os.path.join(sys.argv[1], "config-*.toml")), key=os.path.getmtime, reverse=True):
    print(path)
PY
)
  ((${#files[@]})) || { warn "没有找到配置备份"; return; }
  echo "可恢复的配置备份："
  for ((i=0; i<${#files[@]}; i++)); do printf '  [%d] %s\n' "$((i+1))" "${files[i]}"; done
  read -r -p '选择编号（回车取消）：' idx
  [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#files[@]} )) || return
  source="${files[idx-1]}"
  toml_validate "$source" || { err "备份文件校验失败"; return; }
  backup="$(backup_config)" || { err "当前配置备份失败"; return; }
  cp -p "$source" "$CONF"
  apply_config "$backup"
}

validate_apply_menu() {
  [[ -s "$CONF" ]] || { err "配置文件不存在"; return; }
  toml_validate "$CONF" || return
  read -r -p '是否应用配置并重启 Realm？[y/N] ' answer
  [[ "$answer" == y || "$answer" == Y ]] || { echo "仅完成语法检查，未重启服务"; return; }
  local backup
  backup="$(backup_config)" || { err "备份失败"; return; }
  apply_config "$backup"
}

# ---------- Realm installation / service ----------
install_realm() {
  local version arch url work candidate old_backup old_unit_backup service_file old_active=0 had_unit=0 old_enabled=0 stamp
  refuse_if_legacy && return
  ensure_toml_parser || return

  read -r -p 'Realm 版本（回车=latest，例如 v2.9.6）：' version
  version="${version:-latest}"
  local libc variants variant asset candidate_ok=0
  case "$(uname -m)" in
    x86_64|amd64) arch=x86_64 ;;
    aarch64|arm64) arch=aarch64 ;;
    armv7l|armv6l) arch=armv7 ;;
    *) err "暂不支持架构 $(uname -m)，当前支持 x86_64/aarch64/armv7"; return ;;
  esac
  if ldd --version 2>&1 | grep -qi musl; then libc=musl; else libc=gnu; fi
  # glibc 系统先试 gnu 版；若系统 glibc 过旧导致无法运行，自动改用静态 musl 版
  if [[ "$libc" == gnu ]]; then variants="gnu musl"; else variants="musl"; fi
  if [[ "$version" != latest ]]; then
    [[ "$version" =~ ^v?[0-9A-Za-z._-]+$ ]] || { err "版本号格式不正确"; return; }
  fi

  work="$(mktemp -d /tmp/realmm-install.XXXXXX)" || return
  candidate=""
  for variant in $variants; do
    case "$arch:$variant" in
      x86_64:*) asset="realm-x86_64-unknown-linux-${variant}.tar.gz" ;;
      aarch64:*) asset="realm-aarch64-unknown-linux-${variant}.tar.gz" ;;
      armv7:musl) asset="realm-armv7-unknown-linux-musleabihf.tar.gz" ;;
      armv7:gnu) asset="realm-armv7-unknown-linux-gnueabihf.tar.gz" ;;
    esac
    if [[ "$version" == latest ]]; then
      url="https://github.com/zhboner/realm/releases/latest/download/${asset}"
    else
      url="https://github.com/zhboner/realm/releases/download/${version}/${asset}"
    fi
    rm -rf "$work/pkg" "$work/realm.tar.gz"; mkdir -p "$work/pkg"
    echo "下载：$url"
    if ! download_file "$url" "$work/realm.tar.gz" || ! tar -tzf "$work/realm.tar.gz" >/dev/null 2>&1; then
      warn "$variant 版下载失败或压缩包损坏"
      continue
    fi
    tar -xzf "$work/realm.tar.gz" -C "$work/pkg" || { warn "$variant 版解压失败"; continue; }
    candidate="$(find "$work/pkg" -type f -name realm -print -quit 2>/dev/null)"
    [[ -n "$candidate" ]] || { warn "压缩包中没有 realm 二进制"; continue; }
    chmod 755 "$candidate"
    if "$candidate" --version >/dev/null 2>&1; then candidate_ok=1; break; fi
    if [[ "$variant" == gnu ]]; then
      warn "gnu 版二进制无法在本机运行（常见原因：系统 glibc 过旧）"
      echo "改用静态 musl 版重试..."
    else
      warn "$variant 版二进制无法在本机运行"
    fi
  done
  if (( ! candidate_ok )); then
    err "所有版本均无法使用；现有 Realm 未修改"
    rm -rf "$work"
    return
  fi
  ok "已选用 ${variant} 版：$("$candidate" --version 2>&1 | head -n 1)"

  stamp="$(date +%Y%m%d-%H%M%S)"
  old_backup=""
  service_file="/etc/systemd/system/realm.service"
  [[ "$INIT" == "openrc" ]] && service_file="/etc/init.d/realm"
  old_unit_backup=""
  if [[ -x "$BIN" ]]; then
    old_backup="$BACKUP_DIR/realm-bin-$stamp"
    cp -p "$BIN" "$old_backup" || { err "备份现有 Realm 失败"; rm -rf "$work"; return; }
  fi
  if [[ -f "$service_file" ]]; then
    old_unit_backup="$BACKUP_DIR/realm-service-$stamp"
    cp -p "$service_file" "$old_unit_backup" || { err "备份现有服务文件失败"; rm -rf "$work"; return; }
    had_unit=1
  fi
  service_active && old_active=1
  if [[ "$INIT" == "systemd" ]] && systemctl is-enabled --quiet realm 2>/dev/null; then old_enabled=1; fi
  if [[ "$INIT" == "openrc" ]] && rc-update show default 2>/dev/null | grep -Eq '(^|[[:space:]])realm([[:space:]]|$)'; then old_enabled=1; fi

  install -m 755 "$candidate" "$BIN.new" || { err "写入新二进制失败"; rm -rf "$work"; return; }
  mv -f "$BIN.new" "$BIN" || { err "替换二进制失败"; rm -f "$BIN.new"; rm -rf "$work"; return; }
  rm -rf "$work"

  ensure_config_file
  if ! toml_validate "$CONF"; then
    err "当前配置无效，Realm 已安装但不会启动；请修复配置"
    if [[ -n "$old_backup" ]]; then cp -p "$old_backup" "$BIN"; else rm -f "$BIN"; fi
    return
  fi
  if ! write_service; then
    err "写入服务文件失败，正在恢复原文件"
    if [[ -n "$old_backup" ]]; then cp -p "$old_backup" "$BIN"; else rm -f "$BIN"; fi
    if (( had_unit )); then cp -p "$old_unit_backup" "$service_file"; else rm -f "$service_file"; fi
    [[ "$INIT" == "systemd" ]] && systemctl daemon-reload
    return
  fi
  ok "Realm 安装完成：$("$BIN" --version 2>&1 | head -n 1)"
  [[ -n "$old_backup" ]] && echo "原二进制备份：$old_backup"
  if [[ "$(toml_count "$CONF")" -gt 0 ]]; then
    svc enable >/dev/null 2>&1 || true
    if (( old_active )); then svc restart >/dev/null 2>&1 || true; else svc start >/dev/null 2>&1 || true; fi
    sleep 2
    if service_active; then
      ok "Realm 服务已启动"
    else
      err "新版本启动失败，正在尝试恢复更新前版本"
      if [[ -n "$old_backup" ]]; then cp -p "$old_backup" "$BIN"; else rm -f "$BIN"; fi
      if (( had_unit )); then cp -p "$old_unit_backup" "$service_file"; else rm -f "$service_file"; fi
      if [[ "$INIT" == "systemd" ]]; then systemctl daemon-reload; fi
      if (( old_enabled )); then svc enable >/dev/null 2>&1 || true; else svc disable >/dev/null 2>&1 || true; fi
      if (( old_active )); then svc restart >/dev/null 2>&1 || true; else svc stop >/dev/null 2>&1 || true; fi
      sleep 1
      service_active && ok "已恢复更新前程序和服务" || warn "程序/服务文件已回滚；服务原本未运行或仍未能启动，请检查日志"
      return 1
    fi
  else
    svc stop >/dev/null 2>&1 || true
    svc disable >/dev/null 2>&1 || true
    warn "配置中尚无启用的 [[endpoints]]；服务保持停止且不会开机自启，请导入 AI 配置或添加规则"
  fi
}

start_realm() {
  refuse_if_legacy && return
  [[ -x "$BIN" ]] || { err "Realm 尚未安装"; return; }
  [[ -s "$CONF" ]] || { err "配置文件不存在"; return; }
  toml_validate "$CONF" || return
  [[ "$(toml_count "$CONF")" -gt 0 ]] || { err "配置中没有 [[endpoints]]"; return; }
  service_exists || write_service || return
  svc enable || true
  svc start >/dev/null 2>&1
  sleep 2
  service_active && ok "Realm 已启动" || err "启动失败，请查看日志"
}

stop_realm() {
  refuse_if_legacy && return
  if ! service_exists; then warn "Realm 服务尚未安装"; return; fi
  svc stop >/dev/null 2>&1
  sleep 1
  service_active && err "停止失败" || ok "Realm 服务已停止"
}

restart_realm() {
  refuse_if_legacy && return
  [[ -x "$BIN" ]] || { err "Realm 尚未安装"; return; }
  toml_validate "$CONF" || return
  svc restart >/dev/null 2>&1
  sleep 2
  service_active && ok "Realm 已重启" || err "重启失败，请查看日志"
}

show_status() {
  local exec pid
  echo "版本：$VERSION"
  echo "服务管理器：$INIT"
  echo "配置文件：$CONF"
  if [[ -x "$BIN" ]]; then echo "新路径二进制：$("$BIN" --version 2>&1 | head -n 1)"; else echo "新路径二进制：未安装"; fi
  if [[ -x "$LEGACY_BIN" ]]; then echo "旧路径二进制：$LEGACY_BIN"; fi
  if service_exists; then
    if service_active; then ok "Realm 服务运行中"; else warn "Realm 服务未运行"; fi
    exec="$(service_execstart)"
    echo "ExecStart：$exec"
    if is_legacy_service; then warn "检测到旧版/非标准路径服务，尚未迁移"; fi
    if [[ "$INIT" == systemd ]]; then
      pid="$(systemctl show realm -p MainPID --value 2>/dev/null)"
      echo "MainPID：${pid:-未知}"
    fi
  else
    warn "Realm 服务单元不存在"
  fi
  echo
  echo "--- TOML 配置检查 ---"
  [[ -s "$CONF" ]] && toml_validate "$CONF" || echo "新版配置文件尚不存在"
  echo
  echo "--- 监听端口 ---"
  command -v ss >/dev/null 2>&1 && ss -lntup 2>/dev/null | grep -E 'realm|State|Netid' || true
  echo
  echo "--- 最近日志 ---"
  if [[ "$INIT" == systemd ]]; then
    journalctl -u realm -n 25 --no-pager 2>/dev/null || true
  elif [[ -f /var/log/realm.log ]]; then
    tail -n 25 /var/log/realm.log
  fi
  if [[ -f "$LEGACY_DIR/realm.log" ]]; then
    echo "--- 旧版日志末尾 ---"
    tail -n 10 "$LEGACY_DIR/realm.log"
  fi
}

# ---------- Network tests ----------
tcp_probe() {
  python3 - "$1" <<'PY' >/dev/null 2>&1
import socket, sys, re
s=sys.argv[1]
if s.startswith('['):
    m=re.fullmatch(r'\[([^]]+)\]:(\d+)',s)
    if not m: raise SystemExit(2)
    host,port=m.group(1),int(m.group(2))
else:
    if s.count(':') != 1: raise SystemExit(2)
    host,p=s.rsplit(':',1); port=int(p)
try:
    with socket.create_connection((host,port),timeout=4): pass
except Exception:
    raise SystemExit(1)
PY
}

# 从 Realm 的 host:port / [IPv6]:port 格式中提取目标主机，供 ICMP Ping 使用。
endpoint_host() {
  python3 - "$1" <<'PY'
import re, sys
s = sys.argv[1]
if s.startswith('['):
    m = re.fullmatch(r'\[([^]]+)\]:\d+', s)
    if not m:
        raise SystemExit(2)
    print(m.group(1))
else:
    if s.count(':') != 1:
        raise SystemExit(2)
    host, port = s.rsplit(':', 1)
    if not host or not port.isdigit():
        raise SystemExit(2)
    print(host)
PY
}

ping_probe() {
  local host="$1" output rc=0 summary
  if ! command -v ping >/dev/null 2>&1; then
    warn "系统未安装 ping，跳过 ICMP 检测（可安装 iputils-ping 或 iputils）"
    return 2
  fi

  output="$(ping -n -c 4 -W 2 -- "$host" 2>&1)" || rc=$?
  summary="$(printf '%s\n' "$output" | grep -Ei '^(PING |.*(packets transmitted|packet loss|round-trip|rtt |min/avg/max|平均|丢包))' || true)"
  if [[ -n "$summary" ]]; then
    printf '%s\n' "$summary" | sed 's/^/      /'
  else
    printf '%s\n' "$output" | tail -n 4 | sed 's/^/      /'
  fi

  if printf '%s\n' "$output" | grep -Eq '(^|[^0-9])0([.]0+)?% packet loss|0 packets lost'; then
    ok "ICMP Ping 有响应，未检测到丢包"
  elif printf '%s\n' "$output" | grep -Eq '[1-9][0-9]*([.][0-9]+)?% packet loss|100% packet loss'; then
    warn "ICMP Ping 存在丢包；目标可能限速或过滤 ICMP"
  elif (( rc == 0 )); then
    ok "ICMP Ping 有响应"
  else
    warn "ICMP Ping 无响应；目标可能禁止 ICMP，这不代表 TCP 转发不可用"
  fi
}

test_rules() {
  local i port host
  show_rules || return
  load_endpoints
  echo
  echo "========== 综合连通性测试（TCP / ICMP Ping）=========="
  for ((i=0; i<${#EP_NAMES[@]}; i++)); do
    echo
    echo "[${EP_NAMES[i]}]"
    echo "监听：${EP_LISTENS[i]}"
    echo "目标：${EP_REMOTES[i]}"

    port="$(endpoint_port "${EP_LISTENS[i]}")"
    echo "--- 1. 本机 TCP 监听 ---"
    if ss -H -lnt 2>/dev/null | awk -v p="$port" '{a=$4;sub(/^.*:/,"",a);if(a==p)f=1}END{exit !f}'; then
      ok "本机 TCP 监听端口 $port 正常"
    else
      err "本机 TCP 监听端口 $port 未发现"
    fi

    echo "--- 2. 目标 TCP 连接 ---"
    if tcp_probe "${EP_REMOTES[i]}"; then
      ok "本机到目标 TCP 可连接"
    else
      err "本机到目标 TCP 不通；请检查目标服务、端口及防火墙"
    fi

    echo "--- 3. 目标 ICMP Ping ---"
    host="$(endpoint_host "${EP_REMOTES[i]}")" || {
      warn "无法从目标地址解析主机名，跳过 Ping"
      host=""
    }
    if [[ -n "$host" ]]; then
      echo "目标主机：$host（不包含端口）"
      ping_probe "$host" || true
    fi
  done

  echo
  echo "--- 4. UDP 状态 ---"
  if network_udp_enabled; then
    warn "UDP 已开启；当前检测不进行 UDP 业务层探测，请使用对应 UDP 客户端验证"
  else
    echo "UDP 当前关闭"
  fi
}

# ---------- UDP toggle ----------
toggle_udp() {
  refuse_if_legacy && return
  ensure_config_file
  local new backup
  if network_udp_enabled; then new=false; else new=true; fi
  echo "准备将 [network].use_udp 设置为 $new"
  backup="$(backup_config)" || { err "备份失败"; return; }
  toml_tool udp "$CONF" "$new" || { [[ -n "$backup" ]] && restore_config_file "$backup"; err "修改 UDP 配置失败"; return; }
  apply_config "$backup"
}

# ---------- Legacy migration ----------
migrate_legacy() {
  local stamp backup_root unit_path stage_conf chosen old_conf_exists=0 old_bin_exists=0
  local old_service_active=0 old_unit_saved=0 old_bin_saved=0 old_conf_saved=0 candidate endpoints_before

  if [[ "$INIT" != systemd ]]; then
    err "目前自动迁移仅支持 systemd 旧版服务；OpenRC 请先提供旧服务文件结构。"
    return
  fi
  if ! legacy_detected; then
    err "未发现完整的旧版安装（需要 $LEGACY_BIN 和 $LEGACY_CONF）"
    return
  fi
  if ! is_legacy_service; then
    if service_exists; then
      warn "当前 realm.service 看起来已不是 /opt/realm 旧服务，避免重复迁移。"
      return
    fi
  fi
  ensure_toml_parser || return

  echo "========== 旧版迁移预览 =========="
  echo "旧程序：$LEGACY_BIN"
  echo "旧配置：$LEGACY_CONF"
  echo "旧规则记录：$LEGACY_RULES"
  echo "旧服务：$(service_execstart)"
  echo "旧版本：$("$LEGACY_BIN" --version 2>&1 | head -n 1)"
  if toml_validate "$LEGACY_CONF"; then
    endpoints_before="$(toml_count "$LEGACY_CONF")"
    echo "旧配置中的 endpoint 数量：$endpoints_before"
  else
    err "旧版 config.toml TOML 语法错误，取消迁移"
    return
  fi
  if [[ -f "$LEGACY_RULES" ]]; then
    echo "旧 endpoints.dat 内容："
    sed -n '1,20p' "$LEGACY_RULES"
  fi

  if [[ -s "$CONF" ]]; then
    echo
    warn "检测到新版路径已有 config.toml。请选择迁移时使用哪份配置："
    echo "1) 使用旧版 /opt/realm/config.toml（推荐，保留当前正在运行的规则）"
    echo "2) 保留新版 /etc/realm/config.toml（不会导入旧版配置）"
    echo "0) 取消迁移"
    read -r -p '请选择 [0-2]：' chosen
    case "$chosen" in
      1) stage_conf="$LEGACY_CONF" ;;
      2) stage_conf="$CONF" ;;
      *) echo "已取消迁移"; return ;;
    esac
  else
    stage_conf="$LEGACY_CONF"
  fi

  stamp="$(date +%Y%m%d-%H%M%S)"
  backup_root="/root/realmm-migration-$stamp"
  mkdir -p "$backup_root"
  chmod 700 "$backup_root"
  echo
  echo "正在备份旧版目录和现有服务文件..."
  if [[ -d "$LEGACY_DIR" ]]; then tar -czf "$backup_root/opt-realm.tar.gz" -C /opt realm || { err "备份 /opt/realm 失败，取消迁移"; return; }; fi
  if [[ -d "$RULE_DIR" ]]; then tar -czf "$backup_root/etc-realm.tar.gz" -C /etc realm || { err "备份 /etc/realm 失败，取消迁移"; return; }; fi
  unit_path="$(systemctl show realm -p FragmentPath --value 2>/dev/null)"
  if [[ -n "$unit_path" && -f "$unit_path" ]]; then
    cp -p "$unit_path" "$backup_root/realm.service.original" || { err "备份旧 systemd 服务失败"; return; }
    old_unit_saved=1
  fi
  if [[ -x "$BIN" ]]; then
    cp -p "$BIN" "$backup_root/realm.binary.original" || { err "备份新版路径二进制失败"; return; }
    old_bin_exists=1
  fi
  if [[ -s "$CONF" ]]; then
    cp -p "$CONF" "$backup_root/config.toml.original" || { err "备份新版配置失败"; return; }
    old_conf_exists=1
  fi

  cp -p "$stage_conf" "$backup_root/config.toml.staged" || { err "准备迁移配置失败"; return; }
  if [[ "$(toml_count "$backup_root/config.toml.staged")" == "0" && -s "$LEGACY_RULES" ]]; then
    warn "旧配置没有 endpoint，尝试从 endpoints.dat 恢复规则记录"
    if ! toml_tool append-legacy "$backup_root/config.toml.staged" "$LEGACY_RULES"; then
      err "endpoints.dat 导入失败，取消迁移"
      return
    fi
  fi
  toml_validate "$backup_root/config.toml.staged" || { err "迁移配置校验失败，取消迁移"; return; }
  echo "迁移配置 endpoint 数量：$(toml_count "$backup_root/config.toml.staged")"
  echo
  warn "迁移需要停止旧 Realm 并切换 systemd 服务，会造成短暂连接中断。"
  warn "迁移不会删除 /opt/realm，也不会删除旧版 realm.sh、日志或 endpoints.dat。"
  read -r -p '确认开始迁移？请输入 yes：' answer
  [[ "$answer" == yes ]] || { echo "已取消迁移；备份保留在 $backup_root"; return; }

  if service_active; then
    old_service_active=1
    if ! systemctl stop realm; then
      err "停止旧服务失败，未进行切换"
      return
    fi
  fi

  candidate="$backup_root/realm.migrating"
  if ! cp -p "$LEGACY_BIN" "$candidate" || ! chmod 755 "$candidate" || ! "$candidate" --version >/dev/null 2>&1; then
    err "旧版 Realm 二进制无法复制/运行，正在恢复旧服务"
    (( old_service_active )) && systemctl start realm >/dev/null 2>&1 || true
    return
  fi

  if ! install -m 755 "$candidate" "$BIN.new" || ! mv -f "$BIN.new" "$BIN"; then
    err "复制 Realm 到新版路径失败"
    (( old_service_active )) && systemctl start realm >/dev/null 2>&1 || true
    return
  fi

  cp -p "$backup_root/config.toml.staged" "$CONF" || {
    err "写入新版配置失败"
    if (( old_bin_exists )); then cp -p "$backup_root/realm.binary.original" "$BIN"; else rm -f "$BIN"; fi
    (( old_service_active )) && systemctl start realm >/dev/null 2>&1 || true
    return
  }
  chmod 600 "$CONF"

  if ! write_service; then
    err "写入新版 systemd 服务失败，开始回滚"
    if (( old_unit_saved )); then cp -p "$backup_root/realm.service.original" "$unit_path"; fi
    if (( old_conf_exists )); then cp -p "$backup_root/config.toml.original" "$CONF"; else rm -f "$CONF"; fi
    if (( old_bin_exists )); then cp -p "$backup_root/realm.binary.original" "$BIN"; else rm -f "$BIN"; fi
    systemctl daemon-reload
    (( old_service_active )) && systemctl start realm >/dev/null 2>&1 || true
    return
  fi

  systemctl enable realm >/dev/null 2>&1 || true
  systemctl start realm >/dev/null 2>&1
  sleep 2
  if systemctl is-active --quiet realm && [[ "$(service_execstart)" == *"$BIN"* ]]; then
    ok "旧版迁移成功！"
    echo "新版程序：$BIN"
    echo "新版配置：$CONF"
    echo "备份目录：$backup_root"
    echo "旧版目录 $LEGACY_DIR 完整保留，没有删除。"
    return 0
  fi

  err "新版服务启动失败，正在自动回滚..."
  systemctl stop realm >/dev/null 2>&1 || true
  if (( old_unit_saved )); then
    if [[ -n "$unit_path" ]]; then cp -p "$backup_root/realm.service.original" "$unit_path"; fi
  else
    rm -f /etc/systemd/system/realm.service
  fi
  if (( old_conf_exists )); then cp -p "$backup_root/config.toml.original" "$CONF"; else rm -f "$CONF"; fi
  if (( old_bin_exists )); then cp -p "$backup_root/realm.binary.original" "$BIN"; else rm -f "$BIN"; fi
  systemctl daemon-reload
  if (( old_service_active )); then systemctl start realm >/dev/null 2>&1 || true; fi
  sleep 1
  if systemctl is-active --quiet realm; then
    ok "已恢复旧版服务；旧转发继续运行"
  else
    err "自动回滚后旧服务未能启动，请检查 $backup_root 和 systemctl status realm"
  fi
  echo "迁移备份保留在：$backup_root"
  return 1
}

# ---------- Uninstall ----------
uninstall_realm() {
  local answer
  if is_legacy_service; then
    err "当前是 /opt/realm 旧版服务。为避免误删旧配置，新版管理器不直接卸载旧版。"
    warn "请先迁移成功，再从新版菜单卸载；旧版目录会继续保留作为备份。"
    return
  fi
  read -r -p '确认卸载新版 Realm 服务和二进制？输入 yes：' answer
  [[ "$answer" == yes ]] || { echo "已取消"; return; }
  svc stop >/dev/null 2>&1 || true
  svc disable >/dev/null 2>&1 || true
  if [[ "$INIT" == systemd ]]; then
    rm -f /etc/systemd/system/realm.service
    systemctl daemon-reload
  else
    rm -f /etc/init.d/realm
  fi
  rm -f "$BIN" "$BIN.new"
  read -r -p '同时删除 /etc/realm/config.toml？备份目录仍保留。[y/N] ' answer
  case "$answer" in y|Y) rm -f "$CONF" ;; esac
  ok "新版 Realm 已卸载；realmm 管理器和备份仍保留"
}

# ---------- Header / self test ----------
header() {
  local status version count=0 paused=0
  printf '\033[H\033[2J'
  echo "${B}================================================${N}"
  echo "${W}                 Realmm $VERSION${N}"
  echo "${B}================================================${N}"
  if [[ -x "$BIN" ]]; then
    version="$("$BIN" --version 2>/dev/null | head -n 1)"
  elif [[ -x "$LEGACY_BIN" ]]; then
    version="旧版二进制存在（$LEGACY_DIR）"
  else
    version="未安装"
  fi
  if service_active; then
    if is_legacy_service; then status="${Y}旧版运行中/待迁移${N}"; else status="${G}运行中${N}"; fi
  else
    status="${R}未运行${N}"
  fi
  if [[ -s "$CONF" ]] && toml_module_available; then
    count="$(toml_count "$CONF" 2>/dev/null || echo '?')"
    paused="$(toml_tool paused-count "$CONF" 2>/dev/null || echo '?')"
  else count="?"; paused="?"; fi
  echo " Realm：$version"
  echo " 服务：$status    管理器：$INIT    启用：$count 条 / 暂停：$paused 条"
  echo " 配置：$CONF"
  echo " 快捷命令：realmm"
  echo "${B}------------------------------------------------${N}"
}

self_test() {
  local tmp="$1" testconf="$1/config.toml"
  mkdir -p "$tmp"
  [[ "$(endpoint_host "172.81.111.161:48660")" == "172.81.111.161" ]] || return 1
  [[ "$(endpoint_host "example.com:443")" == "example.com" ]] || return 1
  [[ "$(endpoint_host "[2001:db8::1]:8443")" == "2001:db8::1" ]] || return 1
  cat > "$testconf" <<'TOML'
[log]
level = "warn"
output = "stdout"

[network]
no_tcp = false
use_udp = false
custom_option = "keep-me"

[[endpoints]]
listen = "[::]:10081"
remote = "82.22.31.58:10081"

[[endpoints]]
listen = "0.0.0.0:20000"
remote = "example.com:443"
remote_transport = "tls;sni=example.com"
TOML
  toml_validate "$testconf" || return 1
  [[ "$(toml_count "$testconf")" == 2 ]] || return 1
  toml_tool rename "$testconf" 1 "香港线路" || return 1
  toml_tool set "$testconf" 2 remote "[2001:db8::1]:8443" || return 1
  toml_tool udp "$testconf" true || return 1
  toml_tool add "$testconf" "测试线路" "127.0.0.1:30000" "127.0.0.1:30001" || return 1
  [[ "$(toml_count "$testconf")" == 3 ]] || return 1
  toml_tool delete "$testconf" 3 || return 1
  [[ "$(toml_count "$testconf")" == 2 ]] || return 1
  grep -q 'custom_option = "keep-me"' "$testconf" || return 1
  grep -q 'remote_transport = "tls;sni=example.com"' "$testconf" || return 1
  grep -q 'use_udp = true' "$testconf" || return 1
  toml_tool pause "$testconf" 1 || return 1
  [[ "$(toml_count "$testconf")" == 1 ]] || return 1
  [[ "$(toml_tool paused-count "$testconf")" == 1 ]] || return 1
  mapfile -d '' -t paused_test_fields < <(toml_tool paused-list "$testconf")
  [[ "${paused_test_fields[0]}" == "香港线路" ]] || return 1
  toml_tool resume "$testconf" 1 || return 1
  [[ "$(toml_count "$testconf")" == 2 ]] || return 1
  [[ "$(toml_tool paused-count "$testconf")" == 0 ]] || return 1
  local legacy_conf="$tmp/legacy.toml" legacy_data="$tmp/endpoints.dat"
  printf '[network]\nuse_udp = false\n' > "$legacy_conf"
  printf '[::]:10081|82.22.31.58:10081\n' > "$legacy_data"
  toml_tool append-legacy "$legacy_conf" "$legacy_data" >/dev/null || return 1
  [[ "$(toml_count "$legacy_conf")" == 1 ]] || return 1
  echo "自检通过：TOML 校验、列出、改名、修改目标、UDP 修改、添加、删除、暂停/恢复、旧版 endpoints.dat 导入、目标主机解析（IPv4/域名/IPv6）及自定义字段保留。"
}

# ---------- Main ----------
if [[ "${1:-}" == "--self-test" ]]; then
  if ! toml_module_available; then echo "自检需要 Python tomllib 或 tomli"; exit 2; fi
  test_dir="$(mktemp -d /tmp/realmm-selftest.XXXXXX)" || exit 1
  self_test "$test_dir"
  rc=$?
  rm -rf "$test_dir"
  exit "$rc"
fi

if [[ "${1:-}" == "--update" ]]; then
  update_script
  exit $?
fi

install_manager
ensure_tools || warn "TOML 解析依赖未就绪；请先安装 Python 3.11+ 或 tomli。"

while true; do
  header
  echo "  1) 安装 / 更新 Realm"
  echo "  2) 添加转发规则"
  echo "  3) 查看转发规则"
  echo "  4) 修改转发规则"
  echo "  5) 规则改名"
  echo "  6) 删除转发规则"
  echo "  7) 查看完整 config.toml（适合复制给 AI）"
  echo "  8) 编辑完整 config.toml（AI 配置粘贴/修改）"
  echo "  9) 导入 AI 生成的 TOML 文件"
  echo " 10) 导出当前配置"
  echo " 11) 校验并应用配置"
  echo " 12) 服务状态 / 日志"
  echo " 13) 综合连通性测试（TCP / Ping）"
  echo " 14) UDP 转发开关"
  echo " 15) 识别并迁移旧版 /opt/realm"
  echo " 16) 从配置备份恢复"
  echo " 17) 启动 Realm"
  echo " 18) 停止 Realm"
  echo " 19) 重启 Realm"
  echo " 20) 卸载新版 Realm"
  echo " 21) 暂停 / 恢复单条规则"
  echo " 22) 更新 realmm 脚本"
  echo "  0) 退出"
  echo "${B}------------------------------------------------${N}"
  if ! read -r -p '请选择 [0-22]：' choice; then echo; exit 0; fi
  echo
  case "$choice" in
    1) install_realm ;;
    2) add_rule ;;
    3) show_rules ;;
    4) edit_rule ;;
    5) rename_rule ;;
    6) delete_rule ;;
    7) view_config ;;
    8) edit_config ;;
    9) import_config ;;
    10) export_config ;;
    11) validate_apply_menu ;;
    12) show_status ;;
    13) test_rules ;;
    14) toggle_udp ;;
    15) migrate_legacy ;;
    16) restore_config ;;
    17) start_realm ;;
    18) stop_realm ;;
    19) restart_realm ;;
    20) uninstall_realm ;;
    21) manage_rule_state ;;
    22) update_script ;;
    0) echo '再见'; exit 0 ;;
    *) warn '无效选项' ;;
  esac
  pause
 done
