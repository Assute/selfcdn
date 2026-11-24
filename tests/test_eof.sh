#!/usr/bin/env bash
# language: bash, file: tests/test_eof.sh
# 主菜单在 stdin EOF 时必须立即退出。
# 线上实测：不判 read 返回值时，choice 为空 → 无效分支 → pause 也 EOF 返回
# → 循环空转，烧 28% CPU 十分钟不停。
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC=$HERE/../selfcdn.sh
[[ -f $SRC ]] || SRC=$HERE/selfcdn.sh
[[ -f $SRC ]] || { echo "找不到 selfcdn.sh"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/n" "$TMP/c" "$TMP/k" "$TMP/sd" "$TMP/ac"

PASS=0; FAIL=0
chk() {
  local d=$1; shift
  if "$@" >/dev/null 2>&1; then echo "  PASS  $d"; PASS=$((PASS+1))
  else echo "  FAIL  $d"; FAIL=$((FAIL+1)); fi
}

# 灌入 EOF，限时 6 秒；超时说明还在空转
export T="$TMP" SRC
OUT=$(printf '' | timeout 6 bash -c '
  export NGINX_CONF_D=$T/conf NODES_DIR=$T/n CERT_DIR=$T/c CACHE_ROOT=$T/k
  export ACME_ROOT=$T/a GLOBAL_CONF=$T/g.conf BASE=$T/b
  export APT_SOURCES=/dev/null APT_SOURCES_D=$T/sd APT_CONF_D=$T/ac
  mkdir -p "$NGINX_CONF_D" "$APT_SOURCES_D" "$APT_CONF_D"
  # shellcheck disable=SC1090
  source "$SRC"
  PKG=apt; NGINX_VER=1.18.0
  V6_LISTEN80=""; V6_LISTEN443=""; SSL_LISTEN=""
  main_menu
' 2>&1)
RC=$?

echo "[1] EOF 行为"
echo "    退出码: $RC"
chk "EOF 后正常退出（0）"        test "$RC" -eq 0
chk "未超时（没有空转）"          test "$RC" -ne 124
chk "输出含退出提示"              bash -c "printf '%s' \"\$0\" | grep -q 'EOF'" "$OUT"
chk "只打印了一次菜单"            bash -c "test \$(printf '%s' \"\$0\" | grep -c '选择序号') -le 2" "$OUT"

echo
echo "[2] 非法输入后 EOF 也要能退出"
OUT2=$(printf 'zzz\n' | timeout 6 bash -c '
  export NGINX_CONF_D=$T/conf NODES_DIR=$T/n CERT_DIR=$T/c CACHE_ROOT=$T/k
  export ACME_ROOT=$T/a GLOBAL_CONF=$T/g.conf BASE=$T/b
  export APT_SOURCES=/dev/null APT_SOURCES_D=$T/sd APT_CONF_D=$T/ac
  mkdir -p "$NGINX_CONF_D" "$APT_SOURCES_D" "$APT_CONF_D"
  # shellcheck disable=SC1090
  source "$SRC"
  PKG=apt; NGINX_VER=1.18.0
  V6_LISTEN80=""; V6_LISTEN443=""; SSL_LISTEN=""
  main_menu
' 2>&1)
RC2=$?
chk "非法输入后仍能退出"          test "$RC2" -eq 0
chk "非法输入未超时"              test "$RC2" -ne 124
chk "提示了无效序号"              bash -c "printf '%s' \"\$0\" | grep -q '无效序号'" "$OUT2"

echo
echo "[3] 正常 0 退出"
OUT3=$(printf '0\n' | timeout 6 bash -c '
  export NGINX_CONF_D=$T/conf NODES_DIR=$T/n CERT_DIR=$T/c CACHE_ROOT=$T/k
  export ACME_ROOT=$T/a GLOBAL_CONF=$T/g.conf BASE=$T/b
  export APT_SOURCES=/dev/null APT_SOURCES_D=$T/sd APT_CONF_D=$T/ac
  mkdir -p "$NGINX_CONF_D" "$APT_SOURCES_D" "$APT_CONF_D"
  # shellcheck disable=SC1090
  source "$SRC"
  PKG=apt; NGINX_VER=1.18.0
  V6_LISTEN80=""; V6_LISTEN443=""; SSL_LISTEN=""
  main_menu
' 2>&1)
chk "选 0 退出码为 0"             test $? -eq 0
chk "选 0 有告别提示"             bash -c "printf '%s' \"\$0\" | grep -q 'bye'" "$OUT3"

echo
echo "==================== 结果: PASS=$PASS  FAIL=$FAIL ===================="
[[ $FAIL -eq 0 ]] || exit 1