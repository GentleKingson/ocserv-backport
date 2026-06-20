# trixie 构建机准备到 dry-run 通过 — 操作手册

本手册带新工程师从一台 Debian 13 trixie amd64 裸机构建主机开始，一步步完成
builder 用户配置、bootstrap、sbuild chroot、GPG/aptly 本地状态和 dry-run 验证，
最终跑通 `make dry-run`。

**读者：** 接手 ocserv backport 项目的新工程师，熟悉 Linux 但不熟悉本项目。
**终点：** `make dry-run` 退出码 0，全程不触碰 R2 / Cloudflare / GitHub runner /
staging / production 或正式 aptly DB。
**写作约定：**
- 命令在 trixie amd64 上执行；执行用户在每章开头标注（root 或 builder）。
- 需要权限的命令显式标 `sudo`。
- "为什么" 用引用块（`>`）简短说明。
- 验收点用 ✅ 标记，是进入下一步的前置条件。
- 凡占位符（如 `YYYYMMDDTHHMMSSZ`、`ssh-ed25519 AAAA...`、`<host>`）必须替换为
  真实值，不得原样复制执行。文档会在出现处明确提示。

**访问方式与用户切换（重要）：**
手册里的切换命令按你**怎么连到这台机器**分两种场景，请先确认你属于哪种：

| 场景 | 怎么连进来的 | 切到 builder | 退出回 root |
|------|-------------|-------------|-------------|
| A. 远程工作站 | 从外部电脑 ssh 进这台机器 | `ssh builder@<host>`（外部连入）| `exit` 回到外部 |
| B. 本机控制台 | 云平台 web shell / 控制台直登 / 本地终端 | `su - builder`（本机切换）| `exit` 回到 root |

两种场景的命令不能混用——尤其**不要在机器内部 `ssh builder@<本机IP>`**：那是绕出去再连回来，
要求 builder 配 authorized_keys 给本机 root 用，而这套 key 是给**外部**连入用的，本机
root 不一定有匹配的私钥，会得到 `Permission denied (publickey)`。本机切换一律用 `su -`。

文档后面遇到切换点会标注"（场景 A：ssh / 场景 B：su）"。**sbuild group 刷新**那个特定节点
（第 3 步 3.3）两种场景都用同一个原理：退出当前 builder 会话再重开一个，让新会话重新读取
`/etc/group` 拿到最新组成员身份。

**成功定义：** 能在本机完成源码获取、changelog rewrap、source package、sbuild binary
build、lint/smoke-basic、本地临时 aptly repo/snapshot 验证；dry-run 用临时 aptly root
验证 repo/snapshot 逻辑，不 publish，不触碰正式 aptly DB。

**本文档不含：** production promote/rollback、Ansible staging/production upgrade、
GitHub runner 注册与 secrets 配置。这些是 dry-run 之后的阶段，见
`docs/BUILD_HOST_BOOTSTRAP.md` 及 CI workflow 文档。

> 相关文档：`docs/BUILD_HOST_BOOTSTRAP.md` 是 bootstrap 脚本的快速参考；本手册是"从裸机到 dry-run"的完整线性流程。两者覆盖范围不同。

---

## 第 1 步：裸机准备（以 root 执行）

```text
本步执行用户：root（SSH 登录即 root，或用云平台控制台账号）
完成本步后：builder 用户就位、passwordless sudo 生效、（可选）仓库已克隆，
            但 bootstrap 脚本尚未运行
本步产出：正好满足 bootstrap 的 preflight 前置条件
          （OS=debian/trixie、arch=x86_64、user=builder、非 root、
           passwordless sudo、磁盘 ≥15GB）
```

### 1.1 运行脚本前的只读确认

先确认机器形态（脚本 preflight 也会查，但提前看一眼省得建完用户才发现机器不对）：

```bash
. /etc/os-release; echo "$ID $VERSION_CODENAME"   # 期望：debian trixie
uname -m                                            # 期望：x86_64
df -h /                                             # 确认根盘 ≥40GB（见磁盘阈值）
```

**磁盘阈值（三层表述）：**

```text
脚本硬阈值：
  /var/aptly 与 /var/lib/sbuild 所在文件系统 <15GB 会 die（preflight 直接失败）

可运行下限：
  30GB 左右基本可跑通 dry-run，但后续缓存、构建产物、aptly 累积会紧张

培训推荐：
  root 盘或承载 /var 的磁盘 ≥40GB
```

> bootstrap preflight 的双阈值：<15GB die，15-30GB warn，≥30GB pass。

### 1.2 运行 bootstrap-bare-metal.sh

脚本会装 sudo/git/ca-certificates、建 builder 用户、配 passwordless sudo（临时文件 +
visudo -cf 验证）、配 SSH authorized_keys（追加去重，不覆盖已有 key）、可选 clone 仓库。
全部幂等，可安全重跑。

```bash
# 三种公钥来源任选其一（互斥）；--repo-url 可选（提供则自动 clone）
# ⚠️ 占位符：公钥 / <仓库 URL> 必须替换为真实值
scripts/bootstrap-bare-metal.sh --ssh-pubkey-file /path/to/id_ed25519.pub --repo-url <仓库 URL>
# 或
scripts/bootstrap-bare-metal.sh --ssh-pubkey 'ssh-ed25519 AAAA... replace-with-your-real-public-key' --repo-url <仓库 URL>
# 或
ADMIN_PUBKEY='ssh-ed25519 AAAA... replace-with-your-real-public-key' \
  scripts/bootstrap-bare-metal.sh --repo-url <仓库 URL>
```

可选参数：

```text
--builder-user <name>   builder 用户名（默认 builder；改了的话 .bootstrap.env 的
                        BOOTSTRAP_BUILDER_USER 必须一致）
--host-hint <host>      仅用于脚本结尾打印的 ssh 提示，不参与实际连接
```

