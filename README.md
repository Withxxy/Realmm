# Realm 转发管理面板（Realmm）

一个个人使用的 Realm 转发管理脚本，支持 IPv4 / IPv6，提供可视化菜单管理。

## 功能介绍

- Realm 安装与更新
- IPv4 / IPv6 转发管理
- 添加、修改、删除转发规则
- 自定义规则名称
- TCP / UDP 转发设置
- 本机入口 IP 检测
- 目标服务器连通性测试
- systemd / OpenRC 服务管理
- 服务状态与日志查看
- 快捷命令 `realmm`

## 一键安装

使用 root 用户执行。

### 通用 Linux（Debian / Ubuntu 等）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Withxxy/Realmm/main/realmm.sh 2>/dev/null || wget -qO- https://raw.githubusercontent.com/Withxxy/Realmm/main/realmm.sh)
```

### Alpine Linux

```bash
apk add --no-cache bash curl
curl -fsSL https://raw.githubusercontent.com/Withxxy/Realmm/main/realmm.sh -o /tmp/realmm.sh
bash /tmp/realmm.sh
```

## 使用方法

安装并运行后，根据中文菜单提示进行操作。

后续可以直接执行：

```bash
realmm
```

## 文件说明

| 文件 | 说明 |
|---|---|
| `realmm.sh` | 主程序 |
| `.gitattributes` | 统一 Shell 脚本 LF 换行格式 |
| `README.md` | 项目说明与安装教程 |

## 注意事项

1. 请使用 root 权限运行。
2. 使用前确认 VPS 防火墙和云服务商安全组已放行对应端口。
3. TCP、UDP 是否开放取决于实际转发需求。
4. 修改脚本后，重新运行 GitHub 一键命令即可获取最新版。
5. 使用前请检查脚本内容，确认符合自己的使用环境。

---

个人项目，仅供学习和自用。
