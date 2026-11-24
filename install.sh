#!/usr/bin/env bash
# language: bash, file: install.sh
# SelfCDN 一键安装：拉取脚本到 /usr/local/sbin/selfcdn 并执行
set -euo pipefail

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/Assute/selfcdn/main/selfcdn.sh}"
DEST="${DEST:-/usr/local/sbin/selfcdn}"

R='\033[31m'; G='\033[32m'; Y='\033[33m'; B='\033[36m'; N='\033[0m'
info() { printf "${B}[*]${N} %s\n" "$*"; }
ok()   { printf "${G}[+]${N} %s\n" "$*"; }
err()  { printf "${R}[x]${N} %s\n" "$*" >&2; }

[[ ${EUID:-0} -eq 0 ]] || { err "需要 root：sudo bash install.sh"; exit 1; }

command -v curl >/dev/null 2>&1 || {
  info "安装 curl ..."
  if command -v apt-get >/dev/null 2>&1; then apt-get update -qq && apt-get install -y -qq curl
  elif command -v dnf >/dev/null 2>&1; then dnf install -y -q curl
  elif command -v yum >/dev/null 2>&1; then yum install -y -q curl
  else err "无包管理器可装 curl"; exit 1; fi
}

info "拉取 selfcdn.sh ..."
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
# raw.githubusercontent.com 走 CDN，直接请求可能拿到几分钟前的旧版本（改完代码立刻重跑会中招）。
# 加时间戳参数击穿缓存，保证拿到最新内容。
stamp=$(date +%s)
curl -fsSL "$REPO_RAW?cb=$stamp" -o "$tmp" || { err "下载失败：$REPO_RAW"; exit 1; }

# 下载完整性：非空 + 首行 shebang + 能过语法检查
[[ -s $tmp ]] || { err "下载内容为空"; exit 1; }
head -1 "$tmp" | grep -q '^#!/usr/bin/env bash' || { err "内容不像 selfcdn.sh（shebang 不符）"; exit 1; }
bash -n "$tmp" || { err "语法检查失败，拒绝安装"; exit 1; }
# 关键函数必须在，防止拿到被截断/串版的旧内容
for fn in pkg_install apt_repair_ladder render_global_conf main_menu; do
  grep -q "^$fn()" "$tmp" || { err "内容异常：缺少 $fn()，拒绝安装"; exit 1; }
done
got_ver=$(grep -m1 '^VERSION=' "$tmp" | cut -d'"' -f2)
info "版本: ${got_ver:-未知}"

install -m 755 "$tmp" "$DEST"
ok "已安装: $DEST"

cat <<EOF

  用法：
    selfcdn              # 进菜单
    sudo selfcdn         # 非 root 登录时

  下一步：
    1. 确认域名 A 记录已指向本机
    2. 确认 80 / 443 已放通（安全组 + 防火墙）
    3. selfcdn → 选 1 添加节点

EOF

exec "$DEST"