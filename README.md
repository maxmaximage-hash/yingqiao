# 影桥

原生 macOS iPhone 媒体导入器，使用 SwiftUI、ImageCaptureCore 和 PhotoKit。通过 USB 浏览与导出 iPhone 照片和视频，也可选择本机照片图库。

## 下载安装

需要 **macOS 14 或更高版本**。安装包包含 Apple Silicon 和 Intel 两种架构，运行所需框架均由 macOS 提供。

源码与安装包公开提供，采用 [MIT 许可证](LICENSE)。

1. 打开 [安装包下载](https://github.com/maxmaximage-hash/yingqiao/releases)。
2. 下载最新版本的 `.dmg`，双击打开。
3. 将“影桥.app”拖到 Applications 文件夹，随后从应用程序打开。

当前使用 ad-hoc 签名，尚未完成 Apple Developer ID 签名及公证。首次打开下载版遇到系统拦截时，先核对下载来源，再到“系统设置 → 隐私与安全性”批准打开。操作说明见 [Apple 支持](https://support.apple.com/zh-cn/102445)。

## 拉取后安装

仓库自带通用预编译安装包，安装脚本会校验 SHA-256 与应用签名。

```bash
git clone https://github.com/maxmaximage-hash/yingqiao.git
cd yingqiao
./install.command
```

也可以使用 GitHub 的“Code → Download ZIP”，解压后双击 `install.command`。安装时先退出已运行的影桥。

默认安装到 `/Applications/影桥.app`，该目录无法写入时安装到 `~/Applications/影桥.app`。可指定安装目录。

```bash
./install.command --destination "$HOME/Applications"
```

## 使用

1. 用数据线连接 iPhone，并完成手机与 Mac 的系统授权。
2. 在影桥选择“USB 设备”，等待目录读取完成。
3. 选择媒体，设置“导出到…”目录与导出格式。
4. 点击“开始导出”。默认保留原文件，选择 JPG 时转换图片并使用设定质量。

Live Photo 根据配套资源识别并显示 LIVE 标识，悬停时按需读取配套 MOV 预览。缩略图缓存保存在 `~/Library/Caches/影桥/thumbnails`，设备目录审计日志保存在 `~/Library/Logs/影桥/catalog-audit.ndjson`。

## 当前验证状态

此版本作为预览版同步。USB 目录和 Live Photo 配对已有实机读取记录。缩略图持续空白、加载性能和部分重连行为仍在排查，首屏及滚动视口的 5 秒目标尚待实机验收。安装包包含当前源码构建出的版本。

每台 Mac 的照片图库权限、iPhone 信任和 USB 访问由系统管理，首次连接时按系统提示完成授权。

## 源码构建

需要 macOS 14+ 及 Xcode Command Line Tools 或 Xcode。

```bash
xcode-select --install
./build.sh
```

输出为 `build/影桥.app`，可直接复制到应用程序。构建脚本生成 `arm64` 与 `x86_64` 通用二进制并执行 ad-hoc 签名验证。

重新生成仓库内的安装包与发布用 DMG。

```bash
./scripts/package.sh
```

`Distribution/` 中的 ZIP 和校验文件随源码提交，`dist/` 中的 DMG 和校验文件用于 GitHub Release。构建产物、设备日志与本机缓存由 `.gitignore` 排除。

开发过程记录见 [DEVELOPMENT.md](DEVELOPMENT.md)。历史条目反映各自记录时的实现，当前安装说明以本文件为准。
