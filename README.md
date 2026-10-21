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
| 模块名 | `wuhaiting321/moonprobe`（遵循 mooncakes.io 的 `<author>/<module>` 命名规范） |
| 代码规模 | 5318 行 MoonBit 源码 + 5390 行测试代码，28 个 `.mbt` 文件，合计 10708 行 |
| 测试状态 | `moon test --target wasm-gc` 全部通过（352 个用例，0 失败，含 5 个验收回归用例）；`js` 后端在此基础上另含 9 个真实网络用例 |
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
- **注释**：`#` 注释可以独占一行（可带任意缩进），也可以跟在任意一行代码末尾；
  引号内的 `#` 与紧贴文本的 `#`（如 `https://x/a#frag`）不算注释。
- **套件级全局配置**：文件顶部可用 `config:` 块声明 `base_url`（相对 URL 的基址）、
  `global_headers`（每个用例都会带上的请求头）与 `global_timeout`（每个用例的默认超时）；
  运行器在发请求前自动合并，用例自身的声明优先于全局配置。
- **请求定义**：支持 GET / POST 等 HTTP 方法、URL、查询参数、请求头与请求体，
  方法省略时默认 GET。
- **变量注入**：`{{var}}` 引用用例上下文，`${ENV_VAR}` 引用宿主环境变量，
  `${ENV_VAR:-默认值}` 给出兜底值；环境变量未设置又没有默认值时直接报错中止，
  避免把空串悄悄发出去。两种写法可在同一段文本中混用。
- **状态码断言**：对响应状态码做精确匹配。
- **JSON 响应体断言（严格数值模式）**：用点号路径校验嵌套字段（如 `args.page`、
  `data.user.id`）。比较是**类型感知**的：数字按值精确比较（十进制规范化，19 位整数
  不丢精度），`999` 永远不会被 `7` 满足；`7` 与 `"7"`、`true` 与 `1` 分属不同类型，
  互不通过；`7.0` / `1e3` 这类写法按其数值是否为整数归入 `Int`，与 `type:` 的判定
  规则完全一致。单个用例内的断言**不短路**，一次运行报出全部偏差。
- **HTTP 协议合规性**：`http/` 包是一套自研的 HTTP/1.1 协议栈，不依赖任何外部
  可执行文件。请求侧保留 URL fragment 但不写进请求行，按 UTF-8 字节数计算
  `Content-Length`，请求体按原始字节发送（不会被重新解释为文件路径）；响应侧完整
  支持 chunked（含扩展与 trailer）、`Content-Length` 与 EOF 三种分帧，跳过
  `100 Continue` / `103 Early Hints` 等中间响应，`204` / `304` / `HEAD` 按规范不读
  响应体，并兼容 obs-fold 续行。上述规则均可在 `wasm-gc` 上以脚本化字节流验证。
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
- **智能重试**：`retry:` 可在 `config:` 块（套件级）或 `request:` 块（用例级）声明，
  取值是**额外**尝试次数，优先级「用例 > 套件 > 运行器默认 1 次」。只有可能自愈的失败
  才重试——连接被拒、DNS 失败、超时这类**根本没到达服务端**的失败，以及服务端自认有责的
  5xx；4xx 与其余状态码立即返回，不把真实故障拖成数倍耗时。取值范围 0–10（`retry: 0` 即
  失败即止），超界或非数字在解析阶段就报错；响应会带上实际发出的尝试次数。
- **执行钩子**：`before_each:` / `after_each:` 可写在文件顶部（套件级，环绕每一个用例），
  也可写进某个用例内部（用例级）。每个钩子步骤本身就是一条完整用例，可以发请求、做断言、
  并用 `set:` 把 token 之类的前置数据留在共享上下文里供后续用例使用。执行顺序为
  「套件 `before_each` → 用例 `before_each` → 用例体 → 用例 `after_each` → 套件 `after_each`」；
  `before_each` 失败会跳过用例体，`after_each` 则在任何路径上都会执行。
- **终端报告**：逐用例输出 `[PASS]` / `[FAIL]` 与失败原因，并给出总用例数、
  通过数、失败数与耗时汇总。
- **JUnit XML 报告**：生成符合 Jenkins / GitHub Actions 消费标准的 XML 报告，
  供 CI 流水线展示每个用例的执行结果。
- **命令行入口**：接收 `.probe` 文件路径一键运行整个测试集，
  支持 `--junit <path>` 指定报告输出路径。
