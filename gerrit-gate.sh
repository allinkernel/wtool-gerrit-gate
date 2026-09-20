#!/bin/sh
# gerrit-gate —— 给任意 repo 工作区装一道"检视闸门"（本机 Gerrit，web UI 就是 PolyGerrit）
#
# 用法见 usage()。这里只写实现，设计说明在 README.md。
#
# 一句话：改动先进本机 Gerrit（refs/for/main），人 +2 并 submit 之后
# 才允许推回 GitHub；每个工作区一台自己的 Gerrit，状态全在 <ws>/.gerrit/。
set -eu

self=$0
[ -L "$self" ] && self=$(readlink -f "$self")
here=$(cd -- "$(dirname -- "$self")" && pwd)
# 工具根目录：主题、插件、python 小工具都相对它找（原来默认指向
# ~/.local/share/gerrit-gate，独立成项目之后就是项目自己）
GERRIT_GATE_HOME=${GERRIT_GATE_HOME:-$here}
export GERRIT_GATE_HOME
. "$here/lib.sh"

# ---------------------------------------------------------------------------
# 参数
# ---------------------------------------------------------------------------
DRY=0
WS_ARG=
CHECKOUT=1
RECREATE=0
THEME_NAME=

usage () {
    cat <<'EOF'
gerrit-gate —— 给 repo 工作区装一道检视闸门（本机 Gerrit，web UI 就是 PolyGerrit）

  gerrit-gate all   [工作区]      一次装好：up + bootstrap + import + setup（幂等）
  gerrit-gate up    [工作区]      起/建 Gerrit 容器（挂载该工作区，只绑 127.0.0.1）
                                  加 --recreate 删了重建（数据在卷里，不丢）
  gerrit-gate bootstrap [工作区]  建账号、发密钥、配权限（幂等）
  gerrit-gate import [工作区]     每个仓库建 Gerrit 项目 + 导入 main（幂等）
  gerrit-gate setup [工作区]      每个仓库加 polygerrit remote + ds_dev + commit-msg hook
  gerrit-gate theme [工作区] [主题]  换 UI 主题（不带主题名 = 列出可选的）
  gerrit-gate status [工作区]     体检：容器/账号/项目/接线，并打印给用户的链接
  gerrit-gate open  [工作区]      只打印登录链接 / 待检视链接
  gerrit-gate list                列出 ~/self/* 下装了闸门的工作区
  gerrit-gate help

工作区默认从当前目录往上找 .repo。任何子命令都可以加 --dry-run 先看要做啥。

日常约定：
  * 改动写在各仓库的 ds_dev 分支上
  * 送检：git push polygerrit HEAD:refs/for/main（输出里就有 change 链接）
  * gchk <change> 返回 0（人已 +2 且已 merged）之后，才把 Gerrit 的 main 推回 GitHub
  * 一切状态都在 <工作区>/.gerrit/ 里；每个工作区一台自己的 Gerrit
EOF
}

parse_args () {
    for a in "$@"; do
        case $a in
            --dry-run) DRY=1 ;;
            --no-checkout) CHECKOUT=0 ;;
            --recreate) RECREATE=1 ;;
            -h|--help) usage; exit 0 ;;
            -*) gate_die "不认识的参数: $a" ;;
            *) WS_ARG=$a ;;
        esac
    done
}

resolve_ws () {
    if [ -n "$WS_ARG" ]; then
        GATE_WS=$(gate_find_ws "$WS_ARG") ||
            gate_die "$WS_ARG 往上找不到 .repo（不是 repo 工作区）"
    else
        GATE_WS=$(gate_find_ws "$PWD") ||
            gate_die "当前目录往上找不到 .repo；用法: gerrit-gate <命令> [工作区]"
    fi
}

# ---------------------------------------------------------------------------
# 1. up：起容器
# ---------------------------------------------------------------------------
cmd_up () {
    gate_require_docker
    if [ "$DRY" = 1 ]; then
        gate_info "[dry] 工作区 $GATE_WS"
        gate_info "[dry] 容器 $GATE_CONTAINER（$GATE_IMAGE_I） 网页 $GATE_WEB ssh $GATE_SSH"
        gate_info "[dry] 卷 $(for p in $GATE_VOLUME_PARTS; do printf '%s-%s ' "$GATE_VOL" "$p"; done)"
        return 0
    fi
    gate_ensure_volumes
    if [ "$RECREATE" = 1 ] && [ "$(gate_container_state "$GATE_CONTAINER")" != absent ]; then
        gate_info "==> 删掉旧容器 $GATE_CONTAINER 重建（数据都在卷里，不丢）"
        docker rm -f "$GATE_CONTAINER" >/dev/null
    fi
    case $(gate_container_state "$GATE_CONTAINER") in
        running)
            gate_info "==> $GATE_CONTAINER 已经在跑" ;;
        exited|created|paused)
            gate_info "==> 启动已存在的容器 $GATE_CONTAINER"
            docker start "$GATE_CONTAINER" >/dev/null ;;
        absent)
            gate_info "==> 创建容器 $GATE_CONTAINER（$GATE_IMAGE_I）"
            set --
            for gp in $GATE_VOLUME_PARTS; do
                set -- "$@" -v "$GATE_VOL-$gp:/var/gerrit/$gp"
            done
            docker run -d --name "$GATE_CONTAINER" \
                --restart unless-stopped \
                --label "gerrit-gate.workspace=$GATE_WS" \
                -p "127.0.0.1:$GATE_WEB:8080" \
                -p "127.0.0.1:$GATE_SSH:29418" \
                "$@" \
                -v "$GATE_WS:/workspace:ro" \
                -e "CANONICAL_WEB_URL=$(gate_web_url)/" \
                -e "HTTPD_LISTEN_URL=http://0.0.0.0:8080/" \
                "$GATE_IMAGE_I" >/dev/null ;;
        *) gate_die "$GATE_CONTAINER 状态是 $(gate_container_state "$GATE_CONTAINER")，不认识了" ;;
    esac
    if gate_wait_ready "$GATE_WEB"; then
        gate_info "==> gerrit 就绪：$(gate_web_url)/"
    else
        gate_die "等了 90 秒没起来：docker logs $GATE_CONTAINER"
    fi
}

# ---------------------------------------------------------------------------
# 2. bootstrap：账号 / 权限 / 密钥
# ---------------------------------------------------------------------------
gate_admin_ssh_works () { gate_admin_ssh gerrit version >/dev/null 2>&1; }

gate_ensure_key () {   # <私钥路径> <注释>
    [ -f "$1" ] && return 0
    [ "$DRY" = 1 ] && { gate_info "[dry] 生成 $1"; return 1; }
    ssh-keygen -t rsa -b 3072 -N '' -C "$2" -f "$1" >/dev/null
    gate_info "==> 生成 $1"
}

account_exists () {   # <username>
    gpw=$(cat "$(gate_admin_pw_file)" 2>/dev/null || true)
    [ -n "$gpw" ] || return 1
    gcode=$(curl -s -o /dev/null -w '%{http_code}' -u "$GATE_ADMIN:$gpw" \
        "$(gate_web_url)/a/accounts/$1")
    [ "$gcode" = 200 ]
}

cmd_bootstrap () {
    gate_require_docker
    [ "$DRY" = 1 ] || { cmd_up; }
    if [ "$DRY" = 1 ]; then
        gate_info "[dry] 密钥目录 $GATE_KEYS（会生成 gerrit-admin_rsa / ${GATE_AGENT}_rsa）"
    else
        mkdir -p "$GATE_KEYS"
        chmod 700 "$GATE_KEYS" 2>/dev/null || true
    fi

    gate_ensure_key "$(gate_admin_key)" "gerrit-admin@$GATE_NAME" || true
    gate_ensure_key "$(gate_agent_key)" "$GATE_AGENT@$GATE_NAME" || true

    # --- admin 的 ssh key：只能停机直接写 NoteDb（gerrit 没有"没登录先注册 key"的通道）
    if [ "$DRY" = 1 ]; then
        gate_info "[dry] 需要的话，停机往 All-Users.git 的 refs/users 写 admin 的 authorized_keys"
    elif gate_admin_ssh_works; then
        gate_info "==> admin 的 ssh key 已经就位"
    else
        gate_info "==> 停机写 NoteDb：给第一个账号登记 ssh key"
        docker stop "$GATE_CONTAINER" >/dev/null
        docker run --rm -u 0 \
            -v "$GATE_VOL-git:/git" -v "$GATE_KEYS:/keys:ro" \
            --entrypoint sh "$GATE_IMAGE_I" -c '
set -eu
export HOME=/tmp
printf "[safe]\n\tdirectory = *\n" > /tmp/gitconfig
export GIT_CONFIG_GLOBAL=/tmp/gitconfig
export GIT_AUTHOR_NAME="Gerrit Bootstrap" GIT_AUTHOR_EMAIL="admin@example.com"
export GIT_COMMITTER_NAME="Gerrit Bootstrap" GIT_COMMITTER_EMAIL="admin@example.com"
cd /git/All-Users.git
# 第一个（id 最小）的账号就是 init 建的管理员；别自己拼 shard 目录
ref=$(git for-each-ref --format="%(refname)" refs/users/ | sort -t/ -k4,4n | head -1)
[ -n "$ref" ] || { echo "All-Users 里没有账号" >&2; exit 1; }
echo "  目标账号 ref: $ref"
export GIT_INDEX_FILE=/tmp/idx
git read-tree "$ref"
rm -f /tmp/ak
git cat-file -p "$ref:authorized_keys" > /tmp/ak 2>/dev/null || true
cat /keys/gerrit-admin_rsa.pub >> /tmp/ak
blob=$(git hash-object -w /tmp/ak)
git update-index --add --cacheinfo 100644,$blob,authorized_keys
tree=$(git write-tree)
commit=$(git commit-tree "$tree" -p "$(git rev-parse "$ref")" -m "Add SSH key for the initial admin user")
git update-ref "$ref" "$commit"
'
        docker start "$GATE_CONTAINER" >/dev/null
        gate_wait_ready "$GATE_WEB" || gate_die "重启后没起来"
        gate_admin_ssh_works || gate_die "key 写完了但 ssh 还是不通，看 docker logs $GATE_CONTAINER"
        gate_info "==> admin 的 ssh 通了"
    fi

    # --- admin 的 http 密码（REST 改 ACL 用）
    if [ ! -f "$(gate_admin_pw_file)" ]; then
        if [ "$DRY" = 1 ]; then
            gate_info "[dry] 给 admin 设 http 密码（存 $(gate_admin_pw_file)）"
        else
            gpw=$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 24)
            gate_admin_ssh gerrit set-account "$GATE_ADMIN" --http-password "$gpw" >/dev/null
            printf '%s\n' "$gpw" > "$(gate_admin_pw_file)"
            chmod 600 "$(gate_admin_pw_file)"
            gate_info "==> 给 admin 设了 http 密码"
        fi
    fi

    if [ "$DRY" = 1 ]; then
        gate_info "[dry] 建账号 $GATE_REVIEWER（进 Administrators，能 +2）和 $GATE_AGENT（只能推 refs/for/*）"
        gate_info "[dry] 改 All-Projects ACL：refs/heads/* 上 push=Administrators、submit=Registered Users"
        return 0
    fi

    # --- 人（+2 的那位）
    if account_exists "$GATE_REVIEWER"; then
        gate_info "==> 账号 $GATE_REVIEWER 已存在"
    else
        gate_admin_ssh gerrit create-account "$GATE_REVIEWER" \
            --full-name "$GATE_REVIEWER" --email "$GATE_REVIEWER@example.com" >/dev/null
        gate_info "==> 建了账号 $GATE_REVIEWER"
    fi
    gate_admin_ssh gerrit set-members --add "$GATE_REVIEWER" Administrators >/dev/null

    # --- 助手
    if account_exists "$GATE_AGENT"; then
        gate_info "==> 账号 $GATE_AGENT 已存在"
    else
        cat "$(gate_agent_key).pub" | gate_admin_ssh gerrit create-account "$GATE_AGENT" \
            --full-name "$GATE_AGENT" --email "$GATE_AGENT@example.com" --ssh-key - >/dev/null
        gate_info "==> 建了账号 $GATE_AGENT"
    fi
    # 提交的 author/committer 用的是仓库里的 git 身份，得登记到 agent 名下，
    # 否则 gerrit 以 "email not registered" 拒收。全局身份 + 工作区里各个
    # 仓库自己配的身份，都登记一遍。
    gemail=$(git config --global user.email 2>/dev/null || true)
    if [ -n "$gemail" ]; then
        gate_admin_ssh gerrit set-account "$GATE_AGENT" --add-email "$gemail" >/dev/null 2>&1 || true
        gate_info "==> $GATE_AGENT 名下登记了 $gemail（全局 git 身份）"
    fi
    gwork=$(mktemp -d "${TMPDIR:-/tmp}/gerrit-gate.XXXXXX")
    gate_manifest_list "$GATE_WS" > "$gwork/m.tsv" 2>/dev/null || : > "$gwork/m.tsv"
    while IFS="$(printf '\t')" read -r rpath rname rbr rremote rurl <&3; do
        [ -n "${rpath:-}" ] || continue
        [ -d "$GATE_WS/$rpath/.git" ] || continue
        remail=$(git -C "$GATE_WS/$rpath" config --get user.email 2>/dev/null || true)
        [ -n "$remail" ] || continue
        [ "$remail" = "$gemail" ] && continue
        gate_admin_ssh gerrit set-account "$GATE_AGENT" --add-email "$remail" >/dev/null 2>&1 || true
        gate_info "==> $GATE_AGENT 名下登记了 $remail（$rpath 自己的 git 身份）"
    done 3< "$gwork/m.tsv"
    rm -rf -- "$gwork"

    # --- ACL：闸门本体是 Code-Review +2 这个 submit-requirement
    gate_admin_rest POST /projects/All-Projects/access '{
  "add": {
    "refs/heads/*": {
      "permissions": {
        "push":   { "rules": { "Administrators":         { "action": "ALLOW" } } },
        "submit": { "rules": { "global:Registered-Users": { "action": "ALLOW" } } }
      }
    }
  }
}' >/dev/null
    gate_info "==> ACL 就位（push=Administrators、submit=Registered Users）"
}

# ---------------------------------------------------------------------------
# 3. import：建项目 + 导入 main
# ---------------------------------------------------------------------------
cmd_import () {
    gate_require_docker
    [ "$DRY" = 1 ] || gate_wait_ready "$GATE_WEB" || gate_die "gerrit 没起来，先 gerrit-gate up"
    work=$(mktemp -d "${TMPDIR:-/tmp}/gerrit-gate.XXXXXX")
    trap 'rm -rf -- "$work"' EXIT INT TERM
    failed=0

    if [ "$DRY" = 0 ]; then
        gate_admin_ssh gerrit ls-projects </dev/null > "$work/projects" ||
            gate_die "拿不到项目列表（admin ssh 通吗？先 gerrit-gate bootstrap）"
    else
        : > "$work/projects"
    fi
    has_project () { grep -qx "$1" "$work/projects"; }
    has_branch () {   # <project> <branch>
        [ -f "$work/branches.$2" ] || \
            gate_admin_ssh gerrit ls-projects --show-branch "$2" </dev/null |
            awk '{print $2}' > "$work/branches.$2"
        grep -qx "$1" "$work/branches.$2"
    }

    import_one () {   # <pushdir> <project> <branch> <label>
        ip_dir=$1; ip_proj=$2; ip_br=$3; ip_label=$4
        if has_project "$ip_proj"; then
            :
        elif [ "$DRY" = 1 ]; then
            gate_info "[dry] create-project $ip_proj"
        else
            gate_info "==> create-project $ip_proj"
            gate_admin_ssh gerrit create-project --parent All-Projects \
                --owner Administrators --description "'$GATE_NAME: $ip_label'" "$ip_proj" >/dev/null
            printf '%s\n' "$ip_proj" >> "$work/projects"
        fi
        if has_branch "$ip_proj" "$ip_br"; then
            gate_info "跳过 $ip_label（$ip_proj/$ip_br 已导入）"
            return 0
        fi
        ip_head=$(git -C "$ip_dir" rev-parse HEAD)
        if [ "$DRY" = 1 ]; then
            gate_info "[dry] $ip_label: push $ip_head -> $ip_proj refs/heads/$ip_br"
            return 0
        fi
        gate_info "==> 导入 $ip_label（$ip_head -> $ip_proj/$ip_br）"
        ip_log="$work/push.log"
        if GIT_SSH_COMMAND=$(gate_git_ssh_admin) \
            git -C "$ip_dir" push "ssh://$GATE_ADMIN@127.0.0.1:$GATE_SSH/$ip_proj.git" \
            "HEAD:refs/heads/$ip_br" > "$ip_log" 2>&1; then
            tail -2 "$ip_log"
            return 0
        fi
        cat "$ip_log"
        gate_warn "!! $ip_label 推送失败"
        failed=$((failed + 1))
        return 0
    }

    # --- 清单仓（不在自己的清单里）---
    #
    # 这里比"项目"麻烦：当前分支可能是 ds_dev（没有 upstream），而 GitHub 上
    # 那个仓的分支名是 wtool/wblog/... —— 所以分支名按下面的顺序找，别只看 @{u}
    # （踩过：退回 main，然后 temp clone 报 "Remote branch main not found"）。
    manifests="$GATE_WS/.repo/manifests"
    if [ -d "$manifests/.git" ]; then
        mname=$(git -C "$manifests" remote get-url origin 2>/dev/null | sed -e 's#.*/##' -e 's#\.git$##')
        [ -n "$mname" ] || mname=$GATE_NAME-manifests
        murl=$(git -C "$manifests" remote get-url origin 2>/dev/null || true)
        hurl=$(printf '%s' "$murl" | sed -e 's#^ssh://git@github.com/#https://github.com/#' \
                                           -e 's#^git@github.com:#https://github.com/#')
        # 1) repo 自己记的（manifest 项目那条 branch.<默认分支>.merge）
        mbranch=$(git -C "$manifests" config --get branch.default.merge 2>/dev/null |
                  sed -e 's#^refs/heads/##')
        # 2) 当前分支的 upstream；3) 兜底 main
        [ -n "$mbranch" ] || mbranch=$(git -C "$manifests" rev-parse --abbrev-ref --symbolic-full-name \
                                       '@{u}' 2>/dev/null | sed -e 's#^[^/]*/##')
        [ -n "$mbranch" ] || mbranch=main

        if has_project "allinkernel/$mname" 2>/dev/null || true; then :; fi
        if [ "$DRY" = 0 ] && has_branch "$mname" main 2>/dev/null; then
            gate_info "跳过 清单仓（$mname/main 已导入），本地怎么浅都不管了"
        else
            if [ "$(git -C "$manifests" rev-parse --is-shallow-repository)" = true ]; then
                if [ "$DRY" = 1 ]; then
                    gate_info "[dry] 清单仓是浅克隆：先补历史，补不全就临时克隆一份来推"
                else
                    gate_info "==> 清单仓是浅克隆，先补历史（push 不允许从浅克隆发）"
                    git -C "$manifests" fetch --unshallow >/dev/null 2>&1 || true
                    if [ "$(git -C "$manifests" rev-parse --is-shallow-repository)" = true ] &&
                       [ "$hurl" != "$murl" ]; then
                        git -C "$manifests" fetch --unshallow "$hurl" >/dev/null 2>&1 || true
                    fi
                fi
            fi
            if [ "$(git -C "$manifests" rev-parse --is-shallow-repository)" = false ]; then
                import_one "$manifests" "$mname" main "清单仓"
            elif [ "$DRY" = 1 ]; then
                gate_info "[dry] 清单仓补不全：临时 clone 一份完整的再推 $mname（分支 $mbranch）"
            else
                gate_info "==> 清单仓补不全，临时克隆一份完整的来推（分支 $mbranch）"
                if git clone --bare -q -b "$mbranch" "${hurl:-$murl}" "$work/manifests.git"; then
                    import_one "$work/manifests.git" "$mname" main "清单仓(临时克隆)"
                else
                    gate_warn "!! 临时克隆清单仓失败（${hurl:-$murl} -b $mbranch），跳过"
                    failed=$((failed + 1))
                fi
            fi
        fi
    fi

    # --- 清单里的项目（fd 3 喂循环：循环体里的 ssh 会把管道 stdin 吃掉）
    gate_manifest_list "$GATE_WS" > "$work/manifest.tsv" 2>/dev/null ||
        gate_die "读不出清单（$GATE_HOME/my_repo.py list --root $GATE_WS）"
    while IFS="$(printf '\t')" read -r ipath iname ibr anchor iurl <&3; do
        [ -n "${ipath:-}" ] || continue
        ipdir="$GATE_WS/$ipath"
        iproj=${iname%.git}
        ibr=${ibr:-main}
        if ireason=$(gate_skip_reason "$GATE_WS" "$ipath"); then
            gate_info "跳过 $ipath（$ireason）"
            continue
        fi
        if [ ! -d "$ipdir/.git" ]; then
            gate_info "跳过 $ipath（不是 git 仓库）"
            continue
        fi
        if [ "$(git -C "$ipdir" rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
            gate_info "跳过 $ipath（浅克隆，git 不允许从浅克隆推）"
            continue
        fi
        import_one "$ipdir" "$iproj" "$ibr" "$ipath"
    done 3< "$work/manifest.tsv"

    if [ "$failed" -gt 0 ]; then
        gate_warn "有 $failed 个没导进去（见上面的 !! 行）"
        return 1
    fi
    gate_info "==> 导入完事"
}

# ---------------------------------------------------------------------------
# 4. setup：把工作区接到 gerrit（remote + ds_dev + hook + client.conf）
# ---------------------------------------------------------------------------
cmd_setup () {
    gate_require_docker
    wire_one () {   # <dir> <project> <label>
        w_dir=$1; w_proj=$2; w_label=$3
        w_url="ssh://$GATE_AGENT@127.0.0.1:$GATE_SSH/$w_proj.git"
        if [ "$DRY" = 1 ]; then
            gate_info "[dry] $w_label: remote polygerrit = $w_url；建 ds_dev；装 commit-msg hook"
            return 0
        fi
        if git -C "$w_dir" remote get-url polygerrit >/dev/null 2>&1; then
            git -C "$w_dir" remote set-url polygerrit "$w_url"
        else
            git -C "$w_dir" remote add polygerrit "$w_url"
        fi
        hook="$w_dir/.git/hooks/commit-msg"
        if [ ! -x "$hook" ]; then
            curl -fsS -o "$hook" "$(gate_web_url)/tools/hooks/commit-msg" 2>/dev/null &&
                chmod +x "$hook" || gate_warn "   $w_label 的 commit-msg hook 没装上"
        fi
        if ! git -C "$w_dir" show-ref --verify --quiet refs/heads/ds_dev; then
            git -C "$w_dir" branch ds_dev HEAD >/dev/null
            gate_info "==> $w_label: 建了 ds_dev（从 $(git -C "$w_dir" rev-parse --short HEAD)）"
        fi
        if [ "$CHECKOUT" = 1 ]; then
            git -C "$w_dir" checkout -q ds_dev 2>/dev/null ||
                gate_warn "   $w_label 切到 ds_dev 失败（工作区有改动？）"
        fi
    }

    # 客户端配置：ggcp/gchk/gq/gpush 靠它找服务器
    if [ "$DRY" = 1 ]; then
        gate_info "[dry] 写 $(gate_client_file "$GATE_WS")（host/port/user/sshkey）"
    else
        mkdir -p "$(gate_state_dir "$GATE_WS")"
        cat > "$(gate_client_file "$GATE_WS")" <<EOF
# gerrit-gate：这个工作区的客户端配置（ggcp/gchk/gq/gpush 读它）
host=127.0.0.1
port=$GATE_SSH
user=$GATE_AGENT
sshkey=$(gate_agent_key)
EOF
        gate_info "==> 写了 $(gate_client_file "$GATE_WS")"
    fi

    manifests="$GATE_WS/.repo/manifests"
    if [ -d "$manifests/.git" ]; then
        mname=$(git -C "$manifests" remote get-url origin 2>/dev/null | sed -e 's#.*/##' -e 's#\.git$##')
        [ -n "$mname" ] || mname=$GATE_NAME-manifests
        wire_one "$manifests" "$mname" "清单仓"
    fi

    work=$(mktemp -d "${TMPDIR:-/tmp}/gerrit-gate.XXXXXX")
    trap 'rm -rf -- "$work"' EXIT INT TERM
    gate_manifest_list "$GATE_WS" > "$work/manifest.tsv" 2>/dev/null ||
        gate_die "读不出清单"
    while IFS="$(printf '\t')" read -r spath sname sbr anch url <&3; do
        [ -n "${spath:-}" ] || continue
        sdir="$GATE_WS/$spath"
        [ -d "$sdir/.git" ] || { gate_info "跳过 $spath（不是 git 仓库）"; continue; }
        if sreason=$(gate_skip_reason "$GATE_WS" "$spath"); then
            gate_info "跳过 $spath（$sreason）"
            continue
        fi
        wire_one "$sdir" "${sname%.git}" "$spath"
    done 3< "$work/manifest.tsv"
    gate_info "==> 接线完事"
}

# ---------------------------------------------------------------------------
# theme：换 UI 主题
#
# 原理：PolyGerrit 只允许用 CSS 变量改外观，官方钩子是插件的
# styleApi().insertCSSRule()。所以这里做两件事：
#   * 插件 plugins/wtooltheme.js（只装一次，负责把 /static/wtool-theme.css
#     注入页面；CSS 里带 /*wtool:force-dark*/ 标记时再切到深色）
#   * 主题 CSS static/wtool-theme.css（换主题 = 换这个文件，刷新浏览器即可）
# 两个都在卷里（plugins / static），所以删容器重建也不会丢。
# ---------------------------------------------------------------------------
GATE_THEME_PLUGIN=wtooltheme.js
GATE_THEME_CSS=wtool-theme.css

theme_list () {
    for f in "$GATE_HOME"/themes/*.css; do
        [ -e "$f" ] || continue
        b=$(basename "$f" .css)
        printf '  %s\n' "$b"
    done
}

theme_current () {
    gate_volume_read "$GATE_VOL-static" "$GATE_THEME_CSS.name" | head -1
}

theme_compose () {   # <名字，可带 + 组合> -> stdout CSS
    # "compact+dark" 这种组合按 + 拆开，直接把各段 cat 出来（别再拼字符串：
    # 拼字符串时写 "\n" 会变成字面的反斜杠-n，CSS 解析器从那以后就崩了 —— 踩过）
    local spec=$1 part f
    local IFS=+
    for part in $spec; do
        case $part in
            default) : ;;
            *)
                f="$GATE_HOME/themes/$part.css"
                if [ ! -r "$f" ]; then
                    gate_warn "没有这个主题: $part（可用的见 gerrit-gate theme）"
                    return 1
                fi
                cat "$f"
                ;;
        esac
    done
}

cmd_theme () {
    gate_require_docker
    local want=${THEME_NAME:-}

    if [ -z "$want" ] || [ "$want" = list ]; then
        gate_info "工作区   $GATE_WS（$GATE_CONTAINER）"
        gate_info "当前主题 $(theme_current || true)"
        gate_info ""
        gate_info "可选主题："
        theme_list
        gate_info ""
        gate_info "也可以自己组合：gerrit-gate theme compact+dark"
        gate_info "换完刷新浏览器（Ctrl-Shift-R）就能看到"
        return 0
    fi

    local css_file
    css_file="$(gate_state_dir "$GATE_WS")/theme.css.tmp"
    theme_compose "$want" > "$css_file" || { rm -f "$css_file"; return 1; }

    if [ "$DRY" = 1 ]; then
        gate_info "[dry] 装主题 $want：写 plugins/$GATE_THEME_PLUGIN + static/$GATE_THEME_CSS"
        return 0
    fi

    # 插件只装一次；第一次装要重启 Gerrit 才会被加载
    local need_restart=0 want_sum got_sum
    want_sum=$(sha256sum < "$GATE_HOME/theme-plugin.js" | cut -d' ' -f1)
    got_sum=$(gate_volume_read "$GATE_VOL-plugins" "$GATE_THEME_PLUGIN" | sha256sum | cut -d' ' -f1)
    if [ "$want_sum" != "$got_sum" ]; then
        if [ "$got_sum" = "$(printf '' | sha256sum | cut -d' ' -f1)" ]; then
            gate_info "==> 装主题插件 plugins/$GATE_THEME_PLUGIN（第一次，需要重启 Gerrit）"
        else
            gate_info "==> 主题插件有更新，重装（需要重启 Gerrit）"
        fi
        gate_volume_write "$GATE_VOL-plugins" "$GATE_THEME_PLUGIN" "$GATE_HOME/theme-plugin.js"
        need_restart=1
    fi

    gate_volume_write "$GATE_VOL-static" "$GATE_THEME_CSS" "$css_file"
    printf '%s\n' "$want" > "$(gate_state_dir "$GATE_WS")/theme.name.tmp"
    gate_volume_write "$GATE_VOL-static" "$GATE_THEME_CSS.name" "$(gate_state_dir "$GATE_WS")/theme.name.tmp"
    rm -f "$css_file" "$(gate_state_dir "$GATE_WS")/theme.name.tmp"
    gate_info "==> 主题已切换：$want"

    if [ "$need_restart" = 1 ]; then
        docker restart "$GATE_CONTAINER" >/dev/null
        gate_wait_ready "$GATE_WEB" || gate_die "重启后没起来"
        gate_info "==> Gerrit 重启完了"
    fi
    gate_info "    刷新浏览器（Ctrl-Shift-R）即可看到；想换回来：gerrit-gate theme <名字>"
}

# ---------------------------------------------------------------------------
# status / open / list
# ---------------------------------------------------------------------------
cmd_status () {
    gate_info "工作区   $GATE_WS"
    gate_info "实例     $GATE_CONTAINER（$GATE_IMAGE_I）"
    gate_info "端口     网页 $(gate_web_url)/   ssh 127.0.0.1:$GATE_SSH"
    gate_info "卷       $(for p in $GATE_VOLUME_PARTS; do printf '%s-%s ' "$GATE_VOL" "$p"; done)"

    gst=$(gate_container_state "$GATE_CONTAINER")
    gate_info "容器     $gst"
    if [ "$gst" = running ]; then
        gate_info "账号     $GATE_REVIEWER（+2 的人）/ $GATE_AGENT（只能推 refs/for/*）"
        gate_info "登录     $(gate_login_url)"
        gate_info "待检视   $(gate_open_url)"
    else
        gate_info "         跑 gerrit-gate up 起来"
    fi

    nproj=$(gate_manifest_list "$GATE_WS" 2>/dev/null | wc -l | tr -d ' ')
    gate_info "清单     $nproj 个项目"
    if [ "$gst" = running ] && gate_admin_ssh_works 2>/dev/null; then
        nimported=$(gate_admin_ssh gerrit ls-projects </dev/null 2>/dev/null | grep -c '^' || true)
        gate_info "已导入   $nimported 个 gerrit 项目（含 All-Projects/All-Users）"
    fi

    missing=""
    while IFS="$(printf '\t')" read -r p path name branch remote url; do
        [ -n "${path:-}" ] || continue
        dir="$GATE_WS/$path"
        [ -d "$dir/.git" ] || continue
        reason=$(gate_skip_reason "$GATE_WS" "$path" || true)
        [ -n "$reason" ] && continue
        git -C "$dir" remote get-url polygerrit >/dev/null 2>&1 || missing="$missing $path:no-remote"
        git -C "$dir" show-ref --verify --quiet refs/heads/ds_dev || missing="$missing $path:no-ds_dev"
    done <<EOF
$(gate_manifest_list "$GATE_WS" 2>/dev/null || true)
EOF
    if [ -n "$missing" ]; then
        gate_info "没接线   $missing"
        gate_info "         跑 gerrit-gate setup"
    else
        gate_info "接线     每个仓库都有 polygerrit remote 和 ds_dev 分支"
    fi
    [ -f "$(gate_client_file "$GATE_WS")" ] &&
        gate_info "客户端   $(gate_client_file "$GATE_WS")" ||
        gate_info "客户端   还没有（gerrit-gate setup）"
    if [ "$gst" = running ]; then
        gate_info "UI 主题  $(theme_current 2>/dev/null || echo '(默认)')"
    fi
}

cmd_open () {
    gate_info "登录（$GATE_REVIEWER）：$(gate_login_url)"
    gate_info "待检视：$(gate_open_url)"
    gate_info "全部 open：$(gate_web_url)/q/status:open"
}

cmd_list () {
    found=0
    for d in "$HOME"/self/* "$HOME"/*/self/*; do
        [ -f "$d/.gerrit/gate.conf" ] || continue
        [ -d "$d/.repo" ] || continue
        found=1
        c=$(sed -n 's/^container=//p' "$d/.gerrit/gate.conf" | head -1)
        w=$(sed -n 's/^web_port=//p' "$d/.gerrit/gate.conf" | head -1)
        s=$(sed -n 's/^ssh_port=//p' "$d/.gerrit/gate.conf" | head -1)
        printf '%-28s %-16s %-8s http://127.0.0.1:%s/\n' \
            "$d" "${c:-?}" "$(gate_container_state "${c:-none}")" "${w:-?}"
        [ -n "$s" ] || true
    done
    [ "$found" = 1 ] || gate_info "还没给任何工作区装闸门（在某个 repo 工作区里跑 gerrit-gate all）"
}

# ---------------------------------------------------------------------------
main () {
    cmd=${1:-help}
    [ $# -gt 0 ] && shift
    case $cmd in
        help|-h|--help) usage; exit 0 ;;
        list) parse_args "$@"; cmd_list; exit 0 ;;
        theme)
            # theme 的位置参数是"主题名 [工作区]"，和别的子命令不一样，单独解析
            for a in "$@"; do
                case $a in
                    --dry-run) DRY=1 ;;
                    -*) gate_die "不认识的参数: $a" ;;
                    *) if [ -z "${THEME_NAME:-}" ]; then THEME_NAME=$a; else WS_ARG=$a; fi ;;
                esac
            done
            ;;
        *) parse_args "$@" ;;
    esac
    GATE_DRY=$DRY
    resolve_ws
    case $cmd in
        # 只有"会动手"的子命令才允许生成实例配置；
        # status/open 是只读的 —— 别的 agent 的工作区不该被我们写脏
        up|bootstrap|import|setup|all|theme)
            gate_load "$GATE_WS" --create ;;
        status|open)
            if ! gate_load "$GATE_WS"; then
                gate_info "工作区   $GATE_WS"
                gate_info "闸门     还没装（在这个工作区里跑 gerrit-gate all 一条龙）"
                [ "$cmd" = open ] || gate_info "         装了之后这里会显示容器/账号/链接"
                exit 0
            fi ;;
    esac
    case $cmd in
        up)        cmd_up ;;
        theme)     cmd_theme ;;
        bootstrap) cmd_bootstrap ;;
        import)    cmd_import ;;
        setup)     cmd_setup ;;
        all)       cmd_up; cmd_bootstrap; cmd_import; cmd_setup; cmd_open ;;
        status)    cmd_status ;;
        open)      cmd_open ;;
        *)         usage; exit 2 ;;
    esac
}

main "$@"
