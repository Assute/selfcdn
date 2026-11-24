#!/usr/bin/env bash
# language: bash, file: tests/test_apt_repair.sh
# 验证 Debian 源修复的两级阶梯：纯文件操作，不调 apt、不碰真实 /etc/apt
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC=$HERE/../selfcdn.sh
[[ -f $SRC ]] || SRC=$HERE/selfcdn.sh
[[ -f $SRC ]] || { echo "找不到 selfcdn.sh"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
source "$SRC"
unset -f main 2>/dev/null || true

APT_SOURCES=$TMP/sources.list
APT_SOURCES_D=$TMP/sources.list.d
APT_CONF_D=$TMP/apt.conf.d
mkdir -p "$APT_SOURCES_D" "$APT_CONF_D"

PASS=0; FAIL=0
chk() {
  local desc=$1; shift
  if "$@" >/dev/null 2>&1; then echo "  PASS  $desc"; PASS=$((PASS+1))
  else echo "  FAIL  $desc"; FAIL=$((FAIL+1)); fi
}

# 复刻用户机器上的真实坏源（主源可用，只有 updates/backports 两条失效）
reset_case() {
  cat > "$APT_SOURCES" <<'EOF'
deb http://deb.debian.org/debian bullseye main contrib non-free
deb http://security.debian.org bullseye/updates main contrib non-free
deb http://deb.debian.org/debian bullseye-backports main contrib non-free
deb http://deb.debian.org/debian bullseye-updates main contrib non-free
EOF
  rm -f "$APT_SOURCES.selfcdn.bak" "$APT_CONF_D/99selfcdn-archive"
  : > "$APT_SOURCES_D/extra.list"
}

echo "[1] 第一级：最小修复（用户机器的真实情况）"
reset_case
apt_fix_repos_minimal
RC=$?
chk "返回成功"                       test $RC -eq 0
chk "主源保持 deb.debian.org"        grep -q 'deb.debian.org/debian bullseye main' "$APT_SOURCES"
chk "未错误切到 archive"             bash -c "! grep -q 'archive.debian.org' '$APT_SOURCES'"
chk "旧 security 行已删除"           bash -c "! grep -q 'bullseye/updates' '$APT_SOURCES'"
chk "backports 已删除"               bash -c "! grep -q 'backports' '$APT_SOURCES'"
chk "补正 security 源路径"           grep -q 'security.debian.org/debian-security bullseye-security' "$APT_SOURCES"
chk "security 组件沿用 main 行"      grep -q 'bullseye-security main contrib non-free' "$APT_SOURCES"
chk "bullseye-updates 保留"          grep -q 'bullseye-updates' "$APT_SOURCES"
chk "原文件已备份"                   test -f "$APT_SOURCES.selfcdn.bak"
chk "备份保留原始坏行"               grep -q 'security.debian.org bullseye/updates' "$APT_SOURCES.selfcdn.bak"

echo
echo "  修复后 sources.list:"
sed 's/^/    /' "$APT_SOURCES"

echo
echo "[2] 幂等：再跑不应重复改动"
B=$(md5sum "$APT_SOURCES" | cut -d' ' -f1)
apt_fix_repos_minimal >/dev/null 2>&1
A=$(md5sum "$APT_SOURCES" | cut -d' ' -f1)
chk "二次执行不改内容"               test "$B" = "$A"

echo
echo "[3] 第二级：主源也失效 → 切归档"
reset_case
apt_fix_eol_repos
chk "返回成功"                       test $? -eq 0
chk "主源切到 archive"               grep -q 'archive.debian.org/debian bullseye main' "$APT_SOURCES"
chk "无残留 deb.debian.org"          bash -c "! grep -q 'deb\.debian\.org' '$APT_SOURCES'"
chk "无残留 security.debian.org"     bash -c "! grep -q 'security\.debian\.org' '$APT_SOURCES'"
chk "生成 Valid-Until 关闭配置"      grep -q 'Acquire::Check-Valid-Until "false"' "$APT_CONF_D/99selfcdn-archive"

echo
echo "[4] sources.list.d 一并处理"
reset_case
cat > "$APT_SOURCES_D/extra.list" <<'EOF'
deb https://security.debian.org/debian-security bullseye-security main
deb http://deb.debian.org/debian bullseye-backports main
EOF
apt_fix_repos_minimal >/dev/null 2>&1
chk "extra.list 剔除 backports"      bash -c "! grep -q 'backports' '$APT_SOURCES_D/extra.list'"
chk "extra.list 保留合法 security"   grep -q 'security.debian.org/debian-security bullseye-security' "$APT_SOURCES_D/extra.list"

echo
echo "[5] 干净源 / 第三方镜像不误伤"
cat > "$APT_SOURCES" <<'EOF'
deb http://mirrors.aliyun.com/debian bullseye main
EOF
: > "$APT_SOURCES_D/extra.list"
apt_fix_repos_minimal >/dev/null 2>&1
RC2=$?
chk "最小修复返回 1（无需处理）"      test "$RC2" -eq 1
chk "镜像源内容未被改动"             grep -q 'mirrors.aliyun.com' "$APT_SOURCES"

cat > "$APT_SOURCES" <<'EOF'
# 干净官方源，无坏行
deb http://deb.debian.org/debian bookworm main
deb http://security.debian.org/debian-security bookworm-security main
EOF
apt_fix_repos_minimal >/dev/null 2>&1
RC3=$?
chk "健康官方源返回 1（不动）"        test "$RC3" -eq 1
chk "健康源未被改写"                 grep -q 'deb.debian.org/debian bookworm main' "$APT_SOURCES"
chk "健康源未重复追加 security"       test "$(grep -c 'debian-security' "$APT_SOURCES")" -eq 1

echo
echo "[6] codename 探测"
CN=$(get_debian_codename)
echo "    探测到 codename: ${CN:-（无，非 Debian 环境）}"
chk "函数可调用且不报错"              test $? -eq 0

echo
echo "==================== 结果: PASS=$PASS  FAIL=$FAIL ===================="
[[ $FAIL -eq 0 ]] || exit 1