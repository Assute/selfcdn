#!/usr/bin/env bash
# language: bash, file: tests/test_email.sh
# ACME 账户邮箱校验与 acme.sh 同步。
# 线上真实报错：
#   Account registration error: {"type":"urn:ietf:params:acme:error:invalidContact",
#     "detail":"Error validating contact(s) :: contact email has forbidden domain \"example.com\""}
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

EMAIL_FILE=$TMP/email
ACME_HOME=$TMP/acmehome
ACME_SH=$ACME_HOME/acme.sh
mkdir -p "$ACME_HOME"

PASS=0; FAIL=0
chk() { local d=$1; shift; if "$@" >/dev/null 2>&1; then echo "  PASS  $d"; PASS=$((PASS+1)); else echo "  FAIL  $d"; FAIL=$((FAIL+1)); fi; }
nchk() { local d=$1; shift; if "$@" >/dev/null 2>&1; then echo "  FAIL  $d"; FAIL=$((FAIL+1)); else echo "  PASS  $d"; PASS=$((PASS+1)); fi; }

echo "[1] 必须拒绝的保留域名（LE 会直接 400）"
for e in ops@example.com a@example.net b@example.org c@test.com x@example.edu \
         d@foo.test e@bar.invalid f@baz.localhost g@qux.local h@sub.example; do
  nchk "拒绝 $e" is_valid_email "$e"
done

echo
echo "[2] 必须接受的正常邮箱"
for e in admin@hsaoyun.com ops@my-cdn.cn a.b+tag@sub.domain.co.uk x_y@a1.io; do
  chk "接受 $e" is_valid_email "$e"
done

echo
echo "[3] 格式非法必须拒绝"
for e in "" "@" "a@" "@b.com" "a b@c.com" "a@b" "a@@b.com" "a@b..com"; do
  nchk "拒绝 [${e:-空}]" is_valid_email "$e"
done

echo
echo "[4] 大小写与后缀判定"
nchk "拒绝 EXAMPLE.COM（大写）"   is_valid_email "a@EXAMPLE.COM"
nchk "拒绝 Ops@Example.Com"       is_valid_email "Ops@Example.Com"
chk  "接受 mixed@Hsaoyun.COM"     is_valid_email "mixed@Hsaoyun.COM"

echo
echo "[5] 历史坏邮箱要被识别并拒绝沿用"
printf 'ops@example.com\n' > "$EMAIL_FILE"
nchk "旧值 example.com 判为非法"   is_valid_email "$(cat "$EMAIL_FILE")"
printf 'admin@hsaoyun.com\n' > "$EMAIL_FILE"
chk  "换成真实域名后合法"          is_valid_email "$(cat "$EMAIL_FILE")"

echo
echo "[6] sync_acme_email 覆盖 account.conf 里的坏邮箱"
cat > "$ACME_HOME/account.conf" <<'EOF'
LOG_FILE='/root/.acme.sh/acme.sh.log'
ACCOUNT_EMAIL='ops@example.com'
USER_AGENT='acme.sh/3.1.7'
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$ACME_SH"; chmod +x "$ACME_SH"
sync_acme_email "admin@hsaoyun.com" >/dev/null 2>&1
chk "account.conf 已改为新邮箱"   grep -q "ACCOUNT_EMAIL='admin@hsaoyun.com'" "$ACME_HOME/account.conf"
nchk "account.conf 无 example.com 残留" grep -q 'example\.com' "$ACME_HOME/account.conf"
chk "其他配置行未被破坏"           grep -q "USER_AGENT=" "$ACME_HOME/account.conf"
chk "LOG_FILE 仍在"                grep -q "LOG_FILE=" "$ACME_HOME/account.conf"

echo
echo "[7] account.conf 无 ACCOUNT_EMAIL 时应追加"
cat > "$ACME_HOME/account.conf" <<'EOF'
LOG_FILE='/root/.acme.sh/acme.sh.log'
EOF
sync_acme_email "ops@real-domain.com" >/dev/null 2>&1
chk "已追加 ACCOUNT_EMAIL"         grep -q "ACCOUNT_EMAIL='ops@real-domain.com'" "$ACME_HOME/account.conf"

echo
echo "[8] 含 sed 危险字符的邮箱不能破坏配置文件"
cat > "$ACME_HOME/account.conf" <<'EOF'
ACCOUNT_EMAIL='old@x.com'
EOF
sync_acme_email "bad|pipe@x.com" >/dev/null 2>&1
chk "含 | 被跳过，原值保留"         grep -q "ACCOUNT_EMAIL='old@x.com'" "$ACME_HOME/account.conf"

