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
| 代码规模 | 3409 行 MoonBit 源码 + 3229 行测试代码，16 个 `.mbt` 文件，合计约 6638 行 |
| 测试状态 | `moon test --target wasm-gc` 全部通过（182 个用例，0 失败）；`js` 后端在此基础上另含 9 个真实网络用例 |
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
- **套件级全局配置**：文件顶部可用 `config:` 块声明 `base_url`（相对 URL 的基址）、
  `global_headers`（每个用例都会带上的请求头）与 `global_timeout`（每个用例的默认超时）；
  运行器在发请求前自动合并，用例自身的声明优先于全局配置。
- **请求定义**：支持 GET / POST 等 HTTP 方法、URL、查询参数、请求头与请求体，
  方法省略时默认 GET。
- **变量注入**：`{{var}}` 引用用例上下文，`${ENV_VAR}` 引用宿主环境变量，
  `${ENV_VAR:-默认值}` 给出兜底值；环境变量未设置又没有默认值时直接报错中止，
  避免把空串悄悄发出去。两种写法可在同一段文本中混用。
- **状态码断言**：对响应状态码做精确匹配。
- **JSON 响应体断言**：用点号路径校验嵌套字段（如 `args.page`、`data.user.id`）；
  单个用例内的断言**不短路**，一次运行报出全部偏差。
- **多族断言**：除状态码与 JSON 路径外，还支持
  `contains` / `contains_ci`（原始响应文本必须包含的子串，后者忽略大小写）、
  `length`（JSON 数组长度）、`type`（JSON 类型，区分 `int` 与 `number`）、
  `schema`（字段类型 + `!` 必需标记 + 嵌套对象结构）、
  `duration_ms`（耗时预算，支持 `<` / `<=` / `>` / `>=` 四种比较）。
- **变量提取与上下文串联**：`expect` 块中的 `set` 指令可从三处取值——
  响应体 JSON 路径（`set: token = data.access_token`）、
  响应头（`set: trace = header.X-Trace-Id`）、
  Cookie（`set: sid = cookie.session`）；后续用例通过 `{{var}}` 引用，
  整个测试集共享同一上下文，可完整走通"登录取 token → 携带 token 访问受保护资源"的链路。
- **超时控制**：用例级 `timeout:` 与套件级 `global_timeout` 双层可配，
  优先级为「用例 > 套件 > 运行器默认值」，避免单个用例挂死而拖住整轮运行。
- **终端报告**：逐用例输出 `[PASS]` / `[FAIL]` 与失败原因，并给出总用例数、
  通过数、失败数与耗时汇总。
- **JUnit XML 报告**：生成符合 Jenkins / GitHub Actions 消费标准的 XML 报告，
  供 CI 流水线展示每个用例的执行结果。
- **命令行入口**：接收 `.probe` 文件路径一键运行整个测试集，
  支持 `--junit <path>` 指定报告输出路径。
- **错误诊断**：解析阶段对缺失 URL、未知键、非法状态码、非法缩进、非法配置块、
  非法的 `set` 取值来源等显式报错并给出行号；运行阶段对未定义的环境变量、
  未闭合的占位符、无法解析的相对 URL 同样给出可操作的错误信息，
  避免拼写错误被静默忽略。

---

## 四、技术亮点与实现说明

### 4.1 包结构与职责

| 包 | 职责 | 源码规模 |
| --- | --- | --- |
| `parser/` | 词法分析、AST 定义、`.probe` 文件解析（含 `config:` 块） | 1530 行 |
| `runner/` | 配置合并、占位符插值、HTTP 传输、变量提取与用例编排 | 928 行 |
| `assert/` | 状态码、JSON 路径、文本、长度、类型、schema、耗时断言 | 598 行 |
| `reporter/` | 控制台报告输出、JUnit XML 报告生成 | 164 行 |
| `cli/` | 命令行入口、宿主文件读写 FFI | 189 行 |

依赖方向单向：`cli → reporter → runner → assert → parser`，不存在环。
上表为源码行数（合计 3409 行），另有 3229 行测试代码，总计约 6638 行。

### 4.2 核心技术实现

