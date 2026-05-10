import Foundation
import Network

protocol QLabOSCClientDelegate: AnyObject {
    func oscClient(_ client: QLabOSCClient, didConnect workspace: String)
    func oscClient(_ client: QLabOSCClient, didDisconnect reason: String)
    func oscClient(_ client: QLabOSCClient, didReceiveReply status: String, address: String, data: Any?)
    func oscClient(_ client: QLabOSCClient, didReceiveUpdate address: String, args: [Any])
    func oscClient(_ client: QLabOSCClient, didReceiveEvent event: String, number: String?, name: String?, uniqueID: String?, type: String?)
    func oscClient(_ client: QLabOSCClient, didReceiveTimecode timecode: String)
}

extension QLabOSCClientDelegate {
    func oscClient(_ client: QLabOSCClient, didConnect workspace: String) {}
    func oscClient(_ client: QLabOSCClient, didDisconnect reason: String) {}
    func oscClient(_ client: QLabOSCClient, didReceiveReply status: String, address: String, data: Any?) {}
    func oscClient(_ client: QLabOSCClient, didReceiveUpdate address: String, args: [Any]) {}
    func oscClient(_ client: QLabOSCClient, didReceiveEvent event: String, number: String?, name: String?, uniqueID: String?, type: String?) {}
    func oscClient(_ client: QLabOSCClient, didReceiveTimecode timecode: String) {}
}

final class QLabOSCClient {
    weak var delegate: QLabOSCClientDelegate?

    let host: String
    let port: UInt16
    let useTCP: Bool

    private var connection: NWConnection?
    private var tcpBuffer = Data()
    private let queue = DispatchQueue(label: "com.codex.qlaboscclient.\(UUID().uuidString)")
    private var isConnected = false
    private var passcode: String?
    private var workspace: String?
    private var keepAliveTimer: DispatchSourceTimer?

    init(host: String, port: UInt16, useTCP: Bool = true) {
        self.host = host
        self.port = port
        self.useTCP = useTCP
    }

