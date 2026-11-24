#!/usr/bin/env bash
# language: bash, file: selfcdn.sh
# SelfCDN — 自建 CDN 边缘节点：Nginx 反代 + 代理缓存 + Let's Encrypt 自动证书
# target: Debian/Ubuntu · RHEL/CentOS/Rocky/Alma · 需 root
set -uo pipefail

VERSION="1.0.0"

BASE=/etc/selfcdn
NODES_DIR=$BASE/nodes
CERT_DIR=$BASE/certs
EMAIL_FILE=$BASE/email
NGINX_CONF_D=/etc/nginx/conf.d
GLOBAL_CONF=$NGINX_CONF_D/00-selfcdn-global.conf
CACHE_ROOT=/var/cache/nginx/selfcdn
ACME_ROOT=/var/www/selfcdn-acme
ACME_HOME=/root/.acme.sh
ACME_SH=$ACME_HOME/acme.sh

R='\033[31m'; G='\033[32m'; Y='\033[33m'; B='\033[36m'; D='\033[2m'; N='\033[0m'

info() { printf "${B}[*]${N} %s\n" "$*"; }
ok()   { printf "${G}[+]${N} %s\n" "$*"; }
warn() { printf "${Y}[!]${N} %s\n" "$*"; }
err()  { printf "${R}[x]${N} %s\n" "$*" >&2; }
die()  { err "$*"; exit 1; }
pause() { read -rp "回车继续..." _ || true; }

need_root() {
  [[ ${EUID:-0} -eq 0 ]] || die "需要 root：sudo bash $0"
}

# ---------------------------------------------------------------- 环境准备
detect_os() {
  if   command -v apt-get >/dev/null 2>&1; then PKG=apt
  elif command -v dnf     >/dev/null 2>&1; then PKG=dnf
  elif command -v yum     >/dev/null 2>&1; then PKG=yum
  else die "不支持的发行版（需要 apt / dnf / yum）"
  fi
}

pkg_install() {
  case $PKG in
    apt) DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" ;;
    dnf) dnf install -y -q "$@" ;;
    yum) yum install -y -q "$@" ;;
  esac
}