> 脚本做了什么、为什么这么做：见 **附录 C** 的等价手动操作（排障/原理参考）。

✅ 验收（脚本退出码 0 + 以下检查）：

```bash
su - builder -c 'sudo -n true' && echo "sudo OK"   # passwordless sudo 生效
# 验证能切到 builder 身份（场景 A：从外部连 / 场景 B：本机切换）：
#   场景 A: ssh builder@<host> whoami   # <host> 替换为构建机真实地址
#   场景 B: su - builder -c whoami      # 本机切换
# 期望输出 builder
```

### 1.3 本步退出条件总览

```text
进入第 2 步前，必须全部满足：
  □ bootstrap-bare-metal.sh 退出码 0
  □ OS=debian trixie, arch=x86_64（脚本 preflight 已校验）
  □ builder 用户存在，有 passwordless sudo（sudo -n true 成功）
  □ 能以 builder 身份 SSH 登录
  □ （若提供 --repo-url）~/ocserv-backport 已克隆，git status clean
  □ 当前 shell 身份可切到 builder（准备进入第 2 步）
```

> 排障 / 理解脚本原理：第 1 步的等价手敲命令见 **附录 C**。

---

## 第 2 步：bootstrap 配置、GPG 模式选择与预演（以 builder 执行）

```text
本步执行用户：builder（第 1 步已切过来，此后全程 builder）
完成本步后：.bootstrap.env 就位、已选定 GPG 模式、
            已用 bootstrap --dry-run 预演过构建机初始化（无副作用），
            但尚未真实运行 bootstrap
```

### 2.0 重要区分：两个不同的 dry-run（本步开头必读）

```text
本项目的 "dry-run" 有两个不同含义，不要混淆：

1. bootstrap dry-run
   命令：scripts/bootstrap-build-host.sh --dry-run [GPG 模式]
   预演对象：构建机初始化（装包/建 chroot/生成 GPG/aptly 初始化）
   副作用：无，只打印将执行的动作
   本步末尾用它预演 bootstrap

2. 项目 dry-run
   命令：make dry-run  （即 scripts/dry-run.sh）
   预演对象：构建流水线（fetch→sbuild→lint→smoke→aptly 临时 DB）
   副作用：无，不触碰 R2/staging/prod/正式 aptly DB
   第 4 步末尾用它验收整条链

二者顺序：先 bootstrap 把机器装好（第 3 步），再 make dry-run 跑流水线（第 4 步）。
本步只涉及第 1 个（bootstrap dry-run）。
```

### 2.1 创建 .bootstrap.env（builder）

```bash
cd ~/ocserv-backport
# 幂等：已存在则不覆盖（避免重跑冲掉本地填的真实值）
[[ -f .bootstrap.env ]] || cp .bootstrap.env.example .bootstrap.env
chmod 600 .bootstrap.env
```

> 为什么 chmod 600：bootstrap 的 load_config 阶段会校验 .bootstrap.env 的权限
> （mode 600 + owner=当前用户），不满足会 die。

编辑 .bootstrap.env，至少填这几项（非敏感必填）：

```text
BOOTSTRAP_BUILDER_USER=builder          # 与第 1 步建的用户一致
BOOTSTRAP_APTLY_ROOT=/var/aptly         # 默认值，一般不改
BOOTSTRAP_REPO_NAME=ocserv-backports    # 默认值，一般不改
BOOTSTRAP_GPG_KEYID=                    # 见 2.2，按模式决定是否填
```

> .bootstrap.env 是 gitignored 的，不会进仓库。它是操作者填真实值的本地文件。
> 默认值可推导的项不填也行（load_config 会补），但显式写出更清晰。

✅ 验收：

```bash
stat -c '%a %U' .bootstrap.env          # 期望：600 builder
```

### 2.2 选择 GPG 模式（builder，决策，不执行）

bootstrap 的 setup_gpg_key 阶段要求三选一（互斥）：

```text
--generate-gpg-key       生成新 signing key
--import-gpg-key <path>  导入已有私钥文件
--reuse-gpg-key <KEYID>  复用本机已有 key
```

**决策树：**

```text
这是全新的培训/实验 builder，且还没有任何已发布的 THEHKUS-Backports 签名身份？
  是 → --generate-gpg-key

这是接手现有生产 backport 仓库，或要延续旧仓库签名身份？
  是 → 不要 generate；使用 --import-gpg-key 或 --reuse-gpg-key
```

> 为什么不随便 generate：GPG signing key 是长期身份，一旦用它签名发布的 deb 进入
> 生产，就不能轻易换（换了旧 deb 验签失败）。generate 只在 "首次/全新 identity" 用；
> 生产接手默认是 import/reuse，而不是 generate。
> 迁移机器时必须导入/复用旧 key，而不是生成新 key。

**特别注意：generate 模式不会询问 passphrase**

培训默认的 `--generate-gpg-key` 会生成无保护 key（脚本用 `%no-protection`），
不会读取 `BOOTSTRAP_GPG_PASSPHRASE`，也不会交互式询问 passphrase。

因此 generate 模式只适合受控 dedicated builder；构建机的磁盘、备份和访问权限必须受控。

import/reuse 模式：导入或复用的 key 若带口令保护，口令会在后续真正使用该 key 签名
（如 aptly publish）时由 gpg-agent 按需提示；`BOOTSTRAP_GPG_PASSPHRASE` 可在
.bootstrap.env 预填，供 CI 使用。

> 培训默认路径（首次 + generate）无需任何 GPG 输入，这也是为什么本步 dry-run
> 预演能完全无人值守跑通。

**BOOTSTRAP_GPG_KEYID 按模式：**

```text
generate:  留空（脚本运行时解析新生成 key 的 fingerprint 并回填）
import:    填待导入 key 的 full fingerprint（推荐 full，短 keyid 有碰撞风险）
reuse:     填本机已有 key 的 full fingerprint
```

