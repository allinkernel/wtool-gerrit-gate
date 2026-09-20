#!/bin/sh
# lib.sh —— gerrit-gate 的公共部分（用户级工具，不属于任何项目）
#
# 两条设计约束，都是为了"任何 agent 在任何 repo 工作区里都能自己跑起来"：
#
#  1. **运行期状态全部放在工作区自己里面**（<ws>/.gerrit/：实例配置、密钥、
#     客户端配置）。跑在沙箱里的 agent 只能写自己的 workspace，写不了
#     $HOME；用户级目录里只放工具代码和规则，运行期一个字节都不写。
#  2. 不依赖任何项目自己的东西（不依赖 wtool、不依赖 tools/repo）：清单解析、
#     gerrit query 解析都自带一份（my_repo.py / gerrit_query.py）。
#
# 每个工作区一台自己的 Gerrit：容器 gerrit-<工作区名>、卷 gerrit-<工作区名>-*、
# 端口从 8080/29418 往上找第一对空闲的。已有的实例可以在
# <ws>/.gerrit/gate.conf 里覆盖（wtool 就沿用了当年手起的 docker24）。
set -eu

GATE_HOME=${GERRIT_GATE_HOME:-$HOME/.local/share/gerrit-gate}
GATE_IMAGE_DEFAULT=${GERRIT_GATE_IMAGE:-gerritcodereview/gerrit:3.14.3-ubuntu24}
GATE_WEB_BASE=${GERRIT_GATE_WEB_BASE:-8080}
GATE_SSH_BASE=${GERRIT_GATE_SSH_BASE:-29418}
GATE_REVIEWER_DEFAULT=${GERRIT_GATE_REVIEWER:-mindul}
GATE_AGENT_DEFAULT=${GERRIT_GATE_AGENT:-dsh-agent}
GATE_ADMIN=admin
GATE_VOLUME_PARTS="git etc db index cache"