install_deps() {
  detect_os
  local miss=()
  command -v nginx   >/dev/null 2>&1 || miss+=(nginx)
  command -v curl    >/dev/null 2>&1 || miss+=(curl)
  command -v openssl >/dev/null 2>&1 || miss+=(openssl)
  command -v crontab >/dev/null 2>&1 || miss+=(cron)
  if [[ ${#miss[@]} -gt 0 ]]; then
    info "安装依赖: ${miss[*]}"
    pkg_install "${miss[@]}" || die "依赖安装失败"
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now nginx >/dev/null 2>&1 || true
  else
    nginx >/dev/null 2>&1 || true
  fi
  ok "依赖就绪"
}

ensure_dirs() {
  mkdir -p "$NODES_DIR" "$CERT_DIR" "$ACME_ROOT" "$CACHE_ROOT"
  chmod 700 "$BASE" "$NODES_DIR" "$CERT_DIR"
  local u
  u=$(awk -F: '/^www-data:/{print $1; exit}' /etc/passwd)
  [[ -z $u ]] && u=$(awk -F: '/^nginx:/{print $1; exit}' /etc/passwd)
  [[ -z $u ]] && u=nginx
  chown -R "$u":"$u" "$CACHE_ROOT" 2>/dev/null || true
}

nginx_version_gate() {
  NGINX_VER=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  [[ -z $NGINX_VER ]] && NGINX_VER=0.0.0
  local major minor
  major=${NGINX_VER%%.*}
  minor=${NGINX_VER#*.}
  minor=${minor%%.*}
  # IPv6 被内核关闭时 [::] 监听会让 nginx -t 直接 bind 失败，探测后按需追加
  if [[ -f /proc/net/if_inet6 ]] && ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
    V6_LISTEN80=$'\n    listen [::]:80;'
    V6_LISTEN443=$'\n    listen [::]:443 ssl;'
  else
    V6_LISTEN80=""
    V6_LISTEN443=""
  fi
  if (( major > 1 || ( major == 1 && minor >= 25 ) )); then
    SSL_LISTEN=$'\n    listen 443 ssl;'"${V6_LISTEN443}"$'\n    http2 on;'
  else
    SSL_LISTEN=$'\n    listen 443 ssl http2;'"${V6_LISTEN443/443 ssl/443 ssl http2;}"$'\n'
  fi
}

write_global_conf() {
  cat > "$GLOBAL_CONF" <<'NGINX'
# SelfCDN — 全局片段，由 selfcdn.sh 自动生成
# 手工修改会在下次增删节点时被覆盖
map $http_upgrade $connection_upgrade {
    default upgrade;
    ""      close;
}
NGINX
}

ACME_URL="https://acme-v02.api.letsencrypt.org/directory"

acme_present() { [[ -x $ACME_SH ]]; }

ensure_acme() {
  acme_present && return 0
  local email
  email=$(cat "$EMAIL_FILE" 2>/dev/null || true)
  if [[ -z $email ]]; then
    echo
    read -rp "Let's Encrypt 账户邮箱（用于到期提醒）: " email
    [[ -n $email ]] || die "邮箱不能为空"
    echo "$email" > "$EMAIL_FILE"
    chmod 600 "$EMAIL_FILE"
  fi
  info "安装 acme.sh ..."
  curl -fsS https://get.acme.sh | sh -s "email=$email" >/dev/null 2>&1 \
    || die "acme.sh 安装失败（检查出网）"
  acme_present || die "acme.sh 未安装成功（预期路径 $ACME_SH）"
  "$ACME_SH" --set-default-ca --server "$ACME_URL" >/dev/null 2>&1 || true
  ok "acme.sh 就绪（$ACME_HOME）"
}

# ---------------------------------------------------------------- 节点登记
node_file() { echo "$NODES_DIR/$1.conf"; }

node_exists() { [[ -f $(node_file "$1") ]]; }

list_node_names() {
  local f
  for f in "$NODES_DIR"/*.conf; do
    [[ -e $f ]] || continue
    basename "$f" .conf
  done
}

load_node() {
  local name=$1
  node_exists "$name" || die "节点不存在: $name"
  # shellcheck disable=SC1090
  source "$(node_file "$name")"
}

save_node() {
  local name=$1
  {
    printf 'NAME=%q\n'             "$NAME"
    printf 'DOMAIN=%q\n'           "$DOMAIN"
    printf 'UPSTREAMS=%q\n'        "$UPSTREAMS"
    printf 'UPSTREAM_SCHEME=%q\n'  "$UPSTREAM_SCHEME"
    printf 'PROXY_HOST=%q\n'       "$PROXY_HOST"
    printf 'CACHE_ENABLE=%q\n'     "$CACHE_ENABLE"
    printf 'CACHE_TTL=%q\n'        "$CACHE_TTL"
    printf 'CACHE_SIZE=%q\n'       "$CACHE_SIZE"
    printf 'CACHE_MEM=%q\n'        "$CACHE_MEM"
    printf 'CLIENT_MAX_BODY=%q\n'  "$CLIENT_MAX_BODY"
    printf 'TLS_MODE=%q\n'         "$TLS_MODE"
    printf 'CREATED=%q\n'          "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$(node_file "$name")"
  chmod 600 "$(node_file "$name")"
}

validate_name()   { [[ $1 =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]]; }
validate_domain() { [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])$ ]] && [[ $1 == *.* ]]; }
nginx_id()        { echo "${1//-/_}"; }

normalize_upstream() {
  local h=$1
  h=${h#http://}; h=${h#https://}; h=${h%%/*}
  [[ $h =~ ^[^:]+$ ]] && h="$h:80"
  echo "$h"
}

rebuild_cache_zones() {
  write_global_conf
  local n
  while read -r n; do
    [[ -z $n ]] && continue
    # shellcheck disable=SC1090
    source "$(node_file "$n")"
    [[ ${CACHE_ENABLE:-0} == 1 ]] || continue
    local zid; zid=$(nginx_id "$n")
    cat >> "$GLOBAL_CONF" <<NGINX

proxy_cache_path $CACHE_ROOT/$n levels=1:2 keys_zone=cdn_${zid}:${CACHE_MEM} max_size=${CACHE_SIZE} inactive=${CACHE_TTL} use_temp_path=off;
NGINX
  done < <(list_node_names)
}

# ---------------------------------------------------------------- 配置生成
gen_node_conf() {
  local name=$1
  load_node "$name"
  local zid; zid=$(nginx_id "$name")
  local conf=$NGINX_CONF_D/selfcdn-$name.conf
  local cert="$CERT_DIR/$name/fullchain.cer"
  local key="$CERT_DIR/$name/$DOMAIN.key"

  local upstream_block="" u
  for u in $UPSTREAMS; do
    upstream_block+="    server $u max_fails=3 fail_timeout=30s;"$'\n'
  done

  # location 内 add_header 会覆盖 server 级同名继承，所以安全头随 location 一起下发
  local cache_directives="" hdr_https hdr_http
  # 安全头（HTTPS / 纯 HTTP 两套，避免引导期下发 HSTS）
  hdr_https=$(cat <<NGINX
        add_header X-CDN-Node "${name}" always;
        add_header X-Content-Type-Options nosniff always;
        add_header Strict-Transport-Security "max-age=31536000" always;
NGINX
)
  hdr_http=$(cat <<NGINX
        add_header X-CDN-Node "${name}" always;
        add_header X-Content-Type-Options nosniff always;
NGINX
)

  if [[ $CACHE_ENABLE == 1 ]]; then
    cache_directives=$(cat <<NGINX
        proxy_cache cdn_${zid};
        proxy_cache_key \$scheme\$request_method\$host\$request_uri;
        proxy_cache_valid 200 206 301 302 ${CACHE_TTL};
        proxy_cache_valid 404 1m;
        proxy_cache_use_stale error timeout invalid_header updating http_500 http_502 http_503 http_504;
        proxy_cache_background_update on;
        proxy_cache_lock on;
        proxy_cache_lock_age 30s;
        proxy_cache_lock_timeout 30s;
        proxy_cache_revalidate on;
        proxy_cache_bypass \$http_authorization \$cookie_nocache;
        proxy_no_cache \$http_authorization \$cookie_nocache;
        add_header X-Cache-Status \$upstream_cache_status always;
NGINX
)
  fi
  local cache_block="${cache_directives}${hdr_https}"
  local cache_block_http="${cache_directives}${hdr_http}"

  local common_proxy
  common_proxy=$(cat <<NGINX
        proxy_pass ${UPSTREAM_SCHEME}://${zid}_up;
        proxy_http_version 1.1;
        proxy_set_header Host              ${PROXY_HOST};
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host  \$host;
        proxy_set_header Upgrade           \$http_upgrade;
        proxy_set_header Connection        \$connection_upgrade;
        proxy_hide_header X-Powered-By;

        proxy_connect_timeout 10s;
        proxy_send_timeout    60s;
        proxy_read_timeout    60s;
        proxy_buffering on;
        proxy_buffers 16 32k;
        proxy_busy_buffers_size 64k;
NGINX
)

  if [[ -f $cert && -f $key ]]; then
    cat > "$conf" <<NGINX
# SelfCDN node: ${name} — 由 selfcdn.sh 生成，请勿手改
upstream ${zid}_up {
${upstream_block}}

server {
    listen 80;${V6_LISTEN80}
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ { root ${ACME_ROOT}; }
    location / { return 301 https://\$host\$request_uri; }
}

server {${SSL_LISTEN}
    server_name ${DOMAIN};

    ssl_certificate     ${cert};
    ssl_certificate_key ${key};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL_${zid}:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    server_tokens off;
    client_max_body_size ${CLIENT_MAX_BODY};

    gzip on;
    gzip_vary on;
    gzip_comp_level 5;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/xml application/json application/javascript application/xml application/rss+xml image/svg+xml;

    access_log /var/log/nginx/selfcdn-${name}.access.log;
    error_log  /var/log/nginx/selfcdn-${name}.error.log warn;

    location = /.well-known/acme-challenge/ { return 404; }

    location / {
${common_proxy}
${cache_block}    }
}
NGINX
  else
    cat > "$conf" <<NGINX
# SelfCDN node: ${name} — HTTP 引导模式（证书未签发）
upstream ${zid}_up {
${upstream_block}}

server {
    listen 80;${V6_LISTEN80}
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ { root ${ACME_ROOT}; }

    access_log /var/log/nginx/selfcdn-${name}.access.log;
    error_log  /var/log/nginx/selfcdn-${name}.error.log warn;

    location / {
${common_proxy}
${cache_block_http}    }
}
NGINX
  fi
  ok "配置生成: $conf"
}

nginx_test() {
  local out
  out=$(nginx -t 2>&1)
  if grep -q "syntax is ok" <<< "$out" && grep -q "test is successful" <<< "$out"; then
    return 0
  fi
  err "nginx -t 失败:"
  sed 's/^/    /' <<< "$out" >&2
  return 1
}

nginx_reload() {
  # 返回非 0 而不是 die：调用方决定是中止还是继续（菜单重载失败不该退程序）
  nginx_test || return 1
  if command -v systemctl >/dev/null 2>&1; then
    systemctl reload nginx 2>/dev/null || nginx -s reload
  else
    nginx -s reload
  fi
  ok "Nginx 已重载 (v$NGINX_VER)"
  return 0
}

# ---------------------------------------------------------------- 证书
issue_cert() {
  local name=$1 mode=${2:-webroot}
  load_node "$name"
  ensure_acme

  local dns_ip server_ip
  dns_ip=$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1; exit}')
  server_ip=$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)
  if [[ -n $dns_ip && -n $server_ip && $dns_ip != "$server_ip" ]]; then
    warn "DNS 解析 $DOMAIN → $dns_ip，本机出口 → $server_ip"
    warn "http-01 校验大概率失败，请先改 A 记录"
    local a; read -rp "仍然继续？[y/N] " a
    [[ $a =~ ^[Yy]$ ]] || return 1
  fi

  mkdir -p "$ACME_ROOT"
  local arr=(--issue -d "$DOMAIN" --keylength ec-256 --server "$ACME_URL")

  # 已签发过就直接续期，--issue 对同域会被 acme.sh 拒绝
  local verb="issue"
  if "$ACME_SH" --info -d "$DOMAIN" 2>/dev/null | grep -q "Le_RealCertPath\|Le_CertCreateTime"; then
    verb="renew"
    local rd
    rd=$("$ACME_SH" --info -d "$DOMAIN" 2>/dev/null | awk -F= '/Le_NextRenewTimeStr/{print $2; exit}')
    info "该域已有证书${rd:+（下次续期 $rd）}，走 renew 分支"
  fi

  info "申请证书 [$mode/$verb]: $DOMAIN"
  local rc=1
  if [[ $verb == renew ]]; then
    "$ACME_SH" --renew -d "$DOMAIN" --ecc --server "$ACME_URL" && rc=0
    # 未到续期窗口时 renew 返回非 0，但证书仍有效 —— 继续走 install
    [[ -f "$ACME_HOME/${DOMAIN}_ecc/${DOMAIN}.cer" ]] && rc=0
  elif [[ $mode == webroot ]]; then
    "$ACME_SH" "${arr[@]}" -w "$ACME_ROOT" && rc=0
    if (( rc != 0 )); then
      warn "webroot 失败，降级 standalone 重试 ..."
      if command -v systemctl >/dev/null 2>&1; then systemctl stop nginx 2>/dev/null || true; else nginx -s stop 2>/dev/null || true; fi
      "$ACME_SH" "${arr[@]}" --standalone && rc=0
      if command -v systemctl >/dev/null 2>&1; then systemctl start nginx 2>/dev/null || true; else nginx 2>/dev/null || true; fi
    fi
  else
    if command -v systemctl >/dev/null 2>&1; then systemctl stop nginx 2>/dev/null || true; else nginx -s stop 2>/dev/null || true; fi
    "$ACME_SH" "${arr[@]}" --standalone && rc=0
    if command -v systemctl >/dev/null 2>&1; then systemctl start nginx 2>/dev/null || true; else nginx 2>/dev/null || true; fi
  fi

  if (( rc != 0 )); then
    err "证书申请失败: $DOMAIN"
    echo "    常见原因：A 记录未生效 / 80 端口被封 / 域名未备案被拦 / 家宽 80 被运营商封禁" >&2
    return 1
  fi

  install_cert "$name" || return 1
  ok "证书就绪: $CERT_DIR/$name"
}

install_cert() {
  local name=$1
  load_node "$name"
  mkdir -p "$CERT_DIR/$name"
  "$ACME_SH" --install-cert -d "$DOMAIN" --ecc \
    --key-file       "$CERT_DIR/$name/$DOMAIN.key" \
    --fullchain-file "$CERT_DIR/$name/fullchain.cer" \
    --reloadcmd     "systemctl reload nginx 2>/dev/null || nginx -s reload" >/dev/null 2>&1 \
    || { err "证书安装失败（可能尚未签发）"; return 1; }
  chmod 600 "$CERT_DIR/$name/$DOMAIN.key"
  chmod 644 "$CERT_DIR/$name/fullchain.cer"
  return 0
}

# ---------------------------------------------------------------- 功能 1 新增
add_node() {
  echo
  local name domain raw_up u nu
  read -rp "节点标识（小写字母/数字，如 edge1）: " name
  validate_name "$name" || die "标识不合法（^[a-z0-9][a-z0-9_-]{0,31}$）"

  if node_exists "$name"; then
    warn "节点 $name 已存在，继续将覆盖其配置"
    local a; read -rp "继续？[y/N] " a
    [[ $a =~ ^[Yy]$ ]] || return 0
  fi

  read -rp "绑定域名（如 static.example.com）: " domain
  validate_domain "$domain" || die "域名不合法"
  DOMAIN=$domain; NAME=$name

  read -rp "回源 IP:端口（多个用空格，如 1.2.3.4:8080 5.6.7.8:80）: " raw_up
  [[ -n $raw_up ]] || die "回源地址不能为空"
  UPSTREAMS=""
  for u in $raw_up; do
    nu=$(normalize_upstream "$u")
    [[ $nu =~ ^[^:]+:[0-9]+$ ]] || die "回源格式错误: $u"
    UPSTREAMS+="$nu "
  done
  UPSTREAMS=${UPSTREAMS% }

  read -rp "回源协议 [http/https]（默认 http）: " UPSTREAM_SCHEME
  UPSTREAM_SCHEME=${UPSTREAM_SCHEME:-http}
  [[ $UPSTREAM_SCHEME == http || $UPSTREAM_SCHEME == https ]] || die "协议只能是 http 或 https"

  local def_host='$host'
  read -rp "回源 Host 头（默认保留客户端 Host，回车保持）: " PROXY_HOST
  PROXY_HOST=${PROXY_HOST:-$def_host}

  local c
  read -rp "启用缓存？[Y/n]（默认 Y）: " c
  [[ $c =~ ^[Nn]$ ]] && CACHE_ENABLE=0 || CACHE_ENABLE=1
  read -rp "缓存有效期 TTL（默认 24h）: "  CACHE_TTL;       CACHE_TTL=${CACHE_TTL:-24h}
  read -rp "缓存磁盘上限（默认 5g）: "     CACHE_SIZE;      CACHE_SIZE=${CACHE_SIZE:-5g}
  read -rp "缓存内存索引（默认 100m）: "   CACHE_MEM;       CACHE_MEM=${CACHE_MEM:-100m}
  read -rp "最大请求体（默认 100m）: "     CLIENT_MAX_BODY; CLIENT_MAX_BODY=${CLIENT_MAX_BODY:-100m}
  TLS_MODE=acme

  save_node "$name"
  # 不删旧证书：换域名时 $DOMAIN.key 自然对不上，gen_node_conf 会自动回落到引导模式
  rebuild_cache_zones
  gen_node_conf "$name"
  nginx_test || { err "配置测试失败，节点未启用"; pause; return 1; }
  nginx_reload || { err "重载失败，节点未启用"; pause; return 1; }
  ok "HTTP 引导模式已生效: http://$DOMAIN"

  local a
  read -rp "现在申请证书并切换 HTTPS？[Y/n]（默认 Y）: " a
  if [[ ! $a =~ ^[Nn]$ ]]; then
    if issue_cert "$name" webroot; then
      gen_node_conf "$name"
      if nginx_reload; then ok "节点上线: https://$DOMAIN"
      else err "HTTPS 配置重载失败，节点仍停在 HTTP 模式"; fi
    else
      warn "证书未签。稍后可用菜单 4 重试；当前节点仅 HTTP"
    fi
  else
    warn "跳过证书。DNS 就绪后用菜单 4 申请"
  fi
  pause
}

# ---------------------------------------------------------------- 功能 2 列表
plain_list() {
  local n
  while read -r n; do
    [[ -z $n ]] && continue
    # shellcheck disable=SC1090
    source "$(node_file "$n")"
    echo "  - $n  →  $DOMAIN  ($UPSTREAM_SCHEME://$UPSTREAMS)"
  done < <(list_node_names)
}

list_nodes() {
  local names n idx=0
  names=$(list_node_names)
  if [[ -z $names ]]; then echo; echo "（暂无节点）"; pause; return; fi
  echo
  printf "%-4s %-12s %-32s %-26s %-6s %s\n" "#" "标识" "域名" "回源" "缓存" "证书到期"
  printf '%s\n' "--------------------------------------------------------------------------------------------------------"
  while read -r n; do
    [[ -z $n ]] && continue
    # shellcheck disable=SC1090
    source "$(node_file "$n")"
    idx=$((idx+1))
    local ce=off; [[ ${CACHE_ENABLE:-0} == 1 ]] && ce=on
    local cert="未签发"
    # 证书必须与当前域名匹配，换域名后旧证书不算有效
    if [[ -f "$CERT_DIR/$n/fullchain.cer" && -f "$CERT_DIR/$n/$DOMAIN.key" ]]; then
      local e; e=$(openssl x509 -enddate -noout -in "$CERT_DIR/$n/fullchain.cer" 2>/dev/null | cut -d= -f2)
      cert=${e:-未知}
    fi
    printf "%-4s %-12s %-32s %-26s %-6s %s\n" "$idx" "$n" "$DOMAIN" "$UPSTREAMS" "$ce" "$cert"
  done <<< "$names"
  echo
  pause
}

# ---------------------------------------------------------------- 功能 3 删除
del_node() {
  local names n
  names=$(list_node_names)
  [[ -z $names ]] && { echo "（暂无节点）"; pause; return; }
  plain_list
  read -rp "要删除的节点标识: " n
  node_exists "$n" || die "节点不存在: $n"
  load_node "$n"
  read -rp "确认删除 $n（$DOMAIN，含证书与缓存）？输入 yes: " c
  [[ $c == yes ]] || { warn "已取消"; pause; return; }

  rm -f "$NGINX_CONF_D/selfcdn-$n.conf"
  acme_present && "$ACME_SH" --remove -d "$DOMAIN" >/dev/null 2>&1 || true
  rm -rf "$CERT_DIR/$n" "$CACHE_ROOT/$n"
  rm -f "$(node_file "$n")"
  rm -f "/var/log/nginx/selfcdn-$n.access.log" "/var/log/nginx/selfcdn-$n.error.log"
  rebuild_cache_zones
  nginx_reload || { err "重载失败：请检查 $NGINX_CONF_D"; pause; return 1; }
  ok "节点 $n 已删除"
  pause
}

# ---------------------------------------------------------------- 功能 4 单节点证书
issue_one() {
  local n
  plain_list
  read -rp "节点标识: " n
  node_exists "$n" || die "节点不存在: $n"
  if issue_cert "$n" webroot; then
    gen_node_conf "$n"
    if nginx_reload; then ok "证书已签发并切换 HTTPS"; else err "重载失败"; fi
  fi
  pause
}

# ---------------------------------------------------------------- 功能 5 全部续期
renew_all() {
  ensure_acme
  info "acme.sh --cron 全量续期 ..."
  "$ACME_SH" --cron --home "$ACME_HOME" 2>&1 | sed 's/^/    /'
  local n
  while read -r n; do
    [[ -z $n ]] && continue
    install_cert "$n" && ok "证书同步: $n" || warn "证书同步跳过: $n"
  done < <(list_node_names)
  nginx_reload || warn "重载失败，请检查配置"
  pause
}

# ---------------------------------------------------------------- 功能 6 清缓存
purge_cache() {
  local n
  plain_list
  read -rp "节点标识（all = 全部）: " n
  if [[ $n == all ]]; then
    rm -rf "${CACHE_ROOT:?}"/* 2>/dev/null || true
    ok "全部节点缓存已清空"
  else
    node_exists "$n" || die "节点不存在: $n"
    rm -rf "${CACHE_ROOT:?}/$n"/* 2>/dev/null || true
    ok "节点 $n 缓存已清空"
  fi
  pause
}

# ---------------------------------------------------------------- 功能 8 查看配置
show_node() {
  local n
  plain_list
  read -rp "节点标识: " n
  node_exists "$n" || die "节点不存在: $n"
  echo; echo "===== 节点登记 $NODES_DIR/$n.conf ====="
  sed 's/^/  /' "$(node_file "$n")"
  echo; echo "===== Nginx 配置 $NGINX_CONF_D/selfcdn-$n.conf ====="
  if [[ -f $NGINX_CONF_D/selfcdn-$n.conf ]]; then
    sed 's/^/  /' "$NGINX_CONF_D/selfcdn-$n.conf"
  else
    echo "  （尚未生成）"
  fi
  if [[ -f "$CERT_DIR/$n/fullchain.cer" && -f "$CERT_DIR/$n/$DOMAIN.key" ]]; then
    echo; echo "===== 证书信息 ====="
    openssl x509 -noout -subject -issuer -dates -in "$CERT_DIR/$n/fullchain.cer" 2>/dev/null | sed 's/^/  /'
  elif [[ -f "$CERT_DIR/$n/fullchain.cer" ]]; then
    echo; echo "===== 证书信息（与当前域名不匹配，需重新签发）====="
    openssl x509 -noout -subject -dates -in "$CERT_DIR/$n/fullchain.cer" 2>/dev/null | sed 's/^/  /'
  fi
  pause
}

# ---------------------------------------------------------------- 功能 9 日志/命中率
show_logs() {
  local n
  plain_list
  read -rp "节点标识: " n
  node_exists "$n" || die "节点不存在: $n"
  local acc="/var/log/nginx/selfcdn-$n.access.log"
  local erl="/var/log/nginx/selfcdn-$n.error.log"
  echo
  echo "1) access 日志 + 命中率"
  echo "2) error 日志"
  echo "3) 实时跟踪 access（Ctrl-C 退出）"
  read -rp "选择 [1/2/3]（默认 1）: " s
  case ${s:-1} in
    2) echo; tail -n 100 "$erl" 2>/dev/null || echo "（无日志 $erl）" ;;
    3) echo; tail -f "$acc" 2>/dev/null || echo "（无日志 $acc）" ;;
    *) echo
       tail -n 50 "$acc" 2>/dev/null || echo "（无日志 $acc）"
       echo
       info "缓存命中分布（X-Cache-Status）"
       awk -F'X-Cache-Status: ' 'NF>1{split($2,a,"\"");c[a[1]]++} END{if(length(c)==0){print "    （暂无记录，响应头需带 X-Cache-Status）"}else{for(k in c) printf "    %-10s %d\n", k, c[k]}}' "$acc" 2>/dev/null ;;
  esac
  pause
}

# ---------------------------------------------------------------- 功能 10 状态
show_status() {
  echo; echo "===== Nginx ====="
  if command -v systemctl >/dev/null 2>&1; then
    printf "  service: %s\n" "$(systemctl is-active nginx 2>/dev/null)"
  fi
  printf "  version: %s\n" "$NGINX_VER"

  echo; echo "===== 监听 80/443 ====="
  if command -v ss >/dev/null 2>&1; then
    ss -lntp 2>/dev/null | awk 'NR==1 || /:80 |:443 /' | sed 's/^/  /'
  elif command -v netstat >/dev/null 2>&1; then
    netstat -lntp 2>/dev/null | awk 'NR<=2 || /:80 |:443 /' | sed 's/^/  /'
  else
    echo "  （无 ss / netstat）"
  fi

  echo; echo "===== 防火墙 ====="
  if command -v ufw >/dev/null 2>&1; then ufw status 2>/dev/null | sed 's/^/  /'
  elif command -v firewall-cmd >/dev/null 2>&1; then firewall-cmd --list-all 2>/dev/null | sed 's/^/  /'
  else echo "  （未检测到 ufw / firewalld）"; fi

  echo; echo "===== 节点 ====="
  local c; c=$(list_node_names | wc -l | tr -d ' ')
  echo "  总数: $c"
  plain_list

  echo; echo "===== 证书剩余天数 ====="
  local n
  while read -r n; do
    [[ -z $n ]] && continue
    if [[ -f "$CERT_DIR/$n/fullchain.cer" && -f "$CERT_DIR/$n/$DOMAIN.key" ]]; then
      local days
      days=$(( ( $(date -d "$(openssl x509 -enddate -noout -in "$CERT_DIR/$n/fullchain.cer" 2>/dev/null | cut -d= -f2)" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
      printf "  %-12s %s 天\n" "$n" "$days"
    else
      printf "  %-12s 未签发\n" "$n"
    fi
  done < <(list_node_names)

  echo; echo "===== acme.sh 自动续期 ====="
  crontab -l 2>/dev/null | grep -i acme | sed 's/^/  /' || echo "  （未发现 acme cron，检查 crontab -l）"

  echo; echo "===== 缓存占用 ====="
  du -sh "$CACHE_ROOT" 2>/dev/null | sed 's/^/  /' || echo "  （无）"

  pause
}

# ---------------------------------------------------------------- 功能 11 邮箱
set_email() {
  echo
  local e
  read -rp "Let's Encrypt 账户邮箱: " e
  [[ -n $e ]] || die "邮箱不能为空"
  echo "$e" > "$EMAIL_FILE"; chmod 600 "$EMAIL_FILE"
  ok "已保存: $e"
  warn "已装 acme.sh 的账户邮箱不会变更；更换需 acme.sh --update-account -m 新邮箱"
  pause
}

# ---------------------------------------------------------------- 功能 12 清空
uninstall_all() {
  warn "将删除全部节点配置、证书、缓存、日志与 $BASE"
  warn "保留已安装的 nginx 与 acme.sh"
  local c; read -rp "输入 DELETE 确认: " c
  [[ $c == DELETE ]] || { warn "已取消"; pause; return; }
  local n
  while read -r n; do
    [[ -z $n ]] && continue
    load_node "$n"
    rm -f "$NGINX_CONF_D/selfcdn-$n.conf"
    acme_present && "$ACME_SH" --remove -d "$DOMAIN" >/dev/null 2>&1 || true
    rm -f "/var/log/nginx/selfcdn-$n.access.log" "/var/log/nginx/selfcdn-$n.error.log"
  done < <(list_node_names)
  rm -f "$GLOBAL_CONF"
  rm -rf "$CACHE_ROOT" "$BASE" "$ACME_ROOT"
  nginx_reload || warn "重载失败，请手工检查 $NGINX_CONF_D"
  ok "已清空全部 CDN 节点"
  pause
}

# ---------------------------------------------------------------- 主菜单
banner() {
  clear 2>/dev/null || true
  cat <<BANNER
${B}   ____       _  __   ____ ____  _   _
  / ___|  ___| || |  / ___|  _ \| \ | |
  \___ \ / _ \ || |_| |   | | | |  \| |
   ___) |  __/__   _| |___| |_| | |\  |
  |____/ \___|  |_|  \____|____/|_| \_|${N}
   SelfCDN v$VERSION — 自建 CDN 边缘节点
   Nginx 反代 + 代理缓存 + Let's Encrypt
${D}   ----------------------------------------${N}
BANNER
}

main_menu() {
  while true; do
    banner
    cat <<MENU
   1) 添加 / 更新 CDN 节点
   2) 列出全部节点
   3) 删除节点
   4) 申请 / 续期单节点证书
   5) 全部续期
   6) 清理缓存
   7) 重载 Nginx
   8) 查看节点配置
   9) 查看日志 / 命中率
  10) 运行状态总览
  11) 设置 ACME 邮箱
  12) 清空全部节点
   0) 退出

MENU
    read -rp "选择序号: " choice
    case ${choice:-} in
      1)  add_node ;;
      2)  list_nodes ;;
      3)  del_node ;;
      4)  issue_one ;;
      5)  renew_all ;;
      6)  purge_cache ;;
      7)
          nginx_test && nginx_reload
          pause ;;
      8)  show_node ;;
      9)  show_logs ;;
      10) show_status ;;
      11) set_email ;;
      12) uninstall_all ;;
      0|q|Q) ok "bye"; exit 0 ;;
      *)  warn "无效序号: $choice"; pause ;;
    esac
  done
}

main() {
  need_root
  install_deps
  ensure_dirs
  nginx_version_gate
  write_global_conf
  if ! nginx_reload; then
    warn "Nginx 初始重载失败，通常是 80/443 已被占用"
    warn "排查看: ss -lntp | grep -E ':(80|443)\\b'"
    warn "菜单仍可使用，节点配置已就绪"
  fi
  main_menu
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi