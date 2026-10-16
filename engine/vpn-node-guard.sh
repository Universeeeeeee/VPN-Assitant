#!/usr/bin/env bash
# =============================================================================
# vpn-node-guard.sh                              (v3)
#
# 体检 ChatGPT 专线节点, 判断当前节点是否健康。
#
# v3 变化 (重要):
#   * 默认行为改为「只报告, 绝不自动切换」。探测请求是未认证的, 不涉及
#     账号 Cookie/Token, 也不改动你正在使用的出口 IP, 因此零账号风险。
#   * 新增 --json 模式, 输出结构化报告供菜单栏 App 消费。
#   * 健康判定从"只看探活成功率"升级为三个维度:
#       1) 连通性    -- 能否访问 chatgpt.com
#       2) 出口 IP   -- 是否发生轮换 (cf_clearance 绑定 IP, 轮换=必挂)
#       3) 稳定性    -- 连续多少次不健康 (去抖, 避免误报)
#   * 想恢复自动切换: 显式加 --switch (仍保留冷却/会话保护刹车)。
#
# 用法:
#   vpn-node-guard.sh              人类可读的体检报告 (默认, 不切换)
#   vpn-node-guard.sh --json       输出 JSON 报告 (供 App 使用, 不切换)
#   vpn-node-guard.sh --status     逐个列出组内所有节点
#   vpn-node-guard.sh --switch     评估并在故障时真正切换节点
#   vpn-node-guard.sh --help       帮助
# =============================================================================

set -uo pipefail
export LC_ALL=C

HAVE_JQ=0
command -v jq >/dev/null 2>&1 && HAVE_JQ=1

# ------------------------------- 配置 --------------------------------------
GROUP="${CNG_GROUP:-ChatGPT}"
PROBE_URL="${CNG_PROBE_URL:-https://chatgpt.com/cdn-cgi/trace}"
PROBES="${CNG_PROBES:-4}"                         # 每个节点探测次数
PROBE_TIMEOUT_MS="${CNG_TIMEOUT_MS:-10000}"
PROBE_GAP_S="${CNG_PROBE_GAP_S:-1}"               # 探测间隔; 太小会推高节点延迟造成误判
HEALTHY_OK="${CNG_HEALTHY_OK:-3}"                 # 达到几次成功算连通性达标
ALERT_STREAK="${CNG_ALERT_STREAK:-2}"             # 连续几次"不稳定"才提醒 (去抖)
DOWN_ALERT_IMMEDIATE="${CNG_DOWN_ALERT_IMMEDIATE:-1}"  # 完全不通时立即提醒
CONFIRM_RETRY="${CNG_CONFIRM_RETRY:-1}"               # 探活 0/N 时先复测确认, 避免瞬时抖动误报
CONFIRM_DELAY_S="${CNG_CONFIRM_DELAY_S:-10}"          # 复测前等待秒数
EXCLUDE_REGIONS="${CNG_EXCLUDE_REGIONS:-英国,香港}"    # 不建议切换到的地区 (逗号分隔, 按节点名前缀匹配)
COOLDOWN_H="${CNG_COOLDOWN_H:-12}"                # 仅 --switch 模式使用
EMERGENCY_H="${CNG_EMERGENCY_H:-1}"               # 仅 --switch 模式使用
ACTIVE_WINDOW_S="${CNG_ACTIVE_WINDOW_S:-300}"     # 仅 --switch 模式使用
MAX_DEFER="${CNG_MAX_DEFER:-3}"                   # 仅 --switch 模式使用
DEFER_ON_ACTIVE="${CNG_DEFER_ON_ACTIVE:-1}"       # 仅 --switch 模式使用
ACTIVE_PATTERN="${CNG_ACTIVE_PATTERN:-chatgpt|openai|oaistatic|oaiusercontent}"
MAX_CANDIDATES="${CNG_MAX_CANDIDATES:-6}"         # 报告里最多列几个候选
IP_HISTORY_MAX="${CNG_IP_HISTORY_MAX:-5}"         # 每个节点最多记几个历史出口 IP

