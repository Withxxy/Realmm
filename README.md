# Realmm 2.1.1

Realm TCP/UDP 转发配置管理脚本，配置文件统一使用 `/etc/realm/config.toml`。支持 systemd 和 OpenRC。

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

## 连通性测试说明

菜单选择 `13) 综合连通性测试（TCP / Ping）`：

1. 检查本机 TCP 监听端口。
2. 检查 VPS 到目标 `IP:端口` 的 TCP 连接。
3. 对目标主机执行 4 次 ICMP Ping，显示丢包和 RTT 摘要。
4. 显示 UDP 开关状态。

Ping 只测试目标主机的 ICMP 可达性，不会测试 Realm 转发链路本身。部分服务器会过滤 ICMP，因此 Ping 失败不等于 TCP 服务不可用。若系统没有 `ping` 命令，脚本会提示并跳过 Ping，不会自动安装该命令。

## 自检

```bash
bash realmm.sh --self-test
```

自检需要 Python 3.11+ 的 `tomllib`，或安装 `tomli`。自检不会连接真实转发目标，也不会修改当前 Realm 服务。

## 文件

- `realmm.sh`：主程序。
- `.gitattributes`：统一 Shell / Markdown 文件的 LF 换行格式。
