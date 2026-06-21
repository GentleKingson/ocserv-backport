# Debian Pool Primary Source — fetch/prefetch/import Redesign

**Date:** 2026-06-21
**Trigger:** 部分构建机 IP 被 snapshot.debian.org 限制访问(HTTP 509,
"abusive network requests"),可持续数小时到数天。当前 `fetch-source.sh` 以
Snapshot 为首选、仅在 509 时回退本地 cache,对被限流的构建机没有稳定的在线获取
路径。

**Decision:** 将 `deb.debian.org/debian/pool/main/o/ocserv/` 作为当前版本
`1.5.0-1` 的**首选来源**;Snapshot 降级为仅由具备访问能力的**预取节点**使用的
历史/固定时间点重建来源。构建机不再直连 Snapshot。

**Scope of change (files touched across all slices):**
- `source-lock/<source-name>/<debian-version>.yaml`(new)+ `.lock.tsv`(new)
- `scripts/read-source-lock.py`(new)
- `requirements/prefetch.txt`(new)
- `scripts/_dsc.sh`(new — shared Deb822 parser)
- `scripts/_lock_tsv.sh`(new — slice 2; read_lock_tsv + write_expected_sha256sums;
  shared by prefetch/import/fetch; see §4.3.1)
- `scripts/_cache_meta.sh`(new — slice 2; read_cache_meta +
  verify_cache_meta_versions + verify_manifest_hash; shared by prefetch/import/fetch;
  see §3.5.1)
- `scripts/prefetch-source.sh`(new)
- `scripts/import-source-cache.sh`(new)
- `scripts/fetch-source.sh`(modify — delete Snapshot/509; implement pool|cache)
- `.env.example`(modify — drop `DEBIAN_SNAPSHOT_TIMESTAMP`; add `FETCH_SOURCE`)
- `docs/trixie-builder-dryrun-runbook.md`(modify — delete 509 cache section;
  add prefetch/import workflow + pool/cache modes)
- `README.md`(modify — fetch narrative)
- `Makefile`(modify — fetch target comment)
- `.github/workflows/*`(modify — add lock projection CI guard in slice 1)
- `test/test_read_source_lock.bats`(new)
- `test/test_prefetch_source.bats`(new)
- `test/test_import_source_cache.bats`(new)
- `test/test_fetch_source.bats`(modify — delete Snapshot/509; add pool/cache)

This spec **supersedes** the snapshot-first + 509-fallback design in
`2026-06-20-fetch-source-local-cache-fallback-design.md`. That spec's cache
helpers (`_dsc_field`, `parse_dsc_artifacts`, `validate_artifact_basenames`,
`validate_dsc_metadata`, `publish_source_tree`, `publish_orig_tarball`,
TMP_ROOT + trap) are **retained and upgraded**, not discarded (see §4.2).

---

## 1. Architecture & Pipeline

### 1.1 Core inversion

构建机不再访问 snapshot.debian.org。源码获取拆成一条显式 pipeline,三处角色
分离:

```
预取节点 (能访问 snapshot.debian.org)              构建机 (IP 被 snapshot 限制)
──────────────────────────────────────────────    ──────────────────────────────────────
1. read-source-lock.py 解析                         FETCH_SOURCE=pool
   source-lock/<name>/<version>.yaml                 → deb.debian.org/debian/pool/<pool_path>/
   (safe_load + 严格 schema 校验)                    → 锁定版本(不取最新), 不访问 snapshot
2. prefetch-source.sh                               FETCH_SOURCE=cache
   从 snapshot 下载 + 全校验                          → 只读 build/source-cache/<name>/<version>/
   → 原子写入 build/source-cache/                     → 零网络请求
   → 生成 ocserv_<ver>.source-cache.tar.zst
3. [运维层搬运 bundle: rsync/scp/registry, 不脚本化]
4. import-source-cache.sh
   校验 bundle → 解包 staging → 再校验 → 原子导入 cache
```

### 1.2 职责铁律

1. 构建机 `fetch-source.sh` **两态显式**(`pool`|`cache`),**无自动 fallback**;
   pool 失败即失败。
2. cache 是 prefetch/import 的**受验证产物**;`FETCH_SOURCE=cache` 只读、零网络。
3. bundle 跨机传输方式**不进脚本**(无凭据/主机/协议硬编码)。
4. YAML/JSON 解析**只在预取节点**(`read-source-lock.py`,`yaml.safe_load()`);
   构建机 bash **不碰** YAML/JSON 语义。构建机零 Python、零 PyYAML。
5. pool 与 cache 都必须消费**同一个锁定的 `<name>/<version>` 身份**;pool 不得解释
   为"自动取最新"。lock 始终是来源选择之外的稳定输入。
6. 当构建机的 pool 与 cache 都不可用时,**必须显式失败**并提示"请在具备 Snapshot
   访问能力的预取节点执行 prefetch,并导入 source-cache";**不得**自动尝试 snapshot,
   **不得**隐式切换远端来源。

### 1.3 Shared contracts (defined once here, consumed by both sides)

为避免拆分 spec 导致协议漂移,以下契约由本 spec 统一定义,预取侧与构建机侧共同
消费:

- `source-lock/<name>/<version>.yaml` schema(§2.2)
- `build/source-cache/<name>/<version>/` directory layout(§3.1)
- `source-manifest.json` schema(§3.4)
- `SHA256SUMS` format(§3.3)
- `cache.meta` format(§3.5)
- bundle format `<name>_<version>.source-cache.tar.zst`(§3.9)
- `.lock.tsv` projection format(§2.5)
- unified strong-verification ordering for pool & prefetch(§3.6 step 5)

### 1.4 Slice boundaries (fixed order 1 → 2 → 3 → 4)

| 切片 | 内容 | 影响现有构建 |
|------|------|-------------|
| 1 | `source-lock/` 目录 + `read-source-lock.py` + `.lock.tsv` 派生 + CI byte-for-byte guard + `requirements/prefetch.txt` + 测试 | 无(纯新增) |
| 2 | `scripts/_dsc.sh` + `scripts/_lock_tsv.sh` + `scripts/_cache_meta.sh` + `prefetch-source.sh` + `import-source-cache.sh` + 版本化 cache 契约 + bundle + 测试 | 无(纯新增) |
| 3 | `fetch-source.sh` 重构(删 snapshot/509, 实现 pool\|cache, source 切片 2 的 `_dsc.sh`/`_lock_tsv.sh`/`_cache_meta.sh` 消除重复, cache 读版本化目录 + 身份闭环) | **唯一改变行为** |
| 4 | runbook + `.env.example` + README + Makefile + 文档语义同步 | 文档 |

每个切片可独立 review、测试、合并;**启用顺序必须 1 → 2 → 3 → 4**。切片 1、2 为
纯新增能力;切片 3 是唯一改变现有构建机行为的切片;切片 4 在最终行为稳定后统一
同步文档。