STATE_DIR="${CNG_STATE_DIR:-$HOME/.local/state/chatgpt-node-guard}"
LOG_FILE="$STATE_DIR/guard.log"
STATE_FILE="$STATE_DIR/state"
IP_HIST_FILE="$STATE_DIR/ip-history"
LOG_MAX_LINES=3000
QUIET_STDOUT=0

MODE="report"
case "${1:-}" in
  --json)    MODE="json";   QUIET_STDOUT=1 ;;
  --status)  MODE="status" ;;
  --switch)  MODE="switch" ;;
  -h | --help)
    sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  "") MODE="report" ;;
  *) echo "未知参数: $1 (用 --help 查看用法)" >&2; exit 2 ;;
esac

mkdir -p "$STATE_DIR" 2>/dev/null

[ "$HEALTHY_OK" -gt "$PROBES" ] && HEALTHY_OK="$PROBES"

# ------------------------------- 工具函数 ----------------------------------

log() {
  local line n
  line="$(date '+%Y-%m-%d %H:%M:%S') [$1] $2"
  [ "$QUIET_STDOUT" = "1" ] || printf '%s\n' "$line"
  printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null
  n=$(wc -l <"$LOG_FILE" 2>/dev/null || echo 0)
  if [ "$n" -gt "$LOG_MAX_LINES" ]; then
    tail -n $((LOG_MAX_LINES / 2)) "$LOG_FILE" >"$LOG_FILE.tmp" 2>/dev/null &&
      mv "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null
  fi
}

urlenc() { printf '%s' "$1" | od -An -tx1 -v | tr -d ' \n' | sed 's/../%&/g'; }

# JSON 取值: 有 jq 用 jq, 否则退回 sed
jget() {
  if [ "$HAVE_JQ" = 1 ]; then
    jq -r ".[\"$1\"] // empty" 2>/dev/null
  else
    sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n1
  fi
}
jnum() {
  if [ "$HAVE_JQ" = 1 ]; then
    jq -r ".[\"$1\"] // empty" 2>/dev/null
  else
    sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" | head -n1
  fi
}

median() {
  sort -n | awk '
    {a[NR]=$1}
    END{
      if (NR==0) {print "-"; exit}
      if (NR%2)  {print a[(NR+1)/2]}
      else       {printf "%d\n", (a[NR/2]+a[NR/2+1])/2}
    }'
}

# 把 "a|b|c|d" 拆成 $S1..$S4。
# 注意: 不能用 `IFS='|' read ... <<EOF $(cmd) EOF` ——
# bash 会在临时 IFS 生效期间展开 heredoc 里的命令替换, 导致被调用的函数里
# `for i in $(seq ...)` 只迭代一次。这是踩过的坑, 别改回去。
split4() {
  local s="$1"
  S1="${s%%|*}"; s="${s#*|}"
  S2="${s%%|*}"; s="${s#*|}"
  S3="${s%%|*}"; s="${s#*|}"
  S4="$s"
}

jesc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# ------------------------------- 运行锁 ------------------------------------

LOCK_DIR="$STATE_DIR/lock"
LOCK_STALE_S=1800
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  LOCK_AGE=$(( $(date +%s) - $(stat -f %m "$LOCK_DIR" 2>/dev/null || echo 0) ))
  if [ "$LOCK_AGE" -gt "$LOCK_STALE_S" ]; then
    rmdir "$LOCK_DIR" 2>/dev/null
    mkdir "$LOCK_DIR" 2>/dev/null || { log SKIP "无法获取运行锁, 跳过本次"; exit 0; }
    log WARN "清理了陈旧的运行锁 (${LOCK_AGE}s)"
  else
    log SKIP "已有另一个实例正在运行 (锁存在 ${LOCK_AGE}s), 跳过本次"
    if [ "$MODE" = "json" ]; then
      printf '{"ok":false,"vpn":true,"state":"busy","alert":false,'
      printf '"message":"上一次检测仍在进行中","ts":"%s"}\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    fi
    exit 0
  fi
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT INT TERM