- **验收回归套件**：`tests/regression/` 针对 9 月验收暴露的失败点各设一条端到端用例，
  从 `.probe` 源文件一路跑到断言结果，随 `moon test` 与 CI 一起执行，防止已修复的
  问题重新出现。

---

## 四、安装方式与快速开始

### 4.1 前置要求

| 依赖 | 版本要求 | 说明 |
| --- | --- | --- |
| MoonBit 工具链 | `moonc` ≥ 0.10.14 | 项目以 MoonBit 为主要实现语言；CI 每次都安装官方发布的最新工具链进行验证 |
| Node.js | ≥ 18，运行 `.probe` 用例时需要 | `js` 后端用 Node.js 内置的 `net` / `tls` 作为字节管道（经 `process.execPath` 启动子进程），不调用 `curl` 等任何外部命令；`moon check` / `moon test` 不需要 |
| 网络 | 运行会访问真实站点的用例时需要 | 单元测试完全离线，不受网络影响 |

安装 MoonBit 工具链（Linux / macOS）：

```bash
curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash
export PATH="$HOME/.moon/bin:$PATH"
moon version --all          # 应显示 moonc v0.10.14 或更高
```

> 若 `cli.moonbitlang.com` 不可达，可改用镜像 `https://cli.moonbitlang.cn/install/unix.sh`
> （CI 中即按此顺序回退重试）。Windows 安装包见 <https://www.moonbitlang.com/download/>。

### 4.2 获取项目

```bash
git clone https://github.com/wuhaiting321/MoonProbe.git
cd MoonProbe
```

### 4.3 最小可运行示例

仓库自带的最小示例 `examples/example_com.probe` 对公开站点 `example.com` 发一个 GET
并断言状态码为 200：

```bash
moon run cli --target js -- examples/example_com.probe
```

预期输出（访问的是公网站点，耗时随网络变化）：

```text
[PASS] example.com answers with 200

Summary: 1 total, 1 passed, 0 failed in 3742 ms
Result: PASSED
```

另外两个示例：`examples/httpbin.probe`（查询参数 + JSON 嵌套字段断言）、
`examples/auth_chain.probe`（变量提取与用例串联，可直接生成 JUnit 报告）。

> **运行 CLI 必须带 `--target js`**，原因见 5.5 节。

### 4.4 作为依赖安装

模块名遵循 mooncakes.io 的 `<author>/<module>` 规范，发布到注册表后即可作为依赖引入：

```bash
moon add wuhaiting321/moonprobe
```

---

## 五、技术亮点与实现说明

### 5.1 包结构与职责

| 包 | 职责 | 源码规模 |
| --- | --- | --- |
| `parser/` | 词法分析、AST 定义、`.probe` 文件解析（含 `config:` 块） | 1833 行 |
| `runner/` | 配置合并、占位符插值、重试与钩子编排、变量提取 | 1101 行 |
| `http/` | 自研 HTTP/1.1 协议栈：URL、请求渲染、响应分帧、宿主机字节管道 | 1137 行 |
| `assert/` | 状态码、严格 JSON 数值、文本、长度、类型、schema、耗时断言 | 912 行 |
| `reporter/` | 控制台报告输出、JUnit XML 报告生成 | 155 行 |
| `cli/` | 命令行入口、宿主文件读写 FFI | 180 行 |
| `tests/regression/` | 9 月验收失败点的端到端回归用例（仅测试） | 211 行测试 |

依赖方向单向：`cli → reporter → runner → assert / http → parser`，不存在环。
`http` 与 `assert` 互不依赖；`runner` 只把两者串起来，因此断言引擎和协议栈都能单独
在 `wasm-gc` 上测试。上表为源码文件的总行数（合计 5318 行），另有 5390 行测试代码，
总计 10708 行；验收脚本 `check_验收.sh` / `check_验收.ps1` 按「非空行」口径统计为
5318 行（要求 > 1500）。

### 5.2 核心技术实现

1. **纯 MoonBit 实现，零第三方依赖。** 解析器、执行器、HTTP 协议栈、断言引擎、
   报告生成与 CLI 全部由 MoonBit 编写，仅依赖官方标准库 `moonbitlang/core`。
   留给宿主的只有两类能力：读写成 `.probe` / 报告文件（`cli/file_js.mbt`），
   以及一条 TCP / TLS 字节管道（`http/host_js.mbt`）。后者只用 Node.js 内置的
   `net`、`tls` 模块，经 `process.execPath` 启动，**不查找也不调用任何外部可执行文件**，
   因此在 macOS、Linux 与 Windows 上行为一致。
