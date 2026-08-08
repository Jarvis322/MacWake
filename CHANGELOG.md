# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/).

## [Unreleased]

### Fixed
- 电池校准改为仅手动确认后启动，并在系统睡眠前同步取消，以免控制循环暂停时继续强制放电。
- 新增不依赖 SMC 的校准恢复规则回归测试。
- 修复本地化资源的语法错误，避免选择非英文界面后整张翻译表回退为英文。
