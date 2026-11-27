#!/bin/sh
# instabox-router-watchdog.sh — 放在路由器（OpenWrt/Padavan/Debian 都行）上的外部保活看门狗。
#
# 为什么放路由器：沙箱没法自己把自己叫醒。沙箱被平台暂停后，里面没有任何进程在跑，
# 谁去发 resume？只能是外面一台 24 小时不断电、又不在被暂停名单里的机器。路由器最合适。
#
# 它做三件事，每 10 分钟一趟（cron）：
#   1. 状态是 suspended → resume；stopped → start（撞上强制暂停的冷却就下一趟再来）
#   2. 状态是 running → exec 一条轻命令，刷平台认可的真实活跃，防 30 分钟闲置暂停
#   3. ROTATE_IDS 里的机器跑满 470 分钟 → 主动 suspend→resume，重置 8 小时强制停的计时
#      （本机自己不会轮换自己，它得靠这一步）
#
# 依赖：curl（OpenWrt 还要 opkg install ca-bundle 才有 HTTPS）、sed、date。
# 不需要 python、不需要 jq、不需要 bash。
#
# 装法（OpenWrt）：
#   scp instabox-router-watchdog.sh root@192.168.1.1:/root/
#   ssh root@192.168.1.1 'echo "ibk_你的key" > /etc/instabox.key; chmod 600 /etc/instabox.key'
#   ssh root@192.168.1.1 'chmod +x /root/instabox-router-watchdog.sh && /root/instabox-router-watchdog.sh'
#   看输出没问题，再挂 cron：
#   echo '*/10 * * * * /root/instabox-router-watchdog.sh >/dev/null 2>&1' >> /etc/crontabs/root
#   /etc/init.d/cron restart
#
# 手动跑一次看结果：/root/instabox-router-watchdog.sh
# 只救不防（不 exec）：EXEC=0 /root/instabox-router-watchdog.sh

set -u

# ---------- 配置 ----------
API="${API:-https://api.instabox.sh}"
KEYFILE="${KEYFILE:-/etc/instabox.key}"
KEY="${KEY:-$(cat "$KEYFILE" 2>/dev/null)}"

# 留空 = 自动拉整个账号的机器列表；也可以写死，空格分隔：
# MACHINES="m_agrb2fevhf7xy4urszvzk6uzqy m_xxxxxxxx"
MACHINES="${MACHINES:-}"

# 允许主动轮换的机器（通常就是跑保活 loop 的那台自己）。
# 不填 = 谁都不轮换，只做防睡 + 倒了再救。
ROTATE_IDS="${ROTATE_IDS:-}"

ROTATE_MIN="${ROTATE_MIN:-470}"       # 跑满多少分钟就轮换，免费档 480 是硬线
EXEC="${EXEC:-1}"                     # 1=每趟 exec 一次；0=只救不防
EXEC_CMD="${EXEC_CMD:-if [ -x /data/watchdog.sh ]; then sudo /data/watchdog.sh; else date; fi}"
TAG="instabox-keepalive"

# ---------- 小工具 ----------
log() { echo "$TAG: $*"; logger -t "$TAG" "$*" 2>/dev/null || true; }

have_curl() { command -v curl >/dev/null 2>&1; }

# 返回 body；HTTP 非 2xx 时 body 里带着平台给的错误信息
api() {
  _m="$1"; _p="$2"; _b="${3:-}"
  if [ -n "$_b" ]; then
    curl -sS --max-time 20 -X "$_m" \
      -H "X-API-Key: $KEY" -H 'Content-Type: application/json' \
      --data "$_b" "$API$_p" 2>&1
  else
    curl -sS --max-time 20 -X "$_m" \
      -H "X-API-Key: $KEY" "$API$_p" 2>&1
  fi
}

# 从 JSON 里抠一个字符串字段（够用就行，不做完整解析）
field() { sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1; }

# ISO8601 → epoch。GNU date 和 busybox date 各试一遍；都不行返回 0
iso2epoch() {
  [ -n "$1" ] || { echo 0; return; }
  date -u -d "$1" +%s 2>/dev/null && return
  date -u -D '%Y-%m-%dT%H:%M:%SZ' -d "$1" +%s 2>/dev/null && return
  echo 0
}

now() { date -u +%s; }

# 自动发现机器 id
discover() {
  api GET /v1/machines |
    tr ',{' '\n\n' |
    sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
    sort -u
}

in_list() { case " $1 " in *" $2 "*) return 0 ;; esac; return 1; }

# ---------- 主流程 ----------
[ -n "$KEY" ] || { log "没有 API key（$KEYFILE 或 KEY 环境变量）"; exit 1; }
case "$KEY" in ibk_*) ;; *) log "key 不像 ibk_ 开头，先检查 $KEYFILE"; exit 1 ;; esac
have_curl || { log "没有 curl"; exit 1; }

IDS="$MACHINES"
[ -z "$IDS" ] && IDS="$(discover)"
[ -n "$IDS" ] || { log "拿不到机器列表（key 无效或网络不通）"; exit 1; }

rc=0
for id in $IDS; do
  m="$(api GET "/v1/machines/$id")"
  state="$(printf '%s' "$m" | field state)"

  case "$state" in
    running)
      run0="$(printf '%s' "$m" | field runStartedAt)"
      age=$(( $(now) - $(iso2epoch "$run0") ))
      # 轮换：只有明确点名的机器才动，避免和沙箱里的 loop 抢
      if [ -n "$ROTATE_IDS" ] && in_list "$ROTATE_IDS" "$id" && [ "$age" -ge $((ROTATE_MIN * 60)) ]; then
        log "$id 跑满 $((age / 60)) 分钟，主动轮换"
        api POST "/v1/machines/$id/suspend" '{"timeoutSeconds":60}' >/dev/null
        i=0
        while [ $i -lt 20 ]; do
          sleep 2
          s="$(api GET "/v1/machines/$id" | field state)"
          [ "$s" = "suspended" ] && break
          i=$((i + 1))
        done
        api POST "/v1/machines/$id/resume" >/dev/null && log "$id 已 resume"
        continue
      fi
      if [ "$EXEC" = "1" ]; then
        body="$(printf '{"cmd":"%s","timeoutSeconds":120}' "$EXEC_CMD")"
        r="$(api POST "/v1/machines/$id/exec" "$body")"
        if printf '%s' "$r" | grep -q '"exitCode"[[:space:]]*:[[:space:]]*0'; then
          :
        else
          log "$id exec 异常: $(printf '%s' "$r" | cut -c1-200)"; rc=1
        fi
      fi
      ;;
    suspended)
      r="$(api POST "/v1/machines/$id/resume")"
      case "$r" in
        *'"error":{'*|*"HTTP"*) log "$id resume 失败（冷却中？）: $(printf '%s' "$r" | cut -c1-160)"; rc=1 ;;
        *) log "$id 已 resume" ;;
      esac
      ;;
    stopped)
      r="$(api POST "/v1/machines/$id/start")"
      case "$r" in
        *'"error":{'*|*"HTTP"*) log "$id start 失败: $(printf '%s' "$r" | cut -c1-160)"; rc=1 ;;
        *) log "$id 已 start" ;;
      esac
      ;;
    "")
      log "$id 读不到状态: $(printf '%s' "$m" | cut -c1-160)"; rc=1
      ;;
    creating|starting|stopping|suspending|resuming|deleting)
      # 过渡态，下一趟再看
      ;;
    *)
      log "$id 状态 $state，不自动处理"; rc=1
      ;;
  esac
done

exit $rc
