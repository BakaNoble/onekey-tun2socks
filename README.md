# 给 VPS 一键添加 Alice Socks5 出口

通过 [hev-socks5-tunnel](https://github.com/heiher/hev-socks5-tunnel) 创建 TUN
设备，将 VPS 的 IPv4 流量转发到 Alice Socks5 出口。

## 功能

- 仅保留 Alice 出口，支持端口 `10001-10008`
- 安装时手动选择初始出口
- 每分钟检查一次当前 Socks5 出口
- 当前出口异常时自动探测并切换到其他健康端口
- 自动切换失败时恢复原配置
- GitHub 直连失败时通过 Alice Socks5 下载 tun2socks
- 保留手动切换、更新和卸载功能

## 快速开始

```bash
curl -L https://raw.githubusercontent.com/BakaNoble/onekey-tun2socks/main/onekey-tun2socks.sh -o onekey-tun2socks.sh
chmod +x onekey-tun2socks.sh
sudo ./onekey-tun2socks.sh -i
```

为了兼容旧命令，也可以使用：

```bash
sudo ./onekey-tun2socks.sh -i alice
```

其他安装模式已经移除，`-i legend`、`-i akile` 和 `-i custom` 会被拒绝。

安装程序会先尝试直连 GitHub 下载 tun2socks。直连失败时，先使用安装时选择的
Alice 端口下载，再依次尝试其余端口；不再临时修改系统 DNS。

## 健康检查

安装后会创建：

- `tun2socks-healthcheck.service`：执行一次健康检查
- `tun2socks-healthcheck.timer`：每分钟触发健康检查
- `/usr/local/bin/tun2socks-healthcheck`：健康检查和自动切换脚本
- `/etc/tun2socks/healthcheck.env`：健康检查参数

当前端口连续检测失败后，脚本会依次检查其他 Alice 端口。找到健康端口后：

1. 备份 `/etc/tun2socks/config.yaml`
2. 更新 Socks5 端口
3. 重启 `tun2socks.service`
4. 如果启动失败，恢复原配置并再次启动

手动触发检查：

```bash
sudo systemctl start tun2socks-healthcheck.service
```

查看检查日志：

```bash
journalctl -u tun2socks-healthcheck.service
```

查看定时器：

```bash
systemctl status tun2socks-healthcheck.timer
systemctl list-timers tun2socks-healthcheck.timer
```

## 脚本命令

```bash
# 安装
sudo ./onekey-tun2socks.sh -i

# 手动切换 Alice 端口
sudo ./onekey-tun2socks.sh -s

# 检查脚本更新
sudo ./onekey-tun2socks.sh -u

# 卸载
sudo ./onekey-tun2socks.sh -r
```

## 服务管理

```bash
systemctl status tun2socks.service
systemctl restart tun2socks.service
journalctl -u tun2socks.service
```

## 版本记录

### v1.2.1

- 移除失效的 DNS64 下载流程
- GitHub 直连失败时使用 Alice Socks5 兜底下载
- 首选端口不可用时依次尝试其他 Alice 端口
- 下载完成后检查 ELF 文件头，避免安装错误响应内容

### v1.2.0

- 安装模式收敛为 Alice
- 增加 Socks5 定时健康检查
- 当前出口异常时自动切换健康端口
- 自动切换失败时恢复旧配置
- 更新源和 README 下载地址切换到本仓库
