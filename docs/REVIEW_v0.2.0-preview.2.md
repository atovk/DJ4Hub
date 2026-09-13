# v0.2.0-preview.2 代码审查记录

本轮覆盖 Go 本地服务、通信历史与备份、Web 调用边界、Swift 原生客户端、USB/AT 与 MBIM 协议、安装器和 GitHub Actions。通过分工审查主要路径、合成故障回归、竞态检测及漏洞扫描验证；未逐行重新审计全部第三方源码，也未执行真实短信发送、拨号、SIM 写入或 USB 模式切换。

## 确认的问题与处理

| 问题 | 处理 | 主要文件 |
| --- | --- | --- |
| 本地 API 缺少统一来源校验，跨站简单请求可进入硬件操作 handler | 统一校验环回客户端、Host、Origin、Fetch Metadata；写请求须为 JSON 或带现有非简单客户端头 | `cmd/dj4ghub-macos/local_api_security.go`、`main.go` |
| Go 1.26.3 标准库扫描命中 8 项可达已知漏洞 | 升级同系列补丁版本到 Go 1.26.8，复扫通过 | `go.mod` |
| USB 连接状态被 HTTP 与后台轮询并发访问 | 为连接状态建立统一锁和快照，旧连接错误只清理对应连接 | `cmd/dj4ghub-macos/main.go`、`usb_state_test.go` |
| 后端退出后原生客户端仍保持 ready，无法正常重试 | 回退连接状态，允许重连；旧自管进程未退出时保留其所有权并阻止重复启动 | `apps/hub-macos/Sources/DJ4Hub/Service.swift`、`Store.swift` |
| 关闭最后一个窗口后菜单栏入口不能可靠恢复客户端 | 使用 SwiftUI 主场景标识重新打开窗口 | `apps/hub-macos/Sources/DJ4Hub/App.swift` |
| 备份状态恢复正常后仍显示旧错误 | 分离后台状态错误与本次操作结果，避免旧成功消息覆盖新失败 | `apps/hub-macos/Sources/DJ4Hub/HistoryBackupSettings.swift` |
| 安装器忽略旧服务停止失败并覆盖文件 | 停止失败即退出，保留原安装；加入临时目录升级回归 | `packaging/install`、`scripts/test-macos-install.py` |
| 未完成或损坏的 MBIM 分片持续占用内存 | 清理错误和超时事务，限制重组大小与数量；满载时淘汰无等待事务的分片，保障后续命令和事件恢复 | `pkg/mbim/device.go`、`fragment.go` |
| 类型化 AT 拨号/USSD 接口直接插入参数 | 在发送任何 AT 前拒绝控制字符和引号；拨号同时拒绝分号，保留 USSD 交互文本与原始 AT 终端 | `internal/modem/manager.go` |

MBIM 防御上限为每个重组消息 1 MiB、4096 个分片，每个设备最多保留 64 个未完成重组。单次传输原有的 64 KiB 上限不变。这是客户端资源上限，不是对所有 MBIM 扩展协议的大小承诺。

## 图标与发布

保留原始 PNG 及应用内图标，在打包时生成带透明边距的完整 ICNS。1024 像素画布上的实心主体约为 822 × 825 像素，与本机系统图标接近。App 启动检查同时校验 `CFBundleIconFile` 指向有效 ICNS。

Intel 与 ARM 的 Release 构建必须通过 Go 测试和竞态检测、Swift XCTest、Web 音频测试、安装回归，以及便携包和原生 App 解压后的演示启动检查。发布步骤核对 8 个附件和全部 SHA-256 后才公开 Release。

## 验证方式

```sh
go vet ./...
go test ./...
go test -race ./...
govulncheck ./...
swift build -c release --package-path apps/hub-macos
swift test --package-path apps/hub-macos
node --test scripts/phone-audio.test.cjs
python3 scripts/test-macos-install.py
shellcheck -S warning scripts/*.sh packaging/install packaging/dj4ghub
```

本机使用 Command Line Tools，缺少 XCTest；原生测试交由 GitHub 的完整 Xcode 环境运行。安装器测试仅操作临时目录，协议与接口测试使用合成数据，不连接真实硬件。

同源 Web 与原生请求继续兼容。手写 CLI 写请求现在须带 `Content-Type: application/json`。已知的设备兼容、运营商注册、原生音频长期通话和休眠恢复范围，仍以 README 中的真机验证记录为准。

Go 工具链升级依据：[Go 官方发布记录](https://go.dev/doc/devel/release#go1.26.0)。漏洞结果按本轮扫描时间记录，不代表未来不会披露新问题。
