# 更新日志

本项目的所有重要变更都记录在此文件。版本号遵循语义化版本；模块以
`wuhaiting321/moonprobe` 发布到 [mooncakes.io](https://mooncakes.io/docs/wuhaiting321/moonprobe)。

## 0.2.0 — 2026-10-21

基线 `0.1.0`（提交 `932cea7`）。本版本对应 10 月 MoonBit 黑客松的深度重构：
把 9 月验收暴露的四处缺陷分别升级为协议栈、类型系统与自动化门禁，
而不是逐条修补。提交区间 `932cea7..58feda5`，29 个文件、+3278 / −200 行。

### 新增

- **自研 HTTP/1.1 协议栈**（`http/`，1137 行源码 + 810 行测试）
  - `url.mbt`：scheme / host / IPv6 / 端口 / path / query / fragment 解析；
    fragment 保留在值中但绝不进入请求行。
  - `client.mbt`：请求行与头部渲染，`Content-Length` 按 UTF-8 字节数计算，
    调用方自带的 framing 头被丢弃后重算。
  - `parser.mbt`：chunked（含扩展与 trailer）、`Content-Length`、EOF 三种分帧；
    跳过除 `101` 外的 1xx 中间响应并计数；`204` / `304` / `HEAD` 不读正文；
    obs-fold 续行折叠。
  - `stream.mbt`：字节游标（按行、按长度、取剩余），协议解析全部建立其上。
  - `host_js.mbt` / `host_stub.mbt`：宿主只提供 TCP/TLS 字节管道（Node.js 内置
    `net` / `tls`，经 `process.execPath`），没有可用 socket 的后端返回明确错误。
- **断言引擎严格数值模式**（`assert/`，+358 行源码、+249 行测试）
  - 期望值先分类为 `Int` / `Number` / `String` / `Bool` / `Null`，再与解码值按类型匹配。
  - 数字按「有效数字 + 指数」的十进制规范形式精确比较，不经过 `Double`；
    `999` 与 `7` 不等，`1e3` / `1000` / `1000.0` 相等，19 位整数逐位保留。
  - 解析器保留 `json:` 期望值的引号状态（`JsonCheck.expected_quoted`）。
  - 新增 `assert/json_numeric_test.mbt`，32 个数值 / 类型边界用例。
- **验收回归套件**（`tests/regression/`，211 行测试）
  - 5 条端到端用例：JSON `7` vs `999`、无外部可执行文件的客户端启动、
    `100 Continue` 正文分离、URL fragment 保留、`@` 请求体按字节发送。
  - 从 `.probe` 源文件驱动到断言结果，并作为独立一步接入 CI。

### 变更

- **移除全部 curl FFI**，删除 `runner/http_js.mbt`、`runner/http_stub.mbt`；
  `runner` 只保留 30 行传输适配器。
- **核心功能重新定位**：README 移除「错误诊断」独立条目（内容并入 5.2 解析器章节），
  新增「HTTP 协议合规性」条目。
- README 新增「5.2.1 HTTP 协议符合性矩阵与能力边界」，明确协议层纯 MoonBit、
  TCP/TLS 由宿主提供，以及未实现 HTTP/2、代理、重定向等边界。
- 模块版本从 `0.1.0` 升至 `0.2.0`，默认 `User-Agent` 与模块版本一致。

### 验证

```bash
moon check --target wasm-gc --deny-warn   # 0 error / 0 warning
moon check --target js --deny-warn        # 0 error / 0 warning
moon test  --target wasm-gc               # 352 passed / 0 failed
moon build --target js                    # OK
```

GitHub Actions 运行 `39561875765` 通过；回归套件已在 CI 中单独设步。

### 升级说明

```bash
moon add wuhaiting321/moonprobe@0.2.0
```

`json:` 的期望值现在按类型比较：`code: 999` 只匹配数字 `999`，`code: "999"`
只匹配字符串；依赖旧版字符串比较而“碰巧通过”的用例会变为失败——这是本版本
预期的行为收紧。未加引号且不是数字 / 布尔 / `null` 的值仍按字符串比较。
