#!/usr/bin/env bash
# 离线渲染自测：不碰系统、不碰网络，只验证 gen_node_conf 产出的 Nginx 配置结构
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC=$HERE/../selfcdn.sh
[[ -f $SRC ]] || SRC=$HERE/selfcdn.sh
[[ -f $SRC ]] || { echo "找不到 selfcdn.sh"; exit 1; }
echo "被测脚本: $SRC"

TMP=$(mktemp -d)
# shellcheck disable=SC1090
source "$SRC"
unset -f main 2>/dev/null || true

# 覆盖为临时路径（source 后覆盖，否则被脚本顶部默认值冲掉）
NGINX_CONF_D=$TMP/conf.d
NODES_DIR=$TMP/nodes
CERT_DIR=$TMP/certs
CACHE_ROOT=$TMP/cache
ACME_ROOT=$TMP/acme
BASE=$TMP/base
GLOBAL_CONF=$NGINX_CONF_D/00-selfcdn-global.conf

mkdir -p "$NGINX_CONF_D" "$NODES_DIR" "$CERT_DIR" "$CACHE_ROOT"

PASS=0; FAIL=0
chk() {
  local desc=$1 pat=$2 file=$3 neg=${4:-}
  local hit=0
  grep -qE "$pat" "$file" && hit=1
  if [[ -n $neg ]]; then
    if (( hit == 0 )); then echo "  PASS  $desc"; PASS=$((PASS+1))
    else echo "  FAIL  $desc  (不应出现: $pat)"; FAIL=$((FAIL+1)); fi
  else
    if (( hit == 1 )); then echo "  PASS  $desc"; PASS=$((PASS+1))
    else echo "  FAIL  $desc  (缺失: $pat)"; FAIL=$((FAIL+1)); fi
  fi
}

nginx_version_gate
echo "nginx 版本判断: $NGINX_VER"
echo "SSL_LISTEN = $SSL_LISTEN"
echo

# --- 用例 A: 缓存开启 + 无证书 → HTTP 引导模式
echo "[A] edge1 缓存开启、双回源、无证书（HTTP 引导）"
NAME=edge1; DOMAIN=static.example.com
UPSTREAMS="1.2.3.4:8080 5.6.7.8:80"
UPSTREAM_SCHEME=http
PROXY_HOST='$host'
CACHE_ENABLE=1; CACHE_TTL=24h; CACHE_SIZE=5g; CACHE_MEM=100m
CLIENT_MAX_BODY=100m; TLS_MODE=acme
save_node edge1
render_global_conf
gen_node_conf edge1 >/dev/null
CONF=$NGINX_CONF_D/selfcdn-edge1.conf

chk "生成 upstream 块"            "^upstream edge1_up \{"        "$CONF"
chk "上游 1.2.3.4:8080"           "server 1\.2\.3\.4:8080"        "$CONF"
chk "上游 5.6.7.8:80"             "server 5\.6\.7\.8:80"          "$CONF"
chk "80 引导监听"                 "listen 80;"                    "$CONF"
chk "无 443 监听"                 "listen 443"                    "$CONF" neg
chk "ACME challenge 路径"         "acme-challenge"                "$CONF"
chk "缓存指令存在"                "proxy_cache cdn_edge1;"        "$CONF"
chk "缓存键含 Host"               "proxy_cache_key .*\\\$host"     "$CONF"
chk "X-Cache-Status 下发"         "X-Cache-Status"                "$CONF"
chk "引导期无 HSTS"               "Strict-Transport-Security"     "$CONF" neg
chk "安全头 nosniff"              "X-Content-Type-Options"        "$CONF"
chk "回源 Host 变量"              "Host              \\\$host"     "$CONF"
chk "proxy_pass 指向上游组"       "proxy_pass http://edge1_up;"   "$CONF"
chk "无未替换占位符"              "@[A-Z_]+@"                     "$CONF" neg