**切片 2 自检要点(修正 #1):** `import-source-cache.sh` 在 tar 操作前调用
`read_lock_tsv()` 构造白名单与 `expected-SHA256SUMS`,并校验 `cache.meta`;因此
`_lock_tsv.sh`(read_lock_tsv + write_expected_sha256sums)与 `_cache_meta.sh`
(read_cache_meta + verify_cache_meta_versions + verify_manifest_hash)**必须**归入
切片 2,否则 import 无法独立实现/测试/合并。prefetch/import/fetch **不得**各自
复制 `read_cache_meta()` 或 `expected-SHA256SUMS` 生成逻辑——它们必须 source 同一
helper 文件。

**切片 1 自检要点:** 必须包含 CI projection guard 的实施(见 §5.5),否则切片 1
合并后 `.lock.tsv` 仍无防漂移守卫,与切片边界冲突。

**切片 4 自检要点:** 只同步文档,不再次改变 CI 或构建行为。

---

## 2. Slice 1 — Lock infrastructure (pure new)

### 2.1 Lock file location (locked)

`source-lock/<source-name>/<debian-version>.yaml`,例如
`source-lock/ocserv/1.5.0-1.yaml`。每版本独立、不可被后续版本覆盖。受 git
版本控制。

### 2.2 YAML schema

```yaml
# source-lock/ocserv/1.5.0-1.yaml
schema_version: 1
source: ocserv
debian_version: "1.5.0-1"
allowed_sources:                          # subset of {pool, snapshot}, non-empty
  - pool
  - snapshot
snapshot_timestamp: "20260616T083027Z"   # required iff snapshot in allowed_sources
pool_path: "main/o/ocserv"               # required iff pool in allowed_sources
dsc:                                      # the .dsc itself (not in its own Files)
  name: ocserv_1.5.0-1.dsc
  size: 2234
  sha256: "<64 lowercase hex>"
artifacts:                                # all files referenced by the .dsc's
                                          # Files / Checksums-Sha256 stanzas
  - name: ocserv_1.5.0.orig.tar.xz
    size: 587692
    sha256: "<64 lowercase hex>"
  - name: ocserv_1.5.0.orig.tar.xz.asc    # present ONLY when the .dsc lists it
    size: 833
    sha256: "<64 lowercase hex>"
  - name: ocserv_1.5.0-1.debian.tar.xz
    size: 21536
    sha256: "<64 lowercase hex>"
```

**Field table:**

| 字段 | 类型 | 必填 | 校验规则 |
|------|------|------|----------|
| `schema_version` | int | 是 | `== 1`(数据契约演进时才递增) |
| `source` | str | 是 | 非空;`^[a-z0-9][a-z0-9+.-]*$` |
| `debian_version` | str | 是 | `^[A-Za-z0-9.+~-]+$`(**不支持 epoch**,见 §2.2 epoch 说明;拒空白/控制字符/`/`/`\`) |
| `allowed_sources` | list[str] | 是 | `⊆ {pool, snapshot}` 且非空;**去重**(重复值 → 拒绝) |
| `snapshot_timestamp` | str | 条件必填 | `^\d{8}T\d{6}Z$`;`snapshot ∈ allowed_sources` 时必填;`snapshot ∉` 时**必须缺失** |
| `pool_path` | str | 条件必填 | `pool ∈ allowed_sources` 时必填;`pool ∉` 时**必须缺失**;语法见 §2.2 pool_path 规则 |
| `dsc.name` | str | 是 | 安全 basename(见 §2.2 安全规则);**必须以 `.dsc` 结尾** |
| `dsc.size` | int | 是 | `>= 0` 整数;**禁 YAML bool**(精确类型判断) |
| `dsc.sha256` | str | 是 | `^[0-9a-f]{64}$`(64 位小写 hex) |
| `artifacts` | list | 是 | **非空**;每项含 name/size/sha256,规则同 dsc 字段 |
| `artifacts[].name` | str | 是 | 安全 basename;**不得** == `dsc.name`;artifacts 内 name **不得重复** |
| `artifacts[].size` | int | 是 | `>= 0` 整数;禁 YAML bool |
| `artifacts[].sha256` | str | 是 | `^[0-9a-f]{64}$` |

**字段存在性的双向绑定(对称约束):**
- `snapshot_timestamp` 存在 ⟺ `snapshot ∈ allowed_sources`
- `pool_path` 存在 ⟺ `pool ∈ allowed_sources`

**pool_path 语法规则(修正项 #1):**
`pool_path` 必须是非空相对路径,由**至少一个** slash-separated segment 组成(如
`main/o/ocserv`)。每个 segment 必须匹配 `^[A-Za-z0-9][A-Za-z0-9+._-]*$`。整体
**禁止**:前导 `/`、尾随 `/`、空 segment(`//`)、`.` 或 `..` segment、`\`、控制
字符、ASCII whitespace、`://`、`?`、`#`、`%`。

这样 `pool_path` 不参与任意 URL 语义,只表达 Debian archive 的 canonical `pool/`
层级下的相对路径。pool URL 始终严格构造为
`https://deb.debian.org/debian/pool/<pool_path>/<filename>`,不允许 `pool_path` 贡献
scheme/host/query/fragment。

**安全 basename 规则(适用于 `dsc.name` 与 `artifacts[].name`,贯穿全 pipeline):**
非空、非 `.`/`..`、不含 `/` 与 `\`、不含控制字符(`0x00–0x1f`、`0x7f`)。

**epoch 说明(advisory B,当前明确不支持):** `debian_version` 拒绝 epoch(正则不含
`[0-9]+:` 前缀)。理由:现有构建机入口通过
`OCSERV_UPSTREAM_VERSION-OCSERV_DEBIAN_REVISION` 派生 lock path、publish 目录
(`ocserv-${UPSTREAM}`)和 orig tarball glob;而 Debian Policy 明确 epoch 不出现在
source package 文件名中,一旦未来 lock 使用 epoch,`<UPSTREAM>-<REVISION>` 与
`ocserv-${UPSTREAM}` 的命名模型会产生歧义。ocserv 当前 `1.5.0-1` 无 epoch,故本项
以最小实现范围明确不支持;未来若需 epoch,需先升级 lock schema(增加明确的
`unpack_dir` / `upstream_version_without_epoch`)并改造 fetch 的目录/tarball 推导,
另行设计。

**未知字段一律拒绝**(schema 锁定,防漂移)。

**`.asc` 出现规则:** `artifacts` 仅表示该 `.dsc` 的 Files/Checksums-Sha256 引用
文件;`.asc` 只有在实际 `.dsc` 列出时才可出现。`.dsc` cross-check(下载的 `.dsc`
与 lock 的一致性)在切片 2 prefetch / 切片 3 pool 里做(那时才有下载的 `.dsc`);
本切片的 `read-source-lock.py` 只做 lock 文件**自身**的 schema/类型/值域校验。

**artifact 顺序必须稳定**(消费端按此顺序生成 SHA256SUMS、expected-SHA256SUMS 等
确定性产物;不允许排序打乱)。

### 2.3 `scripts/read-source-lock.py` (new)

**职责单一:** 解析 + 严格校验 + 输出固定 schema 的 TAB 记录流。**不做**网络/
下载/校验和计算/写文件。

**两种互斥调用(locked):**
```bash
python3 scripts/read-source-lock.py --lock source-lock/ocserv/1.5.0-1.yaml
python3 scripts/read-source-lock.py --source ocserv --debian-version 1.5.0-1
```
- `--source X --debian-version Y` 按固定规则解析为唯一路径
  `source-lock/X/Y.yaml`;**不得**扫描目录选"最新",**不得**按日期/远端/git 历史
  推断。
- 参数互斥校验:两者都给或都不给 → stderr 报错 + exit 2。

**解析约束(locked):** 仅 `yaml.safe_load()`;**禁** `yaml.load()`、禁从 YAML
构造任意对象。SafeLoader 限制为简单 YAML 对象,不会构造任意 Python 对象。

**重复 key 拒绝:** 自定义 SafeLoader 子类,在**所有 mapping 层级**拒绝重复 YAML
key(YAML 默认后者覆盖前者,会静默丢失数据)。

> **YAML loader 实现注记(非阻塞, 写入切片 1 实施任务与 parser 测试):** spec 同时
> 要求"仅 `yaml.safe_load()`"和"自定义 SafeLoader 子类拒绝重复 key"。实现时应定义
> `StrictSafeLoader(yaml.SafeLoader)`(覆盖构造 mapping 的方法,遇重复 key 抛异常),
> 再提供 `strict_safe_load()` 包装器——以 SafeLoader 语义读取(只构造简单 Python
> 对象,不构造任意对象)并拒绝重复 key。**不要**使用未受限的通用 loader
> (`yaml.load`/`FullLoader`/`UnsafeLoader`)。PyYAML 明确说明普通 `yaml.load` 对
> 不受信输入可能构造任意 Python 对象。

**类型精确判断:** 先 `isinstance(x, bool)` 拒绝,再 `isinstance(x, int)` 判断,
避免 YAML bool(`true`/`false`)被当作 int(`size` 字段尤其关键)。

**校验规则:** §2.2 字段表的全部规则 + 双向绑定 + 安全 basename。具体:
- 文件不存在 / 非 YAML / 根非 mapping → exit 1
- 任一字段违反规则 → exit 1(stderr 单行,指出字段名与原因)
- `allowed_sources` 含 `snapshot` 但 `snapshot_timestamp` 缺失 → exit 1
- `allowed_sources` 不含 `snapshot` 但 `snapshot_timestamp` 存在 → exit 1
- `pool` 同理双向绑定

**输出格式(固定 schema TAB 记录流,stdout;仅 lock 内容,不含 provenance):**
```
META\t<source>\t<debian_version>\t<allowed_sources>\t<snapshot_ts|->\t<pool_path|->\t<dsc_name>\t<dsc_size>\t<dsc_sha256>
ARTIFACT\t<name>\t<size>\t<sha256>
ARTIFACT\t<name>\t<size>\t<sha256>
...
```
- `allowed_sources` = **先校验无重复**,再按字母排序逗号连(如 `pool,snapshot`)
- 缺失字段用 **`-` sentinel**(不用空字段编码);Bash 消费端将 `-` 还原为空
- 成功 exit 0;**绝不**用 `eval` 输出 shell assignment

**Bash 消费模式(概念示例 — 仅示字段布局;构建机实际消费必须用 §4.3.1 的受限
parser `read_lock_tsv()`,它带完整身份/格式校验,不是下面的裸 while-read):**
```bash
while IFS=$'\t' read -r rectype f1 f2 f3 f4 f5 f6 f7 f8; do
  case "$rectype" in
    META)
      src="$f1"; ver="$f2"; allowed="$f3"
      ts="$f4";  [[ "$ts" == "-" ]] && ts=""
      pool_path="$f5"; [[ "$pool_path" == "-" ]] && pool_path=""
      dsc_name="$f6"; dsc_size="$f7"; dsc_sha256="$f8"
      ;;
    ARTIFACT)
      art_name="$f1"; art_size="$f2"; art_sha256="$f3"
      ;;
  esac