echo
echo "[9] acme 日志分类与诊断文案"
# 注意：不能用 `诊断 2>&1 | grep -q`。grep -q 命中即关管道，左侧收 SIGPIPE，
# 配合 set -o pipefail 会让整条管道返回 141，导致明明是 PASS 却走 FAIL 分支。
diagnose() { diagnose_acme_failure "$1" "$2" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; }

echo '{"type":"urn:ietf:params:acme:error:invalidContact","detail":"contact email has forbidden domain \"example.com\""}' > "$TMP/log1"
acme_log_is_fatal "$TMP/log1" && { echo "  PASS  邮箱错误判为致命（不再降级重试）"; PASS=$((PASS+1)); } \
  || { echo "  FAIL  邮箱错误未判为致命"; FAIL=$((FAIL+1)); }
OUT=$(diagnose "$TMP/log1" "t.example.com")
grep -q 'ACME 拒绝了账户邮箱' <<< "$OUT" \
  && { echo "  PASS  诊断指向邮箱"; PASS=$((PASS+1)); } \
  || { echo "  FAIL  诊断未指向邮箱"; FAIL=$((FAIL+1)); }
grep -q 'forbidden domain' <<< "$OUT" \
  && { echo "  PASS  诊断带出 LE 原始 detail"; PASS=$((PASS+1)); } \
  || { echo "  FAIL  诊断未带出原始 detail"; FAIL=$((FAIL+1)); }
grep -q '菜单 11' <<< "$OUT" \
  && { echo "  PASS  诊断给出改法"; PASS=$((PASS+1)); } \
  || { echo "  FAIL  诊断未给改法"; FAIL=$((FAIL+1)); }

echo 'DNS problem: NXDOMAIN looking up A for x.com' > "$TMP/log2"
acme_log_is_fatal "$TMP/log2" && { echo "  FAIL  DNS 错误被误判为致命"; FAIL=$((FAIL+1)); } \
  || { echo "  PASS  DNS 错误不判致命（可降级重试）"; PASS=$((PASS+1)); }
OUT=$(diagnose "$TMP/log2" "x.com")
grep -q '域名解析问题' <<< "$OUT" \
  && { echo "  PASS  诊断指向 DNS"; PASS=$((PASS+1)); } \
  || { echo "  FAIL  诊断未指向 DNS"; FAIL=$((FAIL+1)); }

echo 'Fetching https://...: Connection refused' > "$TMP/log3"
OUT=$(diagnose "$TMP/log3" "x.com")
grep -q '80 端口不可达' <<< "$OUT" \
  && { echo "  PASS  诊断指向 80 端口"; PASS=$((PASS+1)); } \
  || { echo "  FAIL  诊断未指向端口"; FAIL=$((FAIL+1)); }

echo '{"type":"urn:ietf:params:acme:error:rateLimited"}' > "$TMP/log4"
acme_log_is_fatal "$TMP/log4" && { echo "  PASS  频率限制判为致命"; PASS=$((PASS+1)); } \
  || { echo "  FAIL  频率限制未判致命"; FAIL=$((FAIL+1)); }
OUT=$(diagnose "$TMP/log4" "x.com")
grep -q '频率限制' <<< "$OUT" \
  && { echo "  PASS  诊断指向频率限制"; PASS=$((PASS+1)); } \
  || { echo "  FAIL  诊断未指向频率限制"; FAIL=$((FAIL+1)); }

# 未知错误也要给出完整日志路径，便于排查
echo 'something totally unexpected went wrong' > "$TMP/log5"
OUT=$(diagnose "$TMP/log5" "x.com")
grep -q '完整日志' <<< "$OUT" \
  && { echo "  PASS  未知错误给出日志路径"; PASS=$((PASS+1)); } \
  || { echo "  FAIL  未知错误未给日志路径"; FAIL=$((FAIL+1)); }


echo
echo "[10] 证书状态判定与重复签发处理"
# 线上踩过：acme.sh 3.1.7 的 --info 不输出 Le_RealCertPath / Le_CertCreateTime，
# 靠它判"已签发"会误判 → 重复 --issue → 撞 Domain key exists → 失败。
mkdir -p "$ACME_HOME/demo.example.org_ecc"

# git-bash(MSYS) 会把 -subj 里的 /CN=... 当路径改写，用 //CN= 变通；Linux 保持单斜杠
subj_cn() {
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) printf "//CN=%s" "$1" ;;
    *) printf "/CN=%s" "$1" ;;
  esac
}
SELF_SIGNED=$TMP/ss.cer
openssl req -x509 -newkey rsa:2048 -nodes -days 90 \
  -keyout "$TMP/ss.key" -out "$SELF_SIGNED" -subj "$(subj_cn demo.example.org)" >/dev/null 2>&1