✅ 验收（决策，无命令）：已确定 GPG 模式；若选 import/reuse，BOOTSTRAP_GPG_KEYID 已填 fingerprint

### 2.3 bootstrap dry-run 预演（builder）

本步不真实运行 bootstrap，只预演。真实运行放第 3 步。

```bash
# 首次培训 / 新 signing identity
scripts/bootstrap-build-host.sh --dry-run --generate-gpg-key

# 导入旧 signing key（⚠️ 占位符：/path/to/private.asc 必须替换为待导入的 GPG 私钥文件路径）
scripts/bootstrap-build-host.sh --dry-run --import-gpg-key /path/to/private.asc

# 复用本机已有 signing key（⚠️ 占位符：<FULL_FINGERPRINT> 必须替换为 GPG key 完整 fingerprint）
scripts/bootstrap-build-host.sh --dry-run --reuse-gpg-key <FULL_FINGERPRINT>
```

> import/reuse 模式需要 .bootstrap.env 中已填 BOOTSTRAP_GPG_KEYID；generate 模式留空。

**预期输出特征（以 generate 为例）：**

```text
- args: dry_run=1 gpg_mode=generate ...
- 各阶段打印 "DRY-RUN: ..." 或只读检查结果
- GPG 阶段："DRY-RUN: would generate GPG signing key for THEHKUS-Backports"
  （不生成真 key，不读 passphrase）
- 结尾打印 GitHub 手动步骤清单（print_manual_github_steps 是纯输出，始终执行）
- 退出码 0，全程无 die
```

> 为什么先 dry-run：bootstrap 会装几十个包、建 chroot、生成 GPG、初始化 aptly，都是有
> 状态变更的操作。--dry-run 让你在无副作用前提下确认参数解析、阶段顺序、GPG 模式判定
> 都正确，再到第 3 步真实运行。
> dry-run 下只读检查正常执行（preflight 的 OS/磁盘校验）；修改状态的命令经 run_cmd 只
> 打印不执行；依赖 "本轮本应创建但未创建" 的资源时走 would-verify，不 die。

**常见 dry-run 失败排查（本步预演阶段就会暴露）：**

```text
- preflight die "current user is 'root'": 你在第 1 步没切到 builder，重新切过去
  （场景 A: ssh builder@<host> / 场景 B: su - builder）
- preflight die "OS must be debian" / "codename must be trixie": 机器不对
- preflight die "less than 15GB free": 磁盘不足（回到第 1 步 1.1 扩容或换盘）
- load_config die "must be chmod 600": 2.1 的 chmod 漏了
```

✅ 验收：

```bash
echo $?                                       # 期望 0
```

且：输出含 "would generate GPG signing key"（generate 模式）/ 或对应 import/reuse 逻辑；全程无 die。

### 2.4 本步退出条件总览

```text
进入第 3 步前，必须全部满足：
  □ .bootstrap.env 存在，mode=600，owner=builder
  □ BOOTSTRAP_BUILDER_USER=builder 与实际用户一致
  □ 已选定 GPG 模式（首次培训默认 generate；生产接手默认 import/reuse）
  □ 已按选定 GPG 模式完成 bootstrap dry-run，退出码 0
  □ 若选 generate：dry-run 输出含 "would generate GPG signing key"，无 die
  □ 若选 import：dry-run 输出含导入逻辑或 "key already in keyring"
  □ 若选 reuse：dry-run 输出显示复用 key 或进入 would-verify 逻辑
```

---

## 第 3 步：bootstrap 真实运行（以 builder 执行）

```text
本步执行用户：builder
完成本步后：构建机本机状态全部就位（包/chroot/GPG/aptly 目录/rclone 骨架），
            builder 已在 sbuild group 且已重新登录生效，
            check_runner / check_backups 的输出已记录（info/warn，不阻塞）

本步核心时序（首次裸机必走，因为 group 成员身份不会 retroactively 生效）：
  install_packages（装包 + 加入 sbuild 组）
    → 重新登录 / newgrp sbuild（让组在当前会话生效）
    → 从 prepare_directories 继续（setup_sbuild_chroot 现在能读 chroot 了）
```

### 3.0 阶段执行规则（全步适用）

```text
╔══════════════════════════════════════════════════════════════╗
║ 阶段执行规则（源自 bootstrap 脚本的阶段执行逻辑）              ║
║                                                                ║
║ • load_config 是基础设施，任何非 load_config 的运行都会自动      ║
║   先跑它（设 BUILDER_USER/APTLY_ROOT 等别名，防 set -u）。        ║
║ • preflight 【不】自动前置 —— 只在显式请求/全跑/--from 早于它时跑。║
║ • 因此本步每一段真实运行前，都显式 --only-stage preflight 一次。 ║
╚══════════════════════════════════════════════════════════════╝
```

### 3.1 运行方式选择

```text
bootstrap 支持两种真实运行方式，首次裸机必须用 A：

A. 分段跑（首次裸机推荐，培训默认）：
   第一段前置：scripts/bootstrap-build-host.sh --only-stage preflight
   第一段：    scripts/bootstrap-build-host.sh --only-stage install_packages
   [阶段间动作：重新登录 / newgrp sbuild，见 3.3]
   第二段前置：scripts/bootstrap-build-host.sh --only-stage preflight
   第二段：    scripts/bootstrap-build-host.sh --from-stage prepare_directories --generate-gpg-key

B. 一次全跑（仅适用于 builder 已在 sbuild group 且当前会话已生效）：
   前置确认：
     id -nG | tr ' ' '\n' | grep -qx sbuild && echo OK    # 必须先看到 OK
   命令：
     scripts/bootstrap-build-host.sh --generate-gpg-key
```