# --------------------------- mihomo 接口 -----------------------------------

find_socket() {
  local uid cand
  uid=$(id -u)
  for cand in \
    "/var/run/clash-verge-service/users/$uid/verge-mihomo.sock" \
    "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/verge-mihomo.sock" \
    "/tmp/verge-mihomo.sock"; do
    [ -S "$cand" ] && { printf '%s' "$cand"; return 0; }
  done
  for cand in /var/folders/*/*/T/verge-mihomo.sock; do
    [ -S "$cand" ] && { printf '%s' "$cand"; return 0; }
  done
  return 1
}

emit_no_vpn() {
  # 没开代理时的统一输出
  if [ "$MODE" = "json" ]; then
    printf '{"ok":false,"vpn":false,"state":"novpn","alert":false,'
    printf '"message":"Clash Verge / mihomo 未运行","ts":"%s"}\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  else
    printf 'Clash Verge / mihomo 未运行, 无需体检。\n'
  fi
  printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S') [SKIP] mihomo 未运行" >>"$LOG_FILE" 2>/dev/null
  exit 0
}

SOCKET="$(find_socket)" || SOCKET=""
[ -z "$SOCKET" ] && emit_no_vpn

api_get() { curl -sS --max-time 25 --unix-socket "$SOCKET" "http://localhost$1" 2>/dev/null; }
api_put() { curl -sS --max-time 25 --unix-socket "$SOCKET" -X PUT -H 'Content-Type: application/json' -d "$2" "http://localhost$1" 2>/dev/null; }

MIXED_PORT="$(api_get /configs | jnum mixed-port)"
[ -z "$MIXED_PORT" ] && MIXED_PORT=7897
PROXY_URL="http://127.0.0.1:$MIXED_PORT"

group_now() { api_get "/proxies/$(urlenc "$GROUP")" | jget now; }
node_type() { api_get "/proxies/$(urlenc "$1")" | jget type; }

group_members() {
  local raw
  raw="$(api_get "/proxies/$(urlenc "$GROUP")")"
  if [ "$HAVE_JQ" = 1 ]; then
    printf '%s' "$raw" | jq -r '.all[]?' 2>/dev/null
  else
    # 不能用 sed 's/.*"all":\[\(.*\)\].*/\1/p' —— 贪婪匹配会把 JSON 后面的
    # "dialer-proxy"/"history" 等字段一起吞进来。
    printf '%s' "$raw" | sed -n 's/.*"all":\[//p' | head -n1 | sed 's/\].*//' |
      tr ',' '\n' | sed 's/^"//; s/"$//' | grep -v '^$'
  fi
}

region_of() { printf '%s' "${1%%-*}"; }

# 某节点是否落在"不建议切换到"的地区里 (按区域前缀匹配, 例如 香港WAP 也算香港)
region_excluded() {
  local r="$1" e IFS=','
  [ -z "$EXCLUDE_REGIONS" ] && return 1
  for e in $EXCLUDE_REGIONS; do
    [ -z "$e" ] && continue
    case "$r" in "$e"*) return 0 ;; esac
  done
  return 1
}

is_group_ref() {
  case "$1" in
    Selector | URLTest | Fallback | LoadBalance | Relay | Direct | Reject) return 0 ;;
    *) return 1 ;;
  esac
}

