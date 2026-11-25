#!/usr/bin/env bash
# language: bash, file: selfcdn.sh
# SelfCDN — 自建 CDN 边缘节点：Nginx 反代 + 代理缓存 + Let's Encrypt 自动证书
# target: Debian/Ubuntu · RHEL/CentOS/Rocky/Alma · 需 root
set -uo pipefail

VERSION="1.1.5"

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

# apt 源路径（可在测试中被覆盖）
APT_SOURCES=${APT_SOURCES:-/etc/apt/sources.list}
APT_SOURCES_D=${APT_SOURCES_D:-/etc/apt/sources.list.d}
APT_CONF_D=${APT_CONF_D:-/etc/apt/apt.conf.d}

# 颜色用真实 ESC（$'..'）。printf 会解释 \033，但 cat <<HEREDOC 不会 —— 统一用真字符
R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[36m'; D=$'\033[2m'; N=$'\033[0m'

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

apt_sources_files() {
  local f
  [[ -f $APT_SOURCES ]] && printf '%s\n' "$APT_SOURCES"
  if [[ -d $APT_SOURCES_D ]]; then
    for f in "$APT_SOURCES_D"/*.list; do
      [[ -f $f ]] && printf '%s\n' "$f"
    done
  fi
}

get_debian_codename() {
  local c=""
  [[ -r /etc/os-release ]] && c=$(. /etc/os-release 2>/dev/null; printf '%s' "${VERSION_CODENAME:-}")
  [[ -z $c && -r /etc/lsb-release ]] && c=$(. /etc/lsb-release 2>/dev/null; printf '%s' "${DISTRIB_CODENAME:-}")
  # 兜底：从现有源的主发行版行反推 suite（自定义镜像常缺 VERSION_CODENAME）
  if [[ -z $c ]]; then
    c=$(apt_sources_files | while read -r f; do
          [[ -n $f ]] || continue
          awk '
            /^[[:space:]]*#/ { next }
            $1=="deb" && $2 ~ /debian/ {
              s=$3
              sub(/-security$|-updates$|-backports$/, "", s)
              sub(/\/.*$/, "", s)
              if (s ~ /^[a-z]+$/) { print s; exit }
            }
          ' "$f"
        done | head -1)
  fi
  printf '%s' "$c"
}

# 第一级：最小修复。只剔除已废弃的 <codename>/updates 与 *-backports 行，
# 并把 security 源补正为 security.debian.org/debian-security <codename>-security。
# 没有直接切归档，是因为主源常常还在正常维护（LTS 期），切了会丢安全更新。
apt_fix_repos_minimal() {
  local codename f changed=0 comps tmp
  codename=$(get_debian_codename)
  [[ -n $codename ]] || return 1

  while read -r f; do
    [[ -n $f ]] || continue
    grep -qE 'deb\.debian\.org|security\.debian\.org' "$f" 2>/dev/null || continue
    # 只认真正的坏行（按字段判定，URL 带不带尾斜杠都覆盖）：
    #   suite = *-backports        → 归档后被撤
    #   suite = */updates          → 旧写法，2021 年起废弃
    #   security.debian.org 且缺 /debian-security 路径
    local need=0
    awk '
      /^[[:space:]]*#/ { next }
      $1 ~ /^deb(-src)?$/ {
        s = $3
        if (s ~ /-backports$/) { exit 2 }
        if (s ~ /\/updates$/)  { exit 2 }
        if ($2 ~ /security\.debian\.org/ && $2 !~ /debian-security/) { exit 2 }
      }
    ' "$f"
    need=$?
    [[ $need -eq 2 ]] || continue

    cp -n "$f" "$f.selfcdn.bak" 2>/dev/null || true

    # 组件列表沿用该源里主发行版那一行，避免擅自打开非 free 组件
    comps=$(awk -v cn="$codename" '
      $1=="deb" && $3==cn { for (i=4;i<=NF;i++) printf "%s%s", (i>4?" ":""), $i; exit }
    ' "$f")
    [[ -z $comps ]] && comps="main"

    # 原文件若带 deb-src，security 源也补 deb-src，保持对称（不然 apt-get source 会断）
    local hassrc=0
    grep -qE '^[[:space:]]*deb-src[[:space:]]' "$f" && hassrc=1

    tmp=$(mktemp)
    awk -v cn="$codename" -v comps="$comps" -v hassrc="$hassrc" '
      BEGIN { sec_done = 0; had_sec = 0 }

      /^[[:space:]]*#/ { print; next }

      $1 ~ /^deb(-src)?$/ {
        s = $3
        # security 源优先判定并就地替换：它的 suite 常是 <codename>/updates，
        # 若先命中下面的 /updates$ 规则就会被直接丢掉、替换行落到文件末尾
        if ($2 ~ /security\.debian\.org/) {
          had_sec = 1
          if (!sec_done) {
            printf "deb     http://security.debian.org/debian-security %s-security %s\n", cn, comps
            if (hassrc == 1)
              printf "deb-src http://security.debian.org/debian-security %s-security %s\n", cn, comps
            sec_done = 1
          }
          next
        }
        # 归档后被撤的 backports
        if (s ~ /-backports$/) next
        # 过时的 <suite>/updates
        if (s ~ /\/updates$/) next
      }

      { print }

      END {
        # 原文件本来没有 security 源，补一条到末尾
        if (had_sec == 0) {
          printf "deb     http://security.debian.org/debian-security %s-security %s\n", cn, comps
          if (hassrc == 1)
            printf "deb-src http://security.debian.org/debian-security %s-security %s\n", cn, comps
        }
      }
    ' "$f" > "$tmp"
    mv "$tmp" "$f"
    changed=1
    info "已剔除废弃行并补正 security 源: $f（备份 *.selfcdn.bak）"
  done < <(apt_sources_files)

  (( changed )) && { ok "Debian 源已最小化修复"; return 0; }
  return 1
}

# 第三级：只把 security 源挪到归档站，主源继续用快镜像。
# 线上实况：bullseye-security 索引还在，但 pool 里的 .deb 已被清走，
# install 时报 "Failed to fetch ... 404"，此时主源无需改动。
apt_move_security_to_archive() {
  local changed=0 f
  while read -r f; do
    [[ -n $f ]] || continue
    grep -q 'security\.debian\.org/debian-security' "$f" 2>/dev/null || continue
    cp -n "$f" "$f.selfcdn.bak2" 2>/dev/null || true
    sed -i \
      -e 's|https\?://security\.debian\.org/debian-security|https://archive.debian.org/debian-security|g' \
      "$f"
    changed=1
    info "security 源已改指归档站: $f（备份 *.selfcdn.bak2）"
  done < <(apt_sources_files)

  if (( changed )); then
    mkdir -p "$APT_CONF_D" 2>/dev/null || true
    printf 'Acquire::Check-Valid-Until "false";\n' > "$APT_CONF_D/99selfcdn-archive" 2>/dev/null || true
    ok "security 走 archive.debian.org，主源保持不动"
    return 0
  fi
  return 1
}

# 第二级：主源也失效（发行版彻底 EOL）时，整体切到 archive.debian.org，
# 并关闭 Valid-Until 校验（归档源 Release 已过期）。
apt_fix_eol_repos() {
  local changed=0 f
  while read -r f; do
    [[ -n $f ]] || continue
    grep -qE 'deb\.debian\.org|security\.debian\.org|ftp\.debian\.org|ftp\.cn\.debian\.org' "$f" 2>/dev/null || continue
    cp -n "$f" "$f.selfcdn.bak" 2>/dev/null || true
    sed -i \
      -e 's|https\?://deb\.debian\.org/debian|https://archive.debian.org/debian|g' \
      -e 's|https\?://ftp\.debian\.org/debian|https://archive.debian.org/debian|g' \
      -e 's|https\?://ftp\.cn\.debian\.org/debian|https://archive.debian.org/debian|g' \
      -e 's|https\?://security\.debian\.org/debian-security|https://archive.debian.org/debian-security|g' \
      -e 's|https\?://security\.debian\.org|https://archive.debian.org|g' \
      -e '/-backports/d' \
      -e '/\/[A-Za-z]*\/updates/d' \
      "$f"
    changed=1
    info "已改写源: $f（备份 *.selfcdn.bak）"
  done < <(apt_sources_files)

  if (( changed )); then
    mkdir -p "$APT_CONF_D" 2>/dev/null || true
    printf 'Acquire::Check-Valid-Until "false";\n' > "$APT_CONF_D/99selfcdn-archive" 2>/dev/null || true
    ok "已切到 archive.debian.org，关闭 Valid-Until 校验"
    return 0
  fi
  return 1
}

apt_refresh() {
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
}

APT_LOG=/tmp/selfcdn-apt-install.log

apt_install_quiet() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" > "$APT_LOG" 2>&1
}

# 区分"源/下载问题"和"真·安装冲突"，后者不该去改源
apt_log_is_fetch_failure() {
  grep -qE 'Failed to fetch|Unable to fetch|does not have a Release file|404  *Not Found|Hash Sum mismatch|Some index files failed to download' "$APT_LOG" 2>/dev/null
}

apt_log_tail() {
  tail -20 "$APT_LOG" 2>/dev/null | sed 's/^/    /' >&2
}

# 阶梯：正常更新 → 最小修源 → security 转归档 → 整体归档。任何一级成功即停。
apt_repair_ladder() {
  if apt_refresh; then return 0; fi

  warn "apt 索引更新失败，判断为源失效（发行版过旧 / 过时仓库行）"
  if apt_fix_repos_minimal; then
    if apt_refresh; then return 0; fi
    warn "最小修源后仍失败"
  else
    warn "未发现可最小修复的坏行"
  fi

  if apt_move_security_to_archive; then
    if apt_refresh; then return 0; fi
    warn "security 转归档后仍失败"
  fi

  if apt_fix_eol_repos; then
    if apt_refresh; then return 0; fi
    warn "切归档源后仍更新失败，检查网络 / DNS / 代理"
  fi
  warn "未能自动修复，请手工检查 /etc/apt/sources.list"
  return 1
}

pkg_install() {
  case $PKG in
    apt)
      # 阶梯式：先修源再装 → 装不上再按下载失败升档。
      #
      # 为什么必须先修源：apt-get update 失败时，apt-get install 仍可能靠
      # /var/lib/apt/lists 里的旧索引"蒙"成功。若这时直接 return，装是装上了，
      # 但 sources.list 一行没改、备份也没有，用户下次 update 继续炸。
      # 线上实测确有此现象（install 成功、源仍坏、无备份）。
      local refreshed=1
      apt_refresh >/dev/null 2>&1 || refreshed=0

      if (( ! refreshed )); then
        warn "apt 索引更新失败，先尝试修复软件源"
        if apt_repair_ladder; then
          refreshed=1
        else
          warn "自动修源未成功，尝试用现有缓存索引安装"
        fi
      fi

      apt_install_quiet "$@" && {
        if (( refreshed )); then
          return 0
        fi
        warn "安装成功，但 apt 索引仍不可用；软件源需手工检查（cdn --fix-apt）"
        return 0
      }

      if ! apt_log_is_fetch_failure; then
        err "apt 安装失败（非软件源问题）:"
        apt_log_tail
        return 1
      fi

      warn "包下载失败：索引里引用的 .deb 已不在镜像上"
      local rung
      for rung in apt_fix_repos_minimal apt_move_security_to_archive apt_fix_eol_repos; do
        if "$rung"; then
          apt_refresh >/dev/null 2>&1 || true
          if apt_install_quiet "$@"; then
            ok "$rung 后安装成功"
            return 0
          fi
          apt_log_is_fetch_failure || { err "安装失败:"; apt_log_tail; return 1; }
        fi
      done

      err "依赖安装仍失败，最后错误:"
      apt_log_tail
      return 1
      ;;
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
    if ! pkg_install "${miss[@]}"; then
      err "依赖安装失败: ${miss[*]}"
      if [[ $PKG == apt ]]; then
        echo "    该机可能是已 EOL 的 Debian 版本（索引在、但 .deb 已被移走）。" >&2
        echo "    手工修复：" >&2
        echo "      cp /etc/apt/sources.list /etc/apt/sources.list.bak" >&2
        echo "      # 方案A: security 走归档，主源保持（推荐，最快）" >&2
        echo "      sed -i 's|security.debian.org/debian-security|archive.debian.org/debian-security|g' /etc/apt/sources.list" >&2
        echo "      # 方案B: 全部走归档" >&2
        echo "      sed -i 's|deb.debian.org/debian|archive.debian.org/debian|g' /etc/apt/sources.list" >&2
        echo "      echo 'Acquire::Check-Valid-Until \"false\";' > /etc/apt/apt.conf.d/99archive" >&2
        echo "      apt-get update && apt-get install -y ${miss[*]}" >&2
        echo "    或直接: cdn --fix-apt" >&2
      fi
      die "请修复软件源后重试"
    fi
    # 装完复核：真装上了才算数
    local still=()
    command -v nginx   >/dev/null 2>&1 || still+=(nginx)
    command -v curl    >/dev/null 2>&1 || still+=(curl)
    command -v openssl >/dev/null 2>&1 || still+=(openssl)
    if [[ ${#still[@]} -gt 0 ]]; then
      die "依赖仍未就绪: ${still[*]}（apt 报告成功但命令不存在，检查包名或 PATH）"
    fi
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

# 全局片段（map + 所有节点的 cache zone）只有一个写入口。
# 早期版本把"写 map"和"写 cache zone"分成两个函数，启动时只调前者，
# 结果把已有的 proxy_cache_path 全冲掉 → nginx -t 报
# "proxy_cache zone ... is unknown" → 此时 systemd 重启 nginx 会直接起不来。
# 现在合并为一个幂等函数，启动/增删节点都走它，不会互相覆盖。
render_global_conf() {
  mkdir -p "$(dirname "$GLOBAL_CONF")" 2>/dev/null || true
  cat > "$GLOBAL_CONF" <<'NGINX'
# SelfCDN — 全局片段，由 selfcdn.sh 自动生成
# 手工修改会在下次启动或增删节点时被覆盖
map $http_upgrade $connection_upgrade {
    default upgrade;
    ""      close;
}
NGINX

  local n zid
  while read -r n; do
    [[ -n $n ]] || continue
    # shellcheck disable=SC1090
    source "$(node_file "$n")"
    [[ ${CACHE_ENABLE:-0} == 1 ]] || continue
    zid=$(nginx_id "$n")
    cat >> "$GLOBAL_CONF" <<NGINX

proxy_cache_path $CACHE_ROOT/$n levels=1:2 keys_zone=cdn_${zid}:${CACHE_MEM} max_size=${CACHE_SIZE} inactive=${CACHE_TTL} use_temp_path=off;
NGINX
  done < <(list_node_names)
}

# 兼容旧调用点

ACME_URL="https://acme-v02.api.letsencrypt.org/directory"

acme_present() { [[ -x $ACME_SH ]]; }

# Let's Encrypt 会拒绝 RFC 2606 保留域名下的联系邮箱
# （实测报错：contact email has forbidden domain "example.com"）。
# 占位邮箱一旦写进 acme.sh 的 account.conf 会一直沿用，必须先拦住。
EMAIL_FORBIDDEN_DOMAINS="example.com example.net example.org example.edu test.com localhost invalid local"

is_forbidden_email() {
  local e=$1 d
  d=${e##*@}
  d=$(printf '%s' "$d" | tr 'A-Z' 'a-z')
  local f
  for f in $EMAIL_FORBIDDEN_DOMAINS; do
    [[ $d == "$f" ]] && return 0
  done
  # RFC 2606 保留 TLD / 后缀
  case $d in
    *.example|*.invalid|*.localhost|*.test|*.local) return 0 ;;
  esac
  return 1
}

is_valid_email() {
  local e=$1
  [[ -n $e ]] || return 1
  [[ $e =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$ ]] || return 1
  is_forbidden_email "$e" && return 1
  return 0
}

read_email_interactive() {
  local e
  while true; do
    read -rp "Let's Encrypt 账户邮箱（用于到期提醒，不能填 example.com 之类占位域）: " e
    [[ -n $e ]] || { warn "邮箱不能为空"; continue; }
    if is_forbidden_email "$e"; then
      warn "LE 明确拒绝保留域名邮箱（example.com / *.test / *.invalid 等），换一个真实域名"
      continue
    fi
    if ! is_valid_email "$e"; then
      warn "邮箱格式不对: $e"
      continue
    fi
    printf '%s\n' "$e" > "$EMAIL_FILE"
    chmod 600 "$EMAIL_FILE"
    ok "邮箱已保存: $e"
    printf '%s' "$e"
    return 0
  done
}

# acme.sh 自己把邮箱存在 account.conf 里。只改 /etc/selfcdn/email 不生效，
# 旧的坏邮箱会继续被用，所以必须同步过去。
sync_acme_email() {
  local email=$1
  [[ -n $email && -d $ACME_HOME ]] || return 0
  local acct=$ACME_HOME/account.conf
  if [[ -f $acct ]]; then
    # 邮箱里不该有 sed 分隔符 / 引号；is_valid_email 已挡掉，这里再兜一层
    local bad_pipe='|' bad_sq="'"
    if [[ $email == *"$bad_pipe"* || $email == *"$bad_sq"* ]]; then
      warn "邮箱含异常字符，跳过 account.conf 同步"
      return 0
    fi
    if grep -q '^ACCOUNT_EMAIL=' "$acct" 2>/dev/null; then
      sed -i "s|^ACCOUNT_EMAIL=.*|ACCOUNT_EMAIL='$email'|" "$acct"
      info "已同步 acme.sh 账户邮箱: $email"
    else
      printf "ACCOUNT_EMAIL='%s'\n" "$email" >> "$acct"
    fi
  fi
  # 账户若已注册，顺手更新；未注册会失败，忽略
  if acme_present; then
    "$ACME_SH" --update-account --accountemail "$email" >/dev/null 2>&1 || true
  fi
}

# 返回 0 = 邮箱可用；1 = 需要用户重新输入
ensure_email() {
  local email
  email=$(cat "$EMAIL_FILE" 2>/dev/null || true)

  # 历史遗留的坏邮箱：文件里或 acme.sh 里都可能存在
  if [[ -n $email ]] && ! is_valid_email "$email"; then
    warn "已保存的邮箱不可用: $email"
    is_forbidden_email "$email" && warn "LE 拒绝保留域名（example.com 等），必须换真实域名邮箱"
    email=$(read_email_interactive) || return 1
  fi
  if [[ -z $email ]]; then
    echo
    email=$(read_email_interactive) || return 1
  fi
  sync_acme_email "$email"
  return 0
}

ensure_acme() {
  # 每次都要校验邮箱：acme.sh 已装时也可能带着历史坏邮箱
  ensure_email || return 1
  acme_present && return 0

  local email
  email=$(cat "$EMAIL_FILE" 2>/dev/null || true)
  info "安装 acme.sh ..."
  curl -fsS https://get.acme.sh | sh -s "email=$email" >/dev/null 2>&1 \
    || die "acme.sh 安装失败（检查出网）"
  acme_present || die "acme.sh 未安装成功（预期路径 $ACME_SH）"
  "$ACME_SH" --set-default-ca --server "$ACME_URL" >/dev/null 2>&1 || true
  sync_acme_email "$email"
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
  local cache_block cache_block_http
  # 命令替换会吃掉末尾换行（连 sed 输出的也吃），不补回来就会把 } 粘到最后一条指令行尾，
  # 或者把 add_header 挤到同一行。显式补 $'\n' 并去掉空行。
  cache_block=$( { printf '%s\n' "$cache_directives"; printf '%s\n' "$hdr_https"; } | sed '/^[[:space:]]*$/d' )$'\n'
  cache_block_http=$( { printf '%s\n' "$cache_directives"; printf '%s\n' "$hdr_http"; } | sed '/^[[:space:]]*$/d' )$'\n'

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

    location /.well-known/acme-challenge/ {
        root ${ACME_ROOT};
    }
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

    location = /.well-known/acme-challenge/ {
        return 404;
    }

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

    location /.well-known/acme-challenge/ {
        root ${ACME_ROOT};
    }

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

node_conf_is_https() {
  local conf=$NGINX_CONF_D/selfcdn-$1.conf
  [[ -f $conf ]] && grep -qE '^[[:space:]]*listen[[:space:]]+443' "$conf"
}

# reload 后旧 worker 还在优雅退出，新连接可能被旧 worker 接走（新 vhost 尚未生效）。
# 只认状态码会误报：Debian 默认站点对任意 Host 都可能回 200/404，看起来"通了"其实没生效。
# 所以必须认本节点自己的标记：HTTPS 模式认 301→https，引导模式认 X-CDN-Node 头。
smoke_check_node() {
  local name=$1
  load_node "$name"
  local i resp code want_https=0
  node_conf_is_https "$name" && want_https=1

  for i in $(seq 1 20); do
    resp=$(curl -s -o /dev/null -D - -m 3 -H "Host: $DOMAIN" http://127.0.0.1/ 2>/dev/null || true)
    code=$(printf '%s' "$resp" | awk 'NR==1{print $2}')
    [[ -z $code ]] && code=000

    if (( want_https )); then
      # 443 已启用：80 段应当是「301 跳 https」
      if [[ $code == 301 ]] && printf '%s' "$resp" | grep -qiE '^location:[[:space:]]*https://'; then
        ok "本机自检: 80→443 跳转正常（Host: $DOMAIN）"
        return 0
      fi
    else
      if [[ $code != 000 ]] && printf '%s' "$resp" | grep -qi '^x-cdn-node:'; then
        case $code in
          502|503|504) warn "本机自检: HTTP $code —— 回源 $UPSTREAMS 不可达" ;;
          404)         ok "本机自检: 已命中本站点（HTTP 404，源站没有 /）" ;;
          *)           ok "本机自检: HTTP $code（Host: $DOMAIN）" ;;
        esac
        return 0
      fi
    fi
    sleep 0.5
  done

  if [[ $code == 000 ]]; then
    warn "本机自检未通：127.0.0.1 无响应，检查 nginx 是否在跑"
  elif (( want_https )); then
    warn "本机自检: HTTP $code 但无 301 跳转 —— 新配置可能未生效（稍后用菜单 7 重载）"
  else
    warn "本机自检: HTTP $code 但未见 X-CDN-Node —— 新配置可能未生效，或被默认站点接管"
  fi
  return 0
}

# ---------------------------------------------------------------- 证书
ACME_LOG=/tmp/selfcdn-acme.log

# 把 acme.sh 的失败翻译成人能看懂的原因，而不是一律甩"DNS 没生效"
diagnose_acme_failure() {
  local log=$1 domain=$2
  local detail
  detail=$(grep -E '"(detail|type)"[[:space:]]*:' "$log" 2>/dev/null | head -4)

  if grep -q 'invalidContact\|forbidden domain' "$log" 2>/dev/null; then
    err "证书申请失败：ACME 拒绝了账户邮箱"
    [[ -n $detail ]] && sed 's/^/      /' <<< "$detail" >&2
    echo "    真实域名邮箱不能是 example.com / *.test / *.invalid 这类保留域名。" >&2
    echo "    改法：cdn → 菜单 11 重设邮箱，再回菜单 4 重新申请" >&2
    return 0
  fi
  if grep -qi 'rateLimited\|too many.*certificate\|too many.*identifiers' "$log" 2>/dev/null; then
    err "证书申请失败：触发 Let's Encrypt 频率限制"
    [[ -n $detail ]] && sed 's/^/      /' <<< "$detail" >&2
    echo "    同一组域名每周最多 5 张重复证书。等一段时间，或先用 --staging 调试。" >&2
    return 0
  fi
  if grep -qE 'Domain key exists|Domains are the same' "$log" 2>/dev/null; then
    err "证书申请失败：该域名在 acme.sh 里已有证书/key，拒绝重复签发"
    [[ -n $detail ]] && sed 's/^/      /' <<< "$detail" >&2
    echo "    正常情况脚本会自动改为安装已有证书；走到这里说明证书文件缺失。" >&2
    echo "    手工修复: acme.sh --issue -d $domain --ecc --force" >&2
    return 0
  fi
  if grep -qi 'DNS problem\|NXDOMAIN\|no valid A records\|dns lookup' "$log" 2>/dev/null; then
    err "证书申请失败：域名解析问题"
    [[ -n $detail ]] && sed 's/^/      /' <<< "$detail" >&2
    echo "    确认 $domain 的 A 记录已指向本机，且已生效（dig +short $domain）。" >&2
    return 0
  fi
  if grep -qi 'connection refused\|timeout\|Connection reset\|port 80' "$log" 2>/dev/null; then
    err "证书申请失败：80 端口不可达"
    [[ -n $detail ]] && sed 's/^/      /' <<< "$detail" >&2
    echo "    安全组 / 防火墙未放通 80，或运营商封了 80。" >&2
    return 0
  fi

  err "证书申请失败：$domain"
  [[ -n $detail ]] && sed 's/^/      /' <<< "$detail" >&2
  echo "    完整日志: $log（acme.sh 原始输出）" >&2
  echo "    其他常见原因：A 记录未生效 / 域名未备案被拦" >&2
}

acme_log_is_fatal() {
  # 账户类/频率类错误重试也没用，不必再降级 standalone
  grep -qE 'invalidContact|forbidden domain|rateLimited|too many.*certificate' "$1" 2>/dev/null
}

# acme.sh 说"这个域已有证书/key"，重试换校验方式毫无意义，应改为直接安装现有证书
acme_log_already_issued() {
  grep -qE 'Domain key exists|Domains are the same|already have (an? )?(ECC |RSA )?cert|It seems that .*already|Skip, Next renewal time is' "$1" 2>/dev/null
}

# acme.sh 自己的证书目录。判"是否已签发"要看这里，不能靠 --info 的键名：
# 实测 acme.sh 3.1.7 的 --info 只输出 Le_Domain/Le_Alt/Le_Webroot 等，
# 不含 Le_RealCertPath / Le_CertCreateTime，靠它判会误判成"没签过"→ 重复 --issue → 撞 key exists。
acme_cert_file() { echo "$ACME_HOME/$1_ecc/$1.cer"; }
acme_has_cert()  { [[ -f $(acme_cert_file "$1") ]]; }

# 证书剩余天数；拿不到返回 -1
# 第二个参数可注入"当前时间"（epoch 秒），仅用于测试；正常运行省略。
cert_days_left() {
  local f=$1 now=${2:-} end e
  [[ -f $f ]] || return 0
  [[ -n $now ]] || now=$(date +%s)
  end=$(openssl x509 -enddate -noout -in "$f" 2>/dev/null | cut -d= -f2)
  [[ -n $end ]] || return 0
  e=$(date -d "$end" +%s 2>/dev/null) || return 0
  echo $(( ( e - now ) / 86400 ))
}

# 列表里显示的证书状态文案（单独抽出来，方便离线测各分支）
cert_state_text() {
  local d
  [[ -f $1 ]] || { echo "未签发"; return; }
  d=$(cert_days_left "$1" "${2:-}")
  if [[ -z $d ]]; then
    echo "无法读取"
  elif (( d < 0 )); then
    echo "已过期 $((-d)) 天"
  elif (( d == 0 )); then
    echo "今日到期"
  elif (( d <= 30 )); then
    echo "${d} 天 需续期"
  else
    echo "${d} 天"
  fi
}

issue_cert() {
  local name=$1 mode=${2:-webroot}
  load_node "$name"
  ensure_acme || return 1
  mkdir -p "$ACME_ROOT"

  local local_cert="$CERT_DIR/$name/fullchain.cer"
  local local_key="$CERT_DIR/$name/$DOMAIN.key"

  # ---- 情形 1：acme.sh 里已有该域证书，不必重新签发 ----
  if acme_has_cert "$DOMAIN"; then
    local days
    days=$(cert_days_left "$(acme_cert_file "$DOMAIN")")

    # 本地副本缺失（如节点被删后重建、换了标识）→ 只做安装，一次网络请求都不用发
    if [[ ! -f $local_cert || ! -f $local_key ]]; then
      info "acme.sh 已有 $DOMAIN 的证书（剩余 ${days:-?} 天），直接装到节点目录，不重新签发"
      install_cert "$name" || return 1
      ok "证书已就位: $CERT_DIR/$name"
      return 0
    fi

    # 本地也有效且不临近到期 → 不动
    local ldays
    ldays=$(cert_days_left "$local_cert")
    if [[ -n $ldays ]] && (( ldays > 30 )); then
      ok "证书仍有效（剩余 $ldays 天），无需签发"
      return 0
    fi
    info "证书剩余 ${ldays:-?} 天，执行续期"
    mode=renew
  fi

  local dns_ip server_ip
  dns_ip=$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1; exit}')
  server_ip=$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)
  if [[ -n $dns_ip && -n $server_ip && $dns_ip != "$server_ip" ]]; then
    warn "DNS 解析 $DOMAIN → $dns_ip，本机出口 → $server_ip"
    warn "http-01 校验大概率失败，请先改 A 记录"
    local a; read -rp "仍然继续？[y/N] " a
    [[ $a =~ ^[Yy]$ ]] || return 1
  fi

  local arr=(--issue -d "$DOMAIN" --keylength ec-256 --server "$ACME_URL")
  info "申请证书 [$mode]: $DOMAIN"
  local rc=1

  if [[ $mode == renew ]]; then
    "$ACME_SH" --renew -d "$DOMAIN" --ecc --server "$ACME_URL" > "$ACME_LOG" 2>&1 && rc=0
    # 未到续期窗口时 renew 返回非 0，但证书仍有效
    [[ -f $local_cert ]] && rc=0
  elif [[ $mode == webroot ]]; then
    "$ACME_SH" "${arr[@]}" -w "$ACME_ROOT" > "$ACME_LOG" 2>&1 && rc=0
    if (( rc != 0 )); then
      if acme_log_is_fatal "$ACME_LOG"; then
        diagnose_acme_failure "$ACME_LOG" "$DOMAIN"
        return 1
      fi
      if acme_log_already_issued "$ACME_LOG" && acme_has_cert "$DOMAIN"; then
        info "acme.sh 报告该域证书已存在，改为直接安装"
        install_cert "$name" || return 1
        ok "证书已就位: $CERT_DIR/$name"
        return 0
      fi
      warn "webroot 失败，降级 standalone 重试 ..."
      if command -v systemctl >/dev/null 2>&1; then systemctl stop nginx 2>/dev/null || true; else nginx -s stop 2>/dev/null || true; fi
      "$ACME_SH" "${arr[@]}" --standalone > "$ACME_LOG" 2>&1 && rc=0
      if command -v systemctl >/dev/null 2>&1; then systemctl start nginx 2>/dev/null || true; else nginx 2>/dev/null || true; fi
    fi
  else
    if command -v systemctl >/dev/null 2>&1; then systemctl stop nginx 2>/dev/null || true; else nginx -s stop 2>/dev/null || true; fi
    "$ACME_SH" "${arr[@]}" --standalone > "$ACME_LOG" 2>&1 && rc=0
    if command -v systemctl >/dev/null 2>&1; then systemctl start nginx 2>/dev/null || true; else nginx 2>/dev/null || true; fi
  fi

  if (( rc != 0 )); then
    # 兜底：签发命令失败，但证书其实已存在（key exists / 已签发），装上去就行
    if acme_log_already_issued "$ACME_LOG" && acme_has_cert "$DOMAIN"; then
      info "该域证书已存在，改为直接安装（不重新签发）"
      install_cert "$name" || return 1
      ok "证书已就位: $CERT_DIR/$name"
      return 0
    fi
    diagnose_acme_failure "$ACME_LOG" "$DOMAIN"
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
  render_global_conf
  gen_node_conf "$name"
  nginx_test || { err "配置测试失败，节点未启用"; pause; return 1; }
  nginx_reload || { err "重载失败，节点未启用"; pause; return 1; }

  if node_conf_is_https "$name"; then
    # 证书已就位（复用了该节点已有证书）
    ok "HTTPS 配置已生效: https://$DOMAIN"
    smoke_check_node "$name"
    pause
    return 0
  fi

  ok "HTTP 引导模式已生效: http://$DOMAIN"
  smoke_check_node "$name"

  local a
  read -rp "现在申请证书并切换 HTTPS？[Y/n]（默认 Y）: " a
  if [[ ! $a =~ ^[Nn]$ ]]; then
    if issue_cert "$name" webroot; then
      gen_node_conf "$name"
      if nginx_reload; then
        smoke_check_node "$name"
        ok "节点上线: https://$DOMAIN"
      else
        err "HTTPS 配置重载失败，节点仍停在 HTTP 模式"
      fi
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

# 编号表格：list_nodes 与所有"选节点"的提示共用
NODE_PICK_NAMES=()

render_node_table() {
  NODE_PICK_NAMES=()
  local -a all=()
  local n
  while read -r n; do
    [[ -n $n ]] && all+=("$n")
  done < <(list_node_names)

  if (( ${#all[@]} == 0 )); then
    echo "（暂无节点）"
    return 1
  fi

  echo
  printf "%-4s %-12s %-30s %-24s %-6s %s\n" "#" "标识" "域名" "回源" "缓存" "证书剩余"
  printf '%s\n' "--------------------------------------------------------------------------------------------------------------"
  local i=0
  for n in "${all[@]}"; do
    i=$((i+1))
    # shellcheck disable=SC1090
    source "$(node_file "$n")"
    local ce=off; [[ ${CACHE_ENABLE:-0} == 1 ]] && ce=on
    local cert="未签发"
    if [[ -f "$CERT_DIR/$n/fullchain.cer" && -f "$CERT_DIR/$n/$DOMAIN.key" ]]; then
      cert=$(cert_state_text "$CERT_DIR/$n/fullchain.cer")
    fi
    printf "%-4s %-12s %-30s %-24s %-6s %s\n" "$i" "$n" "$DOMAIN" "$UPSTREAMS" "$ce" "$cert"
    NODE_PICK_NAMES+=("$n")
  done
  echo
  return 0
}

# 按序号选节点。结果写进全局 PICKED_NODE，不用 $( ) 捕获 ——
# 否则表格与警告会被一起吞进变量里。
PICKED_NODE=""
pick_node() {
  local prompt=${1:-请选择序号} allow_all=${2:-0} choice
  render_node_table || return 1

  while true; do
    printf '%s（0 取消）: ' "$prompt"
    if ! read -r choice; then
      echo
      return 1
    fi
    [[ $choice == 0 ]] && { echo "已取消"; return 1; }
    if (( allow_all )) && [[ $choice == all ]]; then
      PICKED_NODE=all
      return 0
    fi
    if ! [[ $choice =~ ^[0-9]+$ ]]; then
      printf '\033[33m[!]\033[0m 请输入序号数字，或 0 取消\n' >&2
      continue
    fi
    if (( choice < 1 || choice > ${#NODE_PICK_NAMES[@]} )); then
      printf '\033[33m[!]\033[0m 序号超出范围：1-%s\n' "${#NODE_PICK_NAMES[@]}" >&2
      continue
    fi
    PICKED_NODE=${NODE_PICK_NAMES[choice-1]}
    return 0
  done
}

list_nodes() {
  render_node_table || { pause; return; }
  pause
}

# ---------------------------------------------------------------- 功能 3 删除
del_node() {
  local names n
  names=$(list_node_names)
  [[ -z $names ]] && { echo "（暂无节点）"; pause; return; }
  pick_node "要删除的节点序号" || { pause; return 0; }
  n=$PICKED_NODE
  node_exists "$n" || die "节点不存在: $n"
  load_node "$n"
  read -rp "确认删除 $n（$DOMAIN，含证书与缓存）？输入 yes: " c
  [[ $c == yes ]] || { warn "已取消"; pause; return; }

  rm -f "$NGINX_CONF_D/selfcdn-$n.conf"
  # 故意保留 acme.sh 里的证书：重建同域名节点时可直接装回来，不必重新签发
  # （LE 对同一组域名每周只允许 5 张重复证书，反复删建会撞限额）
  rm -rf "$CERT_DIR/$n" "$CACHE_ROOT/$n"
  rm -f "$(node_file "$n")"
  rm -f "/var/log/nginx/selfcdn-$n.access.log" "/var/log/nginx/selfcdn-$n.error.log"
  render_global_conf
  nginx_reload || { err "重载失败：请检查 $NGINX_CONF_D"; pause; return 1; }
  ok "节点 $n 已删除"
  if acme_has_cert "$DOMAIN"; then
    info "acme.sh 中 $DOMAIN 的证书已保留（剩余 $(cert_days_left "$(acme_cert_file "$DOMAIN")") 天）"
    info "再次添加同域名节点会直接复用；要彻底删除: acme.sh --remove -d $DOMAIN --ecc"
  fi
  pause
}

# ---------------------------------------------------------------- 功能 4 单节点证书
issue_one() {
  local n
  pick_node "要给哪个节点申请/续期证书" || { pause; return 0; }
  n=$PICKED_NODE
  node_exists "$n" || die "节点不存在: $n"
  if issue_cert "$n" webroot; then
    gen_node_conf "$n"
    if nginx_reload; then ok "证书已就绪，节点已切到 HTTPS"; else err "重载失败"; fi
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
  pick_node "要清缓存的节点序号（也可输入 all 清全部）" 1 || { pause; return 0; }
  n=$PICKED_NODE
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
  pick_node "节点序号" || { pause; return 0; }
  n=$PICKED_NODE
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
    echo "  剩余: $(cert_state_text "$CERT_DIR/$n/fullchain.cer")"
  elif [[ -f "$CERT_DIR/$n/fullchain.cer" ]]; then
    echo; echo "===== 证书信息（与当前域名不匹配，需重新签发）====="
    openssl x509 -noout -subject -dates -in "$CERT_DIR/$n/fullchain.cer" 2>/dev/null | sed 's/^/  /'
  fi
  pause
}

# ---------------------------------------------------------------- 功能 9 日志/命中率
show_logs() {
  local n
  pick_node "节点序号" || { pause; return 0; }
  n=$PICKED_NODE
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
  if is_forbidden_email "$e"; then
    err "LE 拒绝保留域名邮箱（example.com / *.test / *.invalid 等），换一个真实域名"
    warn "这个值如果写进去，签发一定会失败"
    pause
    return 1
  fi
  if ! is_valid_email "$e"; then
    err "邮箱格式不对: $e"
    pause
    return 1
  fi
  printf '%s\n' "$e" > "$EMAIL_FILE"; chmod 600 "$EMAIL_FILE"
  ok "已保存: $e"
  sync_acme_email "$e"
  if acme_present; then
    if "$ACME_SH" --update-account --accountemail "$e" >/dev/null 2>&1; then
      ok "acme.sh 账户邮箱已更新"
    else
      warn "acme.sh 账户尚未注册（或更新失败）；下次签发会用新邮箱自动注册"
    fi
  fi
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
    # 同样保留 acme.sh 证书，避免重建时重复签发撞 LE 限额
    rm -f "/var/log/nginx/selfcdn-$n.access.log" "/var/log/nginx/selfcdn-$n.error.log"
  done < <(list_node_names)
  rm -f "$GLOBAL_CONF"
  rm -rf "$CACHE_ROOT" "$BASE" "$ACME_ROOT"
  nginx_reload || warn "重载失败，请手工检查 $NGINX_CONF_D"
  ok "已清空全部 CDN 节点"
  info "acme.sh 里的证书已保留；彻底清理: acme.sh --remove -d <域名> --ecc"
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
    # stdin 到 EOF（Ctrl-D / 管道输完）时必须退出。
    # 早期版本不判返回值：choice 为空 → 命中无效分支 → pause 也立即 EOF 返回
    # → 循环空转，实测能烧 28% CPU 持续十分钟不停。
    if ! read -rp "选择序号: " choice; then
      echo
      ok "输入结束（EOF），退出"
      exit 0
    fi
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

usage() {
  cat <<EOF
SelfCDN $VERSION — 自建 CDN 边缘节点

用法:
  cdn              进菜单（默认）
  cdn --fix-apt    修复失效的 Debian 源并更新索引（EOL / updates / backports 失效时用）
  cdn --check      只做环境检查，不进菜单
  cdn --set-email <addr>
                   设置/更换 ACME 账户邮箱（会同步 acme.sh 的 account.conf）
  cdn --version    版本
  cdn --help       本帮助
EOF
}

main() {
  case ${1:-} in
    -h|--help) usage; exit 0 ;;
    -v|--version) echo "SelfCDN $VERSION"; exit 0 ;;
    --fix-apt)
      need_root; detect_os
      [[ $PKG == apt ]] || die "仅 Debian/Ubuntu 需要该操作（当前非 apt 系统）"
      if apt_repair_ladder; then
        ok "apt 源已修复，索引更新完成"
      else
        err "自动修复失败。当前 sources.list："
        while read -r f; do [[ -n $f ]] && sed 's/^/    /' "$f"; done < <(apt_sources_files)
        exit 1
      fi
      exit 0 ;;
    --set-email)
      need_root
      local addr=${2:-}
      if [[ -z $addr ]]; then
        addr=$(read_email_interactive) || exit 1
      else
        if is_forbidden_email "$addr"; then
          err "LE 拒绝保留域名邮箱（example.com / *.test / *.invalid 等）"
          exit 1
        fi
        is_valid_email "$addr" || die "邮箱格式不对: $addr"
        mkdir -p "$BASE"
        printf '%s\n' "$addr" > "$EMAIL_FILE"; chmod 600 "$EMAIL_FILE"
        ok "邮箱已保存: $addr"
      fi
      sync_acme_email "$addr"
      if acme_present && "$ACME_SH" --update-account --accountemail "$addr" >/dev/null 2>&1; then
        ok "acme.sh 账户邮箱已同步"
      else
        info "acme.sh 账户尚未注册；下次签发会用该邮箱自动注册"
      fi
      exit 0 ;;
    --check)
      need_root; detect_os; install_deps; nginx_version_gate
      ok "环境检查通过: nginx $NGINX_VER / pkg=$PKG"
      exit 0 ;;
  esac

  need_root
  install_deps
  ensure_dirs
  nginx_version_gate
  render_global_conf
  if ! nginx_reload; then
    warn "Nginx 初始加载失败（上方 nginx -t 已给出具体原因）"
    warn "常见原因：80/443 被占用、配置被外部改动、缓存区定义缺失"
    warn "排查: ss -lntp | grep -E ':(80|443)\\b'  以及上方报错行"
    warn "菜单仍可使用；节点增删会自动重建配置"
  fi
  main_menu
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi