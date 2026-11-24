# SelfCDN

自建 CDN 边缘节点的一键安装与序号菜单管理脚本。填回源 `IP:端口` 和域名，自动申请
Let's Encrypt 证书、切 HTTPS、开代理缓存。

- **Nginx 反代**：多回源轮询 + 健康检查（`max_fails` / `fail_timeout`）
- **代理缓存**：磁盘 + 内存索引，缓存键含 Host，多节点互不串味，响应带 `X-Cache-Status`
- **自动证书**：acme.sh + Let's Encrypt，webroot 优先，失败自动降级 standalone，装好即配好自动续期
- **序号管理**：增 / 删 / 查 / 续期 / 清缓存 / 重载 / 看日志 / 看状态，全菜单驱动
- **不碰业务源站**：只做边缘，回源协议、Host 头、请求体上限都可配

---

## 一键安装

Debian / Ubuntu / RHEL / CentOS / Rocky / Alma，**root** 跑：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Assute/selfcdn/main/install.sh)
```

`install.sh` 会把 `selfcdn.sh` 下到 `/usr/local/sbin/selfcdn`（做完整性 + 语法校验），
装完直接进菜单。之后随时 `selfcdn` 回车。

其他用法：

```bash
selfcdn --fix-apt     # 修复过时 Debian 源并更新索引（EOL / updates / backports 失效时用）
selfcdn --check       # 只做环境检查，不进菜单
selfcdn --version
```

不放心进程替换，分两步：

```bash
curl -fsSL https://raw.githubusercontent.com/Assute/selfcdn/main/selfcdn.sh -o /usr/local/sbin/selfcdn
chmod +x /usr/local/sbin/selfcdn && selfcdn
```

只跑一次不安装：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Assute/selfcdn/main/selfcdn.sh)
```

### 前置条件

| 项 | 要求 |
|---|---|
| 权限 | root |
| 系统 | Debian 11/12、Ubuntu 20.04+、CentOS 7+、Rocky/Alma 8+ |
| 端口 | 80、443 放通（云厂商安全组 + 本机防火墙都要放） |
| DNS | 先加 A 记录指向本机，**生效后再跑**，否则 http-01 校验必挂 |
| 出网 | 能访问 `get.acme.sh`、`acme-v02.api.letsencrypt.org` |

> 家宽/大陆机房 80 端口常被运营商封禁，这种情况 http-01 走不通。两个出路：
> 用 DNS-01 校验（需域名商 API，本脚本未内置），或挂 Cloudflare 代理只回源 443。

放通端口：

```bash
# ufw
ufw allow 80/tcp && ufw allow 443/tcp
# firewalld
firewall-cmd --permanent --add-service={http,https} && firewall-cmd --reload
```

---

## 菜单

```
   1) 添加 / 更新 CDN 节点      7) 重载 Nginx
   2) 列出全部节点              8) 查看节点配置
   3) 删除节点                  9) 查看日志 / 命中率
   4) 申请 / 续期单节点证书     10) 运行状态总览
   5) 全部续期                  11) 设置 ACME 邮箱
   6) 清理缓存                  12) 清空全部节点
   0) 退出
```

---

## 添加节点的完整流程

选 `1`，按提示填：

```
节点标识（小写字母/数字，如 edge1）: edge1
绑定域名（如 static.example.com）:  static.example.com
回源 IP:端口（多个用空格）:         1.2.3.4:8080 5.6.7.8:80
回源协议 [http/https]（默认 http）:  http
回源 Host 头（默认保留客户端 Host）:  （回车）
启用缓存？[Y/n]:                     Y
缓存有效期 TTL（默认 24h）:           24h
缓存磁盘上限（默认 5g）:              5g
缓存内存索引（默认 100m）:            100m
最大请求体（默认 100m）:              100m
```

脚本此时做四件事，顺序固定：

1. 写节点登记 `/etc/selfcdn/nodes/edge1.conf`
2. 生成 **HTTP 引导模式** 配置（只监听 80，带 ACME 校验路径），`nginx -t` 通过才 reload
3. `acme.sh` 申请证书 → 失败自动降级 standalone → 成功则把证书装到 `/etc/selfcdn/certs/edge1/`
4. 重写为 **HTTPS 模式**（80 跳 301 · 443 挂牌 · HSTS），再 `nginx -t` + reload

