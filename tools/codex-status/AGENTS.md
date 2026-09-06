# Codex 安装指引

当用户要求安装本目录的工具时：

1. 只读检查 Mac 是否为 Apple Silicon、macOS 是否为 14.0 或更新版本，以及是否存在 Python 3.9 或更高版本。不满足系统或架构要求时停止安装，不要求用户重装 Xcode。
2. 不读取、打印、复制或提交 `~/.codex/auth.json` 的内容，只检查文件是否存在。
3. 如果 Python 不可用，先向用户说明；获得确认后再通过其已有的 Homebrew 安装 Python。不要静默安装 Homebrew。
4. 首次安装克隆 `https://github.com/liyatang/ai`；更新时优先复用已有仓库，先检查工作区，干净时运行 `git pull --ff-only`，有本地改动时保留并说明，不强制覆盖。进入 `tools/codex-status` 运行 `./install.sh`，使用预编译程序，不让普通用户安装 Xcode 或自行编译；不要手工复制用户的配置或缓存。
5. 验证 App 签名、进程和窗口是否正常；不要替用户添加登录项。
6. 安装期间不得把 token、额度缓存、Codex 日志或个人路径写入仓库。

