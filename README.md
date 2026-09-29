# MoonProbe

**纯 MoonBit 实现的声明式 API 测试运行器。**

用简单的 `.probe` 文本描述 HTTP 请求、断言与变量串联，一条命令跑完整个测试集，
输出可读的终端报告与 CI 友好的 JUnit XML。

[![CI](https://github.com/wuhaiting321/MoonProbe/actions/workflows/ci.yml/badge.svg)](https://github.com/wuhaiting321/MoonProbe/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](./LICENSE)

---

## 一、项目基本信息

| 项目 | 内容 |
| --- | --- |
| 项目名称 | MoonProbe |
| 参赛者 | 吴海婷 |
| 联系方式 | 19177746962@163.com |
| GitHub 仓库 | <https://github.com/wuhaiting321/MoonProbe> |
| 项目方向 | MoonBit 开发者工具 / API 测试基础设施 |
| 是否为移植项目 | 否，原创项目 |
| 代码规模 | 约 2305 行 MoonBit 代码，16 个 `.mbt` 文件 |
| 测试状态 | `moon test --target wasm-gc` 全部通过（42 个用例） |
| 构建状态 | `wasm-gc` 与 `js` 后端 `moon check` 零错误、零告警 |
| 开源许可证 | Apache-2.0 |

---

## 二、项目简介

现代后端与微服务开发中，"运行中的服务是否按契约工作"必须被反复验证。业界已经形成
一类成熟的**声明式接口测试**工具：REST Client 的 `.http` 文件、`hurl` 的 `.hurl` 脚本、
Karate 的 `.feature` 用例。它们用**数据**而不是代码描述请求与期望，用例可读、可评审，
不写代码的人也能维护。

**MoonBit 生态目前缺少这一环。** 现有能力集中在源码级单元测试（`moon test`），
没有任何工具可以面向**进程外、运行中的 HTTP 服务**下发请求并校验响应。
MoonProbe 用于补齐这块空白：一个纯 MoonBit 实现的声明式 API 测试运行器。

**与现有能力的本质区别**

- 与 `moon test` 相比：`moon test` 验证的是链接进测试二进制的源码函数，
  用例必须用 MoonBit 书写；MoonProbe 验证的是通过网络访问的远程服务，
  用例用 `.probe` 文本描述，运行期与被测服务的实现语言完全解耦——
  被测服务用 Go、Rust、Java 还是 MoonBit 写的都无关紧要。
- 与各语言的单元测试框架相比：MoonProbe 不感知被测系统的内部结构，
  只施加真实 HTTP 流量，属于黑盒契约验证。
- 与通用 API 调试工具相比：MoonProbe 的用例是**版本化的静态文件**，
  可以随代码一起评审、一起提交，并直接产出 CI 可消费的测试报告。

---

## 三、核心功能范围

- **声明式用例格式**：`.probe` 文本格式，缩进敏感、类 YAML 风格；
  单个文件可包含多个用例，按顺序串行执行。
- **请求定义**：支持 GET / POST 等 HTTP 方法、URL、查询参数、请求头与请求体，
  方法省略时默认 GET。
- **状态码断言**：对响应状态码做精确匹配。
- **JSON 响应体断言**：用点号路径校验嵌套字段（如 `args.page`、`data.user.id`）；
  单个用例内的断言**不短路**，一次运行报出全部偏差。
- **变量提取与上下文串联**：`expect` 块中的 `set` 指令从响应 JSON 中提取变量，
  后续用例通过 `{{var}}` 语法引用；整个测试集共享同一上下文，
  可完整走通"登录取 token → 携带 token 访问受保护资源"的链路。
- **超时控制**：请求级超时，避免单个用例挂死而拖住整轮运行。
- **终端报告**：逐用例输出 `[PASS]` / `[FAIL]` 与失败原因，并给出总用例数、
  通过数、失败数与耗时汇总。
- **JUnit XML 报告**：生成符合 Jenkins / GitHub Actions 消费标准的 XML 报告，
  供 CI 流水线展示每个用例的执行结果。
- **命令行入口**：接收 `.probe` 文件路径一键运行整个测试集，
  支持 `--junit <path>` 指定报告输出路径。
- **错误诊断**：解析阶段对缺失 URL、未知键、非法状态码、非法缩进等显式报错并给出行号，
  避免拼写错误被静默忽略。

---

## 四、技术亮点与实现说明

### 4.1 包结构与职责

| 包 | 职责 | 源码规模 |
| --- | --- | --- |
| `parser/` | 词法分析、AST 定义、`.probe` 文件解析 | 584 行 |
| `runner/` | HTTP 请求执行器、`{{var}}` 插值、测试用例编排 | 401 行 |
| `assert/` | 状态码断言、JSON 响应体断言 | 121 行 |
| `reporter/` | 控制台报告输出、JUnit XML 报告生成 | 151 行 |
| `cli/` | 命令行入口、宿主文件读写 FFI | 176 行 |

依赖方向单向：`cli → reporter → runner → assert → parser`，不存在环。
上表为源码行数（合计 1433 行），另有 872 行测试代码，总计约 2305 行。

### 4.2 核心技术实现

1. **纯 MoonBit 实现，零第三方依赖。** 解析器、执行器、断言引擎、报告生成与 CLI
   全部由 MoonBit 编写，仅依赖官方标准库 `moonbitlang/core`。
   只有"发起网络请求 / 读写文件"这类宿主能力通过 `extern "js"` 桥接，
   边界收敛在 5 个函数内。
2. **解析器（`parser`）。** 手写词法分析器处理缩进、注释与引号；
   递归下降解析器产出 AST（`Request` / `Expect` / `JsonCheck` / `SetSpec`），
   对未声明的键显式报错并给出行号。
3. **运行器与 HTTP 传输（`runner`）。** 基于 MoonBit 的 JavaScript 后端，
   通过 `extern "js"` 调用宿主机的 `curl.exe` 同步发送请求，支持请求方法、头部、
   查询参数、请求体与超时控制。平台无关的"决定发什么"逻辑与真正触碰网络的 `send`
   分离：`js` 后端走 Node.js + `curl`，其他后端返回明确错误而不是静默失败。
4. **断言引擎（`assert`）。** 状态码精确匹配；JSON 断言基于标准库 `moonbitlang/core/json`
   解析响应体，按点号路径逐级下钻，支持任意深度嵌套字段，并在失败消息中同时给出
   期望值与实际值。
5. **报告器（`reporter`）。** 控制台报告带 ANSI 色彩并保留 `[PASS]` / `[FAIL]`
   文本标签，重定向到日志文件依然可读；JUnit XML 生成器完成 `&`、`<`、`>`、`"`、`'`
   五类字符的 XML 转义，输出的 `<testsuites>` / `<testsuite>` / `<testcase>` /
   `<failure>` 结构可直接被 Jenkins 与 GitHub Actions 解析。
6. **变量提取与上下文传递。** 运行器为整个测试集维护一个 `Map[String, String]` 上下文；
   `set` 指令在断言之后执行，从响应 JSON 中读取指定路径的值写入上下文；
   下一个用例发起请求前，对 URL、查询参数、请求头与请求体统一做 `{{var}}` 插值。
   占位符未被绑定时**保留原文发送**，让错误暴露在请求内容上，而不是静默变成空串。
7. **多后端可移植。** 平台相关代码用 `#cfg(target="js")` / `#cfg(not(target="js"))`
   隔离，共享逻辑在 `wasm-gc` 与 `js` 上均可编译、可测试；CI 只跑 `wasm-gc`
   即可完整覆盖纯逻辑，不受外部服务可用性影响。

### 4.3 `.probe` 用例格式

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
  set: token = args.token          # 从响应 JSON 提取变量

name: "2. send the extracted token back"
request:
  method: GET
  url: "https://httpbin.org/get"
  query:
    echo: "{{token}}"              # 引用上一个用例提取的变量
  headers:
    Authorization: "Bearer {{token}}"
expect:
  status: 200
  json:
    args.echo: "demo-token-42"
```

`set` 支持两种等价写法：内联式 `set: token = data.access_token`，
以及块式（`set:` 下挂多个 `键: 路径`）一次提取多个变量。
第二个用例只有在真正拿到第一个用例提取出的 `token` 时才会通过。

### 4.4 与现有方案的差异

| 维度 | `.http` / `hurl` / Karate | `moon test` | MoonProbe |
| --- | --- | --- | --- |
| 用例形态 | 文本 / 脚本 | MoonBit 源码 | `.probe` 文本 |
| 验证对象 | 运行中的服务（黑盒） | 源码函数（白盒） | 运行中的服务（黑盒） |
| 实现语言 | 各自宿主语言 | MoonBit | 纯 MoonBit |
| CI 报告 | 各自格式 | `moon test` 输出 | 终端报告 + JUnit XML |
| 用例间状态传递 | 部分支持 | 依赖代码变量 | `set:` + `{{var}}` 上下文串联 |

### 4.5 构建与运行

```bash
# 静态检查与单元测试（不依赖网络与 Node.js）
moon check --target wasm-gc
moon test  --target wasm-gc

# 运行示例用例：CLI 必须显式指定 --target js
moon run cli --target js -- examples/httpbin.probe

# 生成 JUnit XML 报告
moon run cli --target js -- examples/auth_chain.probe --junit junit.xml
```

> **运行 CLI 必须使用 `--target js`。** CLI 通过 `extern "js"` 调用宿主机 `curl`
> 发起真实 HTTP 请求，并依赖 JS 宿主读写 `.probe` 用例文件与报告文件；
> 用其他后端（如 `native`）运行会直接失败。模块的 `preferred_target` 也已设为 `js`。

### 4.6 `examples/` 目录的性质

`examples/` 下的 `.probe` 文件是**示例用例，需要手动运行验证**，
**不属于自动化测试套件**：

- 它们不会被 `moon test` 执行，也不进入 CI（CI 只跑 `wasm-gc` 后端的单元测试）；
- 其中部分用例会真实访问外部站点（如 `httpbin.org`、`example.com`），
  运行结果取决于网络可达性，不适合作为构建门禁；
- 项目的自动化测试位于各包的 `*_test.mbt` 文件，由 `moon test` 执行。

`examples/` 目前提供三个可直接运行的示例：`example_com.probe`（最小 GET）、
`httpbin.probe`（查询参数 + JSON 嵌套字段断言）、`auth_chain.probe`（变量提取与串联）。

### 4.7 原创性与参考说明

本项目**不是移植项目**，`.probe` 语法、词法分析器、解析器、执行器、断言引擎、
报告生成器与 CLI 全部为原创实现，不包含任何来源不明的代码、私有代码、闭源代码
或商业代码；仅依赖 Apache-2.0 授权的 MoonBit 官方标准库。

仓库的包划分方式、`moon.pkg` 配置写法与测试命名风格参考了公开 MoonBit 项目
[moonbit-dwarfscope](https://github.com/wuhaiting321/moonbit-dwarfscope)
的**工程组织方式**，未复制其任何业务逻辑。

开发过程中使用 AI 编程助手辅助代码生成、测试补全与文档撰写；项目的技术路径、
质量边界、验证方式与开源合规由作者负责，所有代码均经过本地编译与单元测试验证。

---

## 许可证

Copyright 2026 wuhaiting321.

本项目采用 [Apache License 2.0](./LICENSE) 分发。

参与本项目即表示同意遵守 [CODE_OF_CONDUCT.md](./CODE_OF_CONDUCT.md)，
贡献流程见 [CONTRIBUTING.md](./CONTRIBUTING.md)。