> 为什么首次裸机用 A 而不是 B：install_packages 阶段会把 builder 加入 sbuild 组
> （sudo sbuild-adduser builder）。Linux group 成员身份不会 retroactively 生效到当前
> shell。如果一次全跑，install_packages 后马上进入 setup_sbuild_chroot，此时当前会话的
> sbuild 组还没生效，chroot 文件（root:sbuild mode 0640）读不到，verify_chroot_sources
> 会失败或触发诊断分支提示 "Ensure builder is in the sbuild group"。
> 分段跑把 "让组生效" 这个动作放在正确的阶段之间。
> B 适用场景：机器重装/迁移后，之前已 sbuild-adduser 且新会话已加载组。这是
> "已生效" 的机器，不是首次裸机。

本步按 A 展开（3.2 第一段 → 3.3 阶段间动作 → 3.4 第二段）。

### 3.2 第一段：install_packages（装包 + 加入 sbuild 组）

```bash
# 显式 preflight 前置（preflight 不自动带，见 3.0）
scripts/bootstrap-build-host.sh --only-stage preflight

# 第一段：装包 + 加入 sbuild 组
scripts/bootstrap-build-host.sh --only-stage install_packages
```

**预期输出（两条命令分开看）：**

命令 1（`--only-stage preflight`）预期：

```text
load_config（自动）：  加载 .bootstrap.env
preflight（显式）：    OS=debian/trixie, arch=x86_64, user=builder, disk OK
```

命令 2（`--only-stage install_packages`）预期：

```text
load_config（自动）：  加载 .bootstrap.env
install_packages：    apt-get update + install 一组包
                     (sbuild schroot debootstrap build-essential devscripts
                      debhelper debhelper-compat dpkg-dev fakeroot lintian quilt
                      rclone aptly gnupg jq docker.io git curl ca-certificates)
若 builder 尚不在 sbuild 组：
  sudo sbuild-adduser builder
  WARN: builder was added to sbuild group; log out and back in,
        or run 'newgrp sbuild', before using sbuild without sudo
```

> 注意：--only-stage install_packages 只自动带 load_config，不自动带 preflight
> （bootstrap 脚本只强制 load_config 前置，preflight 不在其中）。所以 preflight 必须
> 显式单独跑一次。这也顺带验证了磁盘/sudo/user 仍 OK。
> install_packages 末尾的 WARN 容易被滚动的 apt 输出淹没。无论是否看到 WARN，
> 都必须执行 3.3 的验收，不能跳过。

退出码 0 后，不要继续直接跑 chroot —— 先做 3.3。

### 3.3 阶段间动作：重新登录让 sbuild group 生效（硬性，必做）

```text
这是首次裸机流程的必做步骤。
没有完成本节验收，不要进入 setup_sbuild_chroot（3.4）。
```

背景：3.2 把 builder 加入了 sbuild group，但 Linux group 成员身份在当前登录会话中
不会立即生效。setup_sbuild_chroot 和后续 make dry-run 里的 sbuild 都需要当前会话能以
sbuild 组身份读 chroot（文件是 root:sbuild 0640）。

原理：**退出当前 builder 会话，再重开一个**——新会话会重新走 PAM 读取 `/etc/group`，
拿到刚加的 sbuild 成员身份。具体怎么"退出再重开"取决于你的访问方式（见开头约定区）。

命令（按访问方式选一种；三种任选其一）：

```bash
# 场景 A（远程工作站）：exit 退出 builder 回到外部，再 ssh 连入建立新 session
exit                          # 退出 builder 会话
# ⚠️ 占位符：<host> 必须替换为构建机的主机名或 IP
ssh builder@<host>            # 从外部重新登录（新 session）
cd ~/ocserv-backport

# 场景 B（本机控制台）：exit 退出 builder 回到 root，再 su 建立新 login shell
exit                          # 退出 builder 会话，回到 root
su - builder                  # 重新 su（新 login shell，重新读 /etc/group）
cd ~/ocserv-backport

# 场景 A/B 通用（不退出当前会话，当前 shell 直接刷新 group）
newgrp sbuild
```

任一方式后，验证 sbuild 组已生效：

```bash
id -nG | tr ' ' '\n' | grep -qx sbuild && echo "sbuild group OK"
```

> 为什么三种都行：核心是"拿到新的 group 快照"。场景 A 的 ssh 是全新网络 login session；
> 场景 B 的 `su -` 是新 login shell（从 root 重新 su 进去，会重新走 PAM，**和 builder
> 里再 `su - builder` 自己切自己不同**——后者不刷新 group）；newgrp 是显式刷新当前 shell。
> 注意：**不要在机器内部 `ssh builder@<本机IP>`**——那是绕出去再连回来，本机 root 不一定
> 有匹配 builder authorized_keys 的私钥，会得到 `Permission denied (publickey)`。本机切换
> 一律用 `su -`。
> 推荐场景 A/B 的 exit+重连而非 newgrp：整个新会话都干净地带着 sbuild 组，后续 make dry-run
> 不会因 subshell/group 继承问题踩坑。

✅ 验收（必须输出 OK 才能进 3.4）：

```bash
id -nG | tr ' ' '\n' | grep -qx sbuild && echo OK
```

### 3.4 第二段：从 prepare_directories 继续（builder）

```bash
# 显式 preflight 前置（重新登录后再确认一次身份/磁盘/sudo）
scripts/bootstrap-build-host.sh --only-stage preflight

# 第二段：继续剩余 bootstrap（三选一，承接第 2 步 GPG 决策）
scripts/bootstrap-build-host.sh --from-stage prepare_directories --generate-gpg-key
# 或（⚠️ 占位符：/path/to/private.asc 必须替换为待导入的 GPG 私钥文件路径）
scripts/bootstrap-build-host.sh --from-stage prepare_directories --import-gpg-key /path/to/private.asc
# 或（⚠️ 占位符：<FULL_FINGERPRINT> 必须替换为 GPG key 完整 fingerprint）
scripts/bootstrap-build-host.sh --from-stage prepare_directories --reuse-gpg-key <FULL_FINGERPRINT>
```

**预期输出（两条命令分开看）：**

