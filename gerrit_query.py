#!/usr/bin/env python3
"""gerrit_query.py —— 解析 `ssh <gerrit> gerrit query --format=JSON` 的输出。

为什么单独一个文件：命令的连接/鉴权部分必须在 shell 里（ssh key、代理、
`~/.ssh/config` 都是 shell 的事），但 JSON 解析用 shell 写又长又脆。
所以 ggcp / gchk 只负责"把 JSON 抓回来"，解析全在这里。

输入永远是 stdin 上的一行行 JSON（gerrit query 的原始输出，最后一行是
`{"type":"stats",...}`，这里会跳过）。

用法：
    gerrit query ... | gerrit_query.py patchset <change> [patchset]
        输出 TSV：number  patchset  revision  ref  project  branch  url  subject
        没给 patchset 时取 current patch set（没有 current 就取编号最大的）。

    gerrit query ... | gerrit_query.py check [<change>]
        输出人类可读的状态/投票摘要；退出码 0 = 已 merged 且有 +2，
        1 = 还没 merged / 还没 +2，2 = 参数或数据有问题。

    gerrit query ... | gerrit_query.py list
        每个 change 一行摘要（number/status/project/subject）。

    gerrit query ... | gerrit_query.py raw
        原样打印去掉 stats 的 JSON（调试用）。
"""

import json
import sys

PROG = "gerrit_query.py"


def die(msg, code=2):
    sys.stderr.write("%s: %s\n" % (PROG, msg))
    return code


def load_changes(stream):
    """读 gerrit query 的 JSON 流，返回 change 列表（去掉 stats 行）。"""
    changes = []
    for line in stream:
        line = line.strip()
        if not line:
            continue
        try:
            data = json.loads(line)
        except ValueError as exc:
            raise ValueError("不是合法的 JSON 行: %s (%s)" % (line[:80], exc))
        if data.get("type") == "stats":
            continue
        changes.append(data)
    return changes


def patchsets_of(change):
    sets = list(change.get("patchSets") or [])
    if not sets and change.get("currentPatchSet"):
        sets = [change["currentPatchSet"]]
    return sorted(sets, key=lambda p: p.get("number", 0))


def pick_patchset(change, wanted=None):
    sets = patchsets_of(change)
    if not sets:
        return None
    if wanted is None:
        current = change.get("currentPatchSet")
        if current:
            for p in sets:
                if p.get("number") == current.get("number"):
                    return p
        return sets[-1]
    for p in sets:
        if str(p.get("number")) == str(wanted):
            return p
    return None


def pick_change(changes, number=None):
    if not changes:
        return None
    if number is None:
        return changes[0]
    # 指定了编号就必须**精确命中**：以前这里有个"只有一条就拿来用"的兜底，
    # 结果查 change 999 会拿到 1234 —— 对 ggcp 来说等于把别的提交打进来
    for c in changes:
        if str(c.get("number")) == str(number):
            return c
    return None


def vote_summary(change, patchset):
    """返回 (是否有 Code-Review +2, 投票字串, +2 的人)。"""
    approvals = (patchset or {}).get("approvals") or []
    if not approvals:
        approvals = change.get("approvals") or []
    plus2 = []
    parts = []
    for a in approvals:
        by = a.get("by") or {}
        who = by.get("username") or by.get("name") or by.get("email") or "?"
        value = a.get("value", "")
        parts.append("%s %s by %s" % (a.get("type", "?"), value, who))
        if a.get("type") == "Code-Review" and value == "+2":
            plus2.append(who)
    return plus2, ", ".join(parts)


def tsv(fields):
    return "\t".join("" if f is None else str(f) for f in fields)


def cmd_patchset(changes, change_no, wanted):
    change = pick_change(changes, change_no)
    if change is None:
        return die("没有匹配 change %s 的提交" % change_no, 1)
    ps = pick_patchset(change, wanted)
    if ps is None:
        if wanted is None:
            return die("change %s 没有任何 patch set" % change_no, 1)
        have = ",".join(str(p.get("number")) for p in patchsets_of(change))
        return die("change %s 没有 patchset %s（现有: %s）"
                   % (change_no, wanted, have or "无"), 1)
    sys.stdout.write(tsv([
        change.get("number"),
        ps.get("number"),
        ps.get("revision"),
        ps.get("ref"),
        change.get("project"),
        change.get("branch"),
        change.get("url"),
        change.get("subject"),
    ]) + "\n")
    return 0


def cmd_list(changes):
    for c in changes:
        sys.stdout.write(tsv([
            c.get("number"), c.get("status", "?"), c.get("project", "?"),
            c.get("subject", ""),
        ]) + "\n")
    return 0


def cmd_raw(changes):
    for c in changes:
        sys.stdout.write(json.dumps(c, ensure_ascii=False) + "\n")
    return 0


def cmd_check(changes, change_no):
    change = pick_change(changes, change_no)
    if change is None:
        return die("没有匹配 change %s 的提交（编号对不对？有没有权限？）" % change_no, 2)
    ps = pick_patchset(change)
    plus2, votes = vote_summary(change, ps)
    status = change.get("status", "?")
    out = sys.stdout
    out.write("change %s  [%s]\n" % (change.get("number"), status))
    out.write("  project : %s\n" % change.get("project", "?"))
    out.write("  branch  : %s\n" % change.get("branch", "?"))
    out.write("  subject : %s\n" % change.get("subject", ""))
    if ps:
        out.write("  patchset: %s  %s\n" % (ps.get("number"),
                                            (ps.get("revision") or "")[:12]))
    out.write("  投票    : %s\n" % (votes or "（还没有任何投票）"))
    out.write("  链接    : %s\n" % change.get("url", "?"))
    if status == "MERGED":
        if plus2:
            out.write("  => 已 merged，且 +2 来自: %s\n" % ", ".join(plus2))
        else:
            out.write("  => 已 merged（当前 patchset 上看不到 +2，"
                      "可能是提交后又有新 patchset）\n")
        return 0
    if status == "ABANDONED":
        out.write("  => 已 abandoned\n")
        return 1
    if plus2:
        out.write("  => 已 +2（来自 %s），但还没 merged\n" % ", ".join(plus2))
    else:
        out.write("  => 还没 +2，不能推 main\n")
    return 1


def main(argv):
    if len(argv) < 2:
        return die("用法: gerrit_query.py {patchset|check|list|raw} [...]", 2)
    action = argv[1]
    rest = argv[2:]
    try:
        changes = load_changes(sys.stdin)
    except ValueError as exc:
        return die(str(exc), 2)

    if action == "patchset":
        if not rest:
            return die("patchset 需要 <change> [patchset]", 2)
        return cmd_patchset(changes, rest[0], rest[1] if len(rest) > 1 else None)
    if action == "check":
        return cmd_check(changes, rest[0] if rest else None)
    if action == "list":
        return cmd_list(changes)
    if action == "raw":
        return cmd_raw(changes)
    return die("不认识的动作: %s" % action, 2)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