# 探测一个节点: 输出 "成功数|总数|中位延迟|失败原因"
probe_node() {
  local name="$1" i d v ok=0 lats="" err="" med="-"
  for i in $(seq 1 "$PROBES"); do
    d=$(api_get "/proxies/$(urlenc "$name")/delay?url=$(urlenc "$PROBE_URL")&timeout=$PROBE_TIMEOUT_MS")
    v=$(printf '%s' "$d" | jnum delay)
    if [ -n "$v" ]; then
      ok=$((ok + 1))
      lats="$lats $v"
    else
      [ -z "$err" ] && err=$(printf '%s' "$d" | jget message)
      [ -z "$err" ] && err="无响应"
    fi
    [ "$i" -lt "$PROBES" ] && sleep "$PROBE_GAP_S"
  done
  [ -n "$lats" ] && med=$(printf '%s\n' $lats | median)
  printf '%s|%s|%s|%s' "$ok" "$PROBES" "$med" "$err"
}

# 当前节点在 Cloudflare 眼里看到的出口 IP (走正常链路, 不切换任何东西)
current_exit_ip() {
  curl -sS --max-time 12 -x "$PROXY_URL" "$PROBE_URL" 2>/dev/null |
    sed -n 's/^ip=//p' | head -n1
}

# --------------------------- 出口 IP 历史 ----------------------------------
# 记录每个节点曾经出现过的出口 IP。出现 2 个以上 = 已知会轮换 = ChatGPT 必挂。

ip_hist_get() { [ -f "$IP_HIST_FILE" ] && awk -F'\t' -v n="$1" '$1==n{print $2}' "$IP_HIST_FILE" | head -n1; }

ip_hist_add() {
  local node="$1" ip="$2" cur new tmp
  [ -z "$ip" ] && return
  [ -f "$IP_HIST_FILE" ] || : >"$IP_HIST_FILE"
  cur="$(ip_hist_get "$node")"
  case ",$cur," in
    *",$ip,"*) return ;;
  esac
  if [ -z "$cur" ]; then new="$ip"; else new="$cur,$ip"; fi
  # 只保留最近 IP_HISTORY_MAX 个
  new="$(printf '%s' "$new" | tr ',' '\n' | tail -n "$IP_HISTORY_MAX" | paste -sd, -)"
  tmp="$IP_HIST_FILE.tmp"
  awk -F'\t' -v n="$node" '$1!=n' "$IP_HIST_FILE" >"$tmp" 2>/dev/null
  printf '%s\t%s\n' "$node" "$new" >>"$tmp"
  mv "$tmp" "$IP_HIST_FILE"
}

ip_hist_count() {
  local v
  v="$(ip_hist_get "$1")"
  [ -z "$v" ] && { printf '0'; return; }
  printf '%s' "$v" | tr ',' '\n' | grep -c .
}

# ------------------------------- 状态 --------------------------------------

state_get() { [ -f "$STATE_FILE" ] && sed -n "s/^$1=//p" "$STATE_FILE" | head -n1; }
state_put() {
  local tmp="$STATE_FILE.tmp"
  : >"$tmp"
  [ -f "$STATE_FILE" ] && grep -v "^$1=" "$STATE_FILE" >>"$tmp" 2>/dev/null
  printf '%s=%s\n' "$1" "$2" >>"$tmp"
  mv "$tmp" "$STATE_FILE"
}

active_conns() {
  local now win
  now=$(date +%s); win="$ACTIVE_WINDOW_S"
  api_get /connections 2>/dev/null |
    sed 's/{"id":/\n{"id":/g' | grep -iE "$ACTIVE_PATTERN" |
    while IFS= read -r line; do
      st=$(printf '%s' "$line" | sed -n 's/.*"start":"\([^"]*\)".*/\1/p')
      [ -z "$st" ] && continue
      ep=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${st%%.*}" +%s 2>/dev/null)
      [ -z "$ep" ] && continue
      [ $((now - ep)) -le "$win" ] && echo x
    done | grep -c .
}

# ------------------------------- 主流程 ------------------------------------

CURRENT="$(group_now)"
if [ -z "$CURRENT" ]; then
  if [ "$MODE" = "json" ]; then
    printf '{"ok":false,"vpn":true,"state":"error","alert":false,'
    printf '"message":"找不到策略组 %s","ts":"%s"}\n' "$(jesc "$GROUP")" "$(date '+%Y-%m-%d %H:%M:%S')"
  else
    printf '找不到策略组 "%s"。\n' "$GROUP"
  fi
  exit 1