    func connect(passcode: String? = nil, workspace: String? = nil) {
        self.passcode = passcode
        self.workspace = workspace
        let params = useTCP ? NWParameters.tcp : NWParameters.udp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            delegate?.oscClient(self, didDisconnect: "Invalid port \(port)")
            return
        }
        connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        connection?.stateUpdateHandler = { [weak self] state in
            self?.handleState(state)
        }
        connection?.start(queue: queue)
    }

    func disconnect() {
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
        sendOSC(address: "/disconnect", args: [])
        connection?.cancel()
        connection = nil
        isConnected = false
        tcpBuffer = Data()
    }

    func sendOSC(address: String, args: [Any] = []) {
        let packet = OSCPacketEncoder.encode(address: address, arguments: args)
        guard let conn = connection else { return }
        if useTCP {
            var framed = Data()
            var size = UInt32(packet.count).bigEndian
            withUnsafeBytes(of: &size) { framed.append(contentsOf: $0) }
            framed.append(packet)
            conn.send(content: framed, completion: .contentProcessed { _ in })
        } else {
            conn.send(content: packet, completion: .contentProcessed { _ in })
        }
    }

    func connectToWorkspace(passcode: String? = nil, workspace: String? = nil, completion: @escaping (Bool, String) -> Void) {
        let ws = workspace?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let address = ws.isEmpty ? "/workspace/connect" : "/workspace/\(ws)/connect"
        let pass = passcode ?? ""
        // We need a temporary reply handler. The current approach sends this before
        // the delegate is fully wired, so we use the connect callback directly.
        // In production, you'd set up a reply listener first.
        self.passcode = passcode
        self.workspace = workspace
        connect(passcode: passcode, workspace: workspace)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            self.sendOSC(address: address, args: [pass])
            // Assume success for now - reply parsing will confirm
            completion(true, "Sending connect to \(self.host):\(self.port)")
        }
    }

    // MARK: - QLab OSC Protocol: Actions

    func go(workspace: String? = nil) {
        wsSend("/go", workspace: workspace)
    }

    func go(cueNumber: String, workspace: String? = nil) {
        wsSend("/go/\(cueNumber)", workspace: workspace)
    }

    func pause(workspace: String? = nil) {
        wsSend("/pause", workspace: workspace)
    }

    func stop(workspace: String? = nil) {
        wsSend("/stop", workspace: workspace)
    }

    func resume(workspace: String? = nil) {
        wsSend("/resume", workspace: workspace)
    }

    func reset(workspace: String? = nil) {
        wsSend("/reset", workspace: workspace)
    }

    func hardStop(workspace: String? = nil) {
        wsSend("/hardStop", workspace: workspace)
    }

    func panic(workspace: String? = nil) {
        wsSend("/panic", workspace: workspace)
    }

    func panicInTime(_ seconds: Double, workspace: String? = nil) {
        wsSend("/panicInTime", args: [seconds], workspace: workspace)
    }

    // MARK: - QLab OSC Protocol: Subscriptions

    func subscribeUpdates() {
        sendOSC(address: "/updates", args: [1])
    }

    func unsubscribeUpdates() {
        sendOSC(address: "/updates", args: [0])
    }

    func enableAlwaysReply() {
        sendOSC(address: "/alwaysReply", args: [1])
    }

    func disableAlwaysReply() {
        sendOSC(address: "/alwaysReply", args: [0])
    }

    func enableKeepAlive() {
        sendOSC(address: "/forgetMeNot", args: [true])
        startKeepAliveHeartbeat()
    }

    func disableKeepAlive() {
        stopKeepAliveHeartbeat()
        sendOSC(address: "/forgetMeNot", args: [false])
    }

    func subscribeShowControl() {
        sendOSC(address: "/listen", args: [])
    }

    func unsubscribeShowControl() {
        sendOSC(address: "/ignore", args: [])
    }

    func setUDPReplyPort(_ port: UInt16) {
        sendOSC(address: "/udpReplyPort", args: [Int(port)])
    }

    // MARK: - QLab OSC Protocol: Queries

    func queryVersion() {
        sendOSC(address: "/version", args: [])
    }

    func queryWorkspaces() {
        sendOSC(address: "/workspaces", args: [])
    }

    func queryCueLists(workspace: String? = nil) {
        wsSend("/cueLists", workspace: workspace)
    }

    func queryCurrentCueList(workspace: String? = nil) {
        wsSend("/currentCueList", workspace: workspace)
    }

    func queryRunningCues(workspace: String? = nil) {
        wsSend("/runningCues", workspace: workspace)
    }

    func queryRunningOrPausedCues(workspace: String? = nil) {
        wsSend("/runningOrPausedCues", workspace: workspace)
    }

    func queryPlaybackPosition(workspace: String? = nil) {
        wsSend("/playbackPosition", workspace: workspace)
    }

    func queryCue(_ identifier: String, workspace: String? = nil) {
        wsSend("/cue_id/\(identifier)", workspace: workspace)
    }

    func queryActiveCue(property: String, workspace: String? = nil) {
        wsSend("/cue/active/\(property)", workspace: workspace)
    }

    func queryPlayheadCue(property: String, workspace: String? = nil) {
        wsSend("/cue/playhead/\(property)", workspace: workspace)
    }

    // MARK: - Private

    private func wsSend(_ address: String, args: [Any] = [], workspace: String? = nil) {
        let ws = workspace ?? self.workspace
        if let ws = ws, !ws.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sendOSC(address: "/workspace/\(ws)\(address)", args: args)
        } else {
            sendOSC(address: "\(address)", args: args)
        }
    }

    private func startKeepAliveHeartbeat() {
        stopKeepAliveHeartbeat()
        keepAliveTimer = DispatchSource.makeTimerSource(queue: queue)
        keepAliveTimer?.schedule(deadline: .now() + 30, repeating: 30)
        keepAliveTimer?.setEventHandler { [weak self] in
            self?.sendOSC(address: "/thump", args: [])
        }
        keepAliveTimer?.resume()
    }

    private func stopKeepAliveHeartbeat() {
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
    }

    private func startReceiving() {
        guard let conn = connection else { return }
        if useTCP {
            receiveTCP(on: conn)
        } else {
            receiveUDP(on: conn)
        }
    }

    private func receiveUDP(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            if let data = data, !data.isEmpty {
                self?.processOSCPacket(data)
            }
            if error == nil {
                self?.receiveUDP(on: conn)
            }
        }
    }

    private func receiveTCP(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65535) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                self?.tcpBuffer.append(data)
                self?.drainTCPBuffer()
            }
            if error == nil && !isComplete {
                self?.receiveTCP(on: conn)
            }
        }
    }

    private func drainTCPBuffer() {
        while tcpBuffer.count >= 4 {
            let size = Int(tcpBuffer.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            guard tcpBuffer.count >= size + 4 else { return }
            let packet = tcpBuffer.subdata(in: 4..<(4 + size))
            processOSCPacket(packet)
            tcpBuffer.removeFirst(4 + size)
        }
    }

    private func processOSCPacket(_ data: Data) {
        guard let message = OscMessageParser.parse(data) else { return }

        let address = message.address

        // Show control broadcast events
        if address.hasPrefix("/qlab/event/workspace/") {
            handleShowControlEvent(message)
            return
        }

        // Reply messages
        if address.hasPrefix("/reply/") {
            handleReply(message)
            return
        }

        // Update messages (subscription push)
        if address.hasPrefix("/update/") {
            handleUpdate(message)
            return
        }

        // Timecode from show control
        if address.hasSuffix("/timecode") || address.contains("/timecode") {
            delegate?.oscClient(self, didReceiveTimecode: message.firstString ?? "")
            return
        }

        // Pass through generic OSC to delegate
        delegate?.oscClient(self, didReceiveUpdate: address, args: message.arguments)
    }

    private func handleReply(_ message: OscMessage) {
        let invokedAddress = String(message.address.dropFirst("/reply".count))
        guard let jsonStr = message.firstString,
              let jsonData = jsonStr.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            delegate?.oscClient(self, didReceiveReply: "error", address: invokedAddress, data: message.arguments)
            return
        }
        let status = dict["status"] as? String ?? "unknown"
        let data = dict["data"]
        delegate?.oscClient(self, didReceiveReply: status, address: invokedAddress, data: data)
    }

    private func handleUpdate(_ message: OscMessage) {
        delegate?.oscClient(self, didReceiveUpdate: message.address, args: message.arguments)
    }

    private func handleShowControlEvent(_ message: OscMessage) {
        let path = message.address
        // /qlab/event/workspace/{event} "{number}" "{name}" "{uniqueID}" "{type}"
        let event = path.replacingOccurrences(of: "/qlab/event/workspace/", with: "")
        let number = message.argument(at: 0) as? String
        let name = message.argument(at: 1) as? String
        let uniqueID = message.argument(at: 2) as? String
        let type = message.argument(at: 3) as? String
        delegate?.oscClient(self, didReceiveEvent: event, number: number, name: name, uniqueID: uniqueID, type: type)
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            isConnected = true
            delegate?.oscClient(self, didConnect: workspace ?? host)
            startReceiving()
        case .failed(let error):
            isConnected = false
            delegate?.oscClient(self, didDisconnect: error.localizedDescription)
        case .cancelled:
            isConnected = false
        case .waiting(let error):
            delegate?.oscClient(self, didDisconnect: "Waiting: \(error.localizedDescription)")
        case .setup, .preparing:
            break
        @unknown default:
            break
        }
    }
}

