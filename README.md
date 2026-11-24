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

**已离线验证**（`bash tests/test_render.sh` 37 项 + `bash tests/lint.sh`）：

配置生成结构、占位符全替换、HTTP 引导期不下发 HSTS、HTTPS 期证书路径、
连字符节点名转下划线做 Nginx ID、缓存关闭时不残留 `proxy_cache`、
节点登记文件 `%q` 往返（含 `$host` 这类 Nginx 变量的转义保全）、
IPv6 关闭时不生成 `[::]` 监听、无残缺 `listen` 行、
`reload` 前强制 `nginx_test`、`rm -rf` 无未加引号变量、`${VAR:?}` 空值保护。

**未在线验证**：证书签发全链路、真实 Nginx 下的缓存命中。
本机没有任何 Linux 运行时（WSL 无发行版、无 Docker），`nginx -t` 只在目标机执行，
脚本每次 reload 前都强制过这一关，不过即中止。

**所以第一次请拿测试域名跑**，别直接上生产域名。

自测命令：

```bash
bash tests/test_render.sh    # 离线渲染验证，不碰系统
bash tests/lint.sh           # 语法 + 反模式扫描 + shellcheck（若装）
```

---

## 排障

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