done < <(python3 "${SCRIPT_DIR}/read-source-lock.py" --lock "$lock_path")
```

### 2.4 Provenance (computed by prefetch, not in the record stream)

read-source-lock.py 的 **stdout 只含 lock 内容**。provenance 由**切片 2 的
prefetch** 自行计算并写入日志/manifest:
- lock 文件路径 = prefetch 自己的 `--lock` 参数(已知)
- lock 文件 SHA256 = prefetch 用 `sha256sum` 计算
- `scripts/read-source-lock.py` 路径 = 已知常量
- PyYAML 版本 = prefetch 用 `python3 -c "import yaml;print(yaml.__version__)"` 取

read-source-lock.py 保持单一职责(解析+校验+输出内容),provenance 由调用方组装。

### 2.5 `.lock.tsv` projection (CI-verified, builder-consumed)

**新增 `source-lock/<source-name>/<debian-version>.lock.tsv`,与 `.yaml` 同
git commit。**

- `.lock.tsv` 的内容必须与 `read-source-lock.py --lock <yaml>` 的 stdout **完全
  字节一致**(`cmp -s`),只含固定的 `META`/`ARTIFACT` TAB 记录流。
- **不得手工编辑**,不添加注释、banner 或其他非记录内容。
- YAML 是**唯一人工维护源和审计源**;`.lock.tsv` 是受 CI 验证的、面向无 PyYAML
  构建机的**编译产物**。

构建机(切片 3 pool/cache)只读 `.lock.tsv`,用 Bash 的受限 TSV parser(见 §4.3.1
`read_lock_tsv()`)获取全部身份字段。构建机因此保持零 Python、零 PyYAML、零
YAML/JSON 解析依赖;`pool` 仍是独立在线模式,不依赖 cache,也不访问 Snapshot。

**`.lock.tsv` 格式契约(供 §4.3.1 与 CI 校验共享):**
- 记录类型仅 `META`(恰好 1 个,必须第一行)与 `ARTIFACT`(≥1 个)
- 字段间 TAB(`\t`)分隔,记录以 `\n` 结尾;**无 CRLF 残留**(`\r` → 拒绝)
- 无注释、无 banner、无 trailing 空行
- ARTIFACT name 不可重复
- 消费端(§4.3.1)对 source / debian_version / pool_path / filename / size / sha256
  复用 §2.2 YAML schema 的同一套格式校验(确保 YAML 与 TSV 两侧规则不漂移)

### 2.6 `requirements/prefetch.txt` (new)

```
PyYAML==6.0.2
```
固定版本(可选附 hash)。构建机**不**安装、**不**需要 Python/YAML。预取节点运行
prefetch 前显式安装。

### 2.7 Slice 1 tests

新增 `test/test_read_source_lock.bats`(及若干 fixture YAML):
- 合法 lock → META + N 个 ARTIFACT,字段值正确
- `--source`+`--debian-version` 正确解析路径;参数互斥错误(两者都给/都不给 →
  exit 2)
- 未知字段 / 重复 artifact name / artifact name == dsc.name → 拒绝
- 非法 SHA256(非 64 hex / 大写)/ 非法 size(负数/非数字/YAML bool)/ 非法
  debian_version(含 `/`、空白)→ 拒绝
- `debian_version` 含 epoch 前缀(如 `1:1.5.0-1`)→ 拒绝(advisory B)
- filename 含 `/`、`\`、控制字符 → 拒绝
- `dsc.name` 不以 `.dsc` 结尾 → 拒绝
- `allowed_sources=[snapshot]` 但无 timestamp → 拒绝
- `allowed_sources` 不含 snapshot 但有 timestamp → 拒绝
- pool_path 双向绑定(pool ∈ 但缺 pool_path → 拒绝;pool ∉ 但有 pool_path →
  拒绝)
- pool_path 语法拒绝:前导 `/`、尾随 `/`、空 segment(`main//o`)、`.`/`..` 段、
  `\`、控制字符、whitespace、`://`、`?`、`#`、`%`、完整 URL(如
  `https://example.invalid/x`)→ 均拒绝(修正 #1)
- snapshot_timestamp 格式错(8 位时间而非 6 位)→ 拒绝
- 重复 mapping key(YAML 同级重复字段)→ 拒绝
- 不扫描目录/不推断最新(给一个只有 `--source` 的目录,确认报缺版本)
- `.lock.tsv` 派生:`read-source-lock.py` 输出 == 已 commit 的 `.lock.tsv`
  (byte-for-byte)

---

## 3. Slice 2 — prefetch/import pipeline + versioned cache (pure new)

### 3.1 Versioned cache directory layout (locked)

```
build/source-cache/ocserv/1.5.0-1/
├── ocserv_1.5.0-1.dsc
├── ocserv_1.5.0.orig.tar.xz
├── ocserv_1.5.0.orig.tar.xz.asc        # present ONLY when .dsc lists it
├── ocserv_1.5.0-1.debian.tar.xz
├── SHA256SUMS
├── source-manifest.json
└── cache.meta
```
不可覆盖(见 §3.8)。`build/source-cache/` 仍由 `build/` 的 `.gitignore` 覆盖
(已有规则)。

### 3.2 Three metadata files — division of labor

| 文件 | 格式 | 校验对象 | 谁写 | 谁读 |
|------|------|----------|------|------|
| `SHA256SUMS` | `sha256sum -c` 兼容 | 全部**源码 artifact**(`.dsc` + artifacts,**不含**三个元数据文件自身)| prefetch | import 校验、fetch(cache) 校验 |
| `source-manifest.json` | JSON | 完整审计 + provenance | prefetch | 人/CI 读;**import 与 fetch 都不解析其 JSON 内容** |
| `cache.meta` | key=value 纯文本 | 轻量锚点 | prefetch | import 逐字段提取(受限 parser);fetch(cache) 读最小字段集 |

**manifest 完整性如何在不解析 JSON 的前提下校验:** `cache.meta` 记录
`manifest_sha256`,import 与 fetch(cache) 用
`echo "$manifest_sha256  source-manifest.json" | sha256sum -c -`(纯 bash,不解析
JSON)。manifest 的 JSON 内容仅供审计,不参与 import/fetch 的业务判断。

> **manifest 的安全地位(advisory):** `manifest_sha256` 仅提供 cache **内部**的
> 一致性检查。攻击者若能同时替换 `source-manifest.json` 与 `cache.meta` 中的
> `manifest_sha256`,该校验仍会通过。但这**不是**安全漏洞——manifest 是审计/provenance
> 文档,**不参与 build identity 判定**。build identity 只由 `.lock.tsv`→
> `expected-SHA256SUMS`(cmp -s)→实际 artifact bytes(sha256sum -c)→`.dsc` 签名/元数据
> 共同确定,而 `.lock.tsv` 是 Git-tracked + CI 守卫的锚点。manifest_sha256 不得被表述为
> 独立的来源认证。

### 3.3 SHA256SUMS

```
<sha256>  ocserv_1.5.0-1.dsc
<sha256>  ocserv_1.5.0.orig.tar.xz
<sha256>  ocserv_1.5.0.orig.tar.xz.asc
<sha256>  ocserv_1.5.0-1.debian.tar.xz
```
行序 = `dsc` 在前,`artifacts` 按 lock 顺序(稳定)。在 cache 目录内
`sha256sum -c SHA256SUMS`。文件名占位列允许并兼容 `sha256sum -c`(GNU coreutils
标准接口)。

### 3.4 source-manifest.json schema (`manifest_schema_version: 1`)

```json
{
  "manifest_schema_version": 1,
  "source": "ocserv",
  "debian_version": "1.5.0-1",
  "snapshot_timestamp": "20260616T083027Z",
  "pool_path": "main/o/ocserv",
  "allowed_sources": ["pool", "snapshot"],
  "dsc": {"name": "ocserv_1.5.0-1.dsc", "size": 2234, "sha256": "..."},
  "artifacts": [
    {"name": "ocserv_1.5.0.orig.tar.xz", "size": 587692, "sha256": "..."}
  ],
  "provenance": {
    "lock_path": "source-lock/ocserv/1.5.0-1.yaml",
    "lock_sha256": "...",
    "read_source_lock_path": "scripts/read-source-lock.py",
    "pyyaml_version": "6.0.2",
    "fetched_at_utc": "2026-06-21T12:00:00Z",
    "fetch_source_kind": "snapshot",
    "original_urls": ["https://snapshot.debian.org/archive/debian/20260616T083027Z/pool/main/o/ocserv/ocserv_1.5.0-1.dsc"],
    "verification": {
      "dscverify_version": "...",
      "dpkg_source_version": "...",
      "dscverify_keyrings": [
        {
          "path": "/usr/share/keyrings/debian-keyring.gpg",
          "sha256": "...",
          "package": "debian-keyring",
          "package_version": "..."
        },
        {
          "path": "/usr/share/keyrings/debian-maintainers.gpg",
          "sha256": "...",
          "package": "debian-keyring",
          "package_version": "..."
        },
        {
          "path": "/usr/share/keyrings/debian-nonupload.gpg",
          "sha256": "...",
          "package": "debian-keyring",
          "package_version": "..."
        },
        {
          "path": "/usr/share/keyrings/debian-tag2upload.pgp",
          "sha256": "...",
          "package": "debian-tag2upload-keyring",
          "package_version": "..."
        }
      ]
    }
  }
}
```

> `fetched_at_utc` 使同一 lock/同一 artifact 在不同时间预取时 manifest 内容必然
> 不同 → `manifest_sha256` 必然不同。因此幂等判断**不**用 `manifest_sha256`,
> 改用 `content_sha256`(见 §3.5、§3.8)。

**provenance.verification(修正阻塞项 #4):** "固定 trust root"(advisory A)指排除
用户 keyring,但**不**等于时间维度固定——`debian-keyring` 与
`debian-tag2upload-keyring` 的内容随系统升级变化。对一个宣称支持 Snapshot 历史重建
的设计,必须将本次验证所用的 trust-root 身份写入 manifest provenance,让未来审计者知道
"当时用什么信任根验证了这个 `.dsc`"。prefetch 在 §3.6 step 4 计算并填入:

- `dscverify_version` / `dpkg_source_version`:`dscverify --version`、
  `dpkg-source --version` 的输出
- `dscverify_keyrings[]`:**有序数组**,按 dscverify 实际 `--keyring` 参数顺序写入;
  每项含 `path`、`sha256`(该 keyring 文件的 sha256)、`package`(提供该文件的 Debian
  包名)、`package_version`(`dpkg-query -W -f='${Version}' <package>`)。默认记录
  advisory A 实际传入的全部 keyring(默认 4 项:`debian-keyring.gpg`、
  `debian-maintainers.gpg`、`debian-nonupload.gpg` 由 `debian-keyring` 提供;
  `debian-tag2upload.pgp` 由 `debian-tag2upload-keyring` 提供)。schema 用数组而非
  固定 scalar 字段,不锁死为两份。

**manifest 生成实现细节(writing-plans 落实, 不改设计结构):** `source-manifest.json`
由预取节点用 Python 标准库 `json`(即 `json.dumps()`)安全生成,**不**用 Bash 拼接字符串。
原因:provenance 中的版本输出、URL、命令输出未来可能带换行、引号或反斜杠;预取节点已
允许使用 Python,`json.dumps()` 是最低风险的实现方式。构建机仍不解析 JSON(符合现有边界)。

这**不**要求现在引入 keyring package lock(未来需求时再考虑);它只让验证所用的
trust-root 可审计。若决定不支持 tag2upload,则只填 debian-keyring 三项,
tag2upload 三项缺失并在 spec 声明。

### 3.5 cache.meta (key=value, bash-friendly)

```
meta_format_version=1
bundle_format_version=1
source=ocserv
debian_version=1.5.0-1
content_sha256=<sha256(SHA256SUMS)>
manifest_sha256=<sha256(source-manifest.json)>
manifest_schema_version=1
```

- **四个独立版本字段各归其主**(防混淆):
  - `schema_version` → lock YAML
  - `manifest_schema_version` → source-manifest.json(也镜像进 cache.meta 便于
    不解析 JSON 的消费端知晓)
  - `meta_format_version` → cache.meta 自身
  - `bundle_format_version` → bundle(声明在 cache.meta,import 解压后第一时间读
    cache.meta 即得)
- **身份字段分工:**
  - `content_sha256` = `sha256(SHA256SUMS)` = **artifact 身份**(幂等判断依据)
  - `manifest_sha256` = `sha256(source-manifest.json)` = **manifest 文件完整性**
    (验证 manifest 未被改动,**不**参与幂等判断)
- **消费端用受限 `read_cache_meta()` parser**(见 §3.5.1),**不是**裸 `grep`。

#### 3.5.1 `read_cache_meta()` + `_cache_meta.sh` (slice 2 shared helper)

`_cache_meta.sh`(切片 2 新增,供 prefetch/import/fetch 共用)导出三个函数:

- `read_cache_meta <file>`: 解析 cache.meta,填全局 CM_* 变量(见下方规则)
- `verify_cache_meta_versions()`: 断言 `meta_format_version==1`、
  `bundle_format_version==1`、`manifest_schema_version==1`
- `verify_manifest_hash <cache_dir>`: `echo "$CM_MANIFEST_SHA256  source-manifest.json" |
  sha256sum -c -`

裸 `grep '^key='` 会被重复字段或注入字段欺骗(如多个 `source=` 或
`manifest_sha256=`)。消费端(import、fetch cache)必须用受限 parser:

规则:
- 只接受精确允许字段:`meta_format_version`、`bundle_format_version`、`source`、
  `debian_version`、`content_sha256`、`manifest_sha256`、`manifest_schema_version`
- 每字段必须**恰好出现一次**
- 未知字段、重复字段、空值、前后空白、控制字符、非法值均失败
- `source`/`debian_version` 复用 lock 的格式正则(`^[a-z0-9][a-z0-9+.-]*$` /
  `^[A-Za-z0-9.+~-]+$` — **无 epoch**,与 §2.2 锁定的"不支持 epoch"一致)
- 两个 sha256 字段必须是 64 位小写 hex(`^[0-9a-f]{64}$`)
- **禁** `source` 文件、**禁** `eval`(防注入);逐行 `IFS='=' read -r k v` 后
  case 分派

> `manifest_schema_version` 在 cache.meta 中是 manifest JSON 的镜像值。构建机/import
> **不**解析 JSON,因此对它的校验只是"consumer compatibility declaration"(消费者
> 兼容性声明)——确认 cache.meta 声明的 manifest schema 版本与消费端期望一致(`== 1`);
> 它**不是**对 JSON 内字段的独立语义验证。

### 3.6 `scripts/prefetch-source.sh` (prefetch node; snapshot only)

```
1. 参数: --source X --debian-version Y | --lock <path>(互斥, 同 read-source-lock.py)
2. 前置校验: snapshot ∈ allowed_sources, 否则 die
   "该 lock 未授权 snapshot 来源; 构建机请用 FETCH_SOURCE=pool"
   (pool-only lock 不走 prefetch; pool 获取是构建机 fetch-source.sh 自己做的事)
3. 解析 YAML lock 并验证 projection(修正 #1 — prefetch 必须消费与构建机/import
   同一份 .lock.tsv, 否则预取节点会从 YAML 得到一套输入, 构建机/import 却据另一份
   .lock.tsv 拒绝 bundle):
   a. 运行 read-source-lock.py --lock <yaml>, 输出到临时 TSV
   b. 计算 companion 路径 source-lock/<name>/<version>.lock.tsv
   c. cmp -s <临时 TSV> <companion .lock.tsv>; 不一致或缺失 → 在任何网络请求前失败
   d. source scripts/_lock_tsv.sh
   e. read_lock_tsv <companion .lock.tsv> <expected version>
   f. 后续下载、SHA256SUMS、cache、bundle 全部使用 read_lock_tsv 填充的
      META_* / ARTIFACT 数组(不再直接消费 YAML parser 输出)
4. provenance 自算:
   - lock_sha256=sha256sum(<lock>); pyyaml_version=python3 -c ...
   - verification(修正 #4): dscverify/dpkg-source 版本; `dscverify_keyrings[]`
     按 dscverify 实际 `--keyring` 参数顺序写入有序数组, 每项含 path、sha256、
     package、package_version; 默认记录 4 项(debian-keyring.gpg、
     debian-maintainers.gpg、debian-nonupload.gpg、debian-tag2upload.pgp,
     见 §3.4 provenance.verification)
5. 下载到 STAGING (mktemp -d), 强校验闭环顺序(权威定义于此, pool 模式 §4.1 同源同序复用):
   a. 下载 .dsc (download_artifact, 见下方)
   b. 校验 .dsc 的 size + SHA256 == lock.dsc
   c. 解析 .dsc 的 Files / Checksums-Sha256 (复用 _dsc.sh, 见 §3.6.1)
   d. 验证: Files name 集 == Checksums-Sha256 name 集 == lock.artifacts name 集
      且每个 artifact 的 size + SHA256 == lock 声明
   e. 下载全部 artifacts (download_artifact)
   f. 校验每个 actual artifact 的 size + SHA256 == lock
   g. dscverify(固定信任根, 见 §3.6 advisory A; artifacts 就绪后才能跑)
   h. dpkg-source --require-valid-signature --require-strong-checksums -x <dsc>
      (此处 -x 仅用于 prefetch 内部完整性确认; 最终 cache 存放未解包 artifact,
       解包留给 fetch cache 模式)
6. snapshot 访问失败(含 HTTP 509): 保留原始 downloader/curl 日志(§3.6.2),
   提示"更换预取节点出口或稍后重试"; 首版不做 509 分类/重试/退避
   (HTTP 509 分类逻辑待后续明确重试次数/指数退避/等待上限/最终失败语义后单独引入)
   注意: 新 pipeline **不使用 dget**(旧 `dget -x -u` 的 `-u` 关闭 dscverify);
   所有下载走 download_artifact(curl)。任何"dget 日志"字样仅作历史背景,不作
   实现接口。
7. 生成 cache 内容到 STAGING/<name>/<version>/:
   a. cp 已校验的 .dsc + artifacts
   b. 生成 SHA256SUMS(行序 = dsc 在前 + artifacts 按 lock 顺序)
   c. 生成 source-manifest.json(含 provenance, fetch_source_kind="snapshot",
      original_urls = 实际 snapshot URL)
   d. 生成 cache.meta(content_sha256 = sha256(SHA256SUMS),
      manifest_sha256 = sha256(source-manifest.json))
8. 原子导入 build/source-cache/<name>/<version>/(§3.8 幂等规则)
9. 生成 bundle(§3.9)
```

**预取节点依赖(显式):** `curl`、`devscripts`(提供 `dscverify`)、
`dpkg-dev`(提供 `dpkg-source`)、`debian-keyring`(提供 `debian-keyring.gpg` +
`debian-maintainers.gpg` + `debian-nonupload.gpg`)、`debian-tag2upload-keyring`
(提供 `debian-tag2upload.pgp`)、`GNU tar`、`zstd`(tar `--zstd` 调用它)、
`python3`+`PyYAML==6.0.2`。

> **keyring 依赖说明:** `dscverify` 官方默认 keyring 集包括四份
> `/usr/share/keyrings/debian-keyring.gpg`、`debian-maintainers.gpg`、
> `debian-nonupload.gpg`、`debian-tag2upload.pgp`(覆盖 Debian Developers、
> Debian Maintainers、non-uploading developers、tag2upload 签名)。前三份由单个包
> `debian-keyring` 提供;`debian-tag2upload.pgp` 由 `debian-tag2upload-keyring`
> 提供。本 spec 在 advisory A 中显式传入全部四份以等价默认集(见下方)。

#### 3.6.2 `download_artifact()` (curl, locked downloader — 修正 #3)

所有在线 artifact 下载(prefetch 的 snapshot URL、pool 模式的 pool URL)**统一使用
curl**,不再使用 dget。

```bash
download_artifact <url> <destination> <logfile>
  # curl --fail --show-error --location --output <destination> <url>
  #   --fail: HTTP 错误(4xx/5xx)返回非零, 不写 body
  #   --location: 跟随重定向
  #   --output: 写入明确 destination
  # 不自动重试(首版; HTTP 509 分类/重试/退避待后续)
  # curl 的 stdout/stderr 原样写入 <logfile>
  # 失败后: 原样输出 logfile 内容, 按调用方语义失败(die)
```

下载失败(HTTP 错误/网络错误)的日志统一称为 **downloader/curl 日志**(不称 dget
日志)。pool 与 prefetch 共用此函数,保证下载接口、错误日志形式、HTTP 509 输出、
测试 stub 方式唯一。

**`dscverify` 固定信任根(advisory A + review-2 fix #4):** `dscverify --no-conf`
不会读 `/etc/devscripts.conf` / `~/.devscripts`,但**仍会**搜索默认 keyring locations,
其中包括用户的 `~/.gnupg/trustedkeys.gpg`——这是不可控信任根。为完全固定验证信任根,
采用 `--no-default-keyrings` + 显式传入**全部四份官方 keyring**(等价默认集,否则由
Debian Maintainers / non-uploaders / tag2upload 签署的有效 `.dsc` 会被错误拒绝):
```bash
dscverify \
  --no-conf \
  --no-default-keyrings \
  --keyring /usr/share/keyrings/debian-keyring.gpg \
  --keyring /usr/share/keyrings/debian-maintainers.gpg \
  --keyring /usr/share/keyrings/debian-nonupload.gpg \
  --keyring /usr/share/keyrings/debian-tag2upload.pgp \
  "$dsc_name"
```
provenance(§3.4)记录实际传入的全部 keyring(数组形式,见 §3.4 review-2 fix #4)。

**`dpkg-source --require-valid-signature` 的安全地位(修正 #4):** 它官方说明会接受
用户 `trustedkeys.gpg`、vendor keyrings 或 Debian 官方 keyrings,因此它**不是**与
`dscverify --no-default-keyrings` 相同的固定信任根。固定信任根的签名判定由
`dscverify` 完成,且**仅在 prefetch 与 pool 模式执行**。`dpkg-source
--require-valid-signature` 是解包前的**补充验证**,它不替代也不扩展固定 trust-root
policy,**不参与 build identity 的定义**(build identity 由 lock.tsv→
expected-SHA256SUMS→artifact bytes→`.dsc` 元数据锚定;cache 模式下 `.dsc` 已在
prefetch 阶段通过固定信任根 dscverify)。

**禁止 `dget -u`:** 旧脚本的 `dget -x -u` 中 `-u/--allow-unauthenticated` 会关闭
dscverify 的 source package 完整性/签名检查。prefetch 显式不用 `-u`,改用单独的
`dscverify`(固定信任根,见 advisory A)+ `dpkg-source --require-valid-signature`。

#### 3.6.1 `scripts/_dsc.sh` (new shared Deb822 parser)

切片 2 新建 `scripts/_dsc.sh`,把现有 `fetch-source.sh` 的 `_dsc_field` /
`parse_dsc_artifacts` / `validate_artifact_basenames` / `validate_dsc_metadata`
提取至此,并**升级**:

- `parse_dsc_artifacts` 不只解析 filename 集合,而是解析 **SHA-256 + size +
  filename 完整映射**(从 `Files` 取 size+filename,从 `Checksums-Sha256` 取
  sha256+size+filename),返回供 cross-check 的结构化数据。
- 提供 `dsc_artifacts_match_lock()`:校验
  `Files name 集 == Checksums-Sha256 name 集 == lock.artifacts name 集`,且每个
  artifact 的 size + sha256 == lock 声明。
- Deb822-aware + PGP-aware(沿用现有 awk-scoped 实现:跳过
  `-----BEGIN PGP SIGNED MESSAGE-----` / `Hash:` / `-----BEGIN SIGNATURE-----`;
  single-line 字段匹配 `^Field:`;multiline 字段按 continuation line 收集)。
- **禁** broad whole-file `grep`(会误匹配相邻字段/PGP armor 行/OpenPGP 签名块)。
- 文件名安全规则贯穿 §3 收紧版(见 §3.10)。

**切片 2 不动 `fetch-source.sh`**(它仍用自己的内联副本);切片 3 时 fetch-source.sh
改为 `source _dsc.sh` 并删除内联副本,消除重复。

### 3.7 `scripts/import-source-cache.sh` (builder/cache node; no YAML/JSON parsing)

**运行位置 = 接收 bundle 的构建机或其内部缓存节点**(不是预取节点)。不解析
YAML/JSON,**但**在 tar 操作前解析 `source-lock/<name>/<version>.lock.tsv`(纯 bash
TSV,满足零 Python/零 PyYAML),以构造精确白名单并生成 expected-SHA256SUMS。

bundle 是跨机输入,**即使有 `.sha256`,也必须当作未受信任输入处理**,直到通过
所有校验。

```
1. 参数: import-source-cache.sh <bundle>
   (ocserv_1.5.0-1.source-cache.tar.zst, 可加 --expected-sha256 <hash>)
2. 从 bundle 文件名解析 <name>+<version>: ^<name>_<version>\.source-cache\.tar\.zst$
3. 校验 bundle 整体 sha256(修正 #5 — 严格 sidecar 解析, 不让未受信 sidecar 作任意输入):
   优先级: --expected-sha256(命令行)> 旁附 <bundle>.sha256。
   sidecar 必须恰好一行, 格式严格:
     ^<64 位小写 hex><两个空格><bundle basename><LF>$
   禁止: 多行、反斜杠 escape、相对/绝对路径、额外文件记录、空白前后缀、CRLF。
   校验不依赖 cwd(修正 #2): bundle 可为任意外部绝对/相对路径, 而
   `sha256sum --check` 会按 cwd 查找 basename —— 因此**直接计算并比较**, 不用
   `--check`:
     bundle_abs="$(realpath -e -- "$bundle")"            # 校验前解析为绝对路径
     sidecar="${bundle_abs}.sha256"                       # sidecar 与 bundle 同目录
     expected_hash=<从 --expected-sha256 或 sidecar 解析; 必须匹配 ^[0-9a-f]{64}$>
     actual_hash="$(sha256sum -- "$bundle_abs" | awk '{print $1}')"
     [[ "$actual_hash" == "$expected_hash" ]] || die "bundle checksum mismatch"
   (不把未受信 sidecar 文件直接喂给 sha256sum -c; 不依赖 cwd 查找 bundle。)
4. 读取 source-lock/<name>/<version>.lock.tsv(read_lock_tsv 受限 parser, 见 §4.3.1):
   a. 恰好一个 META(第一行)+ ≥1 个 ARTIFACT;拒绝未知 record type / 重复 artifact name
   b. 校验 META.source == <name>(bundle 文件名解析的 name)
   c. 校验 META.debian_version == <version>(bundle 文件名解析的 version)
   d. 由 lock.tsv 的 dsc.name + artifacts[].name 构造精确白名单(见步骤 5)
   e. 由 lock.tsv 生成 expected-SHA256SUMS(行序 = dsc 在前 + artifacts 按 lock 顺序)
5. tar类型预扫描(解压前; 修正阻塞项 #2 + #5):
   env -u TAR_OPTIONS LC_ALL=C tar --list --verbose --zstd --file "$bundle"
   (env -u TAR_OPTIONS: GNU tar 会把 TAR_OPTIONS 环境变量选项放在命令行显式选项
   之前; 处理跨机未受信 bundle 时该变量不能继承, 否则可能改变 create/list/extract
   行为。)
   列出每成员的 verbose 首字段(mode/type)。**只接受 regular file(首字符 '-')**,
   逐成员拒绝:
     - mode 首字符 ≠ '-'(目录 'd'、符号链接 'l'、FIFO 'p'、设备 'b'/'c'、其它)
     - 绝对路径(前导 /)
     - 包含 .. 段的路径
     - 空路径段(//)
     - 重复成员名
     - 白名单外成员
   白名单(由步骤 4d 构造, 非硬编码; 全部为文件, 无目录成员):
     <name>/<version>/<dsc.name>
     <name>/<version>/<每个 artifacts[].name>
     <name>/<version>/SHA256SUMS
     <name>/<version>/source-manifest.json
     <name>/<version>/cache.meta
   不允许额外文件、显式目录成员、嵌套目录、PAX/GNU 扩展头成员或任何 link 类型。
   规则:"只按首个 mode/type 字符识别 regular file (-);任何目录成员、link、PAX
   扩展成员或其他类型一律失败。"
   (tar -tf 只能列成员名, 无法可靠区分 regular/link/fifo/device/socket;必须用
   --list --verbose 看 verbose 首字段类型位。LC_ALL=C 避免 locale 影响 verbose 文本。)
6. 仅在空 staging 目录(mktemp -d)中解压, 使用受限选项:
     env -u TAR_OPTIONS LC_ALL=C tar --extract --zstd --file "$bundle" \
         --directory "$staging" \
         --no-same-owner --no-same-permissions --no-overwrite-dir
   staging 及其父目录必须仅允许可信用户访问(GNU tar 对不可信 archive 在
   独立、空、不可信用户不可写的目录中解压的硬要求)。
7. 校验结构: STAGING/<name>/<version>/ 存在
8. 进入 STAGING/<name>/<version>/:
   a. cache.meta 存在 → read_cache_meta() 提取 source/debian_version/
      content_sha256/manifest_sha256/meta_format_version/bundle_format_version/
      manifest_schema_version
   b. 版本断言: bundle_format_version == 1; meta_format_version == 1;
      manifest_schema_version == 1(consumer compatibility declaration, 见 §3.5.1);
      否则 die "unsupported cache format"
   c. 目录名 <name>/<version> == cache.meta 的 source/debian_version
      == lock.tsv 的 META source/version(三方一致)
   d. cmp -s <expected-SHA256SUMS> SHA256SUMS    # lock ↔ cache 清单精确一致
      (expected-SHA256SUMS 由步骤 4e 生成; 这是最关键的身份锚点,
       防止"整套 cache 被同时替换但内部仍自洽")
   e. manifest 完整性: echo "$manifest_sha256  source-manifest.json" | sha256sum -c -
      (仅 cache 内部一致性; manifest 是审计/provenance 文档, 不参与 build identity)
   f. sha256sum -c SHA256SUMS(全部源码 artifact)
   g. content_sha256 == sha256(SHA256SUMS)(cache.meta 自洽; 与 fetch cache §4.4 对称)
   h. .dsc 存在 → validate_dsc_metadata(Source/Version == 目录名)[复用 _dsc.sh]
   i. 不解包(dpkg-source -x 留给 fetch cache 模式; import 职责 = 导入非构建)
9. 原子导入 build/source-cache/<name>/<version>/(§3.8 幂等规则)
10. 清理 STAGING
```

import 因此具备完整的身份闭环(与 cache fetch 同源):

```
bundle filename → lock.tsv → tar 精确白名单 → expected SHA256SUMS
  → cache artifact bytes(sha256sum -c)→ .dsc signed metadata
```

import 仍满足"零 Python、零 YAML、零 JSON 解析"(lock.tsv 是纯 bash TSV)。

### 3.8 Idempotence & non-overwrite (prefetch/import shared)

```
目标 build/source-cache/<name>/<version>/:
  不存在 → 原子 mv 安装

  存在 → 先完整验证现有 target:
      cache.meta(read_cache_meta)、manifest hash、SHA256SUMS、.dsc metadata
      + cmp -s <expected-SHA256SUMS from lock.tsv> SHA256SUMS
    现有 target 损坏 → 失败; 不得覆盖损坏 cache
    source/version/content_sha256 全部相同 → 幂等成功(丢弃新 staging,
      bundle 从既有 canonical cache 生成)
    content_sha256 不同 → 失败; 拒绝覆盖
```
**绝不覆盖。** `manifest_sha256` 因 `fetched_at_utc` 必然不同,**不**参与幂等判断;
`content_sha256` 才是 artifact 身份。prefetch 的 expected-SHA256SUMS 来自其读入的
lock.tsv;import 的 expected-SHA256SUMS 来自其读入的 lock.tsv(§3.7 步骤 4e)。

### 3.9 Bundle format

```
ocserv_1.5.0-1.source-cache.tar.zst          # tar.zst, 内含 <name>/<version>/ 下的文件
ocserv_1.5.0-1.source-cache.tar.zst.sha256   # 旁附 bundle 整体 sha256
```
bundle 格式版本由其内 `cache.meta` 的 `bundle_format_version` 声明(import 解压后
第一时间读 cache.meta 即得)。跨机传输方式(rsync/scp/registry)**不进脚本**——无
凭据/主机/协议硬编码。

**bundle 成员布局(修正阻塞项 #2 — 必须锁定,否则 prefetch 生成端与 import 白名单端
不兼容):** 标准 tar 可能含显式目录成员(`ocserv/`、`ocserv/1.5.0-1/`)、也可能只含
文件成员而由解压器自动建父目录——这两种 bundle 都"合法"但白名单行为不同。为消除
歧义,**bundle 创建端必须只写入 regular-file 成员,不写显式目录成员**:

```
<name>/<version>/<dsc.name>
<name>/<version>/<每个 artifacts[].name>
<name>/<version>/SHA256SUMS
<name>/<version>/source-manifest.json
<name>/<version>/cache.meta
```

不写 PAX / GNU longname / xattr / ACL 扩展成员,不写显式目录成员,不写 symlink/hardlink。
使用 `--format=ustar` 保证可移植且不引入 GNU/PAX 扩展头。

**bundle 创建命令(概念契约,prefetch 实现;修正 #5):**
```bash
env -u TAR_OPTIONS LC_ALL=C tar \
  --create \
  --format=ustar \
  --zstd \
  --no-recursion \
  --file "$bundle" \
  "${whitelist_paths[@]}"
```
- `env -u TAR_OPTIONS`:继承的 TAR_OPTIONS 会改变 create 行为;创建端也必须剥离它,
  保证 bundle 内容只含 locked regular-file members
- `--no-recursion`:只归档显式列出的路径(均为文件),不递归、不自动加目录成员
- `--format=ustar`:可移植,不引入 PAX/GNU 扩展头
- `LC_ALL=C`:确定性的 verbose 文本/成员名编码,便于 import 端按首字符解析

**ustar 不自动降级失败语义(修正 #5):** `--format=ustar` 会拒绝无法由 ustar 表达的
成员名或元数据(ustar 有路径长度/字符集限制)。对当前 ocserv 文件名无问题,但通用
source-lock pipeline 必须定义明确失败语义:bundle 创建前必须检查每个 whitelist member
的完整 archive member path 可由 ustar 表达;若 GNU tar 因 ustar 限制失败,prefetch
必须**显式失败**,**不得**自动降级为 GNU/PAX format(否则破坏 import 的 regular-file /
无扩展头假设)。

**import 端对应(§3.7 步骤 5/6):** 所有 tar 调用前缀 `env -u TAR_OPTIONS LC_ALL=C`;
`--zstd` 显式指定,不依赖 tar 对 `.tar.zst` 的隐式识别;`LC_ALL=C` 保证 verbose 首字段
(mode/type)按固定字节解析。GNU tar 对 hard link 用独立 typeflag 表示;显式限定只接受
regular file(首字符 `-`)最容易审计。

**bundle sidecar 信任边界(spec 必须显式记录):** `bundle.sha256` 只能证明 bundle
与给定 hash 一致;若 bundle 和 sidecar 可被同一攻击者同时替换,它**不**提供来源
认证。来源认证依赖可信传输通道、预取节点访问控制、lock/.dsc 校验与 cache 目录
权限。sidecar 本身的解析必须严格(§3.7 步骤 3),不直接喂给 `sha256sum -c`。

### 3.10 Filename safety rules (whole pipeline, tightened)

适用全 pipeline(lock、`.dsc` 解析、cache、bundle 白名单):

```
非空
非 "." / ".."
不含 "/" 与 "\"
不含控制字符(0x00–0x1f、0x7f)
不含 ASCII whitespace(含普通空格)         # 收紧: 避免 sha256sum -c / tar whitelist /
                                          #        bash 数组处理歧义
不以 "-" 开头                              # 收紧: 避免 cmd option 注入
```

所有 filesystem 操作必须使用引号和 `--`;禁止 glob / for-in-word-splitting 消费
artifact filename。

Debian source artifact 的正常命名不需要空格,因此这不损害 ocserv 或通常 Debian
source package 场景。

### 3.11 Slice 2 tests

**Helper modules(修正 #1 — 切片 2 内,被 import/prefetch/fetch 复用):**

`_lock_tsv.sh` (`test/test_lock_tsv_helper.bats`):
- 合法 lock.tsv → META + ARTIFACT 字段正确填入(§4.3.1 全部规则)
- META 不在第一行 / 无 META / 多个 META / 无 ARTIFACT / ARTIFACT name 重复 /
  ARTIFACT name == dsc.name / 未知 record type → die
- 空字段 / 额外字段(META ≠ 9 列, ARTIFACT ≠ 4 列)/ 缺失字段 → die
- CRLF 残留(`\r`)→ die
- 字段格式违反(source/debian_version/pool_path/filename/size/sha256 复用 §2.2 规则)
  → die
- 三方身份断言(env/bundle-name-derived expect_version ↔ META ↔ lock path)<ver>
  不一致 → die;META.source ≠ ocserv → die
- `write_expected_sha256sums` 输出行序 = dsc 在前 + artifacts 按 lock 顺序

`_cache_meta.sh` (`test/test_cache_meta_helper.bats`):
- 合法 cache.meta → CM_* 字段正确
- 重复字段 / 未知字段 / 空值 / 前后空白 / 控制字符 → die
- source/debian_version 违反正则(含 epoch)→ die
- 两个 sha256 字段非 64 位小写 hex → die
- `verify_cache_meta_versions`:meta/bundle/manifest schema version ≠ 1 → die
- `verify_manifest_hash`:manifest_sha256 不符 source-manifest.json → die

**测试分配(切片边界一致性,修正 #1):**
- 切片 2:`_lock_tsv.sh` 被 import 实际消费的测试;`_cache_meta.sh` 重复字段/未知字段/
  版本/hash 测试;import 完整闭环测试;prefetch 完整闭环测试。
- 切片 3:fetch 复用上述 helper 的集成测试(不再重复 helper 单元测试)。

**prefetch (`test/test_prefetch_source.bats`):**
- stub 本地 snapshot HTTP(curl 调用);合法 lock → 完整 cache + bundle
- YAML parser 输出与 companion `.lock.tsv` 不一致 / `.lock.tsv` 缺失 → prefetch
  在**任何网络请求前**失败(修正 #1)
- prefetch 后续下载/SHA256SUMS/cache/bundle 全部消费 `read_lock_tsv` 填充的
  META_*/ARTIFACT(不直接消费 YAML parser 输出)(断言)
- 下载 `.dsc` sha256 不符 → die
- `.dsc` Files name 集 ≠ lock.artifacts name 集 → die(含 `.asc` 未在 `.dsc` 列出
  却出现在 lock)
- `.dsc` Checksums-Sha256 size/sha256 ≠ lock → die(三层闭环)
- artifact sha256/size 不符 → die
- snapshot 失败(含 HTTP 509)→ 保留原始 downloader/curl 日志,提示换出口/重试
  (无分类/退避)
- dscverify 失败 → die,不生成 cache
- dscverify 必须在 artifact 下载完成后才执行(顺序断言)
- 幂等(同 content_sha256)→ 成功,bundle 从既有 cache 生成
- 同版本不同 content_sha256 → die
- bundle 创建必须是 regular-file-only + ustar + --no-recursion + env -u TAR_OPTIONS
  + LC_ALL=C(断言:用 `env -u TAR_OPTIONS LC_ALL=C tar --list --verbose --zstd`
  检查生成 bundle 无目录成员/无 link/PAX 头)
- TAR_OPTIONS 非空时:bundle 创建行为仍只包含 locked regular-file members(断言)
- ustar 限制失败(注入超长 member path)→ prefetch 显式失败,**不**自动降级为
  GNU/PAX format(断言:bundle 创建失败而非生成 GNU/PAX archive)
- sidecar 生成格式正确(单行 `<64hex>  <basename>` + LF)(断言)
- 真实调用切片 1 的 `read-source-lock.py`(不 mock parser)

**import (`test/test_import_source_cache.bats`):**
- 合法 bundle → 原子导入
- bundle 整体 sha256 不符 → die
- sidecar 多行/含路径/含空白前后缀/含反斜杠 escape/CRLF/格式错 → die(严格解析)
- sidecar 缺失且无 --expected-sha256 → die
- `--expected-sha256` 非 `^[0-9a-f]{64}$` → die
- bundle 为仓库外绝对路径(如 /tmp/incoming/...)且 cwd=仓库根 → checksum 仍正确
  (修正 #2: 不依赖 cwd 查找 basename; 用 realpath -e + 直接 sha256sum 比较)
- tar 成员含绝对路径/`../`/空段/重复/白名单外 → die(预扫描)
- tar 成员非 regular file(目录 'd'、符号链接 'l'、FIFO 'p'、设备 'b'/'c')→ die
  (预扫描按 verbose mode 首字符; 只接受 '-')
- tar 含 PAX/GNU longname/xattr 扩展头成员 → die
- tar 预扫描必须用 `env -u TAR_OPTIONS ... --list --verbose --zstd` 且 `LC_ALL=C`
  (断言)
- TAR_OPTIONS 非空时:import 预扫描与解压行为不被环境变量改变(断言:注入
  TAR_OPTIONS, 验证 regular-file-only / 白名单行为不变)
- 解压结构错 → die
- 解压必须用 `env -u TAR_OPTIONS ... --extract --zstd --no-same-owner
  --no-same-permissions --no-overwrite-dir` 且 `LC_ALL=C`(断言)
- bundle 文件名 name/version ≠ lock.tsv META source/version → die
- `cmp -s expected-SHA256SUMS SHA256SUMS` 失败(cache 与 lock 清单不一致)→ die
- `SHA256SUMS` 篡改(改字节)→ die(sha256sum -c 失败)
- `cache.meta` 的 source/version ≠ 目录名 → die
- `cache.meta` 重复字段/未知字段 → die(read_cache_meta 拒绝)
- `bundle_format_version` ≠ 1 / `meta_format_version` ≠ 1 /
  `manifest_schema_version` ≠ 1 → die(修正阻塞项 #1, 与 fetch cache §4.4 对称)
- `manifest_sha256` 不符 → die
- `content_sha256` ≠ sha256(SHA256SUMS)→ die
- 幂等成功(同 content_sha256,expected-SHA256SUMS 一致)
- 同版本不同 content_sha256 → die
- 文件名注入(`../`/whitespace/`-` 开头)→ die
- lock.tsv 缺失/格式错 → die
- **不得**调用 Python/PyYAML/网络(断言)

---

## 4. Slice 3 — fetch-source.sh refactor (only behavior-changing slice)

### 4.1 Behavior contract (locked, two ironclad rules)

```
FETCH_SOURCE=pool
  → 读 source-lock/<source>/<version>.lock.tsv 取锁定身份
  → 校验 pool ∈ allowed_sources(任何网络请求前); 否则 die
    "lock does not authorize pool source for <source>/<version>"
  → URL = https://deb.debian.org/debian/pool/<pool_path>/<filename>
    (含固定 /pool/; pool_path = main/o/ocserv)
  → 强校验闭环(§3.6 step 5 的 8 步顺序, 与 prefetch 同源同序)
  → 解包 .dsc (dpkg-source --require-valid-signature --require-strong-checksums -x)
  → publish 到 build/source/ + publish orig tarball
  → pool 失败即失败; 不得访问 Snapshot, 不得回退 cache, 不得隐式切源

FETCH_SOURCE=cache
  → 读同一份 source-lock/<source>/<version>.lock.tsv(不靠 .env 版本号猜 cache 身份)
  → 读 build/source-cache/<name>/<version>/(零网络)
  → 身份闭环(§4.4)
  → 解包 → publish(同 pool 的 publish 路径收敛)
  → 任一校验失败即失败; 不得回退 pool, 不得访问 Snapshot
```

**默认值:** `.env` 缺省 `FETCH_SOURCE=pool`(当前版本 1.5.0-1 的首选来源)。
**未知/缺失值:** 除 `pool`/`cache` 外一律 die(不回退默认)。

### 4.1.1 Builder runtime dependencies (修正阻塞项 #3)

`FETCH_SOURCE=pool` 与 `cache` 都执行 `dpkg-source --require-valid-signature
--require-strong-checksums`;pool 模式还执行 `dscverify` + 在线下载。因此构建机
(不只是预取节点)必须有对应运行时依赖。**这些必须在 runbook 的构建机前置检查中体现,
不只是预取节点章节。**

```
FETCH_SOURCE=pool:                     FETCH_SOURCE=cache:
  curl (locked downloader, §3.6.2)       dpkg-dev
  devscripts (dscverify)                 debian-keyring
  dpkg-dev                               debian-tag2upload-keyring
  debian-keyring
  debian-tag2upload-keyring
```

**bundle import 节点(import-source-cache.sh)依赖:**
```
  GNU tar
  zstd                          (tar --zstd 调用它)
  coreutils                     (sha256sum, cmp, mktemp, ...)
  dpkg-dev                      (.dsc metadata 校验)
  debian-keyring + debian-tag2upload-keyring
```
(import 不执行 dscverify,但仍校验 `.dsc` metadata;若未来 import 也跑 dscverify
则需补 devscripts。)

- pool 模式需要 `devscripts`(提供 `dscverify`)+ keyring + `curl`(下载器锁定为
  curl,不二选一,见 §3.6.2)。
- cache 模式不需要 `dscverify` / `curl`(§4.4:cache 的 `.dsc` 已在 prefetch 阶段
  验签;cache 零网络),但仍需 `dpkg-dev` + keyring —— 因为
  `dpkg-source --require-valid-signature` 会用 keyring 重新验证 `.dsc` 签名。
- `debian-keyring` 提供 `debian-keyring.gpg` + `debian-maintainers.gpg` +
  `debian-nonupload.gpg`;`debian-tag2upload-keyring` 提供 `debian-tag2upload.pgp`
  (Trixie 实际路径)。四份随系统升级更新内容(见 §3.4 provenance.verification 记录)。
- `dpkg-source` 原生支持同时要求有效 OpenPGP 签名和强 SHA-256 checksum。

**与 §3.6 预取节点依赖的关系:** 预取节点是 pool+snapshot 超集(额外需要
python3+PyYAML,因为它跑 read-source-lock.py);构建机的 pool 模式依赖与预取节点的
非 Python 部分一致。cache 模式依赖是 pool 模式的子集(无 devscripts、无 curl/wget、
无网络)。

### 4.2 Deletion list (from existing fetch-source.sh)

- `fetch_via_snapshot_staged()`
- `is_509_failure()` + 509 文案
- `snapshot_stage`、`dget_log`、Snapshot dget 日志分类流程
- 所有 `DEBIAN_SNAPSHOT_TIMESTAMP` 读取、Snapshot URL 拼接
- 所有"Snapshot rate-limited 后自动读 cache"逻辑
- 相关测试(见 §4.5)

**保留并改造的 helper(locked):**
- `_dsc_field` / `parse_dsc_artifacts` / `validate_artifact_basenames` /
  `validate_dsc_metadata` / `publish_source_tree` / `publish_orig_tarball` /
  TMP_ROOT + trap / staging 原子 publish + rollback
- `verify_cache_artifacts` **升级**:从"检查存在"→ `sha256sum -c SHA256SUMS`
  (配合 cache.meta/manifest hash)
- 上述 `_dsc_*` **迁出到 `scripts/_dsc.sh` 共享模块**(切片 2 已新建;此处 fetch
  改为 `source _dsc.sh` 并删内联副本,消除重复)

### 4.3 Refactored main flow

**路径解析(仓库根相对,非 cwd 相对;修正 #2):** 不仅 lock path,所有 repo-owned
`build/` 路径也必须固定到仓库根,否则从子目录执行脚本会把 cache/staging/source/
bundle 写入错误的当前工作目录。所有脚本(fetch/prefetch/import)在入口解析一次:

```bash
REPO_ROOT="$(git -C "${SCRIPT_DIR}/.." rev-parse --show-toplevel)"
BUILD_ROOT="$REPO_ROOT/build"
CACHE_ROOT="$BUILD_ROOT/source-cache"
SOURCE_ROOT="$BUILD_ROOT/source"
BUNDLE_ROOT="$BUILD_ROOT/source-bundles"
```

(脚本的 `SCRIPT_DIR` 由 `BASH_SOURCE` 推导;`git -C` 定位仓库根,不依赖 cwd。)

- `fetch-source.sh`:TMP_ROOT=`$BUILD_ROOT/.fetch-tmp.*`;cache=`$CACHE_ROOT/<name>/<version>`;
  publish 目标=`$SOURCE_ROOT/...`
- `prefetch-source.sh`:staging/cache/bundle 均写入 `$BUILD_ROOT` 下
- `import-source-cache.sh`:lock 从 `$REPO_ROOT/source-lock/...` 读;导入到
  `$CACHE_ROOT/<name>/<version>`
- 外部输入 bundle 可以是任意绝对或相对路径(用户在命令行提供);但**脚本自身生成**
  的 bundle 统一落在 `$BUNDLE_ROOT/`

```
main():
  load .env (FETCH_SOURCE, OCSERV_UPSTREAM_VERSION, OCSERV_DEBIAN_REVISION)
  validate FETCH_SOURCE ∈ {pool, cache}; 否则 die
  resolve paths(见上: REPO_ROOT/BUILD_ROOT/CACHE_ROOT/SOURCE_ROOT)
  UPSTREAM="${OCSERV_UPSTREAM_VERSION:-1.5.0}"; REVISION="${OCSERV_DEBIAN_REVISION:-1}"
  REQUEST_VER="${UPSTREAM}-${REVISION}"
  lock_tsv="${REPO_ROOT}/source-lock/ocserv/${REQUEST_VER}.lock.tsv"

  # 通过受限 parser 读取 lock 身份(§4.3.1)
  read_lock_tsv "$lock_tsv" REQUEST_VER   # 把 META 字段填入全局

  # 三方身份断言(修正 #3; §5.1 的注释提升为行为契约):
  #   (1) env-derived REQUEST_VER (OCSERV_UPSTREAM_VERSION-OCSERV_DEBIAN_REVISION)
  #   (2) lock.tsv META.debian_version
  #   (3) lock path 中的 <ver> 段
  #   三者必须相等;且 META.source 必须 == "ocserv"。任一不符 → die。
  [[ "$REQUEST_VER" == "$META_DEBIAN_VERSION" ]] \
    || die "env-derived version '${REQUEST_VER}' != lock.tsv META debian_version '${META_DEBIAN_VERSION}'"
  [[ "$META_SOURCE" == "ocserv" ]] \
    || die "lock.tsv META source '${META_SOURCE}' != 'ocserv'"

  mkdir -p "$BUILD_ROOT"; TMP_ROOT=mktemp -d "$BUILD_ROOT/.fetch-tmp.XXXXXX"; trap cleanup
  mkdir staging=${TMP_ROOT}/staging

  case FETCH_SOURCE in
    pool)   fetch_via_pool "$staging" "$lock_tsv" ;;
    cache)  fetch_via_cache "$staging" "$lock_tsv" "$CACHE_ROOT" ;;
  esac

  publish_source_tree "${staging}/ocserv-${UPSTREAM}" "${SOURCE_ROOT}/ocserv-${UPSTREAM}"
  publish_orig_tarball "$staging" "$SOURCE_ROOT"
  log "source tree ready: ${SOURCE_ROOT}/ocserv-${UPSTREAM} (from ${FETCH_SOURCE})"
```

`fetch_via_pool` / `fetch_via_cache` 各自在 staging 内完成下载/校验/解包,成功后由
main 统一 publish(两路径收敛,复用现有 publish)。

> cache 模式下,cache 目录名 `<name>/<version>` 是第四方身份(§4.4 步骤 3 已要求它
> == META source/version == 目录名),即 cache 场景实为四方一致(env→META→lock
> path→cache dir)。三方断言在 main 早期完成,cache 目录名断言在 fetch_via_cache 内。

### 4.3.1 `read_lock_tsv()` restricted parser (builder-side, fix #3)

构建机完全依赖 `.lock.tsv`(零 Python),因此消费必须用受限 parser,不是裸
`while read`。`_lock_tsv.sh`(切片 2 新增的共享模块,见 §1.4 自检;供 prefetch/import/fetch
复用,避免三处实现漂移)导出两个函数:

- `read_lock_tsv <file> <expect_version>`: 解析 + 严格校验 + 三方身份断言,
  填全局 META_* 变量 + ARTIFACT 数组(见下方规则)
- `write_expected_sha256sums <out_file>`: 由当前 META_*/ARTIFACT 生成
  expected-SHA256SUMS(行序 = dsc 在前 + artifacts 按 lock 顺序),供 `cmp -s` 用

`read_lock_tsv()` 规则:

```
输入: lock.tsv 路径, 期望的 request version(用于反向断言)
输出: 填充全局 META_* 变量 + ARTIFACT 数组; 任一校验失败 → die

解析约束:
- 恰好一个 META 记录, 且必须位于第一行
- 至少一个 ARTIFACT
- 记录类型仅 META / ARTIFACT; 未知 record type → die
- 字段间 TAB 分隔; 记录以 \n 结尾; \r (CRLF 残留) → die
- 无空字段、无额外字段、无缺失字段(META 固定 9 列, ARTIFACT 固定 4 列)
- sentinel "-": snapshot_timestamp / pool_path 字段为 "-" 时还原为空

字段格式校验(复用 §2.2 YAML schema 同一套规则, 防 YAML/TSV 两侧漂移):
- source: ^[a-z0-9][a-z0-9+.-]*$
- debian_version: ^[A-Za-z0-9.+~-]+$ (无 epoch, advisory B)
- pool_path(非 sentinel 时): §2.2 pool_path 规则
- dsc.name / artifacts[].name: 安全 basename + §3.10 收紧(禁 whitespace/禁 "-" 开头);
  dsc.name 必须 .dsc 结尾
- size: ^[0-9]+$ (非负整数)
- sha256: ^[0-9a-f]{64}$
- allowed_sources: 排序去重后的 pool[,snapshot]; 与 timestamp/pool_path 双向绑定一致
  (snapshot ∈ → timestamp 非 sentinel; pool ∈ → pool_path 非 sentinel)

身份断言(在 parser 内或 main 内完成):
- ARTIFACT name 不可重复
- ARTIFACT name 不可 == dsc.name
- META.source 必须 == "ocserv"(本项目固定 source)
- META.debian_version 必须 == 期望 request version(env-derived; §4.3 三方断言)
- lock path 中的 <ver> 段必须 == META.debian_version(路径与内容一致)

禁 eval / 禁 source lock.tsv 文件(它是数据, 不是脚本)。
```

> import-source-cache.sh(§3.7)也消费 `.lock.tsv`,复用同一 `_lock_tsv.sh` 的
> `read_lock_tsv()`,但 import 的"期望 version"来自 bundle 文件名解析而非
> .env(见 §3.7 步骤 2/4)。

### 4.4 cache identity closure (most critical security enhancement)

`FETCH_SOURCE=cache` 不能只验证 cache **内部自洽**(cache.meta + manifest hash +
SHA256SUMS + .dsc metadata)——攻击者/错误导入流程若同时替换 `.dsc`/artifacts/
SHA256SUMS/source-manifest.json/cache.meta,内部自洽校验会全部通过,但字节内容已不
再对应当前 lock。

```
1. 读 source-lock/<source>/<version>.lock.tsv 取锁定身份
2. 读 cache.meta(read_cache_meta 受限 parser): meta_format_version,
   bundle_format_version, source, debian_version, content_sha256,
   manifest_sha256, manifest_schema_version
3. 调用 verify_cache_meta_versions()(修正 #3 — cache mode 独立、零网络验证,
   不依赖历史 import 已查过):
   meta_format_version == 1; bundle_format_version == 1;
   manifest_schema_version == 1(manifest_schema_version 是 cache.meta 镜像值,
   consumer compatibility declaration, 见 §3.5.1)
4. cache.meta.source/version == .lock.tsv 的 META source/version
   (且 == 目录名 <name>/<version>, 四方一致: env→META→lock path→cache dir)
5. cache.meta content_sha256 == sha256(cache/SHA256SUMS)
   (cache.meta 自洽; content_sha256 是 artifact 身份)
6. 由 .lock.tsv 生成 expected-SHA256SUMS(行序 = dsc 在前 + artifacts 按 lock 顺序)
7. cmp -s expected-SHA256SUMS cache/SHA256SUMS    # 关键: lock ↔ cache 清单精确一致
8. sha256sum -c cache/SHA256SUMS                   # 验实际字节
9. manifest 完整性: echo "$manifest_sha256  source-manifest.json" | sha256sum -c -
   (仅 cache 内部一致性; manifest 是审计/provenance 文档, 不参与 build identity)
10. 解析 cache .dsc 的 Files/Checksums-Sha256 映射(复用 _dsc.sh),
    与 .lock.tsv 完全一致(dsc_artifacts_match_lock)
11. dpkg-source --require-valid-signature --require-strong-checksums -x
```

**cache 模式 cache.meta 字段全部被消费(修正阻塞项 #1):** `meta_format_version`、
`manifest_schema_version`(步骤 3)、`content_sha256`(步骤 5)、`manifest_sha256`
(步骤 9)均**读取即验证**,不存"读而不用"的字段。`content_sha256 == sha256(SHA256SUMS)`
与 import(§3.7 步骤 8g)对称。

`cmp -s`(步骤 7)是身份锚点——它让"同时替换 cache 全部文件"的攻击失效(替换后
清单必须仍字节等于 lock 派生内容,而 lock 是 Git-tracked + CI 守卫的)。

**cache 模式不单独跑 `dscverify`:** cache 里的 `.dsc` 在 prefetch(§3.6 step 5g)
阶段已通过 `dscverify`(固定信任根,见 advisory A);cache 是不可覆盖的(prefetch
验证后才原子写入)。cache 模式步骤 11 的 `dpkg-source --require-valid-signature` 会
**重新验证** `.dsc` 的 OpenPGP 签名(签名内嵌于 `.dsc` 文件,不需额外 artifact),作为
解包前的最后一道防线。无需重复 `dscverify` 的 keyring 解析步骤。

**身份闭环链条(spec 必显式记录):**
```
Git-tracked YAML
  → CI verified .lock.tsv
  → cache SHA256SUMS (cmp -s)
  → source artifact bytes (sha256sum -c)
  → .dsc signed metadata (dscverify + dpkg-source --require-valid-signature)
  → extracted source tree
```

### 4.5 Slice 3 tests

**删除:** 所有 Snapshot 测试、`is_509_failure` 测试、509→cache fallback 测试、
`DEBIAN_SNAPSHOT_TIMESTAMP` 相关测试。

**保留并迁移(适配新 cache 目录结构):**
- `.dsc` metadata 校验、artifact 集合一致性、文件名安全(含 §3.10 收紧)、缺失
  artifact、强校验和、原子 publish、publish rollback、TMP_ROOT trap 清理。

**新增:**
- `FETCH_SOURCE=cache` 完整成功(零网络);cache.meta 篡改/重复字段/未知字段 → die;
  SHA256SUMS 篡改(改字节)→ die;manifest_sha256 不符 → die;版本目录不匹配 → die;
  `.dsc` metadata 不符 → die;解包失败 → die
- cache `meta_format_version` ≠ 1 → die(修正阻塞项 #1)
- cache `manifest_schema_version` ≠ 1 → die
- cache `bundle_format_version` ≠ 1 → die(修正 #3 — cache mode 独立验证,
  不依赖历史 import 已查过;verify_cache_meta_versions 三项全查)
- cache `content_sha256` ≠ sha256(SHA256SUMS)→ die(读而不用漏洞)
- cache 内部 SHA256SUMS 自洽但与 `.lock.tsv` 不一致(`cmp -s` 失败)→ die(防全量
  替换攻击)
- cache `.dsc`/artifact 内容与 lock 不一致 → die
- `FETCH_SOURCE=pool` 成功(stub HTTP);下载 `.dsc` sha256 不符 → die;`.dsc`
  Files ≠ lock.artifacts → die;artifact sha256 不符 → die
- `FETCH_SOURCE=pool` 未获 `allowed_sources` 授权 → **零网络**失败
- `FETCH_SOURCE=pool` 失败时**不得调用 Snapshot 或 cache**(断言无 snapshot/cache
  代码路径执行)
- pool URL 必须包含 `/pool/`
- pool 强校验闭环:dsc.Checksums-Sha256.{size,sha256} == lock.{size,sha256} ==
  actual,三者闭环
- dscverify 必须在 artifact 下载完成后才执行(顺序断言)
- cache 模式**不得**调用 Python/PyYAML/Snapshot/pool downloader(断言零网络 + 零
  Python)
- 非法 `FETCH_SOURCE` 值 → die

**`read_lock_tsv()` 受限 parser 测试(修正 #3):**
- 合法 lock.tsv → META + ARTIFACT 字段正确填入
- META 不在第一行 / 无 META / 多个 META → die
- 无 ARTIFACT / ARTIFACT name 重复 / ARTIFACT name == dsc.name → die
- 未知 record type → die
- 空字段 / 额外字段(META ≠ 9 列, ARTIFACT ≠ 4 列)/ 缺失字段 → die
- CRLF 残留(`\r`)→ die
- 字段格式违反(source/debian_version/pool_path/filename/size/sha256 复用 §2.2 规则)
  → die
- `allowed_sources` 未排序/未去重 / 与 timestamp/pool_path 双向绑定不一致 → die

**三方身份断言测试(§5.1 注释提升为行为契约):**
- env-derived REQUEST_VER ≠ lock.tsv META.debian_version → die
- lock path `<ver>` 段 ≠ META.debian_version → die
- META.source ≠ "ocserv" → die

**跨脚本子目录执行测试(修正 #2 — repo-owned 路径固定到仓库根):**
- 从仓库子目录执行 prefetch/import/fetch:lock 仍从 `$REPO_ROOT/source-lock`
  读取;cache/source/tmp/bundle 均写入 `$REPO_ROOT/build`;**当前子目录不产生**
  `build/`(断言:子目录下无新增 build/)
- 外部输入 bundle(用户命令行提供)可以是相对/绝对路径,不受仓库根约束

---

## 5. Slice 4 — documentation & migration (docs only)

> 切片 4 在构建机行为稳定(切片 3 合并)后统一同步文档。**只同步文档,不再次改变 CI
> 或构建行为。**(CI projection guard 的实施归切片 1,见 §5.5。)

### 5.1 `.env.example` modifications

**删:**
```
DEBIAN_SNAPSHOT_TIMESTAMP=YYYYMMDDTHHMMSSZ
```
(构建机不再读它;snapshot timestamp 归 lock 文件,仅预取节点消费,并由
`source-manifest.json` 记录 provenance。`FETCH_SOURCE=cache` 不需要、也不解析
timestamp。)

**加:**
```
# Source acquisition mode (builder):
#   pool  = fetch from deb.debian.org/debian/pool/<pool_path>/ (default; current version)
#   cache = read verified build/source-cache/<name>/<version>/ (zero network)
# The YAML lock is the Git-tracked authority. Builders consume the CI-verified
# source-lock/<name>/<version>.lock.tsv projection; all source identity and
# artifact checksums are taken from that TSV, not inferred from the network.
# OCSERV_UPSTREAM_VERSION / OCSERV_DEBIAN_REVISION are only used to resolve the
# target lock path (e.g. source-lock/ocserv/1.5.0-1.lock.tsv); they are NOT the
# authoritative source identity. If the env-derived request path does not match
# the META identity inside the TSV, the script MUST fail.
# No automatic fallback. pool+cache both unavailable => explicit failure.
FETCH_SOURCE=pool
```

保留 `OCSERV_UPSTREAM_VERSION` / `OCSERV_DEBIAN_REVISION`(只用于解析目标 lock
路径,非 source identity 权威来源)。

### 5.2 README modifications

把 fetch 段的"从 snapshot.debian.org 固定时间戳获取"改为"按 `source-lock/` 锁定
身份从 pool(默认)或 cache 获取"。新增一句指向 runbook 的"源码获取与预取工作流"
小节。

### 5.3 runbook modifications (main body)

**(a) 删除:**
- L587-593 "什么是 snapshot 时间戳"整段(构建机不再消费 timestamp)。
- L595-617 "预置源码缓存(应对 snapshot.debian.org rate-limit)"整段(自动 509
  回退语义已废除)。
- L580-585 §4.1 的 `DEBIAN_SNAPSHOT_TIMESTAMP` 占位符编辑步骤。

**(b) 新增 §4.1(替代)— "源码获取模式与锁定身份":**
- 解释 `FETCH_SOURCE=pool|cache`,默认 pool。
- 解释 `source-lock/<name>/<version>.yaml` 是权威源,`.lock.tsv` 是 CI 守卫的构建
  机消费产物。
- 验收改为:`grep FETCH_SOURCE .env` 输出 pool 或 cache;
  `test -f source-lock/ocserv/1.5.0-1.lock.tsv`。

**(c) 新增 §4.1.1 — "Snapshot 预取与 cache 导入工作流"**

**只描述预取与导入的角色边界。**写出 `prefetch-source.sh`、bundle 产物、人工/运维
层搬运、`import-source-cache.sh`、切换 `FETCH_SOURCE=cache` 即可;**不**写
`rsync`、`scp`、对象存储地址、Registry 地址、凭据或传输协议细节。bundle sidecar
hash 只用于完整性检查,**不应**表述为传输来源认证。

```
# 预取节点(能访问 snapshot.debian.org):
pip install -r requirements/prefetch.txt
scripts/prefetch-source.sh --lock source-lock/ocserv/1.5.0-1.yaml
# → 生成 build/source-cache/ocserv/1.5.0-1/ + ocserv_1.5.0-1.source-cache.tar.zst(+.sha256)

# 运维层搬运 bundle 到构建机(方式自选: rsync/scp/registry; 不脚本化)
[人工/运维层: 将 ocserv_1.5.0-1.source-cache.tar.zst 及其 .sha256 送达构建机]

# 构建机(接收 bundle):
scripts/import-source-cache.sh ocserv_1.5.0-1.source-cache.tar.zst
# → 原子导入 build/source-cache/ocserv/1.5.0-1/

# 构建机: 切到 cache 模式构建
FETCH_SOURCE=cache make dry-run
```

**(d) 重写 §4.2 fetch 产物表行(L657):**
```
| 1 | fetch | build/source/ocserv-1.5.0/ + ocserv_1.5.0.orig.tar.xz(+.asc) | FETCH_SOURCE=pool 在线取锁定版本, 或 cache 读已校验版本化 cache; 不访问 Snapshot; 不自动回退 |
```

**(e) 重写 §4.3 fetch 失败定位(L689-698):**
```
步骤 1 fetch 失败:
  FETCH_SOURCE=pool:
    可能原因 A: source-lock/<name>/<version>.lock.tsv 缺失或不一致
      → 重新生成(CI 守卫); 确认 .yaml 与 .tsv 同 commit
    可能原因 B: lock 未授权 pool(pool ∉ allowed_sources)
      → 改用 cache 模式或更新 lock
    可能原因 C: 下载/校验失败(sha256 不符、dscverify 失败、解包失败)
      → 检查网络/pool 可达性; 不得手动改 cache
    可能原因 D: pool 不可达
      → 显式失败; 不自动回退。预取节点导入 cache 后改用 FETCH_SOURCE=cache
  FETCH_SOURCE=cache:
    可能原因 A: build/source-cache/<name>/<version>/ 缺失
      → 预取节点 prefetch + 导入 bundle
    可能原因 B: cache 与 .lock.tsv 不一致(cmp -s 失败)
      → cache 被篡改/过期; 删除后重新 import; 不得手动修补
    可能原因 C: sha256sum -c / dscverify / 解包失败
      → cache 损坏; 删除重新 import
```

**(f) 更新幂等/retry 段(L726-730):** 保留"fetch 在新临时 staging 完成,验证后
替换 build/source/"的表述(切片 3 仍如此);补一句 pool 与 cache 两模式共用同一
publish 路径。

### 5.4 Makefile comment

`fetch:` target 注释从 `dget ocserv source from snapshot.debian.org` 改为
`fetch ocserv source per FETCH_SOURCE (pool|cache), locked by source-lock/`。

### 5.5 CI workflow (IMPLEMENTED in slice 1; slice 4 only documents semantics)

**切片 1 已实施 lock projection CI job**(切片 1 scope,见 §1.4 / §2.5)。
切片 4 仅在 README/runbook 中**说明该守卫的语义与失败处理**,不再次改变 CI 或构建
行为。

切片 1 落地的 CI job(参考实现,记录于此供切片 4 文档引用):
```yaml
- name: verify lock.tsv projection
  run: |
    set -euo pipefail
    # 受控安装 PyYAML(parser 依赖它), 隔离在 venv 不污染构建机
    python3 -m venv .ci-venv
    .ci-venv/bin/python -m pip install -r requirements/prefetch.txt
    tmp="$(mktemp)"
    # 每个 yaml 必须有 byte-for-byte 一致的 .lock.tsv
    while IFS= read -r -d '' yaml; do
      .ci-venv/bin/python scripts/read-source-lock.py --lock "$yaml" >"$tmp"
      cmp -s "$tmp" "${yaml%.yaml}.lock.tsv" \
        || { echo "lock.tsv drift: $yaml"; exit 1; }
    done < <(find source-lock -type f -name '*.yaml' -print0 | sort -z)
    # 孤立 .lock.tsv(无对应 .yaml)必须失败
    while IFS= read -r -d '' tsv; do
      [[ -f "${tsv%.lock.tsv}.yaml" ]] \
        || { echo "orphan lock.tsv: $tsv"; exit 1; }
    done < <(find source-lock -type f -name '*.lock.tsv' -print0 | sort -z)
```

> 用 `find ... -print0 | sort -z` 替代 `source-lock/**/*.yaml` glob:后者需显式启用
> `globstar` 才递归,且 word-splitting 对含空格路径不安全。`-print0` + `read -d ''`
> 是 NUL 分隔的 POSIX 安全遍历。

切片 4 文档需说明:任一 `.lock.tsv` 缺失、存在孤立 `.lock.tsv`、或与 parser 当前
输出不完全一致,CI 必须失败。CI 在 venv 内安装 PyYAML,构建机本体**不**安装
PyYAML(构建机只读 `.lock.tsv`,零 Python/零 PyYAML)。

### 5.6 Deletion scope checklist (no dead references left)

| 位置 | 处置 |
|------|------|
| `.env.example` `DEBIAN_SNAPSHOT_TIMESTAMP` | 删 |
| `.bootstrap.env.example` | 检查是否引用 timestamp(若否不动) |
| README "snapshot 时间戳"表述 | 改 |
| runbook L587-617(timestamp + 509 cache 段) | 删 |
| runbook L580-585(timestamp 编辑步骤) | 删/替换 |
| runbook L689-698(fetch 失败定位 509 分支) | 重写 |
| Makefile fetch 注释 | 改 |
| 任何残留的 "snapshot.debian.org 首选" 表述 | 清除 |

### 5.7 Slice 4 tests

文档类无 bats 测试;但加一个 shell 单测验证 `.env.example` 含合法
`FETCH_SOURCE=` 行且不含 `DEBIAN_SNAPSHOT_TIMESTAMP`(防回退)。

---

## 6. Verification (post-implementation, per slice)

**切片 1:**
- `make test` → `test_read_source_lock.bats` 全部通过(含 `.lock.tsv` byte-for-byte
  派生测试)。
- CI lock projection guard job 在 `.lock.tsv` 漂移/孤立时 fail。
- 构建机 dry-run 行为**不变**(切片 1 纯新增,fetch-source.sh 未动)。

**切片 2:**
- `make test` → `test_prefetch_source.bats` / `test_import_source_cache.bats` 全部
  通过。
- 在预取节点:对合法 lock 跑 prefetch → 生成 cache + bundle;篡改任一 artifact
  → die。
- 在构建机:import 合法 bundle → 原子导入;篡改 bundle/SHA256SUMS/cache.meta →
  die;幂等成功。
- 构建机 dry-run 行为**不变**(切片 2 纯新增)。

**切片 3:**
- `make test` → `test_fetch_source.bats` 全部通过(删除 Snapshot/509 测试 + 新增
  pool/cache 测试)。
- `FETCH_SOURCE=pool make dry-run` → fetch 从 deb.debian.org/pool 取锁定版本,通过
  全强校验闭环 + dscverify + 解包。
- `FETCH_SOURCE=cache make dry-run`(已 import cache)→ fetch 零网络读 cache,通过
  身份闭环(cmp -s + sha256sum -c + .dsc 匹配 lock)→ 解包。
- pool 失败/不可达 → 显式失败,**不**回退 cache/snapshot。
- cache 与 `.lock.tsv` 不一致 → 显式失败(防全量替换攻击)。

**切片 4:**
- `.env.example` 单测通过(合法 FETCH_SOURCE、无 DEBIAN_SNAPSHOT_TIMESTAMP)。
- runbook / README / Makefile 无残留 "snapshot 首选" / "509 自动回退" 表述。
- CI projection guard job 语义在 README/runbook 中有说明。

---

## 7. Non-goals

- Do NOT add automatic cache population from pool on the builder (pool success
  does **not** write cache; cache is prefetch/import-only product).
- Do NOT keep the snapshot-first / 509-auto-fallback path in `fetch-source.sh`
  (deleted in slice 3).
- Do NOT hardcode bundle transport (rsync/scp/registry/credentials) into any
  script.
- Do NOT make `FETCH_SOURCE=pool` mean "latest version"; it always consumes the
  locked `<name>/<version>` identity.
- Do NOT implement HTTP 509 classification/retry/backoff in prefetch's first
  version (deferred — needs explicit retry-count / backoff / wait-cap / final-
  failure semantics).
- Do NOT renumber existing runbook sections (this change only
  inserts/updates/replaces content within existing sections).
- Do NOT parse YAML/JSON on the builder (builder is zero-Python/zero-PyYAML).
- Do NOT support `FETCH_SOURCE=snapshot` on the builder (removed; snapshot access
  only via prefetch on a node with access).
- Do NOT support epoch in `debian_version` in this revision (schema rejects epoch;
  ocserv 1.5.0-1 has none — advisory B). Future epoch support requires lock
  schema upgrade (`unpack_dir` / `upstream_version_without_epoch`) + fetch
  directory/tarball derivation rework.