**任何一步 `nginx -t` 不过就中止，不写生效**。源站不会因为配置错挂掉。

### 关键字段说明

**回源 Host 头**：默认 `$host`，即客户端访问的 CDN 域名（`static.example.com`）原样传给源站。
源站如果是按自己域名（`origin.example.com`）配的虚拟主机，这里要手填 `origin.example.com`，
否则源站返回 404/421。

**多回源**：多个 `IP:端口` 空格分隔，自动成组轮询，挂了自动摘除 30 秒。

**TTL 影响两处**：`proxy_cache_valid`（内容新鲜度）和 `proxy_cache_path inactive`（未命中多久驱逐）。
调小 TTL 会同时加快回源频率和缓存回收，注意回源带宽。

---

## 访问流程

```
用户 → CDN 域名(443) → Nginx
                         ├─ 缓存命中 → 直接返回（X-Cache-Status: HIT）
                         └─ 未命中   → 回源 IP:端口 → 存缓存 → 返回（X-Cache-Status: MISS）
```

缓存键是 `$scheme$request_method$host$request_uri`，所以：

- 不同 CDN 域名共用磁盘但互不干扰
- `POST` 和 `GET` 不互相污染
- **带 `Authorization` 头或 `nocache` cookie 的请求绕过缓存**，且不被写入缓存（登录态不会泄露给他人）

---

## 不缓存的东西

响应带 `Set-Cookie` 的不缓存（Nginx 默认行为，未开 `proxy_ignore_headers Set-Cookie`）。
同理带 `Cache-Control: private` / `no-store` 的也不缓存。这是安全的默认值，别为了命中率去改。

---

## 常用运维

```bash
selfcdn                                   # 进菜单
nginx -t && systemctl reload nginx         # 手工验配置+重载
curl -I https://static.example.com/       # 看 X-Cache-Status / X-CDN-Node
tail -f /var/log/nginx/selfcdn-edge1.access.log
ls /etc/selfcdn/certs/edge1/              # fullchain.cer + <域名>.key
acme.sh --list                            # 证书清单
```

### 证书续期

acme.sh 装的时候已经写进 cron（每天跑），正常不用管。手动全量续期用菜单 `5`，
单节点用菜单 `4`。菜单 `10` 看剩余天数。

### 清缓存

菜单 `6`，输节点标识或 `all`。清完立即生效，无需 reload。

**注意**：清缓存是直接删磁盘文件。Nginx 打开中的文件描述符不受影响，
但极小概率下正在读取的请求会拿到不完整内容。介意的话在低峰期做。

### reload 生效有个窗口

`systemctl reload nginx` 是优雅重载：旧 worker 会把手上的连接处理完才退出。
这段时间里新连接有可能被旧 worker 接走，表现为「刚加的节点访问不到」。

脚本加的自检会带 `Host` 头打 `127.0.0.1` 最多重试 10 秒，并且**只认本节点自己的标记**
（HTTPS 模式认 301→https，引导模式认 `X-CDN-Node` 头），不会因为 Debian 默认站点回了
200/404 就误报成功。看到自检提示没通，隔几秒用菜单 `7` 重载一次即可。

---

## 文件布局

```
/etc/selfcdn/
├── nodes/edge1.conf              # 节点登记（%q 转义，可直接 source）
├── certs/edge1/
│   ├── fullchain.cer
│   └── static.example.com.key
├── email                         # ACME 账户邮箱
/var/cache/nginx/selfcdn/edge1/   # 缓存数据
/var/www/selfcdn-acme/            # ACME 校验路径 webroot
/etc/nginx/conf.d/
├── 00-selfcdn-global.conf        # upgrade map + 各节点 cache zone
└── selfcdn-edge1.conf            # 节点 vhost
/var/log/nginx/selfcdn-edge1.{access,error}.log
/root/.acme.sh/                   # acme.sh 本体
```

**别手改** `/etc/nginx/conf.d/selfcdn-*.conf` 和 `00-selfcdn-global.conf`，
下次增删节点会被重写覆盖。改节点用菜单 `1` 重填（会覆盖同名节点）。

---

## 已验证 / 未验证

### 真机实测（Debian 11 bullseye · nginx 1.18.0 · 2 核 978M）

以下是在一台真实 Debian 11 机器上跑出来的结果，不是纸面推演：

