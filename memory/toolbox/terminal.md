---
name: terminal
description: 终端效率：bash 快捷键与作业控制、目录栈、tar 查看/局部解压、日志查看、glow、tmux 操作与配置、vim 操作与 YAML 父节点跳转 vimrc
metadata:
  type: reference
---

# 终端操作

## 1. bash 快捷键 / 作业控制

| 按键 | 作用 |
|---|---|
| `Ctrl+r` | 反向搜索历史命令 |
| `Ctrl+a` / `Ctrl+e` | 行首 / 行尾 |
| `Ctrl+w` | 删除光标前一个词（以空白分隔） |
| `Ctrl+_`（多数终端按 `Ctrl+Shift+-`） | 撤销编辑 |
| `!!` / `!$` | 上一条命令 / 上一条命令最后一个参数 |
| `Ctrl+z` | **暂停**当前前台任务（Stopped，不是在后台运行） |

```bash
jobs        # 查看作业
bg %1       # 让暂停的作业在后台继续运行
fg %1       # 调回前台
```

## 2. 目录栈 pushd / popd

```bash
dirs -v          # 带序号列出
dirs +N          # 打印第 N 个
dirs -c          # 清空
pushd <DIR>      # 压栈并切换
pushd            # 交换栈顶两项并切换（在两个目录间来回跳）
pushd +N         # 旋转栈，使第 N 个到栈顶并切换
popd             # 弹出栈顶并切换到新栈顶；popd -n 只弹不切
popd +N          # 删除第 N 个
```

## 3. tar

```bash
tar tf <ARCHIVE>.tgz                         # 列内容（GNU tar 读取时自动识别压缩格式）
tar tf <ARCHIVE>.tgz | cut -d/ -f1 | sort -u            # 只看第一层
tar tf <ARCHIVE>.tgz | cut -d/ -f1-2 | sort -u          # 看前两层（常见：包内只有一个顶层目录）

# 只解压指定成员：-C 必须放在成员名之前，放在后面 GNU tar 会解压到当前目录
tar xvf <ARCHIVE>.tgz -C <DEST_DIR> <MEMBER_PATH>      # MEMBER_PATH 是 tf 列出的包内相对路径
```

## 4. 日志查看

```bash
journalctl --since "<YYYY-MM-DD HH:MM:SS>" --until "<YYYY-MM-DD HH:MM:SS>" -x --no-pager
journalctl -u <UNIT> --since "1 hour ago" --no-pager
```
- 不要和 `--since` 混用 `-e`：`-e` 隐含 `-n1000`，只会显示最后 1000 行，时间段前面的日志看不到。

```bash
dmesg -T -x --level=emerg,alert,crit,err,warn   # 内核环形缓冲区（硬件/驱动/OOM/IO 错误），-T 人类可读时间
```
- `-T` 的时间在挂起/恢复过的机器上可能不准。

## 5. glow（终端渲染 Markdown）

```bash
glow -p -w "$(tput cols)" <FILE>.md     # 分页 + 按终端宽度换行
glow -t <FILE>.md                       # TUI 模式（长行可能被截断）
```

## 6. tmux

**会话管理**
```bash
tmux new -s <SESSION>
tmux ls
tmux attach -t <SESSION>
tmux kill-session -t <SESSION>
tmux kill-server                 # 结束所有会话
tmux source-file ~/.tmux.conf    # 重载配置
tmux list-keys                   # 所有按键绑定
```

**会话内（前缀 `Ctrl+b`，下表均为「先按前缀再按键」）**

| 键 | 作用 |
|---|---|
| `?` | 帮助 |
| `d` | 脱离会话 |
| `s` | 列出/切换所有会话 |
| `c` / `w` / `,` / `&` | 新建窗口 / 选择窗口 / 重命名窗口 / 关闭窗口 |
| `%` | 左右分屏（等同 `split-window -h`） |
| `"` | 上下分屏（等同 `split-window`） |
| `方向键` / `q` | 切换窗格 / 显示窗格编号 |
| `z` | 当前窗格最大化/还原 |
| `x` | 关闭窗格 |
| `空格` | 循环切换布局 |
| `PgUp` | 进入复制模式并上翻（进入后 PgUp/PgDn 翻页，`q` 退出） |
| `[` / `]` / `=` | 进入复制模式 / 粘贴最近缓冲 / 选择缓冲区粘贴 |
| `:` | 命令模式，如 `:source-file ~/.tmux.conf`、`:split-window -h` |