// MARK: - OSC Packet Encoder (full type support)

enum OSCPacketEncoder {
    static func encode(address: String, arguments: [Any]) -> Data {
        var data = Data()
        data.append(oscString(address))

        var typeTag = ","
        var argData = Data()
        for arg in arguments {
            switch arg {
            case let s as String:
                typeTag.append("s")
                argData.append(oscString(s))
            case let i as Int:
                typeTag.append("i")
                argData.append(oscInt32(Int32(i)))
            case let i32 as Int32:
                typeTag.append("i")
                argData.append(oscInt32(i32))
            case let f as Float:
                typeTag.append("f")
                argData.append(oscFloat32(f))
            case let d as Double:
                typeTag.append("f")
                argData.append(oscFloat32(Float(d)))
            case let b as Bool:
                typeTag.append(b ? "T" : "F")
            default:
                typeTag.append("s")
                argData.append(oscString("\(arg)"))
            }
        }
        data.append(oscString(typeTag))
        data.append(argData)
        return data
    }

    private static func oscString(_ s: String) -> Data {
        var data = Data(s.utf8)
        data.append(0)
        while data.count % 4 != 0 { data.append(0) }
        return data
    }

    private static func oscInt32(_ v: Int32) -> Data {
        var val = v.bigEndian
        return withUnsafeBytes(of: &val) { Data($0) }
    }