命令 1（`--only-stage preflight`）预期：

```text
load_config（自动）：  重新加载 .bootstrap.env
preflight（显式）：    再次确认重新登录后 user/disk/sudo 仍正确
```

命令 2（`--from-stage prepare_directories [GPG模式]`）预期：

```text
load_config（自动）：   重新加载 .bootstrap.env
prepare_directories：  mkdir + chown /var/aptly/{public,.locks,state}
setup_sbuild_chroot：  首次 sbuild-createchroot（耗时 5-15 分钟，下 debootstrap）
                      → verify_chroot_sources: chroot sources OK (trixie-only)
setup_gpg_key：        generate 模式不问 passphrase，打印生成 key 的 fingerprint
                      （import/reuse 模式若 key 带口令会在后续签名时由 gpg-agent 提示）
setup_aptly：          生成 ~/.aptly.conf + aptly repo create ocserv-backports
setup_rclone_skeleton：rclone.conf 写 [r2] 骨架（R2 secrets 不落盘）
check_runner：         warn "no runner detected"（正常，见下方提示框）
check_backups：        各路径 warn/info（正常，见下方提示框）
print_manual_github_steps：打印 5 段手动清单（runner/secrets/environment/labels）
```

退出码 0 = 第二段成功，即 bootstrap 全部完成。

结尾的 GitHub 手动清单是 dry-run 之外唯一需要人工后置的内容，但它不属于
"make dry-run 通过" 的范围（第 4 步不需要 runner/secrets）。

**醒目提示框：WARN 不等于失败**

```text
╔══════════════════════════════════════════════════════════════╗
║ 注意：WARN 不等于失败                                          ║
║                                                                ║
║ check_runner 的 "no runner detected" 是正常的：                 ║
║   runner 注册不由 bootstrap 负责，也不是 make dry-run 前置。    ║
║                                                                ║
║ check_backups 的路径缺失提示也是 warn：                          ║
║   bootstrap 只查源路径存在性，不验证备份系统，不阻塞。           ║
║                                                                ║
║ 真正失败以脚本 exit code 非 0 或 ERROR/die 为准。               ║
║ 第二段退出码 0 即视为本步成功，无视上述 WARN。                  ║
╚══════════════════════════════════════════════════════════════╝
```

### 3.5 drift 检查（可选，builder，幂等重跑）

```text
可选。不是第 4 步 make dry-run 的硬性前置。
价值：机器重启后或日常想确认状态没漂移时快速检查，不修改状态。
```

```bash
scripts/bootstrap-build-host.sh --only-stage preflight
scripts/bootstrap-build-host.sh --only-stage setup_sbuild_chroot
scripts/bootstrap-build-host.sh --only-stage check_runner
scripts/bootstrap-build-host.sh --only-stage check_backups
```

> 为什么单独跑 setup_sbuild_chroot：它是最容易暴露 chroot/sbuild group 状态漂移的
> 阶段（chroot 被删、sources 被改、group 丢失都会在这里报出来）。

**幂等语义（见 bootstrap 脚本的阶段定义）：**

```text
safe-repeat (install_packages / prepare_directories)：重跑天然幂等
skip-if-exists (setup_sbuild_chroot / setup_aptly / setup_rclone_skeleton)：
  存在则校验/跳过，不重建
只读 (preflight / check_runner / check_backups)：只检查不修改
fail-if-exists (GPG generate)：已有 key 会 die，drift 时用 --reuse-gpg-key
```

### 3.6 本步退出条件总览

```text
进入第 4 步前，必须全部满足：
  □ 第一段 preflight + install_packages 退出码 0
  □ builder 已在 sbuild group 且当前会话已生效（id 验证输出 OK）
  □ 第二段 preflight + --from-stage prepare_directories [GPG模式] 退出码 0
  □ sbuild trixie chroot 已创建（/var/lib/sbuild/trixie-amd64-sbuild 存在）
  □ GPG signing key 已就位（gpg --list-secret-keys 含 THEHKUS-Backports）
  □ aptly repo ocserv-backports 已创建
  □ check_runner / check_backups 的 warn 已记录（不阻塞，见提示框）
```

---

## 第 4 步：make dry-run 端到端验收（以 builder 执行）

```text
本步执行用户：builder
完成本步后：make dry-run 退出码 0，整份文档的 "成功定义" 达成
```

### 4.1 确认 dry-run 环境参数

make dry-run 之前，确认所有本地环境参数就位。

**唯一必须人工填的参数：`DEBIAN_SNAPSHOT_TIMESTAMP`**

```bash
cd ~/ocserv-backport
[[ -f .env ]] || cp .env.example .env
# ⚠️ 占位符：编辑 .env，把 YYYYMMDDTHHMMSSZ 换成锁定 ocserv 1.5.0-1 源码的真实时间戳
$EDITOR .env
# 确认已替换（不应再看到占位符）：
grep DEBIAN_SNAPSHOT_TIMESTAMP .env
```

> 什么是 snapshot 时间戳：snapshot.debian.org 为 debian archive 的每个时间点存档。
> 固定一个时间戳 = 锁定某一次 ocserv 1.5.0-1 源码输入，保证可复现。fetch-source.sh
> 用它拼出 `https://snapshot.debian.org/archive/debian/<TS>/pool/main/o/ocserv/`，
> 只拿 sid 源码，构建环境（chroot）永远看不到 sid apt 源。
> 格式示例：`YYYYMMDDTHHMMSSZ`，例如 `20251215T000000Z`。实际值必须以
> snapshot.debian.org 上 ocserv 1.5.0-1 的记录为准（见
> https://snapshot.debian.org/package/ocserv/）。不要把示例当成项目固定值。

#### 预置源码缓存（应对 snapshot.debian.org rate-limit）

snapshot.debian.org 对高频请求的 IP 会返回 HTTP 509（"abusive network requests"），
可持续数小时到数天。若 make dry-run 的 fetch 阶段遇到 509，fetch-source.sh 会
自动回退到本地缓存 build/source-cache/。

