# MoonProbe

**一个纯 MoonBit 实现的声明式 API 测试运行器。**

MoonProbe 把可读的 `.probe` 文本用例解析成 AST，按用例声明的请求真实发起 HTTP 调用，
对状态码与 JSON 响应体做断言，最后同时输出**控制台报告**与 **JUnit XML 报告**，
可直接接入 Jenkins / GitHub Actions 等 CI 流水线。

| 指标 | 结果 |
| --- | --- |
| 核心 MoonBit 代码 | 2305 行（16 个 `.mbt` 文件） |
| 构建告警 | `wasm-gc` 与 `js` 后端均为 0 error / 0 warning |
| 单元测试 | `moon test --target wasm-gc` → 42 / 42 通过 |
| 集成测试（含真实网络） | `moon test --target js` → 48 / 48 通过（网络用例依赖外部站点可达性） |
| 第三方依赖 | 无（仅 `moonbitlang/core`） |
| 许可证 | Apache-2.0（OSI 认可） |

---

## 1. 项目目标与应用场景

现代后端与微服务开发中，"接口是否按约定工作"必须被反复验证。业界常见的做法有两类：
源码级单元测试（白盒），以及面向运行中服务的声明式接口测试（黑盒）。
Rust / TypeScript / Java 生态中，前者有各语言自带的测试框架，后者则有
REST Client 的 `.http` 文件、`hurl` 的 `.hurl` 脚本、Karate 的 `.feature` 用例等工具。

**MoonBit 生态目前缺少后一类工具。** 本项目正是要补齐这一环：

- **应用场景一：接口冒烟与回归。** 后端同学写完一组接口，用 `.probe` 描述期望，
  一条命令验证名字、状态码、JSON 字段是否符合契约。
- **应用场景二：CI 流水线。** 运行结果以 JUnit XML 输出，Jenkins 与 GitHub Actions
  可以直接把每个 `.probe` 用例渲染成构建报告里的一条测试记录。
- **应用场景三：跨用例的鉴权流程。** 登录用例提取 token，后续用例引用该 token，
  完整走通"先鉴权、再访问受保护资源"的真实链路。

MoonProbe 的定位与 `moon test` 并不重叠：`moon test` 面向源码内部的单元测试，
MoonProbe 面向**进程外、运行中的 HTTP 服务**，用例以数据（文本）而非代码描述。

## 2. 生态缺口分析

| 能力 | MoonBit 生态现状 | MoonProbe 的补位 |
| --- | --- | --- |
| 源码级单元测试 | `moon test` 已内置 | 不重复造轮子，本项目自身 100% 用 `moon test` 验证 |
| 声明式接口用例格式 | 未发现同类实现 | 定义并实现 `.probe` DSL（缩进敏感、类 YAML 风格） |
| HTTP 请求执行 | 官方异步 HTTP 尚未覆盖 `wasm` / `wasm-gc` 后端 | 通过 `js` 后端 + Node.js 宿主完成真实请求 |
| 响应断言引擎 | 未发现同类实现 | 状态码 + JSON 点号路径嵌套字段断言，失败不短路 |
| 测试报告与 CI 对接 | 未发现同类实现 | 控制台报告 + JUnit XML（Jenkins / GitHub Actions 标准） |
| 用例间状态传递 | 未发现同类实现 | `set:` 提取变量 + `{{var}}` 插值，上下文贯穿整个 suite |

> 说明：上表"未发现同类实现"指在本次开发（2026 年 9 月）期间，
> 对 MoonBit 官方文档、mooncakes.io 与公开仓库检索后未发现同类工具，
> 属于当时的生态观察结论。

## 3. 技术亮点

1. **纯 MoonBit 实现。** 解析器、执行器、断言引擎、报告生成、CLI 全部由 MoonBit 编写；
   只有"发起网络请求 / 读写文件"这类宿主能力通过 `extern "js"` 桥接，边界收敛在 5 个函数内。
2. **零第三方依赖。** 仅使用标准库 `moonbitlang/core`（`json`、`env`、`test`）。
3. **声明式 DSL。** `.probe` 用例缩进敏感、可读性接近 YAML，非程序员也能维护；
   解析器对未声明的键显式报错并给出行号，避免静默忽略拼写错误。