1. **纯 MoonBit 实现，零第三方依赖。** 解析器、执行器、断言引擎、报告生成与 CLI
   全部由 MoonBit 编写，仅依赖官方标准库 `moonbitlang/core`。
   只有"发起网络请求 / 读写文件"这类宿主能力通过 `extern "js"` 桥接，
   边界收敛在 5 个函数内。
2. **解析器（`parser`）。** 手写词法分析器处理缩进、注释与引号；
   递归下降解析器产出 AST（`Config` / `Request` / `Expect` / `JsonCheck` /
   `SetSpec` / `LengthCheck` / `TypeCheck` / `SchemaField`），
   对未声明的键、越界的嵌套与格式错误的取值显式报错并给出行号。
   `config:` 块被限定在文件的首个用例之前且只允许出现一次——全局默认值一旦被
   解析，后续用例就只会读它读过的那一份。
3. **运行器与 HTTP 传输（`runner`）。** 基于 MoonBit 的 JavaScript 后端，
   通过 `extern "js"` 调用宿主机的 `curl.exe` 同步发送请求，支持请求方法、头部、
   查询参数、请求体与超时控制；`curl -i` 让响应头一并回传，供 `set:` 从
   Header / Cookie 取值。平台无关的"决定发什么"逻辑与真正触碰网络的 `send`
   分离：`js` 后端走 Node.js + `curl`，其他后端返回明确错误而不是静默失败。
4. **断言引擎（`assert`）。** 状态码精确匹配；JSON 断言基于标准库 `moonbitlang/core/json`
   解析响应体，按点号路径逐级下钻，支持任意深度嵌套字段，并在失败消息中同时给出
   期望值与实际值。此外提供五族进阶断言：原始文本包含（`contains` / `contains_ci`）、
   数组长度（`length`）、JSON 类型（`type`，按数值整性区分 `int` 与 `number`）、
   对象结构（`schema`，字段类型 + `!` 必需标记 + 嵌套对象）、
   耗时预算（`duration_ms`）。一个用例内的全部断言共享同一份响应，逐条判定、
   互不短路。
5. **报告器（`reporter`）。** 控制台报告带 ANSI 色彩并保留 `[PASS]` / `[FAIL]`
   文本标签，重定向到日志文件依然可读；JUnit XML 生成器完成 `&`、`<`、`>`、`"`、`'`
   五类字符的 XML 转义，输出的 `<testsuites>` / `<testsuite>` / `<testcase>` /
   `<failure>` 结构可直接被 Jenkins 与 GitHub Actions 解析。
6. **配置合并与环境变量注入。** 请求在发出前先与套件配置合并：相对 URL 拼到
   `base_url` 上（两侧斜杠被规范化，绝对 URL 原样保留）、同名请求头由用例级声明
   就地覆盖全局声明（其余保持全局顺序）、超时按「用例 > 套件 > 运行器默认值」取值。
   占位符展开支持两个通道并可混用：`{{var}}` 取自用例上下文，`${ENV}` 与
   `${ENV:-默认值}` 取自宿主环境。整轮展开是一次从左到右的单遍扫描——
   被替换进来的值不会再被扫描一遍，因此响应里带回来的形如 `${...}` 的 token
   会原样发送；而未设置又无默认值的环境变量会让请求以可操作的错误信息中止，
   而不是发出一个空串。
7. **变量提取与上下文传递。** 运行器为整个测试集维护一个 `Map[String, String]` 上下文；
   `set` 指令在断言之后执行，可分别从响应体 JSON 路径、响应头（`header.` 前缀，
   名称按 RFC 9110 折叠大小写）与 Cookie（`cookie.` 前缀，只读 `Set-Cookie` 的
   `name=value` 部分、名称大小写敏感）取值。下一个用例发起请求前，对 URL、查询参数、
   请求头与请求体统一插值；`{{var}}` 未被绑定时**保留原文发送**，
   让错误暴露在请求内容上，而不是静默变成空串。
8. **多后端可移植。** 平台相关代码用 `#cfg(target="js")` / `#cfg(not(target="js"))`
   隔离，共享逻辑在 `wasm-gc` 与 `js` 上均可编译、可测试；环境变量查找与响应头
   解析都做成可注入的纯函数，因此这两条路径在 `wasm-gc` 上也能被完整测到；
   CI 只跑 `wasm-gc` 即可覆盖纯逻辑，不受外部服务可用性影响。