fi

CUR_TYPE="$(node_type "$CURRENT")"
if is_group_ref "$CUR_TYPE"; then
  INNER="$(api_get "/proxies/$(urlenc "$CURRENT")" | jget now)"
  [ -n "$INNER" ] && CURRENT="$INNER"
fi

TS="$(date '+%Y-%m-%d %H:%M:%S')"

# --status: 只列出所有节点
if [ "$MODE" = "status" ]; then
  printf '\n%-22s %-8s %-11s %s\n' "节点" "成功率" "中位延迟" "备注"
  printf -- '----------------------------------------------------------------------\n'
  for m in $(group_members); do
    if is_group_ref "$(node_type "$m")"; then
      printf '%-22s %-8s %-11s %s\n' "$m" "-" "-" "(分组引用)"
      continue
    fi
    split4 "$(probe_node "$m")"
    mark=""
    [ "$m" = "$CURRENT" ] && mark="<== 当前"
    [ "$S1" -eq 0 ] && mark="$mark 故障: ${S4:-未知}"
    printf '%-22s %-8s %-11s %s\n' "$m" "$S1/$S2" "${S3}ms" "$mark"
  done
  printf '\n日志: %s\n\n' "$LOG_FILE"
  exit 0
fi

# ---- 1) 体检当前节点 -------------------------------------------------------
split4 "$(probe_node "$CURRENT")"
CUR_OK="$S1"; CUR_TOT="$S2"; CUR_MED="$S3"; CUR_ERR="$S4"

# 0/N 先不要把话说死。这类 CDN 中转节点的延迟波动很大 (实测 2~6 秒),
# 一次拥塞就可能让几秒内连续 4 次探测全部超时, 而半分钟后自己就恢复了
# (2026-10-16 08:45 真实发生过: 0/4 报故障, 09:12 实测 6/6 正常)。
# 所以隔一会儿复测一次, 两轮都是 0 才判定"故障"。
TRANSIENT=0
if [ "$CUR_OK" -eq 0 ] && [ "$CONFIRM_RETRY" = "1" ]; then
  log WARN "首次探活 0/$CUR_TOT 全部失败, ${CONFIRM_DELAY_S} 秒后复测确认…"
  sleep "$CONFIRM_DELAY_S"
  split4 "$(probe_node "$CURRENT")"
  CUR_OK="$S1"; CUR_TOT="$S2"; CUR_MED="$S3"; CUR_ERR="$S4"
  if [ "$CUR_OK" -gt 0 ]; then
    TRANSIENT=1
    log OK "复测已恢复: $CUR_OK/$CUR_TOT 成功 —— 判定为瞬时抖动, 不按故障处理"
  else
    log FAIL "复测仍为 0/$CUR_TOT —— 确认为故障"
  fi
fi

# ---- 2) 采样出口 IP, 判断是否轮换 -----------------------------------------
CUR_IP="$(current_exit_ip)"
LAST_IP="$(state_get LAST_EXIT_IP)"
LAST_IP_NODE="$(state_get LAST_EXIT_IP_NODE)"
IP_CHANGED=0
if [ -n "$CUR_IP" ] && [ -n "$LAST_IP" ] && [ "$CUR_IP" != "$LAST_IP" ] && [ "$LAST_IP_NODE" = "$CURRENT" ]; then
  IP_CHANGED=1
fi
ip_hist_add "$CURRENT" "$CUR_IP"
CUR_IP_HIST_COUNT="$(ip_hist_count "$CURRENT")"

# ---- 3) 判定 ---------------------------------------------------------------
REASON=""
if [ "$CUR_OK" -eq 0 ]; then
  STATE="down"
  REASON="连续两轮探活全部失败 (0/$CUR_TOT)${CUR_ERR:+ ($CUR_ERR)}"