nchk "无证书时 acme_has_cert 为假"      acme_has_cert "demo.example.org"
cp "$SELF_SIGNED" "$ACME_HOME/demo.example.org_ecc/demo.example.org.cer"
chk  "有证书时 acme_has_cert 为真"      acme_has_cert "demo.example.org"
chk  "证书路径按 <domain>_ecc 构造"      test "$(acme_cert_file demo.example.org)" = "$ACME_HOME/demo.example.org_ecc/demo.example.org.cer"

D1=$(cert_days_left "$SELF_SIGNED")
echo "    自签 90 天证书探测剩余天数: $D1"
chk  "剩余天数为正数（80-91）"           test "$D1" -ge 80 -a "$D1" -le 91
chk  "不存在文件返回 -1"                test "$(cert_days_left "$TMP/nope.cer")" -eq -1

# 过期证书应给出 <=0
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout "$TMP/old.key" -out "$TMP/old.cer" -subj "$(subj_cn old)" >/dev/null 2>&1
chk  "1 天期证书 <=1"                   test "$(cert_days_left "$TMP/old.cer")" -le 1

echo
echo "[11] acme 输出里的\"已存在\"签名"
echo '[Tue] Domain key exists, do you want to overwrite it?' > "$TMP/k1"
echo "    add '--force' and try again." >> "$TMP/k1"
acme_log_already_issued "$TMP/k1" \
  && { echo "  PASS  Domain key exists 识别为已存在"; PASS=$((PASS+1)); } \
  || { echo "  FAIL  Domain key exists 未识别"; FAIL=$((FAIL+1)); }

echo '[Tue] Domains are the same, Please use --force to renew.' > "$TMP/k2"
acme_log_already_issued "$TMP/k2" \
  && { echo "  PASS  Domains are the same 识别为已存在"; PASS=$((PASS+1)); } \
  || { echo "  FAIL  Domains are the same 未识别"; FAIL=$((FAIL+1)); }

echo '[Tue] Skip, Next renewal time is: 2027-02-22' > "$TMP/k3"
acme_log_already_issued "$TMP/k3" \
  && { echo "  PASS  未到续期窗口识别为已存在"; PASS=$((PASS+1)); } \
  || { echo "  FAIL  未到续期窗口未识别"; FAIL=$((FAIL+1)); }

echo '[Tue] Creating domain key' > "$TMP/k4"
acme_log_already_issued "$TMP/k4" \
  && { echo "  FAIL  正常签发改判为已存在"; FAIL=$((FAIL+1)); } \
  || { echo "  PASS  正常签发不误判"; PASS=$((PASS+1)); }

echo
echo "[12] 已存在签名的诊断文案"
OUT=$( { diagnose_acme_failure "$TMP/k1" "demo.example.org"; } 2>&1 | sed 's/\x1b\[[0-9;]*m//g' )
grep -q '已有证书/key' <<< "$OUT" \
  && { echo "  PASS  诊断说明是重复签发"; PASS=$((PASS+1)); } \
  || { echo "  FAIL  诊断未说明重复签发"; FAIL=$((FAIL+1)); }
grep -q '\-\-force' <<< "$OUT" \
  && { echo "  PASS  诊断给出 --force 手工修法"; PASS=$((PASS+1)); } \
  || { echo "  FAIL  诊断未给修法"; FAIL=$((FAIL+1)); }

echo
echo "[13] 脚本必须只在 install 时复制，不在删节点时删 acme 证书"
nchk "del_node 不调用 acme --remove" bash -c "awk '/^del_node\\(\\)/,/^}/' '$SRC' | grep -q 'ACME_SH\" --remove'"
nchk "uninstall_all 不调用 acme --remove" bash -c "awk '/^uninstall_all\\(\\)/,/^}/' '$SRC' | grep -q 'ACME_SH\" --remove'"
chk  "issue_cert 识别已存在证书" bash -c "grep -q 'acme_log_already_issued' '$SRC'"
chk  "issue_cert 不再依赖 --info 键名" bash -c "! awk '/^issue_cert\\(\\)/,/^}/' '$SRC' | grep -q 'Le_RealCertPath'"


echo "==================== 结果: PASS=$PASS  FAIL=$FAIL ===================="
[[ $FAIL -eq 0 ]] || exit 1