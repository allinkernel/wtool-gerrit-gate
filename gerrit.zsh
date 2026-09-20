# gerrit.zsh —— 检视闸门的客户端命令（用户级；任何 repo 工作区都能用）
#
# 由 ~/.zshrc 里那段 gerrit-gate 块 source。提供：
#   ggcp <change> [patchset]   把 gerrit 上的某个提交（指定 patchset）抓回本地、cd 到对应仓库、cherry-pick
#   gchk <change>              看它 +2 了没 / merged 了没（退出码 0 = 可以推 main）
#   gq   <change>              change 摘要（gq -r 出原始 JSON）
#   gpush [remote]             把当前 HEAD 推到 refs/for/<清单声明的分支>
#
# 服务器地址从"当前 repo 工作区"的 .gerrit/client.conf 读（gerrit-gate setup 写的），
# 也可以用环境变量覆盖：
#   WTOOL_GERRIT_HOST / _PORT / _USER / _SSH_KEY  （兼容老名字）
#
# 这个文件不定义 cs/ct/cnp/cdd —— 那些是 wtool 的 tools/repo 项目的事，
# 别在这里把人家的命令覆盖掉。

# 工具位置（my_repo.py / gerrit_query.py 随 gerrit-gate 一起装）
GERRIT_GATE_HOME=${GERRIT_GATE_HOME:-$HOME/.local/share/gerrit-gate}
export GERRIT_GATE_HOME

_gg_manifest_tool () { print -r -- ${GERRIT_GATE_HOME}/my_repo.py }
_gg_query_tool ()    { print -r -- ${GERRIT_GATE_HOME}/gerrit_query.py }

# 往上找含 .repo 的目录（和 wtool 的 css 同义，只是不抢它的名字）
_gg_ws () {
    local d=${PWD}
    while [[ ${d} != / ]]; do
        [[ -d ${d}/.repo ]] && { print -r -- ${d}; return 0 }
        d=${d:h}
    done
    return 1
}

# ---------------------------------------------------------------- 配置解析
_gg_conf_files () {
    local root
    [[ -n ${WTOOL_GERRIT_CONF} ]] && print -r -- ${WTOOL_GERRIT_CONF}
    if root=$(_gg_ws); then
        print -r -- ${root}/.gerrit/client.conf
    fi
    print -r -- ${HOME}/.wtool/gerrit.conf
}

_gg_conf_get () {
    local key=$1 f v
    for f in ${(f)"$(_gg_conf_files)"}; do
        [[ -r ${f} ]] || continue
        v=$( . ${f} >/dev/null 2>&1; eval "print -r -- \"\${${key}}\"" )
        if [[ -n ${v} ]]; then
            print -r -- ${v}
            return 0
        fi
    done
    return 1
}

# ssh://user@host:29418/path 或 user@host:path -> _GERRIT_HOST/PORT/USER
_gg_parse_url () {
    local url=$1 rest
    case ${url} in
        ssh://*) rest=${url#ssh://}; rest=${rest%%/*} ;;
        *://*)   return 1 ;;
        *@*:*)   rest=${url%%:*} ;;
        *)       return 1 ;;
    esac
    [[ -z ${_GERRIT_USER} && ${rest} == *@* ]] && _GERRIT_USER=${rest%%@*}
    rest=${rest#*@}
    if [[ ${rest} == *:* ]]; then
        [[ -z ${_GERRIT_PORT} ]] && _GERRIT_PORT=${rest##*:}
        rest=${rest%%:*}
    fi
    [[ -z ${_GERRIT_HOST} ]] && _GERRIT_HOST=${rest}
    [[ -n ${_GERRIT_HOST} ]]
}

_gg_guess_from_remotes () {
    local r url root
    if git rev-parse --git-dir >/dev/null 2>&1; then
        for r in ${(f)"$(git remote 2>/dev/null)"}; do
            url=$(git remote get-url ${r} 2>/dev/null) || continue
            case ${url} in
                *29418*|*gerrit*) print -r -- ${url}; return 0 ;;
            esac
        done
    fi
    if root=$(_gg_ws); then
        for url in ${(f)"$(python3 $(_gg_manifest_tool) list --root ${root} 2>/dev/null | awk -F'\t' '{print $5}')"}; do
            case ${url} in
                *29418*|*gerrit*) print -r -- ${url}; return 0 ;;
            esac
        done
    fi
    return 1
}