elif [ "$CUR_OK" -lt "$HEALTHY_OK" ]; then
  STATE="unstable"
  REASON="探活成功率不足: $CUR_OK/$CUR_TOT (需 ≥$HEALTHY_OK)"
elif [ "$IP_CHANGED" -eq 1 ]; then
  STATE="unstable"
  REASON="出口 IP 发生轮换: $LAST_IP -> $CUR_IP"
else
  STATE="healthy"
  REASON="连通性达标, 出口 IP 稳定"
fi

# 瞬时抖动: 首次全挂但复测已恢复。不算故障, 但把事实写进原因里, 便于回看。
if [ "$TRANSIENT" = "1" ]; then
  REASON="$REASON (${CONFIRM_DELAY_S} 秒前曾有一轮探活全失败, 复测已恢复)"
fi

if [ "$STATE" = "healthy" ]; then
  STREAK=0
else
  STREAK=$(( $(state_get UNHEALTHY_STREAK) + 0 + 1 ))
fi

ALERT=0
if [ "$STATE" = "down" ] && [ "$DOWN_ALERT_IMMEDIATE" = "1" ]; then
  ALERT=1
elif [ "$STATE" = "unstable" ] && [ "$STREAK" -ge "$ALERT_STREAK" ]; then
  ALERT=1
elif [ "$STATE" = "down" ] && [ "$STREAK" -ge "$ALERT_STREAK" ]; then
  ALERT=1
fi

# ---- 4) 不健康时体检候选 ---------------------------------------------------
CANDS=""
BEST_NAME=""; BEST_OK=""; BEST_TOT=""; BEST_MED=""; BEST_EXCLUDED=0
if [ "$STATE" != "healthy" ]; then
  CUR_REGION="$(region_of "$CURRENT")"
  : >"$STATE_DIR/candidates.tmp"
  for m in $(group_members); do
    [ "$m" = "$CURRENT" ] && continue
    is_group_ref "$(node_type "$m")" && continue
    split4 "$(probe_node "$m")"
    rot=0
    [ "$(ip_hist_count "$m")" -ge 2 ] && rot=1
    same=0
    [ "$(region_of "$m")" = "$CUR_REGION" ] && same=1
    excl=0
    region_excluded "$(region_of "$m")" && excl=1
    [ "$S3" = "-" ] && sortmed=999999 || sortmed=$S3
    # 排序: 已排除地区的最靠后, 其次已知出口轮换的, 再看成功率、同区域、延迟
    printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "$excl" "$rot" "$((S1 * 1000 / S2))" "$same" "$sortmed" "$m" "$S1" "$S2" \
      >>"$STATE_DIR/candidates.tmp"
  done
  sort -t'|' -k1,1n -k2,2n -k3,3nr -k4,4nr -k5,5n "$STATE_DIR/candidates.tmp" \
    >"$STATE_DIR/candidates.sorted" 2>/dev/null
  n=0
  FALLBACK_NAME=""; FALLBACK_OK=""; FALLBACK_TOT=""; FALLBACK_MED=""
  while IFS='|' read -r excl rot score same sortmed name ok tot; do
    n=$((n + 1))
    [ "$n" -gt "$MAX_CANDIDATES" ] && break
    med="$sortmed"; [ "$sortmed" = "999999" ] && med="-"
    CANDS="$CANDS$name|$ok|$tot|$med|$rot|$excl
"
    if [ "$rot" = "0" ] && [ "$ok" -ge "$HEALTHY_OK" ]; then
      if [ "$excl" = "0" ] && [ -z "$BEST_NAME" ]; then
        BEST_NAME="$name"; BEST_OK="$ok"; BEST_TOT="$tot"; BEST_MED="$med"
      elif [ -z "$FALLBACK_NAME" ]; then
        FALLBACK_NAME="$name"; FALLBACK_OK="$ok"; FALLBACK_TOT="$tot"; FALLBACK_MED="$med"
      fi
    fi
  done <"$STATE_DIR/candidates.sorted"
  # 合格候选全落在排除地区时, 仍给一个兜底建议, 但标明该地区已排除
  if [ -z "$BEST_NAME" ] && [ -n "$FALLBACK_NAME" ]; then
    BEST_NAME="$FALLBACK_NAME"; BEST_OK="$FALLBACK_OK"
    BEST_TOT="$FALLBACK_TOT"; BEST_MED="$FALLBACK_MED"; BEST_EXCLUDED=1
  fi
