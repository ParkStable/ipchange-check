# Nezha IP Watch

自动检测公网 IPv4 变化，并重启哪吒 Agent 或整台 Linux 服务器。适合 EC2 更换公网 IP 后，哪吒探针继续显示旧 IP、导致 DDNS 未及时更新的场景。

通过 systemd 定时器开机运行，无需 AWS API 密钥。它通过重启触发探针重新检测 IP，不能替代对哪吒自身 IP 上报或 DDNS 配置问题的修复。

## 一键部署

### 换 IP 后重启整台 EC2

在目标 EC2 的终端执行，下载成功后自动安装并启用定时器：

```bash
curl -fsSL https://raw.githubusercontent.com/ParkStable/ipchange-check/main/install.sh -o nezha-ip-watch-install.sh && sudo bash nezha-ip-watch-install.sh reboot
```

### 换 IP 后只重启哪吒 Agent

如果仅重启 Agent 就能恢复 IP 上报，可以使用此模式，避免整机重启中断其他业务：

```bash
curl -fsSL https://raw.githubusercontent.com/ParkStable/ipchange-check/main/install.sh -o nezha-ip-watch-install.sh && sudo bash nezha-ip-watch-install.sh agent
```

默认 Agent 服务名为 `nezha-agent.service`。自定义服务名时，追加实际名称：

```bash
sudo bash nezha-ip-watch-install.sh agent nezha-agent-custom.service
```

不传模式参数时默认使用 `agent`。安装器会检查依赖和 Agent 服务名；`reboot` 模式不要求存在 Agent 服务。

**首次成功检测只记录当前 IP，不会重启。确认基线建立后，下一次更换 IP 才会触发动作。** `reboot` 模式执行系统重启，会中断当前连接与业务；它不执行 EC2 的停止再启动操作。

## 环境要求

- 使用 systemd 的 Linux，例如 Ubuntu、Debian、Amazon Linux。
- Bash 4 或更高版本、`curl`、`flock`（通常由 `util-linux` 提供）、`awk` 和常规系统工具。
- 可以通过 IPv4 访问至少两个 IP 查询服务。
- 安装时需要 root 或 sudo 权限。

如果提示缺少依赖，可先安装：

```bash
# Ubuntu / Debian
sudo apt-get update && sudo apt-get install -y curl util-linux gawk

# Amazon Linux 2023 / 支持 dnf 的发行版
sudo dnf install -y curl util-linux gawk

# Amazon Linux 2 / 支持 yum 的发行版
sudo yum install -y curl util-linux gawk
```

只执行适合当前系统的一组命令即可。

## 工作方式

1. 开机后约 90 秒开始检测，之后约每分钟检查一次。长时间运行的实例在安装时可能立即执行首次检查。
2. 每次使用 IPv4 查询以下服务，至少两个来源返回同一有效 IPv4，才接受结果：
   - `https://checkip.amazonaws.com`
   - `https://api.ipify.org`
   - `https://ipv4.icanhazip.com`
3. 首次成功查询建立基线，不执行重启。
4. 发现新 IP 后，连续两次定时检查结果一致才执行动作，通常需要约 1～3 分钟。
5. 查询失败、地址格式无效、私网地址或来源无法取得一致时，不执行重启，并中断连续确认计数。
6. 执行动作前保存新 IP，避免同一个新 IP 重复触发。默认两次动作至少相隔 15 分钟。
7. 冷却期内再次变化时，继续检测并延后处理。动作执行失败会记录错误并保留新 IP 基线，需手动排查，不自动反复请求重启。

使用文件锁避免检查同时运行，状态文件通过临时文件替换进行更新。配置和 IP 基线均保存在目标服务器。

## 检查运行状态