2. **解析器与错误诊断（`parser`）。** 手写词法分析器处理缩进、引号与注释——注释在
   分行后立即被剥离（引号内的 `#` 与紧贴文本的 `#` 豁免），所以注释可以出现在任意
   位置，且不会干扰每一行的缩进判定；递归下降解析器产出 AST（`Config` / `Request` /
   `Expect` / `JsonCheck` / `SetSpec` / `LengthCheck` / `TypeCheck` / `SchemaField`）。
   `config:` 块被限定在文件的首个用例之前且只允许出现一次——全局默认值一旦被
   解析，后续用例就只会读它读过的那一份。
   **错误诊断是解析器的技术细节，而不是独立的产品功能**：缺失 URL、未知键、非法状态码、
   非法缩进、非法配置块、非法的 `set` 取值来源都会显式报错并给出行号；运行阶段对
   未定义的环境变量、未闭合的占位符、无法解析的相对 URL 同样给出可操作的错误信息，
   让拼写错误暴露在第一次运行里，而不是变成一个安静发错的请求。`json:` 期望值的
   引号状态也在这里保留（`JsonCheck.expected_quoted`），使 `code: 7` 与 `code: "7"`
   在下游可以走不同的比较路径。
3. **自研 HTTP 栈（`http`）——从“调用工具”到“拥有协议”。** 旧实现把整个网络层
   交给 `curl.exe`：请求由命令行参数拼装、响应由 `curl -i` 的文本回传，于是产生了一串
   无法从外部修正的问题——`POST` 的 `100 Continue` 头块混进正文、URL fragment 被当作
   查询串、以 `@` 开头的请求体被当成文件名、固定的 `curl.exe` 让 macOS / Linux 启动
   即失败。现在协议由项目自己实现：
   - `url.mbt` 按 RFC 3986 解析 scheme / host / IPv6 / port / path / query / fragment；
     fragment 留在 `Url` 值里供用户回读，但 `request_target()` 只拼 `path?query`，
     绝不把 fragment 写进请求行。
   - `client.mbt` 渲染请求行与头部，`Host` 必填（IPv6 加方括号、默认端口省略），
     `Content-Length` 按 **UTF-8 字节** 计算而不是 UTF-16 code unit 数，请求体原样
     发送——`@handle` 就是 7 个字节，不会被重新解释。
   - `parser.mbt` 解析响应：状态行 + 头部（obs-fold 续行、大小写折叠）+ 三种分帧
     （chunked 含扩展与 trailer、`Content-Length`、连接关闭 EOF）；1xx 中间响应
     （`100 Continue`、`103 Early Hints`）被跳过并单独计数，`101` 视为最终响应；
     `204` / `304` / `HEAD` 即使带了 `Content-Length` 也不读响应体。
   - `stream.mbt` 提供字节游标（按行、按长度、取剩余），所有解析都建立在这层之上，
     因此协议栈可以在 `wasm-gc` 上被脚本化字节流完整驱动。
   - `host_stub.mbt` 让没有 socket 的后端返回明确错误，而不是静默失败；
     `host_js.mbt` 只负责把已渲染好的字节写进 socket 并读回原始字节（base64 穿越
     字符串边界，二进制正文逐字节保真），HTTP 语义一律不越过这条边界。
4. **断言引擎（`assert`）。** 状态码精确匹配；JSON 断言基于标准库
   `moonbitlang/core/json` 解析响应体，按点号路径逐级下钻。数值比较采用**严格模式**：
   期望值先按引号状态与字面量语法分类为 `Int` / `Number` / `String` / `Bool` / `Null`，
   再与解码值按类型匹配；数字不做字符串拼接、也不经过 `Double`，而是归约为
   「有效数字 + 指数」的十进制规范形式精确比较（`1e3` 与 `1000.0` 相等，
   `999` 与 `7` 不等，19 位整数逐位保留）；`7.0`、`1e3` 这类数值为整数的写法与
   `type:` 一样归为 `Int`。此外提供五族进阶断言：原始文本包含（`contains` /
   `contains_ci`）、数组长度（`length`）、JSON 类型（`type`）、对象结构（`schema`）、
   耗时预算（`duration_ms`）。一个用例内的全部断言共享同一份响应，逐条判定、互不短路。
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
9. **智能重试与执行钩子。** 重试预算按「用例 `retry:` > 套件 `retry:` > 运行器默认
   `DEFAULT_RETRY_COUNT = 1`」三级取值，语义是**额外**尝试次数而非总次数；解析阶段就把
   负数与超过 `MAX_RETRY_COUNT = 10` 的取值挡在门外，因为重试是立即进行的、不插入退避
   等待，一个荒唐的预算不会失败，只会把一次运行挂死。是否重试只看两件事：transport
   根本没有完成（连接被拒、DNS 失败、超时），或服务端回了 5xx；4xx 与其余一切立刻返回。
   每个响应都带着 `attempts`（实际发出的尝试次数），而耗时与尝试次数只描述产生该响应的
   那一次调用，不把前面失败的尝试算进去。执行钩子复用了 case 语法——钩子步骤就是一条条
   完整用例，能发请求、能断言、能 `set:` 变量，所以"先登录、留下 token"这类前置动作
   不必另造一套语法。嵌套顺序为
   `suite before_each → case before_each → case → case after_each → suite after_each`；
   `before_each` 失败会阻断用例体（真实原因被连锁失败淹没是最难查的故障），`after_each`
   则在任何路径上都执行——用例出错时，恰恰是清理最要紧的时候。钩子的失败信息一律带
   `before_each "<步骤名>"` 之类的前缀，以免被误读成用例本身的失败。

