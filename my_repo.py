#!/usr/bin/env python3
"""my_repo.py —— 只读 repo manifest 的小工具（**自包含**，不依赖 repo 内部实现）。

为什么不再 import `.repo/repo/manifest_xml.py`
------------------------------------------------
老版本是从 repo 的源码里 import `XmlManifest` 来解析清单的，这条路在公司机器上会断：

* 公司的 repo 可能是 **go 版**（git-repo / 阿里版），根本没有 `.repo/repo/manifest_xml.py`；
* 就算是 python 版，`XmlManifest` 的构造函数和属性在各版本之间也改过
  （新版要求 `manifest_file` 必须是绝对路径，相对 root 直接抛
  `ManifestParseError: manifest_file must be abspath`）；
* wtool 的**发布包**里没有 `.repo/repo`，解包后这两个前提一个都不成立。

所以这里自己解析 XML。只依赖标准库，python3.6+ 都能跑；py 版 repo / go 版 repo /
纯解包的工作区都一样能用。

支持的清单语法
--------------
`<remote>` / `<default>` / `<project>` / `<include>` / `<remove-project>` /
`<extend-project>` / `<linkfile>` / `<copyfile>`，
外加 `.repo/local_manifests/*.xml`（本地覆盖清单，AOSP 场景很常用）。
未识别的标签/属性**忽略**而不是报错：新版本 repo 加的东西不该把这个工具弄挂。

用法
----
    my_repo.py name_from_path   <path>  [--root ROOT]
    my_repo.py path_from_name   <name>  [--root ROOT]
    my_repo.py branch_from_path <path>  [--root ROOT]
    my_repo.py branch_from_name <name>  [--root ROOT]
    my_repo.py remote_from_path <path>  [--root ROOT]
    my_repo.py remote_from_name <name>  [--root ROOT]
    my_repo.py url_from_name    <name>  [--root ROOT]
    my_repo.py list                     [--root ROOT] [--format tsv|json]
    my_repo.py root                     [--root ROOT]

`--root` 省略时，从 PATH（默认当前目录）往上找含 `.repo` 的目录。
找不到项目时往 stderr 打一行原因并退出码 1，方便 shell 侧 `if ! ...` 判断。
"""

import argparse
import json
import os
import sys
import xml.etree.ElementTree as ET

PROG = "my_repo.py"


class ManifestError(Exception):
    """清单本身的问题（找不到、解析失败、语法不对）。"""


# ---------------------------------------------------------------------------
# 数据模型
# ---------------------------------------------------------------------------
class Remote(object):
    def __init__(self, name, fetch=None, revision=None):
        self.name = name
        self.fetch = fetch
        self.revision = revision
        self.orig_name = name


class Project(object):
    def __init__(self, name, path, remote, revision=None, upstream=None,
                 dest_branch=None, groups=(), linkfiles=()):
        self.name = name
        self.path = path              # relpath，相对 repo 根
        self.relpath = path           # 兼容老名字
        self.remote = remote          # Remote 对象或 None
        self.revision = revision
        self.upstream = upstream
        self.dest_branch = dest_branch
        self.groups = list(groups)
        self.linkfiles = list(linkfiles)

    #: 实际 checkout 的版本（repo 语义：project > remote > default）
    @property
    def revision_expr(self):
        if self.revision:
            return self.revision
        if self.remote and self.remote.revision:
            return self.remote.revision
        return None

    #: 推送目标分支（repo 语义：upstream > dest-branch > revision）
    @property
    def branch(self):
        return self.upstream or self.dest_branch or self.revision_expr

    def remote_name(self):
        return self.remote.name if self.remote else None


def strip_refs_heads(value):
    """`refs/heads/main` -> `main`；其它原样返回。"""
    if not value:
        return value
    for prefix in ("refs/heads/", "refs/tags/"):
        if value.startswith(prefix):
            return value[len(prefix):]
    return value


