# QLab Cue Monitor

本仓库包含一个适合现场使用的 QLab 看板系统：

- 本机菜单栏 app 负责启动和停止本地代理服务
- 本地服务轮询 Companion 并缓存状态
- 其他设备只访问网页，不直接压 Companion

## 目录结构

- `index.html`：看板前端
- `server.js`：本机代理服务
- `mac-app/`：菜单栏 app 的 Swift 源码
- `start.command` / `stop.command`：手动启动和停止脚本
- `assets/AppIconSource.png`：app 图标源文件
- `release/`：打包产物输出目录

## 开发环境

- macOS
- Swift 6+
- Node.js 18+

## 本地运行

### 方式 1：直接看网页

```bash
node server.js
```

然后打开：

```text
http://127.0.0.1:8080/index.html
```

### 方式 2：菜单栏 app

编译 `mac-app/QLabCueMonitorStatusApp.swift` 后，会得到一个菜单栏 app。
它会自动启动 `server.js`，并在菜单中提供：

- Start / Stop Server
- Open Dashboard
- Copy Dashboard URL
- Quit

## 打包

### 生成 app

```bash
./build-app.sh
```

这个脚本会：

- 生成 `QLab Cue Monitor.app`
- 自动把图标源图转成 `.icns`
- 自动把当前可用的 `node` 一起封进 app

### 生成 dmg

```bash
./build-dmg.sh
```

`build-dmg.sh` 默认把 app 打进 `release/QLab Cue Monitor.dmg`。

## 现场部署建议

- QLab 和 Companion 放在同一台机器时，延迟最低
- 多台设备只访问网页，不要让每台设备直连 Companion
- 如果没有 Apple Developer ID，其他 Mac 首次打开时可能需要手动放行

## 许可证

未指定许可证。发布前请补一个合适的 LICENSE 文件。