### 5.3 `.probe` 用例格式

```text
# 套件级全局配置：对本文件的所有用例生效
config:
  base_url: "https://httpbin.org"          # 相对 url 的基址
  global_timeout: 8000                     # 每个用例的默认超时（毫秒）
  global_headers:                          # 每个用例都会带上的请求头
    Accept: "application/json"
    Authorization: "Bearer ${API_TOKEN}"   # 值里可以引用宿主环境变量

name: "1. read the token from the response"
request:
  method: GET
  url: "/response-headers"                 # 相对 url：拼接 config 里的 base_url
  query:
    # httpbin 会把查询参数原样变成响应头，方便演示三种取值来源
    echo: "demo-token-42"
    X-Trace-Id: "trace-7f3a"
    Set-Cookie: "session=abc123"
expect:
  status: 200
  json:
    echo: "demo-token-42"                  # 点号路径校验嵌套字段
  contains: "demo-token-42"                # 原始响应文本必须包含该子串
  type:
    echo: string                           # JSON 类型
  duration_ms <= 2000                      # 耗时预算
  set: token = echo                        # 从响应 JSON 取值
  set: trace = header.X-Trace-Id           # 从响应头取值
  set: sid = cookie.session                # 从 Cookie 取值

name: "2. send the extracted token back"
request:
  method: GET
  url: "/get"
  timeout: 3000                            # 用例级超时，优先于 global_timeout
  query:
    echo: "{{token}}"                      # 引用上一个用例提取的变量
  headers:
    Authorization: "Bearer {{token}}"
expect:
  status: 200
  json:
    args.echo: "demo-token-42"
  schema:
    args: object!                          # 必需字段用 `!` 标记
      echo: string!                        # object 下的缩进行是它的嵌套结构
    url: string!
```

> `#` 注释既可独占一行（缩进随意），也可跟在任意一行末尾；两者都在词法阶段
> 被剥离，所以既不影响缩进判定，也不会混进值里。引号内的 `#` 不算注释，紧贴
> 文本的 `#` 也不算——`url: https://x/a#frag` 会保留 `#frag`。值本身要以 `#`
> 开头时必须加引号，例如 `contains: "#tag"`。

`json:` 的期望值是**有类型**的，加不加引号决定它要求字符串还是数字：

```text
expect:
  json:
    code: 999          # 要求数字 999，7、7.0 之外的一切数值都不通过
    code: "999"        # 要求字符串 "999"，数字 999 不通过
    ratio: 7.5         # 非整数：按十进制规范形式精确比较
    ratio: 7.0         # 数值为整数，按 Int 比较，等价于 7
    active: true       # Bool 只匹配 true / false，不匹配 1 / 0
    extra: null        # Null 只匹配 JSON null
    name: alice        # 未加引号且不是数字/布尔/null，按字符串 alice 比较
```

数值比较不经过 `Double`：`999` 与 `7` 按值不等，`1e3` 与 `1000.0` 按值相等，
19 位整数逐位比较。失败消息会同时给出两边的类型与取值，例如
`json: "code": expected Int 999, got Int 7`。

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

### 5.4 与现有方案的差异