gate_die ()  { printf 'gerrit-gate: %s\n' "$*" >&2; exit 1; }
gate_info () { printf '%s\n' "$*"; }
gate_warn () { printf 'gerrit-gate: %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# 工作区
# ---------------------------------------------------------------------------
gate_find_ws () {   # [起点] -> 往上找含 .repo 的目录
    gd_start=$(cd -- "${1:-$PWD}" 2>/dev/null && pwd) || return 1
    [ -d "$gd_start" ] || gd_start=$(dirname -- "$gd_start")
    gd=$gd_start
    while [ "$gd" != "/" ]; do
        [ -d "$gd/.repo" ] && { printf '%s\n' "$gd"; return 0; }
        gd=$(dirname -- "$gd")
    done
    return 1
}

gate_name_of () { basename -- "$1"; }

gate_state_dir ()   { printf '%s\n' "$1/.gerrit"; }
gate_conf_file ()   { printf '%s\n' "$1/.gerrit/gate.conf"; }
gate_keys_dir ()    { printf '%s\n' "$1/.gerrit/keys"; }
gate_client_file () { printf '%s\n' "$1/.gerrit/client.conf"; }
gate_logs_dir ()    { printf '%s\n' "$1/.gerrit/logs"; }

gate_conf_get () {   # <ws> <key> -> 值（没有就返回 1）
    gf=$(gate_conf_file "$1")
    [ -r "$gf" ] || return 1
    gv=$(sed -n "s/^$2=//p" "$gf" | head -1)
    [ -n "$gv" ] && printf '%s\n' "$gv"
}

# 加载实例：GATE_WS/NAME/CONTAINER/WEB/SSH/VOL/IMAGE/KEYS/REVIEWER/AGENT/SKIP
#   gate_load <ws>           只读（没有配置就返回 1）
#   gate_load <ws> --create  没有就分配端口/名字并写 <ws>/.gerrit/gate.conf
gate_load () {
    GATE_WS=$(cd -- "$1" && pwd)
    GATE_NAME=$(gate_name_of "$GATE_WS")
    GATE_CREATE=${2:-}

    GATE_CONTAINER=$(gate_conf_get "$GATE_WS" container || true)
    GATE_WEB=$(gate_conf_get "$GATE_WS" web_port || true)
    GATE_SSH=$(gate_conf_get "$GATE_WS" ssh_port || true)
    GATE_VOL=$(gate_conf_get "$GATE_WS" volumes || true)
    GATE_IMAGE_I=$(gate_conf_get "$GATE_WS" image || true)
    GATE_KEYS=$(gate_conf_get "$GATE_WS" keys_dir || true)
    GATE_REVIEWER=$(gate_conf_get "$GATE_WS" reviewer || true)
    GATE_AGENT=$(gate_conf_get "$GATE_WS" agent || true)
    GATE_SKIP=$(gate_conf_get "$GATE_WS" skip || true)

    if [ -z "$GATE_CONTAINER" ]; then
        [ "$GATE_CREATE" = --create ] || return 1
        GATE_CONTAINER=gerrit-$GATE_NAME
        GATE_VOL=gerrit-$GATE_NAME
        GATE_IMAGE_I=$GATE_IMAGE_DEFAULT
        gate_alloc_ports
        if [ "${GATE_DRY:-0}" = 1 ]; then
            # --dry-run 一个字节都不写：连实例配置也只是在内存里算出来
            gate_info "[dry] 实例会建成 $GATE_CONTAINER（网页 $GATE_WEB / ssh $GATE_SSH，卷 $GATE_VOL-*）"
        else
            gate_write_conf
        fi
    fi
    [ -n "$GATE_WEB" ] || GATE_WEB=$GATE_WEB_BASE
    [ -n "$GATE_SSH" ] || GATE_SSH=$GATE_SSH_BASE
    [ -n "$GATE_VOL" ] || GATE_VOL=gerrit-$GATE_NAME
    [ -n "$GATE_IMAGE_I" ] || GATE_IMAGE_I=$GATE_IMAGE_DEFAULT
    [ -n "$GATE_KEYS" ] || GATE_KEYS=$(gate_keys_dir "$GATE_WS")
    [ -n "$GATE_REVIEWER" ] || GATE_REVIEWER=$GATE_REVIEWER_DEFAULT
    [ -n "$GATE_AGENT" ] || GATE_AGENT=$GATE_AGENT_DEFAULT
    return 0
}

gate_write_conf () {
    mkdir -p "$(gate_state_dir "$GATE_WS")"
    cat > "$(gate_conf_file "$GATE_WS")" <<EOF
# gerrit-gate：这个工作区自己的 Gerrit 实例
# 由 gerrit-gate 生成，可以手改（改完再跑 gerrit-gate up）
#
# container  容器名（数据在卷里，容器删了不丢）
# web_port   网页端口，只绑 127.0.0.1
# ssh_port   ssh 端口（git push polygerrit 走它）
# volumes   卷名前缀：\$volumes-{git,etc,db,index,cache}
# image     镜像
# keys_dir  两把 ssh key 放哪（默认 <ws>/.gerrit/keys）
# reviewer  人（+2 的那个）的账号名
# agent     助手账号名（只能推 refs/for/*）
# skip      不导入 gerrit 的项目路径（空格分隔，比如上游镜像/浅克隆）
container=$GATE_CONTAINER
web_port=$GATE_WEB
ssh_port=$GATE_SSH
volumes=$GATE_VOL
image=$GATE_IMAGE_I
reviewer=$GATE_REVIEWER
agent=$GATE_AGENT
skip=$GATE_SKIP
EOF
}

# ---------------------------------------------------------------------------
# 端口
# ---------------------------------------------------------------------------
gate_port_busy () {   # <port>
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$" && return 0
    fi
    if command -v docker >/dev/null 2>&1; then
        docker ps --format '{{.Ports}}' 2>/dev/null | grep -q ":$1->" && return 0
    fi
    return 1
}

gate_alloc_ports () {
    gw=$GATE_WEB_BASE; gs=$GATE_SSH_BASE
    while [ "$gw" -le $((GATE_WEB_BASE + 400)) ]; do
        if ! gate_port_busy "$gw" && ! gate_port_busy "$gs"; then
            GATE_WEB=$gw; GATE_SSH=$gs
            return 0
        fi
        gw=$((gw + 1)); gs=$((gs + 1))
    done
    gate_die "从 $GATE_WEB_BASE/$GATE_SSH_BASE 往上找不到空闲端口对"
}

# ---------------------------------------------------------------------------
# docker
# ---------------------------------------------------------------------------
gate_require_docker () {
    command -v docker >/dev/null 2>&1 || gate_die "没装 docker"
    docker info >/dev/null 2>&1 || gate_die "docker 连不上（daemon 没跑？）"
}

gate_container_state () {   # <container>
    # 不能写 `docker inspect ... || echo absent`：容器不存在时它先往 stdout
    # 吐一个空行，拿到的是 "\nabsent"，case 匹配不上
    gst=$(docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null | head -1 | tr -d '[:space:]')
    if [ -n "$gst" ]; then printf '%s\n' "$gst"; else printf 'absent\n'; fi
}

gate_ensure_volumes () {
    for gp in $GATE_VOLUME_PARTS; do
        docker volume inspect "$GATE_VOL-$gp" >/dev/null 2>&1 ||
            docker volume create "$GATE_VOL-$gp" >/dev/null
    done
}

gate_wait_ready () {   # <web_port>
    gi=0
    while [ "$gi" -lt 90 ]; do
        curl -fsS -o /dev/null "http://127.0.0.1:$1/config/server/version" 2>/dev/null && return 0
        gi=$((gi + 1)); sleep 1
    done
    return 1
}

# ---------------------------------------------------------------------------
# gerrit ssh / rest
# ---------------------------------------------------------------------------
gate_admin_key () { printf '%s\n' "$GATE_KEYS/gerrit-admin_rsa"; }
gate_agent_key () { printf '%s\n' "$GATE_KEYS/$GATE_AGENT"'_rsa'; }

gate_admin_ssh () {
    ssh -i "$(gate_admin_key)" -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR \
        -o ConnectTimeout=10 -p "$GATE_SSH" "$GATE_ADMIN@127.0.0.1" "$@"
}

gate_agent_ssh () {
    ssh -i "$(gate_agent_key)" -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR \
        -o ConnectTimeout=10 -p "$GATE_SSH" "$GATE_AGENT@127.0.0.1" "$@"
}

gate_git_ssh_admin () {
    printf 'ssh -i %s -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -p %s' \
        "$(gate_admin_key)" "$GATE_SSH"
}

gate_web_url ()  { printf 'http://127.0.0.1:%s' "$GATE_WEB"; }
gate_login_url () { printf '%s/login/?user_name=%s' "$(gate_web_url)" "$GATE_REVIEWER"; }
gate_open_url ()  { printf '%s/q/status:open' "$(gate_web_url)"; }

# admin 的 http 密码文件（REST 改 ACL 用；也放在工作区里）
gate_admin_pw_file () { printf '%s\n' "$(gate_state_dir "$GATE_WS")/admin-http-password"; }

gate_admin_rest () {   # <method> <path> [json]
    gpw=$(cat "$(gate_admin_pw_file)")
    if [ $# -ge 3 ]; then
        curl -fsS -u "$GATE_ADMIN:$gpw" -X "$1" -H 'Content-Type: application/json' \
            --data-binary "$3" "$(gate_web_url)/a$2"
    else
        curl -fsS -u "$GATE_ADMIN:$gpw" -X "$1" "$(gate_web_url)/a$2"
    fi
}

# ---------------------------------------------------------------------------
# 清单
# ---------------------------------------------------------------------------
# path<TAB>name<TAB>branch<TAB>remote<TAB>url
gate_manifest_list () {
    python3 "$GATE_HOME/my_repo.py" list --root "$1"
}

gate_skip_reason () {   # <ws> <relpath> -> 打印原因并返回 0 / 返回 1
    for gs in $GATE_SKIP; do
        [ "$gs" = "$2" ] && { printf '%s\n' "在 gate.conf 的 skip 列表里"; return 0; }
    done
    return 1
}
