#!/usr/bin/env bash
# language: bash, file: install.sh
# SelfCDN 一键安装：拉取脚本到 /usr/local/sbin/cdn 并执行
set -euo pipefail

REPO_SLUG="${REPO_SLUG:-Assute/selfcdn}"
BRANCH="${BRANCH:-main}"

# 显式覆盖（镜像 / 内网 / 测试）时直接用，不做 SHA 解析
REPO_RAW_OVERRIDE="${REPO_RAW:-}"

API_REPO="https://api.github.com/repos/$REPO_SLUG"
RAW_BY_SHA="https://raw.githubusercontent.com/$REPO_SLUG"
RAW_PLAIN="$RAW_BY_SHA/$BRANCH/selfcdn.sh"
JSDELIVR="https://cdn.jsdelivr.net/gh/$REPO_SLUG@$BRANCH/selfcdn.sh"

BINDIR="${BINDIR:-/usr/local/sbin}"
DEST="${DEST:-$BINDIR/cdn}"
LEGACY="$BINDIR/selfcdn"

R='\033[31m'; G='\033[32m'; Y='\033[33m'; B='\033[36m'; N='\033[0m'
info() { printf "${B}[*]${N} %s\n" "$*"; }
ok()   { printf "${G}[+]${N} %s\n" "$*"; }
warn() { printf "${Y}[!]${N} %s\n" "$*"; }
err()  { printf "${R}[x]${N} %s\n" "$*" >&2; }

[[ ${EUID:-0} -eq 0 ]] || { err "需要 root：sudo bash install.sh"; exit 1; }

command -v curl >/dev/null 2>&1 || {
  info "安装 curl ..."
  if command -v apt-get >/dev/null 2>&1; then apt-get update -qq && apt-get install -y -qq curl
  elif command -v dnf >/dev/null 2>&1; then dnf install -y -q curl
  elif command -v yum >/dev/null 2>&1; then yum install -y -q curl
  else err "无包管理器可装 curl"; exit 1; fi
}

# raw.githubusercontent.com 的响应带 cache-control: max-age=300，
# 而且查询参数不参与缓存键（?cb=xxx 与裸 URL 返回同一个 etag，实测无效）。
# 所以"加时间戳击穿"是错的。正确做法：先用 API 把分支解析成 commit SHA，
# 再按 SHA 取——同一 SHA 的内容不可变，永不陈旧。
fetch_selfcdn() {
  local dest=$1 sha

  if [[ -n $REPO_RAW_OVERRIDE ]]; then
    curl -fsSL --max-time 30 "$REPO_RAW_OVERRIDE" -o "$dest" || return 1
    info "来源: 指定地址 $REPO_RAW_OVERRIDE"
    return 0
  fi

  # 1) 解析 SHA → 按 SHA 取（最可靠）
  sha=$(curl -fsSL --max-time 10 "$API_REPO/commits/$BRANCH" 2>/dev/null \
        | grep -m1 '"sha"' | cut -d'"' -f4 || true)
  if [[ -n ${sha:-} ]]; then
    if curl -fsSL --max-time 30 "$RAW_BY_SHA/$sha/selfcdn.sh" -o "$dest" 2>/dev/null; then
      info "来源: commit ${sha:0:12}（$BRANCH 当前 HEAD，内容不可变）"
      return 0
    fi
  fi

  # 2) GitHub API 被限流时退到 jsDelivr（独立 CDN，@main 基本是最新）
  if curl -fsSL --max-time 30 "$JSDELIVR" -o "$dest" 2>/dev/null; then
    info "来源: jsDelivr"
    return 0
  fi

  # 3) 最后退到 raw 裸 URL（可能滞后最多 5 分钟）
  if curl -fsSL --max-time 30 "$RAW_PLAIN" -o "$dest" 2>/dev/null; then
    warn "来源: raw.githubusercontent（该 CDN 缓存 5 分钟，可能不是最新提交）"
    return 0
  fi
  return 1
}

info "拉取 selfcdn.sh ..."
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
fetch_selfcdn "$tmp" || { err "下载失败（raw / jsDelivr / API 均不可用）"; exit 1; }

# 下载完整性：非空 + 首行 shebang + 能过语法检查
[[ -s $tmp ]] || { err "下载内容为空"; exit 1; }
head -1 "$tmp" | grep -q '^#!/usr/bin/env bash' || { err "内容不像 selfcdn.sh（shebang 不符）"; exit 1; }
bash -n "$tmp" || { err "语法检查失败，拒绝安装"; exit 1; }
# 关键函数必须在，防止拿到被截断/串版的旧内容
for fn in pkg_install apt_repair_ladder render_global_conf main_menu issue_cert; do
  grep -q "^$fn()" "$tmp" || { err "内容异常：缺少 $fn()，拒绝安装"; exit 1; }
done
got_ver=$(grep -m1 '^VERSION=' "$tmp" | cut -d'"' -f2)
info "版本: ${got_ver:-未知}"

mkdir -p "$BINDIR"
install -m 755 "$tmp" "$DEST"
ok "已安装: $DEST"

# 旧名做成软链；若 $LEGACY 已存在且不是指向我们的软链，先清掉再链
if [[ $LEGACY != "$DEST" ]]; then
  if [[ -e $LEGACY && ! -L $LEGACY ]]; then
    rm -f "$LEGACY"
  fi
  if ln -sfn "$DEST" "$LEGACY" 2>/dev/null; then
    ok "兼容软链: $LEGACY -> $DEST"
  fi
fi

if ! command -v cdn >/dev/null 2>&1; then
  err "$BINDIR 不在 PATH 里，请用绝对路径 $DEST，或把 $BINDIR 加进 PATH"
fi

cat <<EOF

  用法：
    cdn              # 进菜单
    sudo cdn         # 非 root 登录时

  常用：
    cdn --check      # 只做环境检查，不进菜单
    cdn --fix-apt    # 软件源失效时修复并更新索引
    cdn --set-email <addr>
    cdn --version

  下一步：
    1. 确认域名 A 记录已指向本机
    2. 确认 80 / 443 已放通（安全组 + 防火墙）
    3. cdn → 选 1 添加节点

EOF

exec "$DEST"