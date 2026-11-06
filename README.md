# OpenMinis for Mac

基于 [OpenMinis](https://github.com/OpenMinis/OpenMinis) 思路的原生 macOS（SwiftUI）AI Agent 应用，MVP 版本。

## 功能

- 多会话聊天，流式输出，Markdown / 代码块渲染
- 模型服务：OpenAI 兼容接口（OpenAI、DeepSeek、Gemini、OpenRouter、Ollama 等）与 Anthropic 原生接口
- 工具调用：`shell`（本机 /bin/zsh）、`read_file`、`write_file`、`edit_file`、`list_dir`、`web_fetch`、`memory_write`
- 执行 shell 前可要求用户确认（默认开启）
- API Key 存储在系统钥匙串

## 安装

从 [Releases](../../releases) 下载 dmg，拖入「应用程序」。安装包未签名，首次打开请右键选「打开」，或执行：

```sh
xattr -cr /Applications/OpenMinis.app
```

## 构建

需要 macOS 14+ 与 Xcode 15+：

```sh
scripts/bundle.sh 0.1.0   # 产物在 dist/
```

## 许可

GPL-3.0，与上游 OpenMinis 相同。应用图标来自 OpenMinis 项目。