| 项 | 结果 |
|---|---|
| apt 源自动修复（4 级阶梯） | ✅ 索引在、pool 404 的坏源自动爬到归档站后装成功 |
| nginx 安装 | ✅ 1.18.0 装上并 active |
| nginx -t | ✅ 每步都过 |
| 加节点 → HTTP 引导模式 | ✅ 生成配置、reload、自检命中 |
| 代理缓存 | ✅ MISS → HIT → HIT，缓存文件落盘 |
| 缓存键含 Host | ✅ 未匹配的 Host 落默认站点，不串缓存 |
| 双节点隔离 | ✅ 各自 zone / 缓存目录 / `X-CDN-Node`，清一个另一个仍 HIT |
| 清缓存 | ✅ 清后回 MISS |
| 删节点 | ✅ vhost / zone / 缓存目录 / 证书 / 日志全清，nginx -t 仍 OK |
| HTTPS（自签证书顶替） | ✅ 443 挂牌、80→301、TLS1.2 与 TLS1.3 均 200 |
| HSTS / 安全头 | ✅ HTTPS 下发，HTTP 引导期不下发 |
| 已有节点时重复启动脚本 | ✅ 不再破坏配置（见下方踩坑记录） |
| stdin EOF（管道 / Ctrl-D） | ✅ 立即退出，不空转 |

### 真机实测挖出并修掉的 5 个 bug

这些都是离线测试看不出来、只有真跑才会暴露的：

1. **启动即冲掉缓存区** —— `main()` 只写 `map` 不写 `proxy_cache_path`，
   导致每次启动脚本就把已有节点的 cache zone 抹掉，`nginx -t` 报
   `proxy_cache zone ... is unknown`。此时若 systemd 重启 nginx，**直接起不来**。
   修法：合并成单一 `render_global_conf()`，启动与增删节点都走它。
2. **apt 只在 update 失败时升档** —— 实况是索引正常、pool 里的 `.deb` 已 404，
   `install` 阶段才炸。修法：新增「install 下载失败也升档」，并区分源问题和安装冲突。
3. **`add_header` 被拼到同一行** —— 命令替换吃掉末尾换行，多条指令挤在一行、
   `}` 粘在行尾。nginx 能解析但极脆。修法：显式补 `$'\n'`。
4. **自检误报成功** —— 只看状态码，Debian 默认站点回的 200 被当成"通了"。
   修法：改成认本节点标记头（或 301→https），并把重试拉到 10 秒兜住 reload 窗口。
5. **stdin EOF 死循环** —— `read` 返回非 0 时 `choice` 为空 → 无效分支 →
   `pause` 也立即返回 → 空转。实测烧 28% CPU 十分钟不停。修法：判 `read` 返回值并退出。

### 离线测试

`tests/test_render.sh` 50 项 · `tests/test_apt_repair.sh` 43 项 · `tests/test_eof.sh` 9 项 · `tests/lint.sh`

覆盖：配置结构、占位符全替换、HTTP/HTTPS 两种模式的安全头差异、证书路径、
连字符节点名转下划线、缓存关闭时不残留 `proxy_cache`、节点登记 `%q` 往返
（含 `$host` 变量转义）、IPv6 关闭时不生成 `[::]`、指令逐行、zone 不丢不重、
apt 四级阶梯各分支、EOF 与非法输入退出。

### 未验证

- **真实 Let's Encrypt 签发全链路**：需要域名 A 记录指向该机，测试环境没有域名。
  HTTPS 配置分支已用自签证书在真 nginx 上验过，但 `acme.sh --issue` 走到 LE 的
  这一段没跑（会注册真实 ACME 账户）。
- **高并发 / 大文件 / 长连接**压力表现。
- Ubuntu、RHEL 系发行版（只在 Debian 11 上跑过）。

**第一次请拿测试域名跑**，别直接上生产域名。

自测命令：

```bash
bash tests/test_render.sh      # 配置离线渲染，不碰系统
bash tests/test_apt_repair.sh  # Debian 源修复逻辑，不调 apt
bash tests/test_eof.sh         # 菜单 EOF / 非法输入行为
bash tests/lint.sh             # 语法 + 反模式扫描 + shellcheck（若装）
```

---

## 排障

**`apt-get update` 报 `does not have a Release file`（Debian 老版本）**：

典型输出：

```
E: The repository 'http://security.debian.org bullseye/updates Release' does not have a Release file.
E: The repository 'http://deb.debian.org/debian bullseye-backports Release' does not have a Release file.
```