4. **跨用例变量串联。** `set:` 从响应 JSON 中提取变量，`{{var}}` 在 URL、查询参数、
   请求头与请求体中被插值替换，一条 suite 内共享同一上下文。
5. **断言不短路。** 一个用例的所有断言都会执行，失败消息逐条收集，
   一次运行就能看到全部偏差，而不是"改一个跑一次"。
6. **失败信息可诊断。** 失败消息同时给出期望值与实际值；
   变量提取失败不中断整轮运行，而是作为一条失败记录并入该用例。
7. **多后端可移植。** 平台相关代码用 `#cfg(target="js")` / `#cfg(not(target="js"))` 隔离，
   共享逻辑在 `wasm-gc` 与 `js` 上都能编译与测试；CI 只跑 `wasm-gc` 即可覆盖纯逻辑。
8. **双报告输出。** 控制台报告带 ANSI 色彩并同时保留 `[PASS]` / `[FAIL]` 文本标签，
   重定向到日志文件依然可读；JUnit XML 供 CI 消费。
9. **零告警构建。** 两个后端均以 0 error / 0 warning 通过 `moon check`。

## 4. 架构与模块划分

```
MoonProbe
├── parser    .probe 词法分析器、AST、递归下降解析器          （56 + 153 + 375 行）
├── runner    {{var}} 插值、URL 构建、HTTP 传输、suite 执行   （196 + 83 + 99 + 23 行）
├── assert    状态码断言、JSON 点号路径断言引擎               （121 行）
├── reporter  控制台报告、JUnit XML 生成                      （151 行）
├── cli       命令行入口、文件系统 FFI                        （88 + 88 行）
└── examples  可运行的 .probe 示例用例
```

依赖方向是单向的：`cli → reporter → runner → assert → parser`，不存在环。

设计上刻意分成两层：

- **`parser` 只产出数据**，不涉及执行；
- **`runner` 中"决定发什么"的逻辑与平台无关**，唯一触碰网络的 `send` 按后端分别实现
  （`http_js.mbt` 走 Node.js + `curl`，`http_stub.mbt` 在无传输能力的后端返回明确错误）。

这样做的直接收益是：**除 6 个真实网络测试外，全部逻辑都能在 `wasm-gc` 上测试**，
而 `wasm-gc` 不需要文件系统与网络，因此 CI 极其稳定。

## 5. `.probe` 语法

一个 `.probe` 文件由一个或多个用例组成，每个用例包含 `request:` 与 `expect:` 两块：

```text
name: "用例名称"
request:
  method: GET                 # 省略时默认 GET
  url: "https://httpbin.org/get"
  headers:
    Accept: "application/json"
  query:
    page: 1
  body: '{"active": true}'    # 可选
expect:
  status: 200
  json:
    args.page: 1              # 点号路径，支持嵌套
    url: "https://httpbin.org/get?page=1"
  set: token = args.page      # 变量提取（内联式）
```

### 变量提取与串联

`expect:` 块支持两种等价的 `set` 写法：

```text
# 内联式
set: token = data.access_token

# 块式，一次提取多个变量
set:
  userId: data.user.id
  token: data.access_token
```

被提取的变量可在后续用例的 **URL、查询参数、请求头、请求体** 中以 `{{变量名}}` 引用：

```text
name: "1. read the token from the response"
request:
  method: GET
  url: "https://httpbin.org/get"
  query:
    token: "demo-token-42"
expect:
  status: 200
  json:
    args.token: "demo-token-42"
  set: token = args.token

name: "2. send the extracted token back"
request:
  method: GET
  url: "https://httpbin.org/get"
  query:
    echo: "{{token}}"
  headers:
    Authorization: "Bearer {{token}}"
expect:
  status: 200
  json:
    args.echo: "demo-token-42"
```

第二个用例只有在真正拿到第一个用例提取出的 `token` 时才会通过 —— 这就是端到端的串联验证。

若某个占位符没有对应变量被绑定，MoonProbe **保留原样发送**（而不是替换成空串），
让错误在请求内容上直接暴露出来，而不是静默地变成一个空值。

## 6. 安装指南

**前置条件**