echo
echo "  缓存区索引:"
sed 's/^/    /' "$NGINX_CONF_D/00-selfcdn-global.conf"
chk "缓存区含 zone cdn_edge1"     "keys_zone=cdn_edge1:100m"      "$NGINX_CONF_D/00-selfcdn-global.conf"

# --- 用例 B: 有证书 → HTTPS 模式
echo
echo "[B] edge1 已签证书（HTTPS 模式）"
mkdir -p "$CERT_DIR/edge1"
: > "$CERT_DIR/edge1/fullchain.cer"
: > "$CERT_DIR/edge1/static.example.com.key"
gen_node_conf edge1 >/dev/null
chk "443 监听"                    "listen 443 ssl"                "$CONF"
chk "HTTP/2（v>=1.25 用 http2 on）" "http2"                        "$CONF"
chk "证书链路径"                  "ssl_certificate .*fullchain\.cer" "$CONF"
chk "私钥路径"                    "ssl_certificate_key .*\.key"   "$CONF"
chk "301 跳转 HTTPS"              "return 301 https"              "$CONF"
chk "HTTPS 期有 HSTS"             "Strict-Transport-Security"     "$CONF"
chk "无 stapling（LE 已停 OCSP）" "ssl_stapling"                  "$CONF" neg
chk "无未替换占位符"              "@[A-Z_]+@"                     "$CONF" neg
# IPv6 条件监听：行数与当前环境的 V6_LISTEN 一致，不能出现空 listen 行
if [[ -n ${V6_LISTEN80:-}${V6_LISTEN443:-} ]]; then
  chk "v6 开启时监听 [::]:443"    "listen \[::\]:443 ssl"         "$CONF"
else
  chk "v6 关闭时无 [::] 监听"     "listen \[::\]"                 "$CONF" neg
fi
chk "无残缺 listen 行"            "^ *listen *;? *\$"             "$CONF" neg

# 每条指令必须独占一行：命令替换吃掉换行会把 add_header 挤在一起、把 } 粘在行尾
echo
echo "  格式检查（线上实测踩过：add_header 被拼到同一行）"
chk "无单行多指令（add_header 拼接）" "^.*add_header.*add_header"     "$CONF" neg
chk "无指令紧跟闭合括号"              "add_header.*;[[:space:]]+\}"    "$CONF" neg
chk "无 proxy_ 指令紧跟闭合括号"      "proxy_[a-z_]+ .*;[[:space:]]+\}" "$CONF" neg
chk "无单行多 proxy_cache"           "^.*proxy_cache .*proxy_cache "  "$CONF" neg
# 每条 add_header 都要真的换行结尾
badhdr=$(awk '/add_header/{ if ($0 !~ /;[[:space:]]*$/) print NR": "$0 }' "$CONF")
if [[ -z $badhdr ]]; then echo "  PASS  add_header 均以 ; 换行结尾"; PASS=$((PASS+1))
else echo "  FAIL  add_header 行尾异常: $badhdr"; FAIL=$((FAIL+1)); fi

# --- 用例 C: 缓存关闭 + 连字符节点名
echo
echo "[C] edge-two 缓存关闭、连字符标识"
NAME=edge-two; DOMAIN=img.example.com
UPSTREAMS="10.0.0.9:9000"
UPSTREAM_SCHEME=https
PROXY_HOST=origin.example.com
CACHE_ENABLE=0; CACHE_TTL=1h; CACHE_SIZE=1g; CACHE_MEM=50m
CLIENT_MAX_BODY=10m; TLS_MODE=acme
save_node edge-two
render_global_conf
rm -f "$CERT_DIR/edge-two" -r
gen_node_conf edge-two >/dev/null
C2=$NGINX_CONF_D/selfcdn-edge-two.conf

