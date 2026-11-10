# Realmm — Realm 转发管理面板

Realmm 是一个面向 Linux VPS 的 Realm 配置与服务管理脚本。它既支持菜单式管理转发规则，也支持直接编辑或导入 AI 生成的完整 `config.toml`。

## 主要功能

- Realm 安装、更新与卸载
- IPv4 / IPv6 监听地址和目标地址
- 转发规则添加、修改、改名、删除
- 单条规则暂停与恢复
- 完整 `config.toml` 查看、编辑、导入、导出
- TOML 语法检查；应用失败时尝试恢复修改前配置
- 每次修改前自动备份配置，并支持从备份恢复
- systemd / OpenRC 服务管理
- 服务状态、日志和 TCP 目标连通性检查
- 识别旧版 `/opt/realm` 安装，并提供备份后迁移
- `realmm` 快捷命令

## 系统要求

- Linux，root 权限
- Bash
- Python 3.11+（内置 `tomllib`），或 Python 3 + `tomli`
- 支持 systemd 或 OpenRC
- 支持 x86_64、aarch64；安装包提供对应架构时支持 armv7

## 一键运行

### Debian / Ubuntu 等常见 Linux

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Withxxy/Realmm/main/realmm.sh)
```

如果系统没有 curl，但有 wget：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/Withxxy/Realmm/main/realmm.sh)
```

### Alpine Linux

Alpine 默认 shell 通常是 ash，不支持 Bash 的进程替换语法。先安装 Bash 和下载工具：

```bash
apk add --no-cache bash curl
curl -fsSL https://raw.githubusercontent.com/Withxxy/Realmm/main/realmm.sh -o /tmp/realmm.sh
bash /tmp/realmm.sh
```

首次通过 GitHub 运行时，脚本会尝试安装 `/usr/local/bin/realmm`。之后可以直接执行：

```bash
realmm
```

## AI 生成配置的使用方式

1. 让 AI 按 Realm 当前版本的配置格式生成完整 TOML。
2. 将配置保存到 VPS 文件，例如 `/root/realm-new.toml`。
3. 在 Realmm 菜单中选择“导入 AI 生成的 TOML 文件”。
4. 导入前会先校验 TOML 语法，并备份当前配置。
5. 应用后如果服务启动失败，管理器会尝试恢复修改前的配置。

也可以选择“编辑完整 config.toml”，直接使用 nano 或 vi 编辑。

**注意：TOML 语法检查不等同于 Realm 配置 schema 检查。** Realm 本身不接受的字段仍可能导致服务启动失败；管理器会检查服务启动结果并尝试回滚，但建议先备份并在测试环境验证 AI 生成的配置。

## 旧版迁移

如果原来使用 `/opt/realm/realm` 和 `/opt/realm/config.toml`，在新版菜单选择“识别并迁移旧版 /opt/realm”。

迁移前会：

- 备份 `/opt/realm`、`/etc/realm` 和当前 systemd 服务文件
- 检查旧配置 TOML 语法
- 读取旧版 `endpoints.dat`（仅当配置中没有 endpoint 时作为补充）
- 让用户选择迁移使用哪份配置
- 要求输入 `yes` 才开始切换服务

迁移会短暂停止并重新启动 Realm，可能造成数秒连接中断。旧版 `/opt/realm` 目录不会自动删除。若新版服务启动失败，脚本会尝试恢复原 systemd 服务、配置和运行状态。

## 配置与备份位置

| 路径 | 用途 |
|---|---|
| `/etc/realm/config.toml` | 当前唯一生效配置源 |
| `/etc/realm/backups/` | 每次修改前的配置备份 |
| `/usr/local/bin/realm` | Realm 主程序 |
| `/usr/local/bin/realmm` | 管理器快捷命令 |
| `/opt/realm/` | 旧版目录；迁移后保留作回退备份 |

## 自检

下载脚本后可以先检查 Bash 语法：

```bash
bash -n realmm.sh
```

再运行内置配置逻辑自检：

```bash
bash realmm.sh --self-test
```

自检覆盖 TOML 解析、规则增删改名、UDP 设置、单条暂停/恢复、旧版 `endpoints.dat` 导入及自定义字段保留。自检不启动或修改系统 Realm 服务。

## 安全提示

- 建议先在测试 VPS 验证，再用于生产机器。
- 公开仓库不要提交密码、密钥、Token 或私有服务器配置。
- 云厂商安全组、NAT 端口映射和系统防火墙需要按实际网络环境单独配置。
- UDP 连通性不能通过 TCP 探测代替，必须用实际 UDP 客户端验证。
- 修改完整 TOML 前，建议先导出一份配置备份。

## License

个人项目，按需使用。使用前请自行审查脚本和 Realm 配置。