_gg_resolve () {
    typeset -g _GERRIT_HOST _GERRIT_PORT _GERRIT_USER _GERRIT_KEY
    local url
    _GERRIT_HOST=${WTOOL_GERRIT_HOST:-}
    _GERRIT_PORT=${WTOOL_GERRIT_PORT:-}
    _GERRIT_USER=${WTOOL_GERRIT_USER:-}
    _GERRIT_KEY=${WTOOL_GERRIT_SSH_KEY:-}

    [[ -z ${_GERRIT_HOST} ]] && _GERRIT_HOST=$(_gg_conf_get host)
    [[ -z ${_GERRIT_PORT} ]] && _GERRIT_PORT=$(_gg_conf_get port)
    [[ -z ${_GERRIT_USER} ]] && _GERRIT_USER=$(_gg_conf_get user)
    [[ -z ${_GERRIT_KEY}  ]] && _GERRIT_KEY=$(_gg_conf_get sshkey)

    if [[ ${_GERRIT_HOST} == *@* ]]; then
        [[ -z ${_GERRIT_USER} ]] && _GERRIT_USER=${_GERRIT_HOST%%@*}
        _GERRIT_HOST=${_GERRIT_HOST#*@}
    fi
    if [[ ${_GERRIT_HOST} == *:* ]]; then
        [[ -z ${_GERRIT_PORT} ]] && _GERRIT_PORT=${_GERRIT_HOST##*:}
        _GERRIT_HOST=${_GERRIT_HOST%%:*}
    fi
    if [[ -z ${_GERRIT_HOST} ]]; then
        if url=$(_gg_guess_from_remotes); then
            _gg_parse_url ${url}
        fi
    fi
    if [[ -z ${_GERRIT_HOST} ]]; then
        print -r -- "没有 gerrit 服务器信息：先在这个工作区里跑 gerrit-gate setup" >&2
        print -r -- "（或者 export WTOOL_GERRIT_HOST=user@host:29418）" >&2
        return 1
    fi
    [[ -z ${_GERRIT_PORT} ]] && _GERRIT_PORT=29418
    [[ -z ${_GERRIT_USER} ]] && _GERRIT_USER=${USER}
    [[ -n ${_GERRIT_KEY} ]] && _GERRIT_KEY=${_GERRIT_KEY/#\~/$HOME}
    return 0
}

_gg_ssh () {
    local -a opts
    # LogLevel=ERROR：known_hosts 写不进去时 ssh 的抱怨会把 JSON 流搅脏
    opts=(-p ${_GERRIT_PORT} -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ConnectTimeout=10)
    [[ -n ${_GERRIT_KEY} ]] && opts+=(-i ${_GERRIT_KEY} -o IdentitiesOnly=yes)
    ssh ${opts} "${_GERRIT_USER}@${_GERRIT_HOST}" "$@"
}

_gg_git_ssh_command () {
    local cmd="ssh -p ${_GERRIT_PORT} -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR"
    [[ -n ${_GERRIT_KEY} ]] && cmd+=" -i ${_GERRIT_KEY} -o IdentitiesOnly=yes"
    print -r -- ${cmd}
}

# ---------------------------------------------------------------- change 查询
_gg_query_change () {
    _gg_ssh gerrit query --format=JSON --patch-sets --current-patch-set "change:$1"
}

_gg_query_capture () {   # -> $_GERRIT_JSON，stderr 单独落文件
    local change=$1 tmperr rc
    tmperr=$(mktemp "${TMPDIR:-/tmp}/gerrit-gate.XXXXXX") || return 1
    typeset -g _GERRIT_JSON
    _GERRIT_JSON=$(_gg_query_change ${change} 2>${tmperr})
    rc=$?
    (( rc != 0 )) && cat ${tmperr} >&2
    rm -f ${tmperr}
    return ${rc}
}

# 项目名 -> 本地目录（不 cd）；失败时把原因打在 stderr
_gg_project_dir () {
    local target=$1 root rel
    if ! root=$(_gg_ws); then
        print -r -- "当前目录不在 repo 工作区里" >&2
        return 1
    fi
    if rel=$(python3 $(_gg_manifest_tool) path_from_name ${target} --root ${root} 2>/dev/null); then
        print -r -- ${root}/${rel}
        return 0
    fi
    if [[ -e ${root}/${target} ]]; then
        print -r -- ${root}/${target}
        return 0
    fi
    print -r -- "清单里没有 '${target}'" >&2
    return 1
}

# ggcp 从哪条 remote 抓：优先 polygerrit，否则清单声明的 remote
_gg_project_remote () {
    local r root rel
    if git remote 2>/dev/null | grep -qx polygerrit; then
        print -r -- polygerrit
        return 0
    fi
    if root=$(_gg_ws); then
        rel=${PWD#${root}/}
        r=$(python3 $(_gg_manifest_tool) remote_from_path ${rel} --root ${root} 2>/dev/null)
    fi
    if [[ -n ${r} ]] && git remote 2>/dev/null | grep -qx ${r}; then
        print -r -- ${r}
        return 0
    fi
    r=$(git remote 2>/dev/null | head -1)
    [[ -n ${r} ]] && print -r -- ${r} && return 0
    return 1
}

# 拆 <change> 或 URL -> _GERRIT_CHANGE / _GERRIT_PS
_gg_parse_change_arg () {
    local raw=$1 ps=$2 orig=$1
    typeset -g _GERRIT_CHANGE _GERRIT_PS
    if [[ ${raw} == http*://* ]]; then
        raw=${raw%%\?*}
        # 老式链接把 change 号放在 # 后面：https://host/#/c/1234/2
        if [[ ${raw} == *#/c/* ]]; then
            raw=/${raw#*\#/c/}
        else
            raw=${raw%%#*}
        fi
        raw=${raw%/}
        if [[ ${raw} =~ '/([0-9]+)/([0-9]+)$' ]]; then
            _GERRIT_CHANGE=${match[1]}
            [[ -z ${ps} ]] && ps=${match[2]}
        elif [[ ${raw} =~ '/([0-9]+)$' ]]; then
            _GERRIT_CHANGE=${match[1]}
        fi
    else
        _GERRIT_CHANGE=${raw%%[/,]*}
        if [[ -z ${ps} && ${raw} == *[/,]* ]]; then
            ps=${raw#*[/,]}
        fi
    fi
    if [[ ! ${_GERRIT_CHANGE} == <-> ]]; then
        print -r -- "ggcp: '${orig}' 里看不出 change 编号。" >&2
        print -r -- "      用法: ggcp <change> [patchset]，例如 ggcp 1234 / ggcp 1234 2" >&2
        print -r -- "           也认 https://host/c/proj/+/1234/2 和老式 https://host/#/c/1234/2" >&2
        return 2
    fi
    if [[ -n ${ps} && ! ${ps} == <-> ]]; then
        print -r -- "ggcp: patchset '${ps}' 不是数字" >&2
        return 2
    fi
    _GERRIT_PS=${ps}
    return 0
}

# ---------------------------------------------------------------- 命令
ggcp () {
    if [[ $# -lt 1 ]]; then
        print -r -- "Usage: ggcp <change> [patchset]" >&2
        print -r -- "  ggcp 1234        # 当前 patchset" >&2
        print -r -- "  ggcp 1234 1      # 第 1 个 patchset" >&2
        return 2
    fi
    _gg_parse_change_arg "$1" "$2" || return $?
    local change=${_GERRIT_CHANGE} wanted=${_GERRIT_PS}
    _gg_resolve || return 1

    local json line
    if ! _gg_query_capture ${change}; then
        print -r -- "ggcp: 连 ${_GERRIT_USER}@${_GERRIT_HOST}:${_GERRIT_PORT} 查询失败" >&2
        return 1
    fi
    json=${_GERRIT_JSON}

    local -a args
    args=(patchset ${change})
    [[ -n ${wanted} ]] && args+=(${wanted})
    if ! line=$(print -r -- ${json} | python3 $(_gg_query_tool) ${args} 2>&1); then
        print -r -- ${line} >&2
        return 1
    fi

    local number pset revision ref project branch url subject
    IFS=$'\t' read -r number pset revision ref project branch url subject <<< ${line}
    [[ -z ${ref} ]] && ref=${revision}

    local dir
    if ! dir=$(_gg_project_dir ${project}); then
        print -r -- "ggcp: change ${change} 属于项目 '${project}'，但本地清单里找不到它" >&2
        return 1
    fi
    if [[ ! -d ${dir} ]]; then
        print -r -- "ggcp: 项目 '${project}' 的目录还不存在：${dir}（先 repo sync）" >&2
        return 1
    fi

    cd ${dir} || return 1
    local remote
    if ! remote=$(_gg_project_remote); then
        print -r -- "ggcp: 在 $(pwd) 里找不到可用的 git remote" >&2
        return 1
    fi

    print -r -- "ggcp: change ${number} patchset ${pset} -> ${project} (${branch})"
    print -r -- "      commit ${revision}"
    print -r -- "      URL    ${url}"
    GIT_SSH_COMMAND=$(_gg_git_ssh_command) git fetch ${remote} ${ref} || return 1
    local fetched
    fetched=$(git rev-parse FETCH_HEAD 2>/dev/null)
    if [[ ${fetched} != ${revision} ]]; then
        print -r -- "ggcp: 抓到的 commit（${fetched}）和 gerrit 说的（${revision}）对不上，先不 cherry-pick" >&2
        return 1
    fi
    if ! GIT_SSH_COMMAND=$(_gg_git_ssh_command) git cherry-pick ${revision}; then
        if [[ -f $(git rev-parse --git-path CHERRY_PICK_HEAD 2>/dev/null) ]]; then
            print -r -- "ggcp: cherry-pick 冲突了。解决后 git cherry-pick --continue，或 --abort 放弃" >&2
        else
            print -r -- "ggcp: cherry-pick 没跑起来（工作区有没提交的改动？先 commit 或 git stash）" >&2
        fi
        return 1
    fi
    print -r -- "ggcp: 已 cherry-pick 到 $(pwd) 的 $(git rev-parse --abbrev-ref HEAD) 分支"
    return 0
}

gchk () {
    if [[ $# -ne 1 ]]; then
        print -r -- "Usage: gchk <change>   # 退出码 0 = 已 +2 且已 merged（可以推 main）" >&2
        return 2
    fi
    _gg_parse_change_arg "$1" || return $?
    _gg_resolve || return 2
    if ! _gg_query_capture ${_GERRIT_CHANGE}; then
        print -r -- "gchk: 查询失败" >&2
        return 2
    fi
    print -r -- ${_GERRIT_JSON} | python3 $(_gg_query_tool) check ${_GERRIT_CHANGE}
    return $?
}

gq () {
    local raw=0
    [[ ${1:-} == -r || ${1:-} == --raw ]] && { raw=1; shift }
    if [[ $# -lt 1 ]]; then
        print -r -- "Usage: gq [-r] <change>" >&2
        return 2
    fi
    _gg_parse_change_arg "$1" || return $?
    _gg_resolve || return 2
    local json
    json=$(_gg_query_change ${_GERRIT_CHANGE}) || return 1
    if [[ ${raw} -eq 1 ]]; then
        print -r -- ${json}
    else
        print -r -- ${json} | python3 $(_gg_query_tool) list
    fi
}

gpush () {
    local remote=polygerrit branch root rel
    if [[ $# -gt 0 && $1 != -* ]]; then
        remote=$1
        shift
    fi
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        print -r -- "gpush: 当前目录不是 git 仓库" >&2
        return 1
    fi
    if root=$(_gg_ws); then
        rel=${PWD#${root}/}
        branch=$(python3 $(_gg_manifest_tool) branch_from_path ${rel} --root ${root} 2>/dev/null)
    fi
    [[ -n ${branch} ]] || branch=$(git rev-parse --abbrev-ref HEAD)
    if ! git remote 2>/dev/null | grep -qx ${remote}; then
        print -r -- "gpush: 这个仓库没有 remote '${remote}'（先 gerrit-gate setup）" >&2
        return 1
    fi
    _gg_resolve >/dev/null 2>&1
    print -r -- "gpush: git push ${remote} HEAD:refs/for/${branch} $*"
    GIT_SSH_COMMAND=$(_gg_git_ssh_command) git push ${remote} "HEAD:refs/for/${branch}" "$@"
}