chk "连字符转下划线做 nginx id"    "^upstream edge_two_up \{"      "$C2"
chk "请求变量用 edge_two_up"       "proxy_pass https://edge_two_up;" "$C2"
chk "缓存关闭时不写 proxy_cache"   "^ *proxy_cache cdn"            "$C2" neg
chk "回源 https 协议"             "proxy_pass https://"           "$C2"
chk "自定义 Host 头"              "Host              origin\.example\.com" "$C2"
chk "服务器名"                    "server_name img\.example\.com" "$C2"
chk "无未替换占位符"              "@[A-Z_]+@"                     "$C2" neg
chk "注销的 zone 不存在"          "keys_zone=cdn_edge_two"        "$NGINX_CONF_D/00-selfcdn-global.conf" neg

# --- 用例 D: 节点登记文件可再次 source
echo
echo "[D] 节点登记文件往返一致性"
load_node edge1
chk "UPSTREAMS 双值还原"           "1\.2\.3\.4:8080 5\.6\.7\.8:80" <(printf '%s\n' "$UPSTREAMS") || true
echo "    NAME=$NAME DOMAIN=$DOMAIN UPSTREAMS=$UPSTREAMS SCHEME=$UPSTREAM_SCHEME HOST=$PROXY_HOST CACHE=$CACHE_ENABLE"
[[ $UPSTREAMS == "1.2.3.4:8080 5.6.7.8:80" ]] && { echo "  PASS  UPSTREAMS 往返完整"; PASS=$((PASS+1)); } \
  || { echo "  FAIL  UPSTREAMS 往返: [$UPSTREAMS]"; FAIL=$((FAIL+1)); }
[[ $DOMAIN == static.example.com ]] && { echo "  PASS  DOMAIN 往返完整"; PASS=$((PASS+1)); } \
  || { echo "  FAIL  DOMAIN 往返: [$DOMAIN]"; FAIL=$((FAIL+1)); }
[[ $PROXY_HOST == '$host' ]] && { echo "  PASS  PROXY_HOST 变量转义保住"; PASS=$((PASS+1)); } \
  || { echo "  FAIL  PROXY_HOST 往返: [$PROXY_HOST]"; FAIL=$((FAIL+1)); }

echo

# --- 用例 E: 全局片段重建（线上踩过：启动即冲掉 cache zone → nginx -t 挂）
echo
# --- 用例 E: 全局片段重建（线上踩过：启动即冲掉 cache zone → nginx -t 挂）
echo
echo "[E] 全局片段重建不丢 zone、不重复"
assert() {  # assert "描述" 命令...
  local d=$1; shift
  if "$@" >/dev/null 2>&1; then echo "  PASS  $d"; PASS=$((PASS+1))
  else echo "  FAIL  $d"; FAIL=$((FAIL+1)); fi
}
render_global_conf
c1=$(grep -c 'proxy_cache_path' "$GLOBAL_CONF" 2>/dev/null || true)
render_global_conf
c2=$(grep -c 'proxy_cache_path' "$GLOBAL_CONF" 2>/dev/null || true)
c1=${c1:-0}; c2=${c2:-0}
assert "重复重建 zone 数稳定"           test "$c1" = "$c2"
assert "缓存开启节点有且仅有 1 个 zone"  test "$c2" -eq 1
assert "缓存关闭节点不产生 zone"         bash -c "! grep -q 'keys_zone=cdn_edge_two' '$GLOBAL_CONF'"
assert "map 仍在（未被 zone 覆盖）"      grep -q 'connection_upgrade' "$GLOBAL_CONF"
assert "upstream map 存在"              grep -q 'default upgrade' "$GLOBAL_CONF"
n_def=$(grep -vE '^[[:space:]]*#' "$SRC" | grep -c 'proxy_cache_path' 2>/dev/null || true)
assert "脚本里只有一处 zone 生成点"      test "${n_def:-0}" -eq 1
# 启动路径（main）必须走同一个渲染函数，否则又会把 zone 冲掉
assert "main 用 render_global_conf"     bash -c "awk '/^main\\(\\)/,/^}/' '$SRC' | grep -q 'render_global_conf'"
assert "无用旧函数 write_global_conf 分叉" bash -c "! awk '/^write_global_conf\\(\\)/,/^}/' '$SRC' | grep -q 'proxy_cache_path'"


