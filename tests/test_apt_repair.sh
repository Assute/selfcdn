#!/usr/bin/env bash
# language: bash, file: tests/test_apt_repair.sh
# 验证 Debian 源修复两级阶梯。纯文件操作，不调 apt、不碰真实 /etc/apt。
# 样本取自真实 Debian 11 (bullseye) cloud-init 源——线上实测会报：
#   E: The repository 'http://security.debian.org bullseye/updates Release' does not have a Release file.
#   E: The repository 'http://deb.debian.org/debian bullseye-backports Release' does not have a Release file.
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
chk_not() {
  local desc=$1; shift
  if "$@" >/dev/null 2>&1; then echo "  FAIL  $desc"; FAIL=$((FAIL+1))
  else echo "  PASS  $desc"; PASS=$((PASS+1)); fi
}

# 真实 bullseye cloud-init 源（含 deb-src、URL 带尾斜杠）
write_real_bullseye() {
  cat > "$APT_SOURCES" <<'EOF'
## Note, this file is written by cloud-init on first boot of an instance
###
deb http://deb.debian.org/debian bullseye main
deb-src http://deb.debian.org/debian bullseye main

## Major bug fix updates produced after the final release of the
## distribution.
deb http://security.debian.org/ bullseye/updates main
deb-src http://security.debian.org/ bullseye/updates main
deb http://deb.debian.org/debian bullseye-updates main
deb-src http://deb.debian.org/debian bullseye-updates main

## Uncomment the following two lines to add software from the 'backports'
## repository.
deb http://deb.debian.org/debian bullseye-backports main
deb-src http://deb.debian.org/debian bullseye-backports main
EOF
  : > "$APT_SOURCES_D/extra.list"
  rm -f "$APT_SOURCES.selfcdn.bak" "$APT_CONF_D/99selfcdn-archive"
}

echo "[1] 一级最小修复：真实 bullseye cloud-init 源"
write_real_bullseye
apt_fix_repos_minimal; RC=$?
chk "返回成功"                         test "$RC" -eq 0
chk "主源保持 deb.debian.org"          grep -q 'deb.debian.org/debian bullseye main' "$APT_SOURCES"
chk "未误切 archive"                   chk_not grep -q 'archive.debian.org' "$APT_SOURCES"
chk "旧 security 行已删除"             chk_not grep -q 'bullseye/updates' "$APT_SOURCES"
chk "backports 已删除"                 chk_not grep -q 'backports' "$APT_SOURCES"
chk "security 路径已补正"              grep -q 'security.debian.org/debian-security bullseye-security' "$APT_SOURCES"
chk "security 组件沿用主源"            grep -q -- '-security main$' "$APT_SOURCES"
chk "deb 与 deb-src 均补正（对称）"     test "$(grep -c 'debian-security.*bullseye-security main' "$APT_SOURCES")" -eq 2
chk "bullseye-updates 保留"            grep -q 'bullseye-updates' "$APT_SOURCES"
chk "保留主源 deb-src"                 grep -q '^deb-src http://deb.debian.org/debian bullseye main' "$APT_SOURCES"
chk "注释块未被删除"                   grep -q 'cloud-init' "$APT_SOURCES"
chk "备份已生成"                       test -f "$APT_SOURCES.selfcdn.bak"
chk "备份保留原始坏行"                 grep -q 'bullseye/updates' "$APT_SOURCES.selfcdn.bak"
chk "备份保留原始 backports"           grep -q 'bullseye-backports' "$APT_SOURCES.selfcdn.bak"

# 原位保序：security 应出现在 bullseye-updates 之前（原文件就是这么排的）
sec_ln=$(grep -n 'debian-security' "$APT_SOURCES" | head -1 | cut -d: -f1)
upd_ln=$(grep -n 'bullseye-updates main' "$APT_SOURCES" | head -1 | cut -d: -f1)
chk "security 原位替换未追加到末尾"     test "$sec_ln" -lt "$upd_ln"

echo
echo "  修复后："
sed 's/^/    /' "$APT_SOURCES"

