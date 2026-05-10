# QLab OSC Dashboard

一个适合 QLab 5.4+ 的本地 OSC 信息看板。

## 作用

- QLab 通过 OSC 把 cue 信息发到本机
- 本地 Node 服务接收 OSC
- 页面通过 WebSocket 实时更新
- 同一局域网内的其他设备可以直接打开网页查看

## 启动

```bash
node server.js
```

默认端口：

- 看板网页：`3000`
- OSC 接收：`53000`

## 访问

- 本机：`http://localhost:3000`
- 局域网：启动后终端会打印可访问的 IP 地址

## QLab 配置思路

把 QLab 的 OSC 输出指向这台机器的 `53000` 端口，然后让看板页面通过浏览器打开 `3000` 端口。

## 已支持的 OSC 地址

当前版本会尽量兼容一些常见地址，例如：

- `/cue/active/name`
- `/cue/active/number`
- `/cue/active/type`
- `/cue/active/id`
- `/cue/active/path`
- `/cue/active/color`
- `/cue/active/notes`
- `/cue/active/listName`
- `/cue/next/name`
- `/cue/next/number`
- `/cue/next/type`
- `/cue/next/id`

如果你后面给我一组你实际在 QLab 里发出的 OSC 地址，我可以把映射再补完整，做得更准。
