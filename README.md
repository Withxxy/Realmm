# Realmm

[Realm](https://github.com/zhboner/realm) 端口转发的交互式管理脚本。不用手写 TOML，菜单里就能完成安装、添加规则、查看入口地址、连通性测试和故障回滚。

```text
================================================
                 Realmm 2.3.0
================================================
 Realm：Realm 2.9.6
 服务：运行中    管理器：systemd    启用：2 条 / 暂停：0 条
 配置：/etc/realm/config.toml
 快捷命令：realmm
------------------------------------------------
  1) 安装 / 更新 Realm
  2) 添加转发规则
  3) 查看转发规则
  ...
```

## 特性

- **一键安装 Realm**：从官方 GitHub Releases 下载。glibc 太旧导致二进制无法运行时，自动改用静态 musl 版。
- **规则管理**：添加、查看、修改、改名、删除、暂停 / 恢复单条规则。监听端口可留空，自动分配随机高位端口。
- **查看入口地址**：列出每条规则的 `监听端口 -> 转发目标`、监听状态，以及本机 IPv4 / IPv6 入口地址，可直接填进客户端。
- **综合连通性测试**：逐条规则检查本机监听、目标 TCP 连接、目标 ICMP Ping（延迟与丢包率）和 UDP 状态。
- **安全修改配置**：每次改动前自动备份，应用失败自动回滚到修改前的配置；导入 / 编辑的 TOML 先校验再应用。
- **完整配置可读可写**：可查看、编辑、导入、导出整份 `config.toml`，方便让 AI 生成配置后直接导入。
- **兼容 systemd 和 OpenRC**：Debian / Ubuntu / CentOS / Alpine 均可使用；Alpine 下防火墙规则会自动保存并开机加载。
- **脚本自更新**：`realmm --update` 或菜单 22，更新前校验并备份旧脚本。
- **旧版迁移**：识别 `/opt/realm` 旧安装并迁移，迁移前完整备份，失败自动回滚。

## 环境要求

| 项目 | 说明 |
|---|---|
| 权限 | root |
| 系统 | Linux，使用 systemd 或 OpenRC |
| 架构 | x86_64、aarch64（armv7 尽力支持） |
| 依赖 | bash、python3（3.11+ 自带 `tomllib`，或安装 `tomli`）、tar、ss（iproute2）、curl 或 wget |

缺少依赖时，脚本会询问并尝试用 apt / dnf / yum / apk 自动安装。

## 安装

以 root 执行（会安装为快捷命令 `realmm`）：

```bash
curl -fL --retry 3 -o /usr/local/bin/realmm \
  https://raw.githubusercontent.com/Withxxy/Realmm/main/realmm.sh \
  && chmod 755 /usr/local/bin/realmm && realmm
```

没有 curl 时使用 wget：

```bash
wget -qO /usr/local/bin/realmm \
  https://raw.githubusercontent.com/Withxxy/Realmm/main/realmm.sh \
  && chmod 755 /usr/local/bin/realmm && realmm
```

之后任何目录输入 `realmm` 即可打开菜单。

> 想先检查再安装：先下载到 `/tmp/realmm.sh`，执行 `bash -n /tmp/realmm.sh` 做语法检查，再 `install -m 755 /tmp/realmm.sh /usr/local/bin/realmm`。

## 快速开始

1. 输入 `realmm`，选 `1) 安装 / 更新 Realm`。
2. 选 `2) 添加转发规则`，按提示输入：
   - 规则名称：回车使用默认名（规则1、规则2……）
   - 监听地址：回车 = 随机端口；只输入端口号（如 `10081`）会自动补成 `[::]:10081`；也可输入完整地址如 `0.0.0.0:10081`
   - 目标地址：如 `172.81.111.161:48660` 或 `[2001:db8::1]:443`
3. 选 `3) 查看转发规则`，复制显示的入口地址：

```text
本机地址：IPv4 82.22.31.58    IPv6 2a0a:d687:f001::11c

  [1] 规则1   :27771 -> 172.81.111.161:48660   (监听中)
      v6 入口：[2a0a:d687:f001::11c]:27771
      v4 入口：82.22.31.58:27771
```

4. 在云厂商控制台的安全组中放行对应端口（TCP；开了 UDP 则同时放行 UDP）。
5. 选 `13) 综合连通性测试` 确认链路正常。

监听地址 `[::]` 为双栈，v4 和 v6 都能连入；`0.0.0.0` 只监听 IPv4。

## 菜单说明

| 编号 | 功能 |
|---|---|
| 1 | 安装 / 更新 Realm（可指定版本，默认 latest） |
| 2 | 添加转发规则 |
| 3 | 查看转发规则（含监听状态和本机 v4 / v6 入口地址） |
| 4 | 修改规则：名称、监听地址或目标地址 |
| 5 | 规则改名（只改名称，不重启服务） |
| 6 | 删除规则（同时清理对应防火墙规则） |
| 7 | 查看完整 `config.toml`（适合复制给 AI） |
| 8 | 编辑完整 `config.toml`（nano / vi，保存后校验并应用） |
| 9 | 导入 AI 生成的 TOML 文件 |
| 10 | 导出当前配置 |
| 11 | 校验并应用配置 |
| 12 | 服务状态 / 日志 |
| 13 | 综合连通性测试（TCP / Ping） |
| 14 | UDP 转发开关 |
| 15 | 识别并迁移旧版 `/opt/realm` |
| 16 | 从配置备份恢复 |
| 17 / 18 / 19 | 启动 / 停止 / 重启 Realm |
| 20 | 卸载新版 Realm（保留 realmm 和备份） |
| 21 | 暂停 / 恢复单条规则 |
| 22 | 更新 realmm 脚本 |

命令行参数：

```bash
realmm --update       # 更新脚本本身
realmm --self-test    # 运行内置自检(需要 Python 3.11+ tomllib 或 tomli)
```

## 连通性测试

菜单 13 对每条启用的规则依次检查：

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

- Ping 只测试 VPS 到目标主机的 ICMP 可达性，不是转发链路本身。很多服务器会过滤 ICMP，Ping 失败不等于 TCP 不可用。
- UDP 开启时只提示状态；UDP 业务是否可用需要用实际的 UDP 客户端验证。
- 没有 `ping` 命令时会提示并跳过，不会自动安装。

## 文件位置

| 路径 | 说明 |
|---|---|
| `/usr/local/bin/realm` | Realm 二进制 |
| `/usr/local/bin/realmm` | 本管理脚本（快捷命令） |
| `/etc/realm/config.toml` | Realm 配置，所有规则都在这里 |
| `/etc/realm/backups/` | 配置备份（保留最近 30 份）和脚本更新前的旧版本备份 |
| `/etc/systemd/system/realm.service` | systemd 服务（systemd 系统） |
| `/etc/init.d/realm` | OpenRC 服务（Alpine） |
| `/var/log/realm.log` | OpenRC 下的日志；systemd 下用 `journalctl -u realm` |
| `/root/realmm-migration-时间戳/` | 旧版迁移时的完整备份 |

规则名称保存在 `config.toml` 的注释里（`# realmm-name-b64: ...`），不会写入 Realm 不认识的配置字段，也不影响手动编辑。

## 防火墙

脚本会在 `iptables` / `ip6tables` 的 INPUT 链放行规则端口，并带 `realmm:端口` 注释，删除规则时精确清理。

- 检测到 **UFW** 或 **firewalld** 已启用时，只给出提示，需要你手动放行端口。
- Debian 系安装了 `netfilter-persistent` 时会自动保存规则；Alpine（OpenRC）会执行 `rc-service iptables save` 并加入开机启动。
- **云厂商安全组 / NAT 端口映射需要在控制台单独放行**，脚本改不了。

## 备份与回滚

- 添加、修改、删除、导入、编辑、恢复前都会先备份当前配置。
- 应用配置后 Realm 没能正常启动，会自动回滚到修改前的配置并尝试恢复服务。
- 菜单 16 可从任意一份备份恢复。

## 常见问题

**安装时提示 `GLIBC_2.xx not found` 或"新二进制无法运行"**
2.2.0 起会自动改用静态 musl 版重试。如果还在用旧版脚本，先 `realmm --update`。

**客户端连不上，但服务显示运行中**
按顺序排查：菜单 13 看本机监听和目标 TCP；检查云厂商安全组是否放行了监听端口；目标服务器是否限制了来源 IP（需要放行本机 v4）；监听地址是否为 `0.0.0.0`（此时 v6 无法连入）。

**本机没有 IPv6，只想用 v4**
添加规则时监听地址填 `0.0.0.0:端口`。

**菜单 3 里的 IPv4 地址不对**
地址通过 ip.sb 等外部服务检测；检测失败时会回退为网卡地址。NAT 机器请以云厂商面板里的公网 IP 为准。

**Ping 失败但 TCP 正常**
目标禁了 ICMP，属于正常情况，以 TCP 检测结果为准。

**想手动改配置**
直接编辑 `/etc/realm/config.toml` 后选菜单 11（校验并应用），或用菜单 8 编辑，保存后自动校验、应用、失败回滚。

## 自检

```bash
bash realmm.sh --self-test
```

覆盖 TOML 解析与编辑、规则增删改、暂停 / 恢复、UDP 开关、旧版规则导入、目标主机与监听地址解析等逻辑。自检不会连接真实转发目标，也不会修改当前 Realm 服务。

## 仓库文件

- `realmm.sh`：主程序
- `README.md`：本说明
- `CHANGELOG.md`：更新日志
- `.gitattributes`：统一 Shell / Markdown 文件为 LF 换行

## 致谢

转发核心：[zhboner/realm](https://github.com/zhboner/realm)。