| 维度 | `.http` / `hurl` / Karate | `moon test` | MoonProbe |
| --- | --- | --- | --- |
| 用例形态 | 文本 / 脚本 | MoonBit 源码 | `.probe` 文本 |
| 验证对象 | 运行中的服务（黑盒） | 源码函数（白盒） | 运行中的服务（黑盒） |
| 实现语言 | 各自宿主语言 | MoonBit | 纯 MoonBit |
| CI 报告 | 各自格式 | `moon test` 输出 | 终端报告 + JUnit XML |
| 用例间状态传递 | 部分支持 | 依赖代码变量 | `set:` + `{{var}}` 上下文串联 |
| 套件级配置与环境变量 | 各自语法 | 无 | `config:` 块 + `${ENV}` 注入 |
| 断言族 | 视工具而定 | 由代码自行编写 | 状态码 / JSON / 文本 / 长度 / 类型 / schema / 耗时 |

### 5.5 构建与运行

```bash
# 静态检查与单元测试（不依赖网络与 Node.js）
moon check --target wasm-gc
moon test  --target wasm-gc

# 只跑 9 月验收回归套件（它同样包含在上一条命令里）
moon test --target wasm-gc -p wuhaiting321/moonprobe/tests/regression

# 运行示例用例：CLI 必须显式指定 --target js
moon run cli --target js -- examples/httpbin.probe

# 生成 JUnit XML 报告
moon run cli --target js -- examples/auth_chain.probe --junit junit.xml
```

> **运行 CLI 必须使用 `--target js`。** CLI 依赖 JS 宿主读写 `.probe` 用例文件与报告
> 文件，并通过 Node.js 内置的 `net` / `tls` 建立 TCP 连接（见 `http/host_js.mbt`）；
> 用其他后端（如 `native`）运行会给出明确的“无网络传输”错误。模块的
> `preferred_target` 也已设为 `js`。

`tests/regression/` 的 5 条端到端用例对应 9 月验收的 5 个失败点：
JSON 数值 `7` vs `999`、macOS / Linux 下无外部可执行文件的客户端启动、
`POST` 的 `100 Continue` 正文分离、URL fragment 保留、`@` 请求体按字节发送。
它们由 `moon test --target wasm-gc` 自动发现并执行，CI 中也单独列成一步，
任一行为回退都会让流水线变红。

以上检查已固化为验收脚本：`check_验收.sh`（Linux / macOS）与 `check_验收.ps1`（Windows）
会依次执行代码规模统计、两个后端的 `moon check`、`moon build --target js`、
`moon test --target wasm-gc`、`moon fmt --check` 与提交记录统计，全部通过才返回 0：

```bash
bash check_验收.sh                                          # Linux / macOS
powershell -ExecutionPolicy Bypass -File .\check_验收.ps1   # Windows
```

### 5.6 `examples/` 目录的性质

`examples/` 下的 `.probe` 文件是**示例用例，需要手动运行验证**，
**不属于自动化测试套件**：

- 它们不会被 `moon test` 执行，也不进入 CI（CI 只跑 `wasm-gc` 后端的单元测试）；
- 其中部分用例会真实访问外部站点（如 `httpbin.org`、`example.com`），
  运行结果取决于网络可达性，不适合作为构建门禁；
- 项目的自动化测试位于各包的 `*_test.mbt` 文件与 `tests/regression/` 端到端套件，
  由 `moon test` 执行。

`examples/` 目前提供三个可直接运行的示例：`example_com.probe`（最小 GET）、
`httpbin.probe`（查询参数 + JSON 嵌套字段断言）、`auth_chain.probe`（变量提取与串联）。

### 5.7 原创性与参考说明

本项目**不是移植项目**，`.probe` 语法、词法分析器、解析器、执行器、断言引擎、
报告生成器与 CLI 全部为原创实现，不包含任何来源不明的代码、私有代码、闭源代码
或商业代码；仅依赖 Apache-2.0 授权的 MoonBit 官方标准库。

