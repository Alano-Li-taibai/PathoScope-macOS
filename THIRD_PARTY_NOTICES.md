# Third-Party Notices

PathoScope 自有源代码按 MIT License 发布。以下项目参与了当前实现的运行、验证或格式理解：

## OpenSlide

- Project: https://openslide.org/
- Source: https://github.com/openslide/openslide
- License: GNU Lesser General Public License, version 2.1
- Usage: `Tools/OpenSlideTileHelper/main.c` 调用系统安装的 OpenSlide 动态库，读取 SVS、NDPI、SCN 和 TIFF 等格式。

本仓库和当前 DMG 不捆绑 OpenSlide 动态库；用户通过 Homebrew 单独安装。OpenSlide 及其依赖继续受各自许可证约束。

## mrxs-reader 0.1.0

- Project: https://github.com/cardiac-adhesive-lab/mrxs-reader
- License: MIT
- Usage: 在早期格式审计中用于理解 MRXS 字段并做独立结果对照。

公开仓库不包含该 Python 包；PathoScope 运行时使用本项目自己的 Swift/ImageIO MRXS 读取器。

## Apple frameworks

SwiftUI、AppKit、Metal、ImageIO、CoreGraphics 和 Compression 来自 macOS SDK，并受 Apple 相应条款约束。