def norm_path(value):
    """把清单里的 path 归一化：去掉 `./`、多余的 `/`，去掉结尾斜杠。"""
    if value is None:
        return None
    p = value.replace("\\", "/").strip()
    while p.startswith("./"):
        p = p[2:]
    p = p.strip("/")
    return os.path.normpath(p) if p else p


# ---------------------------------------------------------------------------
# 解析
# ---------------------------------------------------------------------------
class ManifestParser(object):
    def __init__(self, root):
        self.root = root
        self.repdir = os.path.join(root, ".repo")
        self.remotes = {}
        self.projects = {}            # name -> Project
        self.default_revision = None
        self.default_remote = None
        self.default_upstream = None
        self.default_dest_branch = None
        self.loaded_files = []

    # -- 找文件 ------------------------------------------------------------
    def manifest_file(self, explicit=None):
        if explicit:
            cand = explicit if os.path.isabs(explicit) else os.path.join(self.root, explicit)
            if not os.path.exists(cand):
                raise ManifestError("manifest 文件不存在: %s" % cand)
            return os.path.realpath(cand)
        # repo 的标准位置：.repo/manifest.xml（一般是指向 manifests/ 的软链）
        cand = os.path.join(self.repdir, "manifest.xml")
        if os.path.exists(cand):
            return os.path.realpath(cand)
        # 退路：发布包/手工解包时可能只剩 .repo/manifests/
        mdir = os.path.join(self.repdir, "manifests")
        if os.path.isdir(mdir):
            for name in ("default.xml", "manifest.xml"):
                cand = os.path.join(mdir, name)
                if os.path.exists(cand):
                    return os.path.realpath(cand)
        raise ManifestError("在 %s 下找不到 .repo/manifest.xml" % self.root)

    def load(self, manifest_file=None, local_manifests=True):
        path = self.manifest_file(manifest_file)
        self._parse_file(path, set())
        if local_manifests:
            ldir = os.path.join(self.repdir, "local_manifests")
            if os.path.isdir(ldir):
                for name in sorted(os.listdir(ldir)):
                    if name.endswith(".xml"):
                        self._parse_file(os.path.join(ldir, name), set(),
                                         optional=True)
        return self

    def _parse_file(self, path, seen, optional=False, inherit_revision=None):
        path = os.path.realpath(path)
        if path in seen:            # 防 include 成环
            return
        seen.add(path)
        try:
            tree = ET.parse(path)
        except (ET.ParseError, OSError) as exc:
            if optional:
                return
            raise ManifestError("解析失败: %s: %s" % (path, exc))
        self.loaded_files.append(path)
        node = tree.getroot()
        if node.tag != "manifest":
            raise ManifestError("%s 的根节点不是 <manifest>" % path)
        self._walk(node, os.path.dirname(path), seen,
                   inherit_revision=inherit_revision)

    def _walk(self, node, base_dir, seen, inherit_revision=None):
        for child in node:
            tag = child.tag
            # repo 的规矩：<include revision="X"> 里所有没写 revision 的
            # project/include 都继承这个 X
            if inherit_revision and not child.get("revision"):
                child.set("revision", inherit_revision)
            if tag == "include":
                self._parse_include(child, base_dir, seen)
            elif tag == "remote":
                self._parse_remote(child)
            elif tag == "default":
                self._parse_default(child)
            elif tag == "project":
                self._parse_project(child)
            elif tag == "remove-project":
                name = child.get("name")
                self.projects.pop(name, None)
            elif tag == "extend-project":
                self._parse_extend_project(child)
            # 其它标签（repo 新加的、厂商私有的）一律忽略

    def _parse_include(self, node, base_dir, seen):
        name = node.get("name")
        if not name:
            return
        # repo 把 include 的 name 解释成"相对清单项目目录"；
        # 手工拼出来的工作区里也可能相对当前文件，两条路都试
        candidates = [
            os.path.join(self.repdir, "manifests", name),
            os.path.join(base_dir, name),
        ]
        cand = next((c for c in candidates if os.path.exists(c)), None)
        if cand is None:
            raise ManifestError("include 的清单不存在: %s" % name)
        self._parse_file(cand, seen, inherit_revision=node.get("revision"))

    def _parse_remote(self, node):
        name = node.get("name")
        if not name:
            return
        self.remotes[name] = Remote(name, node.get("fetch"), node.get("revision"))

    def _parse_default(self, node):
        if node.get("revision"):
            self.default_revision = node.get("revision")
        if node.get("remote"):
            self.default_remote = node.get("remote")
        if node.get("upstream"):
            self.default_upstream = node.get("upstream")
        if node.get("dest-branch"):
            self.default_dest_branch = node.get("dest-branch")

    def _remote_for(self, node):
        name = node.get("remote") or self.default_remote
        if not name:
            return None
        return self.remotes.get(name)

    def _parse_project(self, node):
        name = node.get("name")
        if not name:
            return
        path = norm_path(node.get("path")) or name
        remote = self._remote_for(node)
        revision = (node.get("revision") or (remote.revision if remote else None)
                    or self.default_revision)
        upstream = node.get("upstream") or self.default_upstream
        dest_branch = node.get("dest-branch") or self.default_dest_branch
        groups = (node.get("groups") or "").split(",")
        linkfiles = [(lf.get("src"), lf.get("dest")) for lf in node
                     if lf.tag in ("linkfile", "copyfile")]

        old = self.projects.get(name)
        if old is not None:
            # 同一 name 在后面的文件里再出现 = 扩展它
            old.path = path
            old.relpath = path
            if remote is not None:
                old.remote = remote
            if revision:
                old.revision = revision
            if upstream:
                old.upstream = upstream
            if dest_branch:
                old.dest_branch = dest_branch
            for g in groups:
                if g and g not in old.groups:
                    old.groups.append(g)
            old.linkfiles = linkfiles or old.linkfiles
            return

        self.projects[name] = Project(
            name, path, remote, revision=revision, upstream=upstream,
            dest_branch=dest_branch, groups=groups, linkfiles=linkfiles)

    def _parse_extend_project(self, node):
        name = node.get("name")
        project = self.projects.get(name)
        if project is None:
            return
        path = norm_path(node.get("path"))
        if path:
            project.path = project.relpath = path
        for g in (node.get("groups") or "").split(","):
            if g and g not in project.groups:
                project.groups.append(g)

    # -- 查询 --------------------------------------------------------------
    def find_by_name(self, name):
        """按清单 name 找；`.git` 后缀和 remote 前缀都容忍。"""
        if name in self.projects:
            return self.projects[name]
        for cand in (name + ".git", name[:-4] if name.endswith(".git") else None):
            if cand and cand in self.projects:
                return self.projects[cand]
        for p in self.projects.values():
            if p.path == norm_path(name):
                return p
        return None

    def find_by_path(self, path):
        want = norm_path(path)
        if not want:
            return None
        # 允许传 cwd 相对的路径
        if not os.path.isabs(path):
            cwd = os.path.realpath(os.getcwd())
            root = os.path.realpath(self.root)
            if cwd != root and cwd.startswith(root + os.sep):
                rel = os.path.relpath(cwd, root).replace("\\", "/")
                candidates = [norm_path(os.path.join(rel, want)), want]
            else:
                candidates = [want]
        else:
            candidates = [norm_path(os.path.relpath(os.path.realpath(path), self.root))]
        for candidate in candidates:
            for p in self.projects.values():
                if norm_path(p.path) == candidate:
                    return p
        return None


