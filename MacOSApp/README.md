# QLab OSC Dashboard macOS App

这是原生 macOS App 版本的源码骨架。

## 结构

- App 本体：`MacOSApp/*.swift`
- 看板静态资源：`MacOSApp/Resources/*`
- App 内设置：`SettingsView.swift`

## 说明

App 启动后会：

- 在本机开启 Web 服务
- 在局域网里提供 HTML 看板
- 通过 App 内设置修改 Web 端口和 OSC 端口

## 下一步

我还需要把 OSC 解析和 HTTP 服务器做完整，才能真正成为可编译可用的 macOS App。
