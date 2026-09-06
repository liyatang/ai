# Codex 状态

面向 Apple Silicon Mac 的轻量桌面状态卡片，固定显示在主屏幕左上角。

<img src="docs/screenshot-v2.png" alt="Codex 状态应用截图：额度、GPT 连接诊断、本机 CPU 与内存、系统资源趋势" width="330">

截图为新版界面的合成验收示例；实际数值随使用情况变化。

它显示：

- 当前连接结论、近五分钟后台重试、最近模型输出与明确操作建议。
- 选中节点、实际连接节点、Clash/mihomo TUN 及真实路由；支持任意策略组名称，包括 `Proxy`。
- 最近三分钟 ChatGPT 短请求延迟与失败标记；探针不代表模型速度或长连接稳定性。
- 已观察的最近 24 小时历史重试，独立于当前告警；新版启动前未采集的事件不宣称完整覆盖。
- 周额度、重置时间、额度独立更新时间；未知额度不显示为剩余 100%，失败回退标记缓存，跨重置点失效。
- GPT 本机、系统 CPU/内存和三分钟上下行趋势。GPT 本机仍按明确程序路径识别 ChatGPT/Codex 应用及专用 Computer Use/Chrome 助手，每个 PID 只计一次；排除普通浏览器、项目 Node、Docker 和状态小组件。CPU 为单核 100% 的进程口径，内存采用 `ri_phys_footprint`，按十进制 GB 显示；读取失败不回退为 RSS。

## 诊断规则

- 近期至少三次**尚无同任务后续输出**的连接重试，且两次间隔至少十秒的采集仍满足条件，才显示持续异常。单次重试、已继续输出或历史累计不要求切节点。
- 三次连续探针失败独立提示探针异常，连续两次成功后恢复。长时间没有输出不自动认定网络故障。
- 诊断超过 45 秒、探针超过各自周期两倍后，不再生成当前告警；日志不完整或格式不支持时明确降级。
- 节点切换、控制器/节点实例变化、监控恢复后隔离观察代次。路由或节点身份无法确认时不生成节点建议。
- 仅持续异常或手动刷新时测速；每节点五次，最多五个并发，整轮最长约一分钟。未完成五次成功的节点不进入候选。自动比较至少间隔十分钟，结果十分钟后过期。
- 候选仅供手动尝试，不承诺长连接稳定；App 不修改 selector、不发系统通知、不调用模型测速。正常状态下不主动建议切换。

源码按采集适配（`status_logs.py`、`status_proxy.py`）、纯诊断（`status_engine.py`）、协调与持久化（`diagnostics.py`）及 AppKit 呈现拆分。Python 脚本现在随 App 捆绑；原共享脚本保留供旧 App 回退。

## 安装或更新（推荐）

**支持 M 系列 Mac，macOS 14 或更新版本。无需安装 Xcode 或自己编译。**

复制下面这句话给 Codex，首次安装和更新都可以：

```text
请帮我安装或更新 https://github.com/liyatang/ai 中的 Codex 状态工具。先检查电脑是否满足要求；缺少依赖时告诉我并协助处理，按照仓库的 AGENTS.md 完成后确认应用能正常打开。
```

需要 Python 3.9 或更新版本，缺少时 Codex 会先说明并征得确认再协助安装。登录 Codex 后即可显示额度；更新会保留个人配置和缓存。

## 隐私

- 不上传、不提交或显示 Codex token
- 不读取提示词、工具参数和工作目录
- Codex 性能诊断通过 SQL 仅提取时间、脱敏任务关联及事件类型，不返回消息正文
- 新版观察事件保存在 `~/.config/quota-widget/observations-v2.json`，仅包含脱敏任务标识、事件时间/类型和代理实例观察元数据，权限 `0600`。最多保留 24 小时重试及短期活动；旧 `gpt_node_quality.json` 保留，不参与新版评级。
- 最近 100 条脚本启动、退出和解码错误保存在 `~/.config/quota-widget/app_events.log`，不记录提示词或认证信息，权限为 `0600`
- 节点测速通过 mihomo 让候选节点分别访问 ChatGPT 轻量端点；测速不切换节点、不调用模型，App 也不提供 selector 写操作
- 配置保存在 `~/.config/quota-widget/config.json`，权限设置为 `0600`
- 额度请求使用当前用户自己的 Codex 登录态

不要把 `~/.codex/auth.json`、`config.json`、`cache.json`、`gpt_node_quality.json` 、`observations-v2.json` 或 Codex 日志提交到仓库。

## 首次打开与开机启动

通过 Git 克隆并运行安装脚本通常可以直接启动。如果 macOS 阻止打开，请在 Finder 中右键 App，选择“打开”，不要全局关闭 Gatekeeper。

需要开机启动时，在“系统设置 → 通用 → 登录项”中手动添加 `~/Applications/Codex 状态.app`。

在卡片上点右键可以“立即刷新”或退出 App。`config.json` 可选配置 `"anchor_screen": "mouse"`，让卡片跟随鼠标所在屏幕。

## 手动安装与更新（进阶）

首次安装：

```bash
git clone https://github.com/liyatang/ai.git
cd ai/tools/codex-status
./install.sh
```

已有安装：在之前下载的 `ai` 仓库目录打开终端，执行：

```bash
git pull --ff-only
cd "$(git rev-parse --show-toplevel)/tools/codex-status"
./install.sh
```

若更新提示本地改动或冲突，请交给 Codex 协助处理，不要强制覆盖。旧 App 会先移动到废纸篓，个人配置和额度缓存不会被覆盖。低于 macOS 14 的电脑会在修改安装前收到提示并退出。

## 卸载

退出 App 后删除：

- `~/Applications/Codex 状态.app`
- `~/.config/quota-widget`

如果添加过登录项，也请在系统设置中移除。

## 开发验证

```bash
./build.sh
python3 -m unittest discover -s tests -v
./tests/run_swift_tests.sh
./tests/render_previews.sh /tmp/codex-status-previews
```

当自动识别缺少连接样本时，可在 `config.json` 中设置 `"diagnostics": {"proxy_group": "Proxy"}` 提供策略组候选；该配置不会覆盖实际路由冲突。

诊断术语与边界见 [CONTEXT.md](CONTEXT.md)。

发布前检查 `xcrun vtool -show-build bin/AIQuota` 的 `minos` 为 `14.0`，并验证签名。提交构建脚本、Info.plist、预编译程序、源码校验文件和说明后推送仓库，用户即可按上述方式更新。最低系统版本的编译检查不替代 macOS 14.6 实机启动验收。