# ---------------------------------------------------------------------------
# root 探测
# ---------------------------------------------------------------------------
def find_root(start=None):
    cur = os.path.realpath(start or os.getcwd())
    if os.path.isfile(cur):
        cur = os.path.dirname(cur)
    while True:
        if os.path.isdir(os.path.join(cur, ".repo")):
            return cur
        parent = os.path.dirname(cur)
        if parent == cur:
            return None
        cur = parent


def resolve_root(arg_root, hint_path=None):
    if arg_root:
        root = os.path.realpath(os.path.abspath(arg_root))
        if not os.path.isdir(os.path.join(root, ".repo")):
            raise ManifestError("%s 下没有 .repo（不是 repo 工作区）" % root)
        return root
    start = None
    if hint_path:
        hp = hint_path
        if not os.path.isabs(hp):
            hp = os.path.abspath(hp)
        start = hp if os.path.isdir(hp) else os.path.dirname(hp)
    root = find_root(start)
    if root is None:
        raise ManifestError("从 %s 往上没找到 .repo" % (start or os.getcwd()))
    return root


# ---------------------------------------------------------------------------
# URL
# ---------------------------------------------------------------------------
def project_url(project):
    """按 repo 的规则拼 clone URL：<remote.fetch>/<name>[.git]"""
    if project.remote is None or not project.remote.fetch:
        return None
    fetch = project.remote.fetch
    if not fetch.endswith("/"):
        fetch += "/"
    name = project.name
    # fetch 末尾是 "/" 时 repo 用 name 原样拼（AOSP 的 name 自带 .git 与否都可能）
    return fetch + name


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def build_parser():
    parser = argparse.ArgumentParser(
        prog=PROG, description="读取 repo manifest 的小工具（自包含）")
    parser.add_argument("action", choices=[
        "name_from_path", "path_from_name",
        "branch_from_path", "branch_from_name",
        "remote_from_path", "remote_from_name",
        "url_from_name", "list", "root",
    ])
    parser.add_argument("value", nargs="?", default=None,
                        help="路径 / 项目名（list、root 不需要）")
    parser.add_argument("--root", default=None,
                        help="repo 工作区根目录（默认从当前目录往上找 .repo）")
    parser.add_argument("--manifest", default=None,
                        help="指定清单文件（默认 .repo/manifest.xml）")
    parser.add_argument("--format", default="tsv", choices=["tsv", "json"],
                        help="list 的输出格式（默认 tsv）")
    return parser


