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
for f in "$ROOT/selfcdn.sh" "$ROOT/install.sh" "$ROOT/tests/test_render.sh"; do
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

step "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S warning "$ROOT/selfcdn.sh"; then good "shellcheck 无 warning 及以上"
  else bad "shellcheck 有告警"; fi
else
  printf "  跳过（未安装 shellcheck）\n"
fi

printf "\n==================== lint: FAIL=%d ====================\n" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1