仓库的包划分方式、`moon.pkg` 配置写法与测试命名风格参考了公开 MoonBit 项目
[moonbit-dwarfscope](https://github.com/wuhaiting321/moonbit-dwarfscope)
的**工程组织方式**，未复制其任何业务逻辑。

开发过程中使用 AI 编程助手辅助代码生成、测试补全与文档撰写；项目的技术路径、
质量边界、验证方式与开源合规由作者负责，所有代码均经过本地编译与单元测试验证。

---

## 六、10 月黑客松新增工作

本阶段没有把 9 月验收问题当作“改几行代码”来处理，而是把每一处缺陷都变成了架构升级：
断言引擎获得类型系统，网络层从“调用外部工具”变成“自研协议栈”，核心功能重新定位，
并把验收失败点固化成回归门禁。相对 9 月提交，净增约 2850 行代码（含测试）。

| # | 实质工作 | 交付物 | 代码增量 |
| --- | --- | --- | --- |
| 1 | 断言引擎类型系统增强：JSON 数值严格比较 | `assert/assert.mbt` 重写 JSON 期望分类与十进制规范化比较；新增 `assert/json_numeric_test.mbt`（32 个数值 / 类型用例）；`parser` 保留 `json:` 期望值的引号状态 | +358 行源码，+249 行测试，解析器 +71/-12 |
| 2 | 移除 curl，自研 HTTP/1.1 协议栈 | 新增 `http/` 包（`url.mbt`、`client.mbt`、`parser.mbt`、`stream.mbt`、`base64.mbt`、`host_js.mbt`、`host_stub.mbt`）与 `runner/transport.mbt`；删除 `runner/http_js.mbt`、`runner/http_stub.mbt` 中的 curl FFI | +1947 行（1137 源码 + 810 测试），删除 125 行 |
| 3 | 核心功能重新定位：错误诊断降级，HTTP 协议合规性上位 | README「三、核心功能范围」重组：删除「错误诊断」独立条目并并入 5.2 解析器章节，新增「HTTP 协议合规性」 | 文档结构重构 |
| 4 | 9 月验收回归套件 | 新增 `tests/regression/`：5 条端到端用例 + `moon.pkg`，接入 `moon test` 与 CI | +211 行测试 |

**1. JSON 数值比较：从字符串比较到类型化精确比较。**
旧逻辑把期望值和响应值都当成文本，数值的类型信息在比较前就已丢失，`999` 与 `7`
这类差异只能靠字符串碰巧不相等来兜底，`7` / `"7"` / `7.0` 的语义也无从区分。
新实现先把期望值分类为 `Int` / `Number` / `String` / `Bool` / `Null`——加引号就是字符串，
未加引号的 JSON 字面量按其语法与**数值整性**归入整数或浮点；再与解码后的 JSON 值按
类型匹配。数字比较把字面量归约为「有效数字 + 指数」的十进制规范形式，不经过
`Double`，因此 `1e3`、`1000`、`1000.0` 相等，`999` 与 `7` 不等，19 位整数逐位保留。
边界值 `0`、`-0`、`-1`、`1.5`、`1e-3`、`9007199254740993` 等均有测试覆盖。

**2. 自研 HTTP 栈：网络层不再受制于工具行为。**
旧实现的 `curl` 调用把协议决策交给了外部程序：`POST` 的 `100 Continue` 头块会混入正文，
fragment 会挤进查询串，`@` 开头的正文会被当作文件名读取，固定的 `curl.exe` 让
macOS / Linux 无法启动。新实现把 URL、请求渲染、响应分帧全部收进 `http/` 包：
chunked 与 `Content-Length` / EOF 三种分帧、1xx 中间响应跳过与计数、`204` / `304` /
`HEAD` 无正文、obs-fold 续行、UTF-8 字节级 `Content-Length`。宿主只保留一条
TCP / TLS 字节管道，且只用 Node.js 内置模块，不查找任何外部可执行文件。

**3. 核心功能重新定位。**
「错误诊断」不再单列为核心功能，其内容作为解析器章节的技术细节保留；
新的核心条目「HTTP 协议合规性」承载本阶段最重要的架构成果，与声明式用例、
变量串联、多族断言等并列。

**4. 验收回归套件。**
`tests/regression/` 的 5 条用例分别锁定：`{"code":7}` 对 `code: 999` 必须失败、
客户端不依赖平台可执行文件即可启动、`100 Continue` 头块不进入正文、
fragment 保留但不发送、`@deploy.json` 按字节发送。它们从 `.probe` 源文件一路
驱动到断言结果，任何一条行为回退都会让 `moon test --target wasm-gc` 与 CI 失败。

本阶段验收状态：`moon test --target wasm-gc` 共 352 个用例全部通过；`wasm-gc` 与
`js` 两个后端 `moon check --deny-warn` 零错误、零告警。

---

## 许可证

Copyright 2026 wuhaiting321.

本项目采用 [Apache License 2.0](./LICENSE) 分发。

参与本项目即表示同意遵守 [CODE_OF_CONDUCT.md](./CODE_OF_CONDUCT.md)，
贡献流程见 [CONTRIBUTING.md](./CONTRIBUTING.md)。