fi

# ---- 5) 落状态 -------------------------------------------------------------
state_put UNHEALTHY_STREAK "$STREAK"
[ -n "$CUR_IP" ] && state_put LAST_EXIT_IP "$CUR_IP"
[ -n "$CUR_IP" ] && state_put LAST_EXIT_IP_NODE "$CURRENT"
state_put LAST_CHECK_TS "$(date +%s)"
state_put LAST_STATE "$STATE"

# ---- 6) 输出 ---------------------------------------------------------------
log INFO "json 报告: state=$STATE alert=$ALERT streak=$STREAK transient=$TRANSIENT node=$CURRENT ok=$CUR_OK/$CUR_TOT ip=${CUR_IP:-未知}"
if [ "$MODE" = "json" ]; then
  printf '{'
  printf '"ok":true,"vpn":true,"ts":"%s","group":"%s",' "$(jesc "$TS")" "$(jesc "$GROUP")"
  printf '"state":"%s","alert":%s,"streak":%s,"transient":%s,"reason":"%s",' \
    "$STATE" "$([ "$ALERT" = 1 ] && echo true || echo false)" "$STREAK" \
    "$([ "$TRANSIENT" = 1 ] && echo true || echo false)" "$(jesc "$REASON")"
  printf '"current":{"name":"%s","ok":%s,"total":%s,"median":"%s","exit_ip":"%s","prev_ip":"%s","ip_changed":%s,"ip_history_count":%s,"error":"%s"},' \
    "$(jesc "$CURRENT")" "$CUR_OK" "$CUR_TOT" "$CUR_MED" "$(jesc "$CUR_IP")" "$(jesc "$LAST_IP")" \
    "$([ "$IP_CHANGED" = 1 ] && echo true || echo false)" "$CUR_IP_HIST_COUNT" "$(jesc "$CUR_ERR")"
  printf '"recommend":{"name":"%s","ok":"%s","total":"%s","median":"%s","excluded":%s},' \
    "$(jesc "$BEST_NAME")" "$BEST_OK" "$BEST_TOT" "$BEST_MED" \
    "$([ "$BEST_EXCLUDED" = "1" ] && echo true || echo false)"
  printf '"candidates":['
  first=1
  printf '%s' "$CANDS" | while IFS='|' read -r cn cok ctot cmed crot cexcl; do
    [ -z "$cn" ] && continue
    [ "$first" = 0 ] && printf ','
    first=0
    printf '{"name":"%s","ok":%s,"total":%s,"median":"%s","rotating":%s,"excluded":%s}' \
      "$(jesc "$cn")" "$cok" "$ctot" "$cmed" \
      "$([ "$crot" = "1" ] && echo true || echo false)" \
      "$([ "$cexcl" = "1" ] && echo true || echo false)"
  done
  printf ']}\n'
  exit 0
fi

# 人类可读报告
printf '\n════════ ChatGPT 节点体检 %s ════════\n' "$TS"
case "$STATE" in
  healthy)  printf '状态: ✅ 健康\n' ;;
  unstable) printf '状态: ⚠️  不稳定\n' ;;
  down)     printf '状态: ❌ 故障\n' ;;
esac
printf '当前节点: %s\n' "$CURRENT"
printf '原因:     %s\n' "$REASON"
printf '探活:     %s/%s 成功, 中位延迟 %sms\n' "$CUR_OK" "$CUR_TOT" "$CUR_MED"
printf '出口 IP:  %s (历史出现过 %s 个)\n' "${CUR_IP:-未知}" "$CUR_IP_HIST_COUNT"
if [ "$IP_CHANGED" = 1 ]; then
  printf '          ⚠️  上次是 %s, 已发生变化\n' "$LAST_IP"
