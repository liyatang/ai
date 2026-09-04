# Codex 状态

面向 Apple Silicon Mac 的轻量桌面状态卡片，固定显示在主屏幕左上角。

<img src="docs/screenshot.jpg" alt="Codex 状态应用截图：额度、GPT 连接诊断、本机 CPU 与内存、系统资源趋势" width="330">

截图为实际运行示例，数值随使用情况变化。

它显示：

- Codex 周额度和重置时间
- Clash/mihomo TUN 是否真正生效、当前 AI 代理节点
- 当前节点的真实 GPT 首连成功率、流重连、连续稳定轮数和轻量端点 P50/P90
- 仅在当前连接不稳定时显示已验证稳定节点建议；未验证节点标记为“候选节点”
- App 不修改 selector，用户在 Clash 中手动切换；旧连接未结束时显示“旧连接收尾”
- ChatGPT 网络延迟、Codex 最近五分钟首输出等待和保守诊断
- CPU、内存、实时上下行网速
- GPT 本机资源：汇总 ChatGPT/Codex 应用包内进程，以及当前用户 `.codex/computer-use/` 下的 Computer Use 专用服务、`.codex/plugins/cache/openai-bundled/chrome/` 下的 Chrome 通信助手；按明确程序路径识别，不依赖父进程，每个 PID 只计一次。排除共享系统辅助服务、整个外部浏览器、项目 Node/next-server、Docker 和状态小组件。后台约每 6 秒更新；CPU 为 `ps` 进程口径（单核 100%，多核可超过 100%）；内存通过 `proc_pid_rusage` 读取 `ri_phys_footprint`，按十进制 GB 显示，更接近活动监视器的内存口径，但采样时刻和进程分组可能不同。任一进程内存读取失败时显示“内存不可用”，不回退到 RSS；这些数据不代表云端模型资源。
- 连接诊断中的 ChatGPT 延迟图，以及系统区的网络速度滚动图（最近三分钟）

## 用 Codex 安装（推荐）

把下面这段话发给 Codex：

```text
请安装这个仓库里的 tools/codex-status。
先只读检查我的 Mac 是否为 Apple Silicon、Python 3 是否满足要求，以及 Codex 是否已登录。
不要读取或输出 auth.json 的内容。
如果缺少 Python，请先说明安装方式并等我确认；然后运行 install.sh，验证 App 签名、进程和窗口。
不要自动添加开机登录项。
```

如果还没有下载仓库，也可以让 Codex 执行：

```bash
git clone https://github.com/liyatang/ai.git
cd ai/tools/codex-status
./install.sh
```

## 环境要求

- Apple Silicon Mac（M1/M2/M3/M4/M5 系列）
- macOS
- Python 3.9 或更高版本
- 已登录 Codex，通常应存在 `~/.codex/auth.json`

仓库内已包含 arm64 预编译 App，不要求安装 Xcode。Python 只用于本地额度和诊断脚本；如果机器上没有，让 Codex 在获得确认后协助安装即可。

## 隐私

- 不上传、不提交或显示 Codex token
- 不读取提示词、工具参数和工作目录
- Codex 性能诊断只读取本机日志中的时间、模型、reasoning effort、事件类型和重试元数据
- 节点稳定性历史保存在 `~/.config/quota-widget/gpt_node_quality.json`，仅包含最近 24 小时、至多 20 轮的聚合性能元数据，权限为 `0600`
- 最近 100 条脚本启动、退出和解码错误保存在 `~/.config/quota-widget/app_events.log`，不记录提示词或认证信息，权限为 `0600`
- 节点测速通过 mihomo 让候选节点分别访问 ChatGPT 轻量端点；测速不切换节点、不调用模型，App 也不提供 selector 写操作
- 配置保存在 `~/.config/quota-widget/config.json`，权限设置为 `0600`
- 额度请求使用当前用户自己的 Codex 登录态

不要把 `~/.codex/auth.json`、`config.json`、`cache.json`、`gpt_node_quality.json` 或 Codex 日志提交到仓库。

## 首次打开与开机启动

通过 Git 克隆并运行安装脚本通常可以直接启动。如果 macOS 阻止打开，请在 Finder 中右键 App，选择“打开”，不要全局关闭 Gatekeeper。

需要开机启动时，在“系统设置 → 通用 → 登录项”中手动添加 `~/Applications/Codex 状态.app`。

在卡片上点右键可以“立即刷新”或退出 App。`config.json` 可选配置 `"anchor_screen": "mouse"`，让卡片跟随鼠标所在屏幕。

## 更新

拉取最新代码后重新运行安装脚本：

```bash
git pull
cd tools/codex-status
./install.sh
```

旧 App 会先移动到废纸篓，个人配置和额度缓存不会被覆盖。

## 卸载

退出 App 后删除：

- `~/Applications/Codex 状态.app`
- `~/.config/quota-widget`

如果添加过登录项，也请在系统设置中移除。

## 开发验证

```bash
./build.sh
swiftc -warnings-as-errors -O -o /tmp/AIQuota app/main.swift
python3 -m unittest discover -s tests -v
./tests/run_swift_tests.sh
```

诊断术语与边界见 [CONTEXT.md](CONTEXT.md)。
