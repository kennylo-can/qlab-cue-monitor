QLab Cue Monitor 一键启动包

使用方法：
1. 双击 start.command 启动网页服务。
2. 浏览器会自动打开本机页面。
3. 终端窗口里会显示局域网访问地址，例如：
   http://192.168.1.50:8080/index.html
4. 其他设备在同一个局域网内打开这个地址即可访问。
5. 这台演出主机会自己轮询 Companion，其他设备只看缓存，不会直接压 Companion。
6. 需要关闭时，双击 stop.command。

重要设置：
- 共享看板模式下，网页默认走本机服务器代理，不需要每台设备单独连 Companion。
- 如果你要在同一台机器上直接打开 HTML 文件做调试，左下角齿轮里仍然可以改 Companion Address 和 QLab Connection ID。

macOS 安全提示：
- 第一次双击 .command 文件可能会提示安全限制。
- 可以右键点击 start.command / stop.command，选择“打开”。
- 如果仍然打不开，在终端里进入文件夹后执行：
  chmod +x start.command stop.command

默认端口：
- 网页服务端口：8080
- Companion 默认端口：8000