缓存是操作者信任的本地 seed：fetch-source.sh 不会自动下载填充它。
预置步骤（一次性，在未被 rate-limit 的机器上下载，或从 Debian 主 archive）：

    mkdir -p build/source-cache
    cd build/source-cache
    wget https://deb.debian.org/debian/pool/main/o/ocserv/ocserv_1.5.0-1.dsc
    wget https://deb.debian.org/debian/pool/main/o/ocserv/ocserv_1.5.0.orig.tar.xz
    wget https://deb.debian.org/debian/pool/main/o/ocserv/ocserv_1.5.0.orig.tar.xz.asc
    wget https://deb.debian.org/debian/pool/main/o/ocserv/ocserv_1.5.0-1.debian.tar.xz

（ocserv 1.5.0-1 的真实 .dsc 引用 4 个文件：.orig.tar.xz / .orig.tar.xz.asc / .debian.tar.xz，
加上 .dsc 本身。务必下齐——以 cached .dsc 的 Checksums-Sha256 stanza 为准。）

注意：
- 所需文件以 cached .dsc 的 Checksums-Sha256 stanza 为准，不要假设永远是这三个文件名。
- 缓存恢复依赖操作者批准的本地 seed。脚本验证 cached .dsc 与 artifacts 的 checksum、
  Source 和 Version 一致性，但不能在线重新证明 cached .dsc 来自当前配置的 snapshot timestamp。

**其他参数（按当前脚本默认值，无需人工填，除非要覆盖）：**

```text
OCSERV_VERSION=1.5.0-1~bpo13+1     （Makefile / 各脚本默认）
OCSERV_UPSTREAM_VERSION=1.5.0      （fetch-source.sh 默认）
OCSERV_DEBIAN_REVISION=1           （fetch-source.sh 默认）
MAINTAINER_NAME / MAINTAINER_EMAIL （rewrap-changelog.sh 默认）
arch=amd64                          （build-binary.sh --arch=amd64）
```

> 注：这些默认值随脚本演进可能变化，以当前脚本实际默认值为准。

**dry-run 专用行为（无需填，但需知晓）：**

```text
aptly 步骤用 APTLY_ROOT_DIR=$(mktemp -d) 临时目录，
绝不触碰 /var/aptly 正式 DB；退出时 trap 自动清理。
```

✅ 验收：

```bash
grep DEBIAN_SNAPSHOT_TIMESTAMP .env | grep -qv YYYYMMDDTHHMMSSZ && echo "timestamp set"
```

必须输出 "timestamp set"，即占位符已被真实值替换。

### 4.2 运行 make dry-run：8 步流水线与产物验收

```bash
make dry-run
```

make dry-run（即 scripts/dry-run.sh）顺序跑 8 步，任何一步失败立即停下并打印
`DRY-RUN FAILED at: <step>`。逐步预期如下：

| 步骤 | Make target | 预期产物 | 不触碰 |
|------|-------------|----------|--------|
| 1 | fetch | `build/source/ocserv-1.5.0/` + upstream `ocserv_1.5.0.orig.tar.xz` 及 `.asc` | 不启用 sid apt 源（只 dget 源码）；持久发布 source tree 与 upstream orig tarball(+asc) 到 `build/source/`（src-pkg 的 quilt 重打包需要 orig tarball）。sid 原版 `.dsc` / `.debian.tar.xz` 不发布为 fetch 输出（backport 会重新生成它们） |
| 2 | rewrap | debian/changelog 顶部 = `1.5.0-1~bpo13+1`，distribution = trixie | 不改 upstream tarball |
| 3 | src-pkg | `build/source/ocserv_1.5.0-1~bpo13+1.dsc` + `.debian.tar.xz` | 不构建 binary；`dpkg-source -b` 从 `build/source/` 找 upstream orig tarball（见第 1 步），缺失时报 `no upstream tarball`，可据此回查 fetch 产物完整性 |
| 4 | binary（sbuild） | `build/binary/ocserv_1.5.0-1~bpo13+1_amd64.deb` + `.changes` / `.buildinfo` | 不用宿主机直接建（只在干净 chroot） |
| 5 | lint | lintian 无 Error（Warning 可接受，记录） | 不发布 |
| 6 | smoke-basic | trixie 容器内：dpkg 版本对 / `ocserv --version` / unit 存在 / ldd 无 not found | 不启动真实 VPN 服务（无 systemd） |
| 7 | aptly temp DB | 临时 repo `ocserv-backports-dryrun` + snapshot 含 ocserv | 不触碰 /var/aptly；用 mktemp 临时 root；退出时清理 |
| 8 | snapshot-name 一致性 | 名字匹配 `ocserv-1.5.0-1~bpo13+1-build-(gh<n>\|local-<ts>)` | （纯本地校验） |

全部通过时最后一行打印：

```text
DRY-RUN PASSED — no real aptly/R2/staging/prod touched.
```

> smoke-basic 用 docker 跑 debian:trixie 容器。普通容器没有完整 systemd / /dev/net/tun，
> 所以 CI/dry-run 阶段只验安装+版本+依赖完整性，真正的 systemctl+TCP/UDP 探活留到
> staging verify（不在本文档范围）。

✅ 验收：

```bash
echo $?
```

期望 0，且输出含 `DRY-RUN PASSED — no real aptly/R2/staging/prod touched.`

### 4.3 失败定位：按步骤编号回查

make dry-run 失败时会打印 `DRY-RUN FAILED at: <step>`。按下表定位：