def need_value(args):
    if args.value is None:
        sys.stderr.write("%s: %s 需要一个 <path|name> 参数\n"
                         % (PROG, args.action))
        sys.exit(2)


def emit(text):
    if text is not None:
        sys.stdout.write("%s\n" % text)


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        root = resolve_root(args.root, args.value)
        manifest = ManifestParser(root).load(args.manifest)
    except ManifestError as exc:
        sys.stderr.write("%s: %s\n" % (PROG, exc))
        return 1

    if args.action == "root":
        emit(root)
        return 0

    if args.action == "list":
        rows = []
        for p in manifest.projects.values():
            rows.append({
                "path": p.path,
                "name": p.name,
                "branch": strip_refs_heads(p.branch) or "",
                "revision": p.revision_expr or "",
                "remote": p.remote_name() or "",
                "url": project_url(p) or "",
                "groups": ",".join([g for g in p.groups if g]),
            })
        if args.format == "json":
            emit(json.dumps(rows, ensure_ascii=False, indent=2))
        else:
            for row in rows:
                emit("\t".join([row["path"], row["name"], row["branch"],
                                row["remote"], row["url"]]))
        return 0

    need_value(args)

    if "_from_path" in args.action:
        project = manifest.find_by_path(args.value)
        what = "路径"
    else:
        project = manifest.find_by_name(args.value)
        what = "项目名"

    if project is None:
        sys.stderr.write("%s: 清单里没有这个%s: %s\n"
                         % (PROG, what, args.value))
        return 1

    if args.action.startswith("name_"):
        emit(project.name)
    elif args.action.startswith("path_"):
        emit(project.path)
    elif args.action.startswith("branch_"):
        emit(strip_refs_heads(project.branch))
    elif args.action.startswith("remote_"):
        emit(project.remote_name())
    elif args.action.startswith("url_"):
        emit(project_url(project))
    return 0


if __name__ == "__main__":
    sys.exit(main())
