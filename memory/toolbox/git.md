---
name: git
description: Git 日常与救急速查（配置、提交、分支、日志、撤销、stash、强制同步远端），标注危险操作与恢复办法
metadata:
  type: reference
---

# Git 速查

## 1. 配置

```bash
git config --list --show-origin            # 看所有配置及来自哪个文件
git config <KEY> <VALUE>                   # 默认写当前仓库 .git/config；--global 写 ~/.gitconfig
git config --global user.name  "<NAME>"
git config --global user.email "<EMAIL>"
git config --global pull.rebase false      # 2.27+ 未设置时 git pull 会告警；按团队习惯选 merge/rebase
```

## 2. 日常开发

```bash
git status
git diff              # 工作区 vs 暂存区
git diff --staged     # 暂存区 vs 最近提交（提交前自查）
git add <FILE>        # git add . 会把当前目录下所有改动（含新文件）加入，先看 status
git commit -m "<MSG>"            # 说明含空格必须加引号
git commit --amend               # 改最近一次提交（说明 + 已暂存内容），会改写提交哈希
git pull
git push -u origin <BRANCH>      # 首次推送并建立跟踪
```
- `--amend` / rebase 改写的是历史，**已推送的提交不要改**；确需改时用 `git push --force-with-lease`，不要用 `--force`。

## 3. 分支

```bash
git branch -vv                 # 本地分支及跟踪关系、领先/落后
git switch <BRANCH>            # 2.23+；git switch -c <BRANCH> 新建并切换
git branch -d <BRANCH>         # 仅删除已合并的分支
git branch -D <BRANCH>         # !! 强制删除未合并分支（可从 reflog 找回）
git push origin --delete <BRANCH>   # 删除远端分支
```

## 4. 日志

```bash
git log --oneline --graph --all --decorate   # 注意是 --oneline，不是 --online
git log -p -- <FILE>                         # 某文件的变更历史
git log -S '<STRING>'                        # 找引入/删除某字符串的提交
git blame -L <START>,<END> <FILE>
git reflog                                   # 本地 HEAD 移动记录，误操作后的救命稻草
```

## 5. 撤销

| 目的 | 命令 | 风险 |
|---|---|---|
| 丢弃工作区修改 | `git restore <FILE>`（2.23+，旧版 `git checkout -- <FILE>`） | 未暂存的改动无法恢复 |
| 取消暂存，保留修改 | `git restore --staged <FILE>` | 安全 |
| 撤销最近提交，改动回到暂存区 | `git reset --soft HEAD~1` | 安全 |
| 撤销最近提交，改动回到工作区 | `git reset HEAD~1`（默认 --mixed） | 安全 |
| !! 回退到上一提交并丢弃所有改动 | `git reset --hard HEAD~1` | 丢弃最近一次提交**和**所有未提交改动；提交可用 reflog 找回，未提交改动不可找回 |
| 撤销已推送的提交 | `git revert <COMMIT>` | 生成反向提交，不改历史，共享分支用这个 |

误 reset 找回：`git reflog` 找到之前的 HEAD，`git reset --hard <REFLOG_HASH>`。

## 6. stash

```bash
git stash push -u -m "<MSG>"   # -u 包含未跟踪文件（默认不含新文件）
git stash list
git stash show -p stash@{n}    # 看内容
git stash apply stash@{n}      # 应用但保留记录
git stash pop                  # 应用并删除记录（有冲突时不会删除）
git stash drop stash@{n}       # !! 删除单条
git stash clear                # !! 清空全部
```
- 误 drop/clear 后可尝试：`git fsck --unreachable | grep commit`，找到后 `git stash apply <HASH>`。

## 7. !! 强制让本地与远端一致（丢弃本地一切）

```bash
git fetch origin
git status                         # 确认当前分支和本地有哪些改动
git stash push -u -m backup        # 可选：先留底
git reset --hard origin/<BRANCH>   # 丢弃本地提交与已跟踪文件的修改
git clean -nd                      # 先预览将删除的未跟踪文件/目录
git clean -fd                      # 真删除；-x 连 .gitignore 忽略的文件一起删（会删 .env、构建产物）
```
- `git clean` 删除的文件不进回收站、reflog 也救不回来，**务必先 -n**。
- 分支名不要写死 main，先 `git branch -vv` 确认跟踪的远端分支。