```text
步骤 1 fetch 失败：
  可能原因 A：DEBIAN_SNAPSHOT_TIMESTAMP 写错或仍为占位符
    回到：4.1（确认 .env 时间戳）
  可能原因 B：网络到 snapshot.debian.org 不通
    排查网络/代理
  可能原因 C：snapshot.debian.org 返回 HTTP 509（rate-limit / "abusive network requests"）
    表现：dget 日志含 "curl: (22) The requested URL returned error: 509" 等显式 509 标记
    自动恢复：fetch-source.sh 会自动回退到 build/source-cache/ 本地缓存
    前提：操作者已预先 seed 缓存（见下方"预置源码缓存"）
    若缓存未 seed 或不全：脚本会列出缺失文件，按提示从 Debian pool 下载后重跑

步骤 4 binary / sbuild 失败：
  可能原因 A：builder 当前会话没有 sbuild group（最常见）
    → 回到：第 3 步 3.3（重新登录 / newgrp sbuild）
  可能原因 B：trixie sbuild chroot 不存在
    → 回到：第 3 步 3.4 第二段（setup_sbuild_chroot）
  可能原因 C：chroot sources 污染（含 sid/unstable/testing）
    → 回到：第 3 步 3.5（--only-stage setup_sbuild_chroot 看 verify_chroot_sources 报错）

步骤 6 smoke-basic 失败：
  可能原因 A：docker 未安装或 daemon 未启动
    → 回到：第 3 步 3.2（install_packages 装了 docker.io）；sudo systemctl start docker
  可能原因 B：builder 当前会话没有 docker socket 权限
    → 检查：docker ps
    → 临时验证：sudo docker ps
    → 后续处理：将 builder 加入 docker 组并重新登录，或调整 smoke-test 使用 sudo docker
    → 注意：docker 组权限属于独立运行时权限议题，不属于 bootstrap sbuild group 修复范围
  可能原因 C：deb 依赖缺失（dpkg -i 报错）
    → 看 dry-run 输出的容器内 apt 错误，通常是 chroot build-dep 不全

步骤 7 aptly temp 失败：
  可能原因：aptly 未安装 / 临时目录权限问题
  回到：第 3 步 3.4 第二段（setup_aptly 阶段）；或看 dry-run 日志的具体 aptly 报错
```

> 其他步骤（2/3/5/8）失败概率低：直接看对应脚本输出和 `build/` 目录下的半成品产物。
> 通用排查：任一步失败后，产物目录 `build/source/` 和 `build/binary/` 会保留到失败点，
> 可直接检查半成品。fetch 每次都在新的临时 staging 目录中完成下载和解包；完整
> source tree 通过验证后，以带回滚的替换方式更新 `build/source/ocserv-1.5.0/`，随后从同一
> staging 目录发布 upstream `ocserv_1.5.0.orig.tar.xz` 及 `.asc` 到 `build/source/`（两步独立，
> 非单一原子事务）。sid 原版 `.dsc` 与 `.debian.tar.xz` 不发布为 fetch 输出，backport 在
> src-pkg 阶段重新生成它们。若需彻底重置本地构建状态，重跑前可手动执行 rm -rf build/。

### 4.4 最终终态验收清单：机器状态 + dry-run 产物状态

整份文档 "成功定义" 达成 = 以下两组全部满足。

**【A. 机器状态】（来自第 1-3 步）**

```text
□ OS=debian trixie, arch=x86_64
□ builder 用户存在，shell=/bin/bash
□ builder 有 passwordless sudo（sudo -n true 成功）
□ builder 在 sbuild group 且当前会话已生效（id -nG 含 sbuild）
□ trixie sbuild chroot 存在（/var/lib/sbuild/trixie-amd64-sbuild）
□ chroot sources 干净（仅 trixie/trixie-updates/trixie-security）
□ GPG signing key 存在（gpg --list-secret-keys 含 THEHKUS-Backports）
□ aptly repo ocserv-backports 存在
□ /var/aptly/{public,.locks,state} 存在且 owner=builder
□ smoke-basic 已通过，因此 Docker 运行条件已满足
```

> Docker 状态的验收口径：不把 docker group 配置提前变成第 3 步职责，而是以
> "smoke-basic 已通过" 反推 Docker 运行条件满足。

**【B. dry-run 产物状态】（来自第 4 步）**

```text
□ source package：build/source/ocserv_1.5.0-1~bpo13+1.dsc 存在
□ binary .deb：build/binary/ocserv_1.5.0-1~bpo13+1_amd64.deb 存在
□ lint 无 Error
□ smoke-basic 通过（安装/版本/unit/ldd）
□ 临时 aptly repo+snapshot 验证通过（snapshot 含 ocserv）
□ snapshot-name 形态正确
□ make dry-run 退出码 0
□ 全程未触碰：R2 / Cloudflare / GitHub runner / staging / production / 正式 /var/aptly DB
```

判定：**A 组全勾 + B 组全勾 = 成功定义达成（本文档终点）。**

### 4.5 dry-run 之后是什么

dry-run 通过只证明 "这台 builder 能完整跑通 backport 构建链"。
下一步才是 testing publish、staging verify、production promote，这些不属于本文档范围。

后续流程见：

```text
docs/BUILD_HOST_BOOTSTRAP.md
  （GitHub 手动清单：runner / secrets / environment 注册配置）
.github/workflows/
  ci-testing.yml / promote-production.yml / rollback-production.yml
  （CI 流水线与生产发布/回滚 workflow）
```

本文档到此为止。

---

## 附录 A：文档结构与命令主路径速查

| 步 | 主题 | 执行用户 | 关键产出 |
|----|------|---------|---------|
| 引言 | 文档定位与读者约定 | — | 范围/终点/成功定义 |
| 第 1 步 | 裸机准备（`bootstrap-bare-metal.sh`） | root → builder | builder 用户 + sudo + SSH + 仓库 |
| 第 2 步 | bootstrap 配置 + GPG 模式 + bootstrap dry-run 预演 | builder | .bootstrap.env + GPG 决策 + 无副作用预演 |
| 第 3 步 | bootstrap 真实运行（分段） | builder | 机器状态全就位 |
| 第 4 步 | make dry-run 端到端验收 | builder | 成功定义达成 |

