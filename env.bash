# env.bash —— 检视闸门的客户端命令（bash 版，和 env.zsh 等价）
#
# 由 wtool 的块 source：WTOOL_PROJECT_DIR = ~/.wtool/links/tools/gerrit-gate。
# 提供 ggcp / gchk / gq / gpush（用法见 env.zsh 顶部注释或 README）。
#
# 两份必须同改；tests/env_test.sh 会用同一张用例表把两个 shell 都跑一遍。

# 工具位置
GERRIT_GATE_DIR=${WTOOL_PROJECT_DIR:-$HOME/.wtool/links/tools/gerrit-gate}

# ---------------------------------------------------------------- gerrit 客户端
# 往上找含 .repo 的目录（自包含：不依赖 wtool 的 tools/repo —— 本项目独立可用）
_gg_ws () {
    local d=${PWD}
    while [ "$d" != "/" ]; do
        [ -d "$d/.repo" ] && { printf '%s\n' "$d"; return 0; }
        case $d in
            */*) d=${d%/*} ;;
            *)   d=/ ;;
        esac
    done
    return 1
}

_gg_conf_files () {
    local root
    [ -n "${WTOOL_GERRIT_CONF}" ] && printf '%s\n' "${WTOOL_GERRIT_CONF}"
    if root=$(_gg_ws); then
        printf '%s\n' "${root}/.gerrit/client.conf"
    fi
    printf '%s\n' "${HOME}/.wtool/gerrit.conf"
}

_gg_conf_get () {
    local key=$1 f v
    while IFS= read -r f; do
        [ -r "${f}" ] || continue
        v=$( . "${f}" >/dev/null 2>&1; eval "printf '%s' \"\${${key}}\"" )
        if [ -n "${v}" ]; then
            printf '%s\n' "${v}"
            return 0
        fi
    done < <(_gg_conf_files)
    return 1
}

# 从 URL 里拆出 host/port/user：ssh://user@host:29418/path 或 user@host:path
_gg_parse_url () {
    local url=$1 rest
    case ${url} in
        ssh://*)
            rest=${url#ssh://}
            rest=${rest%%/*}
            ;;
        *://*)
            # http(s):// 的 remote 不当 gerrit ssh 端点用
            return 1
            ;;
        *@*:*)
            rest=${url%%:*}
            ;;
        *)
            return 1
            ;;
    esac
    if [ -z "${_GERRIT_USER}" ] && [[ ${rest} == *@* ]]; then
        _GERRIT_USER=${rest%%@*}
    fi
    rest=${rest#*@}
    if [[ ${rest} == *:* ]]; then
        [ -z "${_GERRIT_PORT}" ] && _GERRIT_PORT=${rest##*:}
        rest=${rest%%:*}
    fi
    [ -z "${_GERRIT_HOST}" ] && _GERRIT_HOST=${rest}
    [ -n "${_GERRIT_HOST}" ]
}

_gg_guess_from_remotes () {
    local r url css_dir
    if git rev-parse --git-dir >/dev/null 2>&1; then
        while IFS= read -r r; do
            url=$(git remote get-url "${r}" 2>/dev/null) || continue
            case ${url} in
                *29418*|*gerrit*) printf '%s\n' "${url}"; return 0 ;;
            esac
        done < <(git remote 2>/dev/null)
    fi
    if css_dir=$(_gg_ws); then
        while IFS= read -r url; do
            case ${url} in
                *29418*|*gerrit*) printf '%s\n' "${url}"; return 0 ;;
            esac
        done < <(python3 ${GERRIT_GATE_DIR}/my_repo.py list --root ${css_dir} 2>/dev/null | awk -F'\t' '{print $5}')
    fi
    return 1
}

# 填好 _GERRIT_HOST/_PORT/_USER/_KEY；失败返回 1
_gg_resolve () {
    local url
    _GERRIT_HOST=${WTOOL_GERRIT_HOST:-}
    _GERRIT_PORT=${WTOOL_GERRIT_PORT:-}
    _GERRIT_USER=${WTOOL_GERRIT_USER:-}
    _GERRIT_KEY=${WTOOL_GERRIT_SSH_KEY:-}

    [ -z "${_GERRIT_HOST}" ] && _GERRIT_HOST=$(_gg_conf_get host)
    [ -z "${_GERRIT_PORT}" ] && _GERRIT_PORT=$(_gg_conf_get port)
    [ -z "${_GERRIT_USER}" ] && _GERRIT_USER=$(_gg_conf_get user)
    [ -z "${_GERRIT_KEY}"  ] && _GERRIT_KEY=$(_gg_conf_get sshkey)

    # host 允许写成 user@host:port
    if [[ ${_GERRIT_HOST} == *@* ]]; then
        [ -z "${_GERRIT_USER}" ] && _GERRIT_USER=${_GERRIT_HOST%%@*}
        _GERRIT_HOST=${_GERRIT_HOST#*@}
    fi
    if [[ ${_GERRIT_HOST} == *:* ]]; then
        [ -z "${_GERRIT_PORT}" ] && _GERRIT_PORT=${_GERRIT_HOST##*:}
        _GERRIT_HOST=${_GERRIT_HOST%%:*}
    fi

    if [ -z "${_GERRIT_HOST}" ]; then
        if url=$(_gg_guess_from_remotes); then
            _gg_parse_url "${url}"
        fi
    fi

    if [ -z "${_GERRIT_HOST}" ]; then
        printf 'ggcp: 不知道 gerrit 服务器在哪。请任选一种方式告诉它：\n' >&2
        printf '  export WTOOL_GERRIT_HOST=user@gerrit.company.com:29418\n' >&2
        printf '  或写 ~/.wtool/gerrit.conf（host=/port=/user=/sshkey=）\n' >&2
        printf '  或在 repo 根下放 .gerrit/client.conf\n' >&2
        return 1
    fi
    [ -z "${_GERRIT_PORT}" ] && _GERRIT_PORT=29418
    [ -z "${_GERRIT_USER}" ] && _GERRIT_USER=${USER}
    # 配置文件里 sshkey 常写成 ~/...，这里展开
    case ${_GERRIT_KEY} in
        '~'/*) _GERRIT_KEY="${HOME}/${_GERRIT_KEY#\~/}" ;;
    esac
    return 0
}

# 跑一条 gerrit ssh 命令（stdin/stdout 透传）
_gg_ssh () {
    local -a opts
    # LogLevel=ERROR：known_hosts 写不进去时 ssh 会往 stderr 抱怨一句，
    # 那句话会把 ggcp/gchk 的 JSON 流搅脏，这里直接压掉
    opts=(-p ${_GERRIT_PORT}
          -o StrictHostKeyChecking=accept-new
          -o LogLevel=ERROR
          -o ConnectTimeout=10)
    if [ -n "${_GERRIT_KEY}" ]; then
        opts+=(-i ${_GERRIT_KEY} -o IdentitiesOnly=yes)
    fi
    ssh "${opts[@]}" "${_GERRIT_USER}@${_GERRIT_HOST}" "$@"
}

# 给 git 用：让 git fetch/push 也走同一把 key
_gg_git_ssh_command () {
    local cmd="ssh -p ${_GERRIT_PORT} -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR"
    [ -n "${_GERRIT_KEY}" ] && cmd+=" -i ${_GERRIT_KEY} -o IdentitiesOnly=yes"
    printf '%s\n' "${cmd}"
}

# ggcp 用哪条 remote 抓：优先 polygerrit（本地送检用的镜像），
# 否则用清单里声明的 remote（公司树里就是它）
_gg_project_remote () {
    local r
    if git remote 2>/dev/null | grep -qx polygerrit; then
        printf 'polygerrit\n'
        return 0
    fi
    r=$(cnr 2>/dev/null)
    if [ -n "${r}" ] && git remote 2>/dev/null | grep -qx "${r}"; then
        printf '%s\n' "${r}"
        return 0
    fi
    r=$(git remote 2>/dev/null | head -1)
    if [ -n "${r}" ]; then
        printf '%s\n' "${r}"
        return 0
    fi
    return 1
}

# 内部：把 <change> 或 URL 拆成 "编号 [patchset]"（结果放 _GERRIT_CHANGE/_GERRIT_PS）
_gg_parse_change_arg () {
    local raw=$1 ps=$2 orig=$1
    _GERRIT_CHANGE=
    _GERRIT_PS=
    if [[ ${raw} == http*://* ]]; then
        raw=${raw%%\?*}
        # 老式链接把 change 号放在 # 后面：https://host/#/c/1234/2
        if [[ ${raw} == *#/c/* ]]; then
            raw=/${raw#*\#/c/}
        else
            raw=${raw%%#*}
        fi
        raw=${raw%/}
        # bash 里正则不能加引号（加了就按字面匹配）
        if [[ ${raw} =~ /([0-9]+)/([0-9]+)$ ]]; then
            _GERRIT_CHANGE=${BASH_REMATCH[1]}
            [ -z "${ps}" ] && ps=${BASH_REMATCH[2]}
        elif [[ ${raw} =~ /([0-9]+)$ ]]; then
            _GERRIT_CHANGE=${BASH_REMATCH[1]}
        fi
    else
        _GERRIT_CHANGE=${raw%%[/,]*}
        if [ -z "${ps}" ] && [[ ${raw} == *[/,]* ]]; then
            ps=${raw#*[/,]}
        fi
    fi
    if [[ ! ${_GERRIT_CHANGE} =~ ^[0-9]+$ ]]; then
        printf "ggcp: '%s' 里看不出 change 编号。\n" "${orig}" >&2
        printf '      用法: ggcp <change> [patchset]，例如 ggcp 1234 / ggcp 1234 2\n' >&2
        printf '           也认 https://gerrit.company.com/c/proj/+/1234/2 这种链接\n' >&2
        return 2
    fi
    if [ -n "${ps}" ] && [[ ! ${ps} =~ ^[0-9]+$ ]]; then
        printf "ggcp: patchset '%s' 不是数字\n" "${ps}" >&2
        return 2
    fi
    _GERRIT_PS=${ps}
    return 0
}

# 内部：抓一个 change 的 JSON（stdout）
_gg_query_change () {
    local change=$1
    _gg_ssh gerrit query --format=JSON --patch-sets --current-patch-set "change:${change}"
}

# 内部：抓 JSON 到 $_GERRIT_JSON。
# 关键点：ssh 的 stderr 不能混进 JSON（known_hosts 之类的一句话就能把它搅脏），
# 所以这里把 stderr 单独落文件，只有失败时才回显。
_gg_query_capture () {
    local change=$1 tmperr rc
    tmperr=$(mktemp "${TMPDIR:-/tmp}/wtool-gerrit.XXXXXX") || return 1
    _GERRIT_JSON=$(_gg_query_change ${change} 2>${tmperr})
    rc=$?
    [ ${rc} -ne 0 ] && cat ${tmperr} >&2
    rm -f ${tmperr}
    return ${rc}
}

# ggcp <change> [patchset]
#   把 gerrit 上第 <change> 号提交的第 <patchset> 个版本抓回本地，
#   cd 到它在清单里对应的项目目录，fetch 之后 cherry-pick。
#   不给 patchset 就用当前（最新）那个。
ggcp () {
    if [ $# -lt 1 ]; then
        printf 'Usage: ggcp <change> [patchset]\n' >&2
        printf '  ggcp 1234        # 当前 patchset\n' >&2
        printf '  ggcp 1234 1      # 第 1 个 patchset\n' >&2
        printf '  ggcp https://gerrit.company.com/c/proj/+/1234/2\n' >&2
        return 2
    fi
    _gg_parse_change_arg "$1" "$2" || return $?
    local change=${_GERRIT_CHANGE} wanted=${_GERRIT_PS}
    _gg_resolve || return 1

    local json line
    if ! _gg_query_capture ${change}; then
        printf 'ggcp: 连 %s@%s:%s 查询失败\n' "${_GERRIT_USER}" "${_GERRIT_HOST}" "${_GERRIT_PORT}" >&2
        return 1
    fi
    json=${_GERRIT_JSON}
    if [ -z "${json//[[:space:]]/}" ]; then
        printf 'ggcp: change %s 查不到（编号对不对？有没有权限？）\n' "${change}" >&2
        return 1
    fi

    local -a args
    args=(patchset ${change})
    [ -n "${wanted}" ] && args+=(${wanted})
    if ! line=$(printf '%s\n' "${json}" | python3 ${GERRIT_GATE_DIR}/gerrit_query.py "${args[@]}" 2>&1); then
        printf '%s\n' "${line}" >&2
        return 1
    fi

    local number pset revision ref project branch url subject
    IFS=$'\t' read -r number pset revision ref project branch url subject <<< "${line}"
    [ -z "${ref}" ] && ref=${revision}

    local dir
    if ! dir=$(cdd_path ${project}); then
        printf "ggcp: change %s 属于项目 '%s'，但清单里找不到它\n" "${change}" "${project}" >&2
        printf '      （本地清单和 gerrit 上的是同一份吗？）\n' >&2
        return 1
    fi
    if [ ! -d "${dir}" ]; then
        printf "ggcp: 项目 '%s' 的目录还不存在：%s\n" "${project}" "${dir}" >&2
        printf '      先 repo sync %s\n' "${project}" >&2
        return 1
    fi

    cd ${dir} || return 1
    local remote
    if ! remote=$(_gg_project_remote); then
        printf 'ggcp: 在 %s 里找不到可用的 git remote\n' "$(pwd)" >&2
        return 1
    fi

    printf 'ggcp: change %s patchset %s -> %s (%s)\n' "${number}" "${pset}" "${project}" "${branch}"
    printf '      commit %s\n' "${revision}"
    printf '      URL    %s\n' "${url}"
    GIT_SSH_COMMAND=$(_gg_git_ssh_command) git fetch ${remote} ${ref} || return 1
    # fetch 回来核对一下：ref 里写的 patchset 和 gerrit 报的 commit 必须是同一个，
    # 不然就是我把 ref 拼错了，这时候宁可不 cherry-pick
    local fetched
    fetched=$(git rev-parse FETCH_HEAD 2>/dev/null)
    if [ "${fetched}" != "${revision}" ]; then
        printf 'ggcp: 抓到的 commit（%s）和 gerrit 说的（%s）对不上，\n' "${fetched}" "${revision}" >&2
        printf '      这次不 cherry-pick。用 gq %s 看看 patchset 列表\n' "${number}" >&2
        return 1
    fi
    if ! GIT_SSH_COMMAND=$(_gg_git_ssh_command) git cherry-pick ${revision}; then
        if [ -f "$(git rev-parse --git-path CHERRY_PICK_HEAD 2>/dev/null)" ]; then
            printf 'ggcp: cherry-pick 冲突了。解决后 git cherry-pick --continue，\n' >&2
            printf '      或者 git cherry-pick --abort 整个放弃\n' >&2
        else
            printf 'ggcp: cherry-pick 没跑起来（工作区有没提交的改动？先 commit 或 git stash）\n' >&2
        fi
        return 1
    fi
    printf 'ggcp: 已 cherry-pick 到 %s 的 %s 分支\n' "$(pwd)" "$(git rev-parse --abbrev-ref HEAD)"
    return 0
}

# 项目名/路径 -> 绝对路径（不 cd）
cdd_path () {
    local target=$1 css_dir repo_path
    if ! css_dir=$(_gg_ws); then
        printf 'cdd_path: 当前目录不在 repo 工作区里\n' >&2
        return 1
    fi
    if repo_path=$(python3 ${GERRIT_GATE_DIR}/my_repo.py path_from_name ${target} --root ${css_dir} 2>/dev/null); then
        printf '%s\n' "${css_dir}/${repo_path}"
        return 0
    fi
    if [ -e "${css_dir}/${target}" ]; then
        printf '%s\n' "${css_dir}/${target}"
        return 0
    fi
    printf "cdd_path: 清单里没有 '%s'\n" "${target}" >&2
    return 1
}

# gchk <change>：能不能推 main？—— 看 +2 和 merged
# 退出码 0 = 已 merged（此时必然有 +2），1 = 还没，2 = 查不到
gchk () {
    if [ $# -ne 1 ]; then
        printf 'Usage: gchk <change>\n' >&2
        return 2
    fi
    _gg_parse_change_arg "$1" || return $?
    local change=${_GERRIT_CHANGE}
    _gg_resolve || return 2
    if ! _gg_query_capture ${change}; then
        printf 'gchk: 查询失败\n' >&2
        return 2
    fi
    printf '%s\n' "${_GERRIT_JSON}" | python3 ${GERRIT_GATE_DIR}/gerrit_query.py check ${change}
    return $?
}

# gq <change>：把 change 的摘要列出来（raw JSON 用 gq -r）
gq () {
    local raw=0
    [[ ${1:-} == -r || ${1:-} == --raw ]] && { raw=1; shift; }
    if [ $# -lt 1 ]; then
        printf 'Usage: gq <change>\n' >&2
        return 2
    fi
    _gg_parse_change_arg "$1" || return $?
    _gg_resolve || return 2
    local json
    json=$(_gg_query_change ${_GERRIT_CHANGE}) || return 1
    if [ ${raw} -eq 1 ]; then
        printf '%s\n' "${json}"
    else
        printf '%s\n' "${json}" | python3 ${GERRIT_GATE_DIR}/gerrit_query.py list
    fi
}

# gpush [remote] [额外参数...]：推当前 HEAD 去送检
gpush () {
    local remote=polygerrit branch
    if [ $# -gt 0 ] && [[ $1 != -* ]]; then
        remote=$1
        shift
    fi
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        printf 'gpush: 当前目录不是 git 仓库\n' >&2
        return 1
    fi
    if ! branch=$(cnb); then
        printf 'gpush: 取不到清单里声明的分支（cnb 失败）\n' >&2
        return 1
    fi
    if ! git remote 2>/dev/null | grep -qx ${remote}; then
        printf "gpush: 这个仓库没有 remote '%s'。现有的：\n" "${remote}" >&2
        git remote -v >&2
        return 1
    fi
    _gg_resolve >/dev/null 2>&1
    printf 'gpush: git push %s HEAD:refs/for/%s %s\n' "${remote}" "${branch}" "$*"
    GIT_SSH_COMMAND=$(_gg_git_ssh_command) git push ${remote} "HEAD:refs/for/${branch}" "$@"
}