```bash
# 定时器
sudo systemctl status nezha-ip-watch.timer --no-pager

# 当前 IP、记录的基线与所选模式；不会更新 IP 基线或触发重启
sudo /usr/local/sbin/nezha-ip-watch status

# 最近日志
sudo journalctl -u nezha-ip-watch.service -n 30 --no-pager

# 实时查看日志
sudo journalctl -u nezha-ip-watch.service -f
```

第一次成功运行会出现：

```text
Initial baseline saved: ...; no restart.
```

确认这条日志后再测试更换公网 IP。该脚本不会读取哪吒面板中的旧 IP，也不会在首次安装时推断此前发生过的 IP 变化。

## 配置

编辑 `/etc/default/nezha-ip-watch`：

```bash
sudo nano /etc/default/nezha-ip-watch
```

示例：

```bash
ACTION=reboot
AGENT_UNIT=nezha-agent.service
COOLDOWN_SECONDS=900
CONFIRMATIONS=2
```

| 配置项 | 说明 |
| --- | --- |
| `ACTION` | `agent` 仅重启 Agent；`reboot` 重启整台服务器 |
| `AGENT_UNIT` | `agent` 模式使用的 systemd 服务名 |
| `COOLDOWN_SECONDS` | 两次动作的最小间隔，默认 900 秒 |
| `CONFIRMATIONS` | 新 IP 需要连续确认的次数，默认 2 次 |

每次检查都会重新读取配置，修改后无需重启定时器。

重复执行安装命令可更新脚本、切换模式，并保留已有 IP 基线；配置项会按安装参数和默认值重写。如果自定义过配置，更新前请备份 `/etc/default/nezha-ip-watch`。

## 停用

```bash
sudo systemctl disable --now nezha-ip-watch.timer
sudo systemctl stop nezha-ip-watch.service
```

停止定时器不会撤销已经提交给 systemd 的整机重启请求。

## 适用范围与限制

- 检测的是**公网出口 IPv4**，不监控 IPv6。如果服务器通过固定 NAT 网关或代理出站，查询结果可能与实例绑定的入口 EIP 不同，此时需要改为通过 AWS API 或实例元数据检测入口 IP。
- 查询时绕过 `HTTP_PROXY` / `HTTPS_PROXY`；透明代理、VPN 和路由层的出口变化仍会影响检测结果。
- 如果换 IP 后无法访问互联网，脚本不会仅因查询失败就重启。
- 如果重启 Agent 后 IP 已恢复，但 DDNS 仍未更新，还需检查哪吒 Dashboard 的 DDNS 配置与日志。

## 从本地文件安装

将仓库下载到服务器后，也可以直接执行：

```bash
sudo bash install.sh reboot
# 或
sudo bash install.sh agent
```

## 项目结构

```text
nezha-ip-watch/
├── install.sh             # 自包含安装器，生成检测脚本和 systemd 单元
├── README.md
├── .gitattributes         # 统一 Shell、Markdown、Python 文件的 LF 换行
├── .gitignore
└── tests/
    └── test_ip_watch.py   # 模拟 IP 和重启命令的行为检查
```

推送本目录内容到 GitHub 仓库根目录，使 `install.sh` 与 `README.md` 位于根目录。发布后，可将上面示例中的占位仓库地址替换为实际地址。

## 本地验证

测试需要 Python 3.10+、Bash 和常规命令行工具；**安装和运行监控本身不依赖 Python**。

```bash
python3 tests/test_ip_watch.py
```

测试模拟 IP 查询和所有 `systemctl` 动作，不会执行真实重启。包含首次初始化、IP 不变、连续确认、查询失败、来源不一致、IP 波动、冷却期、Agent 模式、动作失败和状态损坏等 18 项行为检查，并检查安装器与检测脚本的 Bash 语法。

Windows 上可使用 Git Bash 执行测试；必要时通过 `BASH_PATH` 环境变量指定 Bash 完整路径。Windows 测试会额外模拟 Linux 目录权限和文件锁，Linux 测试使用真实文件锁。实际服务器的网络可达性、服务名和重启行为仍需部署后验证。