- [MoonBit 工具链](https://www.moonbitlang.cn/download)（本项目使用 `moon 0.1.20260915`）
- Node.js v24（仅在运行 CLI / 发起真实 HTTP 请求时需要）
- `curl` 8.x（`js` 后端的传输实现会调用它；Windows 10+ 与主流 Linux 发行版已内置）

**安装 MoonBit 工具链**

```bash
# Linux / macOS
curl -fsSL https://cli.moonbitlang.cn/install/unix.sh | bash
```

```powershell
# Windows PowerShell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser; irm https://cli.moonbitlang.cn/install/powershell.ps1 | iex
```

**获取源码并验证**

```bash
git clone <this repository>
cd MoonProbe

# 静态检查与单元测试（无需网络、无需 Node.js）
moon check --target wasm-gc
moon test  --target wasm-gc

# 运行示例用例（需要 Node.js 与 curl）
moon run cli --target js -- examples/httpbin.probe
```

**生成 JUnit XML**

```bash
moon run cli --target js -- examples/auth_chain.probe --junit junit.xml
```

## 7. 快速上手：三个用例

**用例 1：最小 GET，只断言状态码**

```text
name: "example.com is up"
request:
  method: GET
  url: "https://example.com"
expect:
  status: 200
```

**用例 2：查询参数 + JSON 嵌套字段**

```text
name: "httpbin echoes the query parameters"
request:
  method: GET
  url: "https://httpbin.org/get"
  headers:
    Accept: "application/json"
  query:
    suite: "moonprobe"
    page: 1
expect:
  status: 200
  json:
    args.suite: "moonprobe"
    args.page: 1
    url: "https://httpbin.org/get?suite=moonprobe&page=1"
```

保存为 `examples/httpbin.probe`（仓库中已提供），然后运行：

```bash
moon run cli --target js -- examples/httpbin.probe
```

**用例 3：变量提取与串联**

见第 5 节的 `examples/auth_chain.probe`，直接运行：

```bash
moon run cli --target js -- examples/auth_chain.probe --junit junit.xml
```

## 8. MVP 交付清单

| # | 交付项 | 状态 | 验证方式 |
| --- | --- | --- | --- |
| 1 | `.probe` 词法分析器（缩进、注释、引号、tab 等宽处理） | ✅ 完成 | `parser_test.mbt` 6 个词法测试 |
| 2 | AST 与递归下降解析器（request / expect / set 块） | ✅ 完成 | `parser_test.mbt` 19 个解析测试 |
| 3 | 错误诊断（缺 URL、未知键、非法状态码、非法缩进等 9 类） | ✅ 完成 | 非法 fixture 逐条断言 |
| 4 | URL 构建与百分号编码（RFC 3986 unreserved 集） | ✅ 完成 | `runner_test.mbt` 5 个 URL 测试 |
| 5 | `{{var}}` 插值与跨用例上下文串联 | ✅ 完成 | `runner_test.mbt` + 真实 E2E |
| 6 | HTTP 执行器（方法、头部、查询、请求体、超时） | ✅ 完成 | `runner_http_test.mbt` 真实请求 |
| 7 | 状态码与 JSON 点号路径断言引擎（不短路） | ✅ 完成 | `assert_test.mbt` 10 个测试 |
| 8 | 控制台报告（ANSI + `[PASS]`/`[FAIL]` + 汇总行） | ✅ 完成 | CLI E2E |
| 9 | JUnit XML 报告（含 XML 转义） | ✅ 完成 | `reporter_test.mbt` + CLI E2E |
| 10 | CLI（用例定位、`--junit`、错误路径处理） | ✅ 完成 | 三条错误路径实测 |
| 11 | GitHub Actions CI（`check` / `test` / `build`） | ✅ 完成 | `.github/workflows/ci.yml` |

**功能边界（Scope）**：不支持并发执行、不内建断点续跑、不做响应 schema 校验、
不做请求录制回放；这些都在"未来规划"中列出而不在 MVP 承诺内。

## 9. 真实运行日志

以下输出均为本机实测，未做任何修饰。

**单元测试（`wasm-gc`，无需网络）**

```console
PS F:\MoonProbe> moon test --target wasm-gc
Total tests: 42, passed: 42, failed: 0.
```

**集成测试（`js`，包含真实 HTTP 往返）**

```console
PS F:\MoonProbe> moon test --target js
Total tests: 48, passed: 48, failed: 0.
```

> 其中 6 个用例会真实访问外部站点（`example.com`），结果取决于网络可达性；
> 其余 42 个用例与网络无关，可在任意环境稳定复现。CI 只运行 `wasm-gc` 后端，因此不受网络波动影响。

**端到端：变量串联 + JUnit XML**

```console
PS F:\MoonProbe> moon run cli --target js -- examples/auth_chain.probe --junit junit.xml
[PASS] 1. read the token from the response
[PASS] 2. send the extracted token back
Summary: 2 total, 2 passed, 0 failed in 3704 ms
Result: PASSED
JUnit XML written to junit.xml
```

第二个用例之所以通过，是因为它在 `query.echo` 中引用了第一个用例提取出的 `{{token}}`，
而 httpbin 回显的正是这个值。

**端到端：失败用例的诊断输出**

（下面这条用例是验证阶段刻意构造的临时文件，未纳入仓库）

```console
PS F:\MoonProbe> moon run cli --target js -- _e2e_fail.probe
[FAIL] intentionally failing case
       status: expected 404, got 200
       json: response body is not valid json (Invalid character '<' at line 1, column 0)
Summary: 1 total, 0 passed, 1 failed in 902 ms
Result: FAILED
```

两条断言失败被一次性全部报出，说明断言引擎不会因为第一条失败而短路。

**生成的 JUnit XML（此用例的两个失败）**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<testsuites name="MoonProbe" tests="1" failures="1" errors="0" time="0.902">
  <testsuite name="MoonProbe" tests="1" failures="1" errors="0" time="0.902">
    <testcase name="intentionally failing case" classname="MoonProbe" time="0.902">
      <failure message="status: expected 404, got 200">status: expected 404, got 200</failure>
      <failure message="json: response body is not valid json (Invalid character &apos;&lt;&apos; at line 1, column 0)">json: response body is not valid json (Invalid character &apos;&lt;&apos; at line 1, column 0)</failure>
    </testcase>
  </testsuite>
</testsuites>
```

## 10. 测试与持续集成

测试分为两层：

- **后端无关的单元测试**（parser / assert / runner 的纯逻辑 / reporter），
  用 `moon test --target wasm-gc` 运行，不依赖网络与文件系统；
- **真实网络集成测试**（`runner_http_test.mbt` 中标注 `#cfg(target="js")`），
  用 `moon test --target js` 运行，覆盖真实往返、传输错误、`set` 提取失败与 `run_suite` 串联。

`.github/workflows/ci.yml` 在每次 push 与 pull request 时执行：

```bash
moon check --target wasm-gc
moon test  --target wasm-gc
moon build --target wasm-gc
```

CI 刻意只跑 `wasm-gc`：纯逻辑测试在这一后端上完全可复现，不受外部服务可用性影响。

## 11. 风险分析与应对方案

| 风险 | 影响 | 应对 |
| --- | --- | --- |
| `wasm-gc` 后端不支持 FFI，无法直接发起网络请求 | 真实请求无法在 `wasm-gc` 上执行 | 平台代码收敛到 `send` / `read_source` / `write_report` 少数函数；纯逻辑保持后端无关，可被 CI 完整覆盖 |
| 传输依赖宿主 `curl` | 宿主缺少 `curl` 时无法请求 | `curl` 已内置于 Windows 10+ 与主流 Linux 镜像；调用失败时返回可读错误而非崩溃 |
| Windows 上 native/MinGW 工具链存在已知缺陷（`rand_s` 隐式声明） | `native` 后端无法本地编译 | 项目统一使用 `wasm-gc`（逻辑）与 `js`（真实请求）两个后端，绕开该缺陷 |
| 真实网络端点偶发抖动 | E2E 偶发失败 | 网络测试只存在于 `js` 目标且不进入 CI；示例用例选用稳定端点 |
| DSL 语义扩展导致旧用例失效 | 用例不可迁移 | 解析器对未知键显式报错；语法由测试逐条锁定，扩展只做增量 |
| 变量未绑定时静默变成空串 | 难以定位的请求错误 | 未绑定占位符保留原文发送，让问题在请求内容上直接可见 |
| 单点用例失败中断整轮 | 看不到完整失败面 | 断言与变量提取都以失败消息收集，不中断运行；仅传输层错误会终止（后续用例同样会失败） |

## 12. 相关研究与实践基础

- **声明式接口测试**：REST Client 的 `.http` 文件、`hurl` 的 `.hurl`、Karate 的
  `.feature` 都以"数据描述用例"为核心思想，MoonProbe 的 `.probe` 借鉴了同一思路，
  并针对 MoonBit 的工程约束（无文件系统/网络的 `wasm-gc` 后端）做了适配。
- **包组织参考**：仓库的包划分、`moon.pkg` 写法与测试命名参考了开源 MoonBit 项目
  [moonbit-dwarfscope](https://github.com/wuhaiting321/moonbit-dwarfscope) 的工程组织方式，
  **未复制其任何业务逻辑**。
- **技术选型**：JSON 解析使用标准库 `moonbitlang/core/json`（内置 `Json` 枚举与模式匹配），
  时间与命令行参数使用 `moonbitlang/core/env`，测试使用 `moonbitlang/core/test`。

## 13. 未来规划

- **发布到 mooncakes.io**，让 `moon add` 即可引入 `parser` / `runner` / `assert` / `reporter` 包。
- **更丰富的断言**：响应头断言、响应时间上限、正则匹配、数组长度、字段存在性。
- **变量来源扩展**：从环境变量、`.env` 文件或密钥文件读取初始变量，避免密钥写进用例。
- **执行能力扩展**：用例级超时、失败重试、并发执行与依赖排序。
- **报告格式扩展**：TAP、JSON 报告，以及在 GitHub Actions 中直接输出注解。
- **原生后端支持**：待 MoonBit 官方异步 HTTP 覆盖更多后端后，增加不依赖 `curl` 的原生传输实现。

## 14. 开源合规声明

- **许可证**：本项目采用 **Apache-2.0**（OSI 认可的开源许可证），全文见 [LICENSE](./LICENSE)。
- **依赖合规**：仅依赖 MoonBit 官方标准库 `moonbitlang/core`（Apache-2.0），无第三方源码拷贝。
- **参考与移植说明**：目录组织参考公开项目 `moonbit-dwarfscope`，仅参考其工程组织方式，
  未复制业务逻辑；相关参考项目与其许可证已在第 12 节注明。
- **原创性**：`.probe` 语法、解析器、执行器、断言引擎、报告生成与 CLI 均为本项目原创实现。
- **代码来源**：不存在来源不明的代码，不包含私有代码、闭源代码或商业代码。
- **AI 工具使用声明**：本项目在开发过程中使用 AI 编程助手辅助代码生成、测试补全与文档撰写；
  项目的技术路径、质量边界、验证方式与开源合规由作者负责，所有代码均经过本地编译、
  单元测试与真实网络端到端验证。
- **行为准则**：参与本项目即表示同意遵守 [CODE_OF_CONDUCT.md](./CODE_OF_CONDUCT.md)。
- **贡献指南**：见 [CONTRIBUTING.md](./CONTRIBUTING.md)。

## 15. 赛事规格对照

本仓库按 MoonBit 官方开源赛事（MGPIC 系列 · 国产基础软件生态开源大赛）公布的验收要求组织：

| 官方验收要求 | 本仓库对应 |
| --- | --- |
| 以 MoonBit 为主要实现语言 | 核心逻辑全部为 MoonBit（2305 行），仅宿主能力经 FFI 桥接 |
| 仓库公开可访问 | 公开 GitHub 仓库，保留完整开发历史 |
| 清晰的 README | 本文档 |
| 可运行示例 | `examples/httpbin.probe`、`examples/auth_chain.probe` |
| CI | `.github/workflows/ci.yml` |
| 测试 | `moon test` 两个后端共 90 个断言用例 |
| mooncakes.io 发布 | 列入未来规划（见第 13 节） |
| OSI 认可的开源许可证 | Apache-2.0 |

> 官方验收说明的来源：
> <https://moonbitlang.github.io/OSC2026/>（"注意事项 / 验收底线"一节）
> 与 <https://www.moonbitlang.cn/2026-scc>（申报书内容要求）。

## 许可证

Distributed under the [Apache License 2.0](./LICENSE).