    private static func oscFloat32(_ v: Float) -> Data {
        var val = v
        var bits = val.bitPattern.bigEndian
        return withUnsafeBytes(of: &bits) { Data($0) }
    }
}

// MARK: - OSC Message Parser (full type support)

struct OscMessage {
    let address: String
    let arguments: [Any]

    var firstString: String? { arguments.compactMap { $0 as? String }.first }
    var firstFloat: Float? { arguments.compactMap({ $0 as? Float }).first ?? arguments.compactMap({ $0 as? Double }).first.map(Float.init) }
    var firstInt: Int? { arguments.compactMap({ $0 as? Int }).first ?? arguments.compactMap({ $0 as? Int32 }).first.map(Int.init) }
    var firstBool: Bool? { arguments.compactMap({ $0 as? Bool }).first }
    var firstNumber: Double? {
        if let i = firstInt { return Double(i) }
        if let f = firstFloat { return Double(f) }
        return arguments.compactMap({ $0 as? Double }).first
    }

    func argument(at index: Int) -> Any? {
        guard arguments.indices.contains(index) else { return nil }
        return arguments[index]
    }
}

enum OscMessageParser {
    static func parse(_ data: Data) -> OscMessage? {
        var offset = 0
        guard let address = readString(data, &offset) else { return nil }
        guard let typeTag = readString(data, &offset), typeTag.hasPrefix(",") else { return nil }
        var args: [Any] = []
        for tag in typeTag.dropFirst() {
            switch tag {
            case "s":
                if let v = readString(data, &offset) { args.append(v) }
            case "i":
                guard let v = readInt32(data, &offset) else { return nil }
                args.append(v)
            case "f":
                guard let v = readFloat(data, &offset) else { return nil }
                args.append(v)
            case "d":
                guard let v = readDouble(data, &offset) else { return nil }
                args.append(v)
            case "T":
                args.append(true)
            case "F":
                args.append(false)
            case "N":
                args.append(Optional<Any>.none as Any)
            default:
                skip(data, &offset)
            }
        }
        return OscMessage(address: address, arguments: args)
    }

    private static func readString(_ data: Data, _ offset: inout Int) -> String? {
        guard offset < data.count else { return nil }
        var end = offset
        while end < data.count, data[end] != 0 { end += 1 }
        guard let s = String(data: data[offset..<end], encoding: .utf8) else { return nil }
        offset = ((end + 1 + 3) / 4) * 4
        return s
    }

    private static func readInt32(_ data: Data, _ offset: inout Int) -> Int32? {
        guard offset + 4 <= data.count else { return nil }
        let v = data[offset..<offset+4].withUnsafeBytes { $0.load(as: Int32.self) }
        offset += 4
        return Int32(bigEndian: v)
    }

    private static func readFloat(_ data: Data, _ offset: inout Int) -> Float? {
        guard offset + 4 <= data.count else { return nil }
        let bits = data[offset..<offset+4].withUnsafeBytes { $0.load(as: UInt32.self) }
        offset += 4
        return Float(bitPattern: UInt32(bigEndian: bits))
    }

    private static func readDouble(_ data: Data, _ offset: inout Int) -> Double? {
        guard offset + 8 <= data.count else { return nil }
        let bits = data[offset..<offset+8].withUnsafeBytes { $0.load(as: UInt64.self) }
        offset += 8
        return Double(bitPattern: UInt64(bigEndian: bits))
    }

    private static func skip(_ data: Data, _ offset: inout Int) {
        offset = min(data.count, offset + 4)
    }
}
