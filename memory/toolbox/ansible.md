---
name: ansible
description: Ansible 运维速查（YAML inventory、ad-hoc 命令、ansible-vault 加密变量、playbook 安全执行），基于 ansible-core 2.x
metadata:
  type: reference
---

# Ansible 运维速查

## 1. Inventory（YAML 格式）

```yaml
# hosts.yml
all:
  vars:
    ansible_user: <SSH_USER>
    ansible_python_interpreter: auto_silent
  children:
    <GROUP_A>:
      hosts:
        <HOST_1>:
          ansible_host: <HOST_1_IP>
        <HOST_2>:
          ansible_host: <HOST_2_IP>
          ansible_port: 2222
    <GROUP_B>:
      hosts:
        <HOST_3>:
```

```bash
ansible-inventory -i hosts.yml --graph          # 看分组树，确认 inventory 解析正确
ansible-inventory -i hosts.yml --host <HOST_1>  # 看某主机最终生效的变量
ansible -i hosts.yml all --list-hosts           # 看 pattern 实际命中哪些主机
```
- 文件名 `-i` 要与实际一致（`.yml` / `.yaml` 都可，但别写错）；可在 `ansible.cfg` 中设 `inventory = ./hosts.yml` 省掉 `-i`。
- `hosts:` 下每台主机后面必须有冒号（值为空也要），否则 YAML 解析成字符串报错。

## 2. Ad-hoc 常用

```bash
ansible -i hosts.yml all -m ping                               # 连通性 + Python 可用性（不是 ICMP）
ansible -i hosts.yml <GROUP_A> -m shell -a 'df -h /' -o        # -o 单行输出，便于 grep
ansible -i hosts.yml <GROUP_A> -m setup -a 'filter=ansible_distribution*'
ansible -i hosts.yml <GROUP_A> -b -m service -a 'name=<SERVICE> state=restarted' --limit <HOST_1>
ansible -i hosts.yml all -m ping -f 20                         # -f 并发数，默认 5
```
- `-m command`（默认）不经 shell，管道/重定向/变量要用 `-m shell`。
- pattern：`<GROUP_A>:<GROUP_B>` 并集、`<GROUP_A>:&<GROUP_B>` 交集、`<GROUP_A>:!<HOST_1>` 排除（shell 中加单引号）。

## 3. ansible-vault 加密变量

```bash
ansible-vault create vault.yml           # 新建加密文件（交互设置密码）
ansible-vault edit vault.yml             # 编辑
ansible-vault view vault.yml             # 只读查看
ansible-vault encrypt / decrypt <FILE>   # 加/解密已有文件
ansible-vault rekey vault.yml            # 换密码
ansible-vault encrypt_string '<SECRET>' --name 'db_password'   # 生成可直接贴进普通 vars 文件的加密字符串
```

使用：
```bash
ansible -i hosts.yml <GROUP_A> -m ping -e @vault.yml --ask-vault-pass
ansible-playbook -i hosts.yml site.yml -e @vault.yml --vault-password-file ~/.vault_pass   # 文件权限 600，勿入库
```
- 更推荐把 vault 文件放 `group_vars/<GROUP>/vault.yml`，自动加载，无需 `-e @`；变量命名约定 `vault_xxx`，在 `vars.yml` 里 `xxx: "{{ vault_xxx }}"` 引用，便于 grep。
- `-e` 优先级最高，会覆盖 inventory/role 中同名变量。
- `encrypt_string` 的明文会进 shell history，可用 `--stdin-name` 从标准输入读。

## 4. Playbook 安全执行

```bash
ansible-playbook -i hosts.yml site.yml --syntax-check
ansible-playbook -i hosts.yml site.yml --list-hosts --list-tasks
ansible-playbook -i hosts.yml site.yml --check --diff --limit <HOST_1>   # 演练（shell/command 模块在 check 下默认跳过）
ansible-playbook -i hosts.yml site.yml --limit <HOST_1> --start-at-task '<TASK_NAME>'
ansible-playbook -i hosts.yml site.yml --tags <TAG> -v
```
- 先 `--limit` 单台灰度，再全量；play 里用 `serial: 1` 或 `serial: "25%"` 滚动执行，`max_fail_percentage` 控制熔断。
- 失败后 `--limit @site.retry` 只重跑失败主机（需开启 `retry_files_enabled`）。