fi
[ "$STREAK" -gt 0 ] && printf '连续不健康: %s 次 (达 %s 次提醒)\n' "$STREAK" "$ALERT_STREAK"
printf '是否提醒: %s\n' "$([ "$ALERT" = 1 ] && echo 是 || echo 否)"

if [ -n "$BEST_NAME" ]; then
  printf '\n建议切换到: %s (探活 %s/%s, 中位延迟 %sms)\n' "$BEST_NAME" "$BEST_OK" "$BEST_TOT" "$BEST_MED"
  if [ "$BEST_EXCLUDED" = "1" ]; then
    printf '            ⚠️  该节点所在地区在排除列表里 (%s), 仅作兜底 —— 其他合格候选都不可用\n' "$EXCLUDE_REGIONS"
  fi
elif [ "$STATE" != "healthy" ]; then
  printf '\n没有找到推荐的替代节点。\n'
fi

if [ -n "$CANDS" ]; then
  printf '\n候选节点 (已排除: %s):\n' "${EXCLUDE_REGIONS:-无}"
  printf '%s' "$CANDS" | while IFS='|' read -r cn cok ctot cmed crot cexcl; do
    [ -z "$cn" ] && continue
    r=""
    [ "$crot" = "1" ] && r="$r  (出口IP轮换)"
    [ "$cexcl" = "1" ] && r="$r  [已排除地区]"
    printf '  %-22s %s/%s  中位 %sms%s\n' "$cn" "$cok" "$ctot" "$cmed" "$r"
  done
fi

printf '\n提示: 本工具不会自动切换节点, 请在 Clash Verge 里手动切换。\n\n'

# ---- 7) --switch 模式: 显式请求才真正切换 ---------------------------------
if [ "$MODE" = "switch" ]; then
  if [ "$STATE" = "healthy" ]; then
    log OK "节点健康, 无需切换"
    exit 0
  fi
  if [ -z "$BEST_NAME" ]; then
    log FAIL "没有达标候选, 保持原节点 $CURRENT"
    exit 1
  fi
  NOW=$(date +%s)
  LAST_TS="$(state_get LAST_SWITCH_TS)"; LAST_TS="${LAST_TS:-0}"
  GAP_S=$((NOW - LAST_TS))
  if [ "$CUR_OK" -eq 0 ]; then MIN_GAP=$((EMERGENCY_H * 3600)); else MIN_GAP=$((COOLDOWN_H * 3600)); fi
  if [ "$GAP_S" -lt "$MIN_GAP" ]; then
    log SKIP "冷却中: 距上次切换 $((GAP_S / 60)) 分钟, 需 $((MIN_GAP / 60)) 分钟"
    exit 0
  fi
  if [ "$DEFER_ON_ACTIVE" = "1" ]; then
    AC="$(active_conns)"; AC="${AC:-0}"
    DEFER_N="$(state_get DEFER_COUNT)"; DEFER_N="${DEFER_N:-0}"
    if [ "$AC" -gt 0 ] && [ "$DEFER_N" -lt "$MAX_DEFER" ]; then
      state_put DEFER_COUNT $((DEFER_N + 1))
      log SKIP "最近 $((ACTIVE_WINDOW_S / 60)) 分钟内有 $AC 条活跃连接, 推迟切换"
      exit 0
    fi
  fi
  log OK "切换 $GROUP : $CURRENT -> $BEST_NAME"
  api_put "/proxies/$(urlenc "$GROUP")" "{\"name\":\"$BEST_NAME\"}" >/dev/null
  state_put LAST_SWITCH_TS "$NOW"
  state_put DEFER_COUNT 0
  NEW="$(group_now)"
  log INFO "切换后当前节点 = $NEW"
fi

exit 0