### 4.3 `.probe` 用例格式

```text
# 套件级全局配置：对本文件的所有用例生效
config:
  # 相对 url 的基址
  base_url: "https://httpbin.org"
  # 每个用例的默认超时（毫秒）
  global_timeout: 8000
  # 每个用例都会带上的请求头，值里可以引用宿主环境变量
  global_headers:
    Accept: "application/json"
    Authorization: "Bearer ${API_TOKEN}"

name: "1. read the token from the response"
request:
  method: GET
  # 相对 url：拼接 config 里的 base_url
  url: "/response-headers"
  # httpbin 会把查询参数原样变成响应头，方便演示三种取值来源
  query:
    echo: "demo-token-42"
    X-Trace-Id: "trace-7f3a"
    Set-Cookie: "session=abc123"
expect:
  status: 200
  # 点号路径校验嵌套字段
  json:
    echo: "demo-token-42"
  # 原始响应文本必须包含该子串
  contains: "demo-token-42"
  # JSON 类型
  type:
    echo: string
  # 耗时预算
  duration_ms <= 2000
  # 分别从响应 JSON、响应头与 Cookie 提取变量
  set: token = echo
  set: trace = header.X-Trace-Id
  set: sid = cookie.session

name: "2. send the extracted token back"
request:
  method: GET
  url: "/get"
  # 用例级超时，优先于 global_timeout
  timeout: 3000
  query:
    # 引用上一个用例提取的变量
    echo: "{{token}}"
  headers:
    Authorization: "Bearer {{token}}"
expect:
  status: 200
  json:
    args.echo: "demo-token-42"
  # 必需字段用 `!` 标记，object 下的缩进行是它的嵌套结构
  schema:
    args: object!
      echo: string!
    url: string!
```

> 注释必须独占一行（可带缩进）。词法分析器不识别行尾注释，
> `url: "/get"  # 说明` 会把 `# 说明` 一并当成值。

`config:` 必须写在首个用例之前，且一个文件只允许出现一次。其中 `base_url`
只对相对 URL 生效，写绝对 URL 的用例不受影响；`global_headers` 与用例自身
`headers` 同名时以用例为准；超时优先级为「用例 `timeout:` > `global_timeout` >
运行器默认值」。

占位符有两个通道且可混用：`{{var}}` 取自用例上下文，`${ENV_VAR}` 取自宿主
环境变量，`${ENV_VAR:-默认值}` 提供兜底；环境变量未设置又没有默认值时会直接
报错中止。`{{var}}` 未被绑定时保留原文发送，让拼写错误暴露在请求内容上。

`set` 可从一个用例的响应中提取变量供后续用例使用，取值来源有三种：
不带前缀的 `set: token = data.access_token` 读响应体 JSON 路径，
`set: trace = header.X-Trace-Id` 读响应头（名称忽略大小写），
`set: sid = cookie.session` 读服务端下发的 Cookie（名称区分大小写）。
`set` 同样支持块式写法（`set:` 下挂多个 `键: 路径`）一次提取多个变量。
第二个用例只有在真正拿到第一个用例提取出的 `token` 时才会通过。

### 4.4 与现有方案的差异

| 维度 | `.http` / `hurl` / Karate | `moon test` | MoonProbe |
| --- | --- | --- | --- |
| 用例形态 | 文本 / 脚本 | MoonBit 源码 | `.probe` 文本 |
| 验证对象 | 运行中的服务（黑盒） | 源码函数（白盒） | 运行中的服务（黑盒） |
| 实现语言 | 各自宿主语言 | MoonBit | 纯 MoonBit |
| CI 报告 | 各自格式 | `moon test` 输出 | 终端报告 + JUnit XML |
| 用例间状态传递 | 部分支持 | 依赖代码变量 | `set:` + `{{var}}` 上下文串联 |
| 套件级配置与环境变量 | 各自语法 | 无 | `config:` 块 + `${ENV}` 注入 |
| 断言族 | 视工具而定 | 由代码自行编写 | 状态码 / JSON / 文本 / 长度 / 类型 / schema / 耗时 |

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