**第 3 步完整主路径（培训默认，三种 GPG 模式平行）：**

```bash
# 第一段前置检查
scripts/bootstrap-build-host.sh --only-stage preflight

# 第一段：装包 + 加入 sbuild 组
scripts/bootstrap-build-host.sh --only-stage install_packages

# 阶段间动作：重新登录让 sbuild 组生效（硬性）
# 场景 A（远程）: exit; ssh builder@<host>; cd ~/ocserv-backport   (<host> 替换为真实地址)
# 场景 B（本机）: exit; su - builder; cd ~/ocserv-backport
id -nG | tr ' ' '\n' | grep -qx sbuild && echo OK

# 第二段前置检查（重新登录后再确认一次身份）
scripts/bootstrap-build-host.sh --only-stage preflight

# 第二段：继续剩余 bootstrap（三选一，承接第 2 步 GPG 决策）
scripts/bootstrap-build-host.sh --from-stage prepare_directories --generate-gpg-key
# 或（⚠️ 占位符：/path/to/private.asc 必须替换为待导入的 GPG 私钥文件路径）
scripts/bootstrap-build-host.sh --from-stage prepare_directories --import-gpg-key /path/to/private.asc
# 或（⚠️ 占位符：<FULL_FINGERPRINT> 必须替换为 GPG key 完整 fingerprint）
scripts/bootstrap-build-host.sh --from-stage prepare_directories --reuse-gpg-key <FULL_FINGERPRINT>
```

## 附录 B：占位符清单（实现/执行时必须替换为真实值）

| 占位符 | 出现位置 | 含义 |
|--------|---------|------|
| `YYYYMMDDTHHMMSSZ` | 第 4 步 4.1 `.env` 的 `DEBIAN_SNAPSHOT_TIMESTAMP` | snapshot.debian.org 锁定 ocserv 1.5.0-1 源码的时间戳，以 snapshot.debian.org 实际记录为准 |
| `ssh-ed25519 AAAA... replace-with-your-real-public-key` | 第 1 步 1.2 `ADMIN_PUBKEY` | 管理员真实 SSH 公钥 |
| `<host>` | 第 1 步 1.2 / 第 3 步 3.3 等 | 构建机的主机名或 IP |
| `<仓库 URL>` | 第 1 步 1.2 的 `--repo-url`（git clone） | ocserv-backport 仓库地址 |
| `<FULL_FINGERPRINT>` | 第 2 步 2.3 / 第 3 步 3.4 reuse-gpg-key | GPG key 的完整 fingerprint（非短 keyid） |
| `/path/to/private.asc` | 第 2 步 2.3 / 第 3 步 3.4 import-gpg-key | 待导入的 GPG 私钥文件路径 |
| `/path/to/id_ed25519.pub` | 第 1 步 1.2 `--ssh-pubkey-file` | 管理员真实 SSH 公钥文件路径 |

---

## 附录 C：第 1 步等价手动操作（排障/原理参考）

> 本附录是第 1 步 `bootstrap-bare-metal.sh` 的等价手敲命令，**非默认路径**。
> 用途：脚本失败时排障、或想理解脚本每一步在做什么。默认请直接用脚本（见第 1 步 1.2）。
> 所有命令以 root 执行，幂等可重跑。

### C.1 安装 sudo + 创建 builder 用户 + 配置 passwordless sudo

> 时序前提：Debian minimal 裸机不一定预装 sudo，而下面要用 visudo。所以 sudo 必须先装。

```bash
# 先装 sudo（裸 Debian minimal 不一定有）；顺带装 git/ca-certificates 供 C.3 clone 用
apt-get update
apt-get install -y sudo ca-certificates git

# 幂等：用户已存在则跳过
id -u builder >/dev/null 2>&1 || useradd -m -s /bin/bash builder

# sudoers 覆盖式写入（重跑安全）
cat >/etc/sudoers.d/builder <<'EOF'
builder ALL=(ALL) NOPASSWD: ALL
EOF
chmod 0440 /etc/sudoers.d/builder
visudo -c                                          # 语法校验 sudoers
```

> 脚本与手敲的差异：脚本把 sudoers 先写临时文件 + `visudo -cf` 验证后再 `install`，
> 避免坏内容进入 `/etc/sudoers.d`；手敲版直接 cat 写入后 visudo -c 全量校验。
> 脚本用 `useradd -U`（建同名主组）；手敲版省略 -U（Debian 默认也会建同名组）。

### C.2 配置 builder 的 SSH authorized_keys

```bash
# ⚠️ 占位符：把 ADMIN_PUBKEY 替换为你的真实公钥；不要原样复制占位值
ADMIN_PUBKEY='ssh-ed25519 AAAA... replace-with-your-real-public-key'
install -d -o builder -g builder -m 0700 /home/builder/.ssh
printf '%s\n' "$ADMIN_PUBKEY" > /home/builder/.ssh/authorized_keys
chown builder:builder /home/builder/.ssh/authorized_keys
chmod 0600 /home/builder/.ssh/authorized_keys
```

> 脚本与手敲的差异：脚本用 `id -gn` 取真实主组（不假设组名 == 用户名），
> 且逐行追加 + `grep -qxF` 精确去重（不覆盖已有 key）；手敲版直接覆盖写。
> 已存在用户的场景请优先用脚本。

### C.3 切 builder + 克隆仓库

```bash
su - builder
cd ~
# ⚠️ 占位符：<仓库 URL> 必须替换为 ocserv-backport 仓库地址
git clone <仓库 URL> ocserv-backport
cd ocserv-backport
```

> 脚本与手敲的差异：脚本用 `sudo -H -u builder git clone`，文件 owner 直接是 builder；
> 手敲版 `su - builder` 后 clone 同样让 owner 是 builder。脚本对"目录已存在但非 git"
> 会 die 并提示 `rm -rf`，手敲版需自行判断。