原因是 Debian 11 及更早的 `security.debian.org <codename>/updates` 这种旧写法早已废弃，
`*-backports` 在发行版进入 LTS/归档后也会被撤。

**更坑的是第二种情况**：`apt-get update` 能过，但 `apt-get install` 报一片 404 ——
索引还在、pool 里的 `.deb` 已被清走。真机实测就是这个状态：

```
E: Failed to fetch http://security.debian.org/debian-security/pool/updates/main/n/nginx/nginx-common_1.18.0-6.1+deb11u8_all.deb  404  Not Found
E: Unable to fetch some archives, maybe run apt-get update or try with --fix-missing?
```

所以脚本走**四级阶梯**，任一级成功即停，且 `update` 失败和 `install` 下载失败都会触发升档：

| 级 | 动作 | 适用 |
|---|---|---|
| 1 | 直接装 | 源正常 |
| 2 | 最小修源：剔 `/<suite>/updates` 与 `*-backports`，security 补正为 `security.debian.org/debian-security <codename>-security` | 旧写法失效，主源还好 |
| 3 | 只把 security 挪到 `archive.debian.org/debian-security`，**主源继续用快镜像** | 索引在但 security pool 已空 ← 真机实测的这个 |
| 4 | 整体切 `archive.debian.org` + `Acquire::Check-Valid-Until "false"` | 发行版彻底 EOL，主源也没了 |

前两级备份成 `*.selfcdn.bak`，第三级另存 `*.selfcdn.bak2`。手动触发：

```bash
selfcdn --fix-apt
```

改坏了回滚：

```bash
mv /etc/apt/sources.list.selfcdn.bak /etc/apt/sources.list
rm -f /etc/apt/apt.conf.d/99selfcdn-archive
apt-get update
```

如果还不行，把 `/etc/apt/sources.list.selfcdn.bak2` 也还原回去。

codename 从 `/etc/os-release` 取，取不到就从现有源的 suite 反推，**不硬编码**。
第三方源不会被误伤（只有 `deb.debian.org` / `security.debian.org` 会被改写）。
组件列表沿用你主源那一行，不会擅自打开 `non-free`；原文带 `deb-src` 的，security 也补
`deb-src` 保持对称，`apt-get source` 不断。

---

**`nginx -t` 失败**：看输出里指的行。最常见是 80/443 被占用（
`ss -lntp | grep :80` 找现行监听，通常是自带的 default_server）。

**证书申请失败**：

```bash
# 1. DNS 对不对
dig +short static.example.com
# 2. 80 端口通不通（从外面另一台机器）
curl -v http://static.example.com/.well-known/acme-challenge/test
# 3. acme.sh 日志
acme.sh --issue -d static.example.com -w /var/www/selfcdn-acme --debug 2
```

常见原因按概率排：A 记录没生效 / 安全组没开 80 / 运营商封 80 / 域名未备案被墙 /
LE 对该域名多次失败已限流（等一周）。

**缓存不命中**：先 `curl -I` 看 `X-Cache-Status`。

- `MISS` 每次都这样 → 源站响应带了 `Set-Cookie` 或 `Cache-Control: no-cache`
- 响应头压根没有 `X-Cache-Status` → 缓存没开，检查 `/etc/selfcdn/nodes/<name>.conf` 里 `CACHE_ENABLE`
- `BYPASS` → 请求带了 `Authorization`

**回源 404/421**：回源 Host 头配错了，见上文。

**改了配置不生效**：菜单 `7` 重载。如果报配置错，脚本会打印 `nginx -t` 原文。

---

## 卸载

菜单 `12` 输 `DELETE`，清掉所有节点、证书、缓存、日志、`/etc/selfcdn`。
保留 Nginx 和 acme.sh 本身（它们可能还有别的用途）。

彻底删干净：

```bash
selfcdn          # 菜单 12
apt remove nginx || dnf remove nginx
rm -rf /root/.acme.sh
crontab -l | grep -v acme | crontab -
```

---

## 免责

脚本会改 `/etc/nginx/conf.d/`、`/etc/selfcdn/`、`/var/cache/nginx/`、crontab。
**跑之前先看一遍代码**，生产机先快照/备份。

`selfcdn.sh` 以 root 跑，会装包（nginx/curl/openssl/cron）和写系统路径。
自己清楚在做什么再用。

## License

MIT