# Codex 安装指引

当用户要求安装本目录的工具时：

1. 只读检查 Mac 是否为 Apple Silicon，以及是否存在 Python 3.9 或更高版本。
2. 不读取、打印、复制或提交 `~/.codex/auth.json` 的内容，只检查文件是否存在。
3. 如果 Python 不可用，先向用户说明；获得确认后再通过其已有的 Homebrew 安装 Python。不要静默安装 Homebrew。
4. 运行 `./install.sh`，不要手工复制用户的配置或缓存。
5. 验证 App 签名、进程和窗口是否正常；不要替用户添加登录项。
6. 安装期间不得把 token、额度缓存、Codex 日志或个人路径写入仓库。