# --- 用例 F: 按序号选节点（pick_node）
echo
echo "[F] 节点选择改为按序号"
NODES_DIR=$TMP/fnodes
CERT_DIR=$TMP/fcerts
mkdir -p "$NODES_DIR" "$CERT_DIR"
mk_fnode() {
  printf 'NAME=%s\nDOMAIN=%s\nUPSTREAMS=%s\nUPSTREAM_SCHEME=http\nPROXY_HOST=\\$host\nCACHE_ENABLE=0\nCACHE_TTL=24h\nCACHE_SIZE=1g\nCACHE_MEM=10m\nCLIENT_MAX_BODY=1m\nTLS_MODE=acme\n' \
    "$1" "$2" "10.0.0.9:80" > "$NODES_DIR/$1.conf"
}
mk_fnode a1   a1.test
mk_fnode b2   b2.test
mk_fnode c3   c3.test

TABLE=$(render_node_table 2>&1)
printf '%s\n' "$TABLE" | grep -vE '^$' | sed 's/^/    /'
grep -q '^#  ' <<< "$TABLE" \
  && { echo "  PASS  表格有编号列"; PASS=$((PASS+1)); } \
  || { echo "  FAIL  表格无编号列"; FAIL=$((FAIL+1)); }
for nm in a1 b2 c3; do
  assert "表格列出 $nm" grep -qw "$nm" <<< "$TABLE"
done

t_pick() {  # t_pick <描述> <期望> <输入> [allow_all] <期望成功0/失败1>
  local desc=$1 want=$2 input=$3 allow=${4:-0} wantrc=${5:-0} rc
  PICKED_NODE=""
  pick_node "选" "$allow" <<< "$input" >/dev/null 2>&1
  rc=$?
  if [[ $rc -eq $wantrc && $PICKED_NODE == "$want" ]]; then
    echo "  PASS  $desc"; PASS=$((PASS+1))
  else
    echo "  FAIL  $desc  (rc=$rc want=$wantrc, got='$PICKED_NODE' want='$want')"; FAIL=$((FAIL+1))
  fi
}

t_pick "输 2 选到第 2 个"            "b2" "2"
t_pick "输 1 选到第 1 个"            "a1" "1"
t_pick "输 3 选到第 3 个"            "c3" "3"
t_pick "超范围后重输可用"            "b2" $'9\n2'
t_pick "非数字后重输可用"            "c3" $'abc\n3'
t_pick "空行后重输可用"              "a1" $'\n1'
t_pick "0 取消"                      ""   "0" 0 1
t_pick "EOF 退出"                    ""   ""  0 1
t_pick "all 关键字（允许时）"        "all" "all" 1
t_pick "all 关键字（不允许时被拒）"  "a1" $'all\n1' 0

echo
echo "  序号与标识对应关系（编号与节点名是两个东西，不能混）"
PICKED_NODE=""; pick_node "选" <<< "1" >/dev/null 2>&1
echo "    序号 1 -> '$PICKED_NODE'（节点标识，不是序号）"
assert "序号1 解析成节点标识 a1"        test "$PICKED_NODE" = "a1"
assert "pick_node 结果走全局变量而非 stdout" bash -c "! grep -q 'PICKED_NODE=\$(pick_node' '$SRC'"
# 各"选节点"的函数都必须走 pick_node（add_node 里问的是新节点取名，不算）
for fn in del_node issue_one purge_cache show_node show_logs; do
  assert "$fn 用 pick_node 选节点" bash -c "awk '/^$fn\\(\\)/,/^}/' '$SRC' | grep -q 'pick_node'"
done
assert "选节点处不再 read 节点标识" bash -c "! grep -qE 'read -rp .节点标识(（all[^）]*）)?: ' '$SRC'"

# 复原
NODES_DIR=$TMP/n
CERT_DIR=$TMP/c


echo "==================== 结果: PASS=$PASS  FAIL=$FAIL ===================="
rm -rf "$TMP"
[[ $FAIL -eq 0 ]] || exit 1