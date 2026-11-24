#!/usr/bin/env bash
# language: bash, file: tests/lint.sh
# 静态检查：shellcheck（若装）+ bash -n + 关键反模式扫描
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

FAIL=0
step() { printf "\n=== %s ===\n" "$*"; }
bad()  { printf "  FAIL  %s\n" "$*"; FAIL=$((FAIL+1)); }
good() { printf "  ok    %s\n" "$*"; }

step "语法检查"
for f in "$ROOT/selfcdn.sh" "$ROOT/install.sh" "$ROOT/tests/test_render.sh" "$ROOT/tests/test_apt_repair.sh" "$ROOT/tests/test_eof.sh" "$ROOT/tests/test_email.sh"; do
  if bash -n "$f" 2>/dev/null; then good "$(basename "$f")"; else bad "$(basename "$f") bash -n"; fi
done

step "反模式扫描"
scan_absent() {
  local desc=$1 pat=$2 file=$3
  if grep -nE "$pat" "$file" >/dev/null 2>&1; then
    bad "$desc"
    grep -nE "$pat" "$file" | head -5 | sed 's/^/          /'
  else good "$desc"; fi
}
# 未加引号的 rm -rf 变量是灾难源
scan_absent 'rm -rf \$变量未加引号保护' 'rm -rf \$[A-Z_]+ ' "$ROOT/selfcdn.sh"
# 必须有 set -uo pipefail
grep -q 'set -uo pipefail' "$ROOT/selfcdn.sh" && good "set -uo pipefail" || bad "缺 set -uo pipefail"
# 必须有 root 检查
grep -q 'EUID' "$ROOT/selfcdn.sh" && good "root 检查" || bad "缺 root 检查"
# nginx -t 必须卡在 reload 前
awk '/^nginx_reload\(\)/,/^}/' "$ROOT/selfcdn.sh" | grep -q 'nginx_test' \
  && good "reload 前强制 nginx_test" || bad "reload 未强制 nginx_test"
# 危险删除必须有 ${VAR:?} 保护
grep -q 'rm -rf "${CACHE_ROOT:?}"' "$ROOT/selfcdn.sh" \
  && good "缓存清理有 :? 空值保护" || bad "缓存清理缺 :? 保护"
# update 失败时必须先修源再装：否则 install 会靠旧索引蒙成功，把坏源留给用户
awk '/^pkg_install\(\)/,/^}/' "$ROOT/selfcdn.sh" | grep -q 'refreshed=0' \
  && good "pkg_install 感知 update 失败" || bad "pkg_install 不感知 update 失败"
awk '/^pkg_install\(\)/,/^}/' "$ROOT/selfcdn.sh" | grep -q 'apt_repair_ladder' \
  && good "update 失败先走修源阶梯" || bad "update 失败未先修源"
awk '/^pkg_install\(\)/,/^}/' "$ROOT/selfcdn.sh" | grep -q '索引仍不可用' \
  && good "修源失败有明确告警（不静默留坏源）" || bad "修源失败仍静默成功"
# install 阶段的下载失败（.deb 404）也要触发升档，不能只看 update
awk '/^pkg_install\(\)/,/^}/' "$ROOT/selfcdn.sh" | grep -q 'apt_log_is_fetch_failure' \
  && good "install 下载失败也升档" || bad "pkg_install 忽略了 install 阶段失败"
awk '/^pkg_install\(\)/,/^}/' "$ROOT/selfcdn.sh" | grep -q 'apt_move_security_to_archive' \
  && good "升档含 security 转归档" || bad "缺 security 转归档升档"
awk '/^pkg_install\(\)/,/^}/' "$ROOT/selfcdn.sh" | grep -q 'apt_fix_eol_repos' \
  && good "升档含整体归档兜底" || bad "缺整体归档兜底"
# 源修复必须先备份再改
awk '/^apt_fix_repos_minimal\(\)/,/^}/' "$ROOT/selfcdn.sh" | grep -q 'cp -n .*selfcdn.bak' \
  && good "源修复前有备份" || bad "源修复未备份"
# 不得在可执行语句里硬编码具体 codename（注释里提案例可以）
if grep -vE '^[[:space:]]*#' "$ROOT/selfcdn.sh" | grep -qE '(bullseye|bookworm|focal|jammy)-security'; then
  bad "硬编码了具体 codename"
else
  good "无硬编码 codename（按 os-release 推导）"
fi
# ACME 邮箱必须校验保留域名，否则 LE 直接 400 invalidContact（线上踩过）
grep -q 'is_forbidden_email' "$ROOT/selfcdn.sh" \
  && good "校验 LE 保留域名邮箱" || bad "未校验保留域名邮箱（example.com 会导致签发失败）"
grep -q 'sync_acme_email' "$ROOT/selfcdn.sh" \
  && good "邮箱同步到 acme.sh account.conf" || bad "只写 /etc/selfcdn/email 不生效，未同步 acme.sh"
grep -q 'diagnose_acme_failure' "$ROOT/selfcdn.sh" \
  && good "ACME 失败按原因分类诊断" || bad "ACME 失败未分类诊断"# 主菜单必须在 stdin EOF 时退出，否则管道/ Ctrl-D 会空转烧 CPU
awk '/^main_menu\(\)/,/^}/' "$ROOT/selfcdn.sh" | grep -qE 'if ! read|read -rp .* \|\|' \
  && good "主菜单处理 EOF（不会空转）" || bad "主菜单未处理 EOF，可能死循环"
# 颜色码必须是真实 ESC，否则 cat <<HEREDOC 会打出字面量 \033
grep -q "R=\$'\\\\033" "$ROOT/selfcdn.sh" \
  && good "颜色码为真实 ESC（banner 不会打出字面量）" || bad "颜色码是字面量 \\033，banner 会乱"

step "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S warning "$ROOT/selfcdn.sh"; then good "shellcheck 无 warning 及以上"
  else bad "shellcheck 有告警"; fi
else
  printf "  跳过（未安装 shellcheck）\n"
fi

printf "\n==================== lint: FAIL=%d ====================\n" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1