echo
echo "[2] 幂等：二次执行不改内容"
B=$(md5sum "$APT_SOURCES" | cut -d' ' -f1)
apt_fix_repos_minimal >/dev/null 2>&1; RC2=$?
A=$(md5sum "$APT_SOURCES" | cut -d' ' -f1)
chk "内容未变"                         test "$B" = "$A"
chk "健康文件返回 1（不再处理）"        test "$RC2" -eq 1

echo
echo "[3] security 单独坏、无 backports（原正则会漏判）"
cat > "$APT_SOURCES" <<'EOF'
deb http://deb.debian.org/debian bullseye main
deb http://security.debian.org/ bullseye/updates main
EOF
rm -f "$APT_SOURCES.selfcdn.bak"
apt_fix_repos_minimal >/dev/null 2>&1; RC3=$?
chk "仍能识别并修复"                   test "$RC3" -eq 0
chk "security 已补正"                  grep -q 'debian-security bullseye-security main' "$APT_SOURCES"
chk "旧行已删"                         chk_not grep -q 'bullseye/updates' "$APT_SOURCES"

echo
echo "[4] 二级归档兜底（发行版彻底 EOL）"
write_real_bullseye
apt_fix_eol_repos; RC4=$?
chk "返回成功"                         test "$RC4" -eq 0
chk "主源切 archive"                   grep -q 'archive.debian.org/debian bullseye main' "$APT_SOURCES"
chk "无 deb.debian.org 残留"           chk_not grep -q 'deb\.debian\.org' "$APT_SOURCES"
chk "无 security.debian.org 残留"      chk_not grep -q 'security\.debian\.org' "$APT_SOURCES"
chk "生成 Valid-Until 关闭配置"        grep -q 'Acquire::Check-Valid-Until "false"' "$APT_CONF_D/99selfcdn-archive"

echo
echo "[5] sources.list.d 一并处理"
write_real_bullseye
cat > "$APT_SOURCES_D/extra.list" <<'EOF'
deb https://security.debian.org/debian-security bullseye-security main
deb http://deb.debian.org/debian bullseye-backports main
EOF
apt_fix_repos_minimal >/dev/null 2>&1
chk "extra.list 剔除 backports"        chk_not grep -q 'backports' "$APT_SOURCES_D/extra.list"
chk "extra.list 保留合法 security"     grep -q 'debian-security bullseye-security main' "$APT_SOURCES_D/extra.list"
chk "extra.list 未重复追加"            test "$(grep -c 'debian-security' "$APT_SOURCES_D/extra.list")" -eq 1

echo
echo "[6] 不误伤：第三方镜像 / 健康官方源"
cat > "$APT_SOURCES" <<'EOF'
deb http://mirrors.aliyun.com/debian bullseye main
EOF
apt_fix_repos_minimal >/dev/null 2>&1; RC6=$?
chk "镜像源返回 1（无需处理）"          test "$RC6" -eq 1
chk "镜像源内容未变"                   grep -q 'mirrors.aliyun.com' "$APT_SOURCES"

cat > "$APT_SOURCES" <<'EOF'
deb http://deb.debian.org/debian bookworm main
deb http://security.debian.org/debian-security bookworm-security main
EOF
apt_fix_repos_minimal >/dev/null 2>&1; RC7=$?
chk "健康源返回 1（不动）"              test "$RC7" -eq 1
chk "健康源未改写"                     grep -q 'deb.debian.org/debian bookworm main' "$APT_SOURCES"
chk "健康源未重复追加 security"         test "$(grep -c 'debian-security' "$APT_SOURCES")" -eq 1

echo
echo "[7] codename 推导（不硬编码）"
CN=$(get_debian_codename)
echo "    探测到: ${CN:-（无）}"
chk "非空且形如小写字母"               test -n "$CN" -a "$(printf '%s' "$CN" | grep -cE '^[a-z]+$')" -eq 1
chk "脚本内无硬编码 codename"          chk_not grep -qE 'bullseye-security|bookworm-security' "$SRC"

echo
echo "==================== 结果: PASS=$PASS  FAIL=$FAIL ===================="
[[ $FAIL -eq 0 ]] || exit 1