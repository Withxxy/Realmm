# Realmm 2.2.1

Realm TCP/UDP 转发配置管理脚本，配置文件统一使用 `/etc/realm/config.toml`。支持 systemd 和 OpenRC。

## 2.2.1 更新内容

- 修复菜单 13 点击后只显示规则列表、不执行任何检测的问题：规则没有 `type` 字段时，`show_rules` 会返回失败状态，导致连通性测试提前退出。
- 菜单 13 改为按规则分块输出：`[1] 本机监听检测`、`[2] TCP 目标检测`、`[3] ICMP Ping 检测`、`[4] UDP 状态`。
- Ping 检测输出最低 / 平均 / 最高延迟和丢包率；目标禁 Ping 时只提示，不判定转发失败。
- 兼容 iputils（Debian / Ubuntu / CentOS）和 busybox（Alpine）两种 ping 输出格式，IPv6 目标自动使用 `ping -6`。

## 2.2.0 更新内容

- 新增菜单 `22) 更新 realmm 脚本`：从 GitHub 检查并更新脚本本身，也可在命令行执行 `realmm --update`。
- 更新前会校验下载内容（脚本头、版本号、`bash -n` 语法检查），失败或内容异常时不会覆盖当前脚本。
- 更新前自动备份旧脚本到 `/etc/realm/backups/realmm-script-时间戳`，出问题可直接复制回 `/usr/local/bin/realmm`。
- 更新脚本不会改动 Realm 服务和 `config.toml`，转发不会中断。
- 修复在旧 glibc 系统上安装 Realm 失败（`新二进制无法运行`）：glibc 系统先尝试 gnu 版，无法运行时自动改用静态 musl 版重试。

## 2.1.1 更新内容

- 修复菜单 13 的功能回退：恢复 ICMP Ping 检测。
- 菜单 13 更名为“综合连通性测试（TCP / Ping）”。
- 每条启用规则依次检查本机 TCP 监听、目标 TCP 连接和目标主机 ICMP Ping。
- 从 `host:port` 或 `[IPv6]:port` 中正确提取 Ping 主机，不会把目标端口当成 Ping 地址。
- 输出 Ping 的发送/接收、丢包率和 RTT 摘要；目标禁 Ping 时明确提示，不把 ICMP 失败误判为 TCP 转发失败。
- 保留 UDP 状态提示。UDP 业务是否可用仍需使用实际 UDP 客户端验证。
- 增加自检：覆盖 IPv4、域名和 IPv6 目标主机解析。

## 主要功能

- 安装 / 更新 Realm。
- 添加、查看、修改、改名、删除转发规则。
- 查看、编辑、导入、导出完整 `config.toml`，便于与 AI 协作生成配置。
- 配置校验、应用前备份和应用失败回滚。
- 服务状态、日志、TCP 连通性及 ICMP Ping 检测。
- UDP 开关、单条规则暂停 / 恢复。
- 识别并迁移旧版 `/opt/realm` 安装；迁移前备份旧文件。

## 安装 / 更新

在 Linux VPS 上以 root 执行：

```bash
curl -fL --retry 3 \
  -o /usr/local/bin/realmm \
  https://raw.githubusercontent.com/Withxxy/Realmm/main/realmm.sh \
  && chmod 755 /usr/local/bin/realmm \
  && realmm
```

如果服务器没有 curl，可使用 wget：

```bash
wget -qO /usr/local/bin/realmm \
  https://raw.githubusercontent.com/Withxxy/Realmm/main/realmm.sh \
  && chmod 755 /usr/local/bin/realmm \
  && realmm
```

也可以先下载后检查语法：

```bash
curl -fL --retry 3 -o /tmp/realmm.sh \
  https://raw.githubusercontent.com/Withxxy/Realmm/main/realmm.sh
bash -n /tmp/realmm.sh && install -m 755 /tmp/realmm.sh /usr/local/bin/realmm
realmm
```

> 以上 Raw 链接在把本版本的 `realmm.sh` 上传到 GitHub 仓库 `Withxxy/Realmm` 的 `main` 分支后生效。仅下载本压缩包不会自动修改 GitHub 仓库。

## 更新脚本

```bash
realmm --update
```

或在菜单中选择 `22) 更新 realmm 脚本`。脚本会显示当前版本和 GitHub 上的最新版本，确认后替换 `/usr/local/bin/realmm` 并可选择立即重新启动。更新源可通过环境变量 `REALMM_SCRIPT_URL` 覆盖。

## 连通性测试说明

菜单选择 `13) 综合连通性测试（TCP / Ping）`，对每条启用的规则依次输出：

```text
========== 连通性测试 ==========

[规则1]
监听：[::]:27771
目标：172.81.111.161:48660

[1] 本机监听检测
✔ TCP 27771 正在监听

[2] TCP 目标检测
✔ 目标 TCP 端口连接成功

[3] ICMP Ping 检测
✔ 目标 IP 可达
  最低延迟：31.0 ms
  平均延迟：31.4 ms
  最高延迟：32.2 ms
  丢包率：0%

[4] UDP 状态
! UDP 当前关闭
```

说明：

- Ping 只测试目标主机的 ICMP 可达性，不会测试 Realm 转发链路本身。部分服务器会过滤 ICMP，Ping 失败不等于 TCP 服务不可用。
- 若系统没有 `ping` 命令，脚本会提示并跳过 Ping，不会自动安装。
- UDP 开启时只提示状态；UDP 业务是否可用仍需用实际 UDP 客户端验证。

## 自检

```bash
bash realmm.sh --self-test
```

自检需要 Python 3.11+ 的 `tomllib`，或安装 `tomli`。自检不会连接真实转发目标，也不会修改当前 Realm 服务。

## 文件

- `realmm.sh`：主程序。
- `.gitattributes`：统一 Shell / Markdown 文件的 LF 换行格式。