**复制模式选择（进入复制模式后直接按，不再按前缀）**
- emacs 键位（默认）：`Ctrl+Space` 开始选择 → `Alt+w` 复制。
- vi 键位（`set -g mode-keys vi`，或 EDITOR/VISUAL 含 vi 时默认）：`Space` 开始选择 → `Enter` 复制。

**~/.tmux.conf**（先装 TPM：`git clone <TPM 仓库 tmux-plugins/tpm> ~/.tmux/plugins/tpm`，装插件 `前缀 + I`）
```tmux
set -g default-terminal "tmux-256color"   # tmux 官方建议用 tmux-256color/screen-256color；老系统无该 terminfo 时退回 screen-256color
set -g mouse on                           # 开启后终端原生选择需按住 Shift
set -g status-right "#{?client_prefix,#[bg=red][PREFIX]#[default] ,}#{=21:pane_title} %H:%M %d-%b-%y"   # 按下前缀时状态栏显示 [PREFIX]
set -g status-position top

# 前缀 + m 切换鼠标模式（需要复制终端文本时临时关掉）
bind m if-shell -F "#{||:#{==:#{mouse},on},#{==:#{mouse},1}}" \
  "set -g mouse off; display 'mouse: OFF'" \
  "set -g mouse on;  display 'mouse: ON'"

# TPM 插件
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'alexwforsythe/tmux-which-key'   # 快捷键弹出菜单
run '~/.tmux/plugins/tpm/tpm'                   # 必须放在文件最后
```

## 7. vim

**普通模式移动**：`0` 行首、`^` 行首非空字符、`$` 行尾、`w`/`b` 下/上一个单词。

**命令行模式**
```vim
:vsp / :sp          " 左右 / 上下分屏
:vert res 40        " 当前窗口宽度设为 40 列
:term / :vert term  " 上下 / 左右分屏打开终端（vim 8.1+）
:r !<CMD>           " 把命令输出插入到当前行下方
:registers          " 查看寄存器
:browse oldfiles    " 最近打开的文件
:changes            " 修改位置列表（g; / g, 跳转）
```

**~/.vimrc：YAML 按缩进跳父节点（大 YAML/K8s manifest 很好用）**
```vim
set hlsearch          " 高亮搜索
set incsearch         " 增量搜索

" 跳到 YAML 父节点（缩进更浅的最近非空行）
function! JumpToYAMLParent()
    let lnum = line('.')
    let ind = indent(lnum)
    while lnum > 1
        let lnum -= 1
        if indent(lnum) < ind && getline(lnum) =~ '^\s*\S'
            normal! m'
            call cursor(lnum, 1)
            return
        endif
    endwhile
    echo "No parent key found"
endfunction

" 显示当前行和父节点
function! ShowYAMLParentInfo()
    let lnum = line('.')
    let ind = indent(lnum)
    while lnum > 1
        let lnum -= 1
        if indent(lnum) < ind && getline(lnum) =~ '^\s*\S'
            echo printf("Current [%d] %s | Parent [%d] %s",
                \ line('.'), trim(getline('.')), lnum, trim(getline(lnum)))
            return
        endif
    endwhile
    echo "No parent key found"
endfunction

" 用户命令与全局函数名都必须大写字母开头
command! JP call JumpToYAMLParent()
command! SP call ShowYAMLParentInfo()
```
- `normal! m'` 记录跳转前位置，可用 `''` 或 `Ctrl+o` 跳回（原版注释说"记录当前位置"但未实现）。
- 局限：纯按缩进判断；未缩进的列表项（`- ` 与父 key 同列）和注释行会被误判为父节点。`trim()` 需 vim 8.0.1630+。
