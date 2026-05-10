import Foundation

final class DashboardState {
    static let shared = DashboardState()

    private(set) var currentCueName = ""
    private(set) var currentCueNumber = ""
    private(set) var currentCueType = ""
    private(set) var nextCueName = ""
    private(set) var nextCueNumber = ""
    private(set) var nextCueType = ""
    private(set) var timecode = "--:--:--:--"
    private(set) var countdown = "--:--"
    private(set) var elapsed = "--:--"
    private(set) var remaining = "--:--"
    private(set) var prewait = "--.--"
    private(set) var progress: Double = 0
    private(set) var connectionState = "WAITING FOR QLAB"
    private(set) var workspaceName = "Default Workspace"
    private(set) var cueListName = "Default Cue List"
    private(set) var latestAddress = ""
    private(set) var latestValue = ""
    private(set) var latestTime = ""

    var jsonData: Data {
        let payload: [String: Any] = [
            "currentCueName": currentCueName,
            "currentCueNumber": currentCueNumber,
            "currentCueType": currentCueType,
            "nextCueName": nextCueName,
            "nextCueNumber": nextCueNumber,
            "nextCueType": nextCueType,
            "timecode": timecode,
            "countdown": countdown,
            "elapsed": elapsed,
            "remaining": remaining,
            "prewait": prewait,
            "progress": progress,
            "connectionState": connectionState,
            "workspaceName": workspaceName,
            "cueListName": cueListName,
            "latestAddress": latestAddress,
            "latestValue": latestValue,
            "latestTime": latestTime
        ]
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])) ?? Data()
    }

    func applyOSC(_ data: Data) {
        guard let message = OSCMessageParser.parse(data) else {
            latestTime = ISO8601DateFormatter().string(from: Date())
            latestAddress = "OSC packet \(data.count) bytes"
            latestValue = ""
            return
        }
        latestTime = ISO8601DateFormatter().string(from: Date())
        latestAddress = message.address
        latestValue = message.arguments.map { String(describing: $0) }.joined(separator: " ")
        connectionState = "CONNECTED"

        let value = message.firstString ?? message.firstNumberString ?? ""
        if message.address.contains("/active/number") || message.address.hasSuffix("/number") {
            currentCueNumber = value
        } else if message.address.contains("/active/name") || message.address.hasSuffix("/name") {
            currentCueName = value
        } else if message.address.contains("/active/type") || message.address.hasSuffix("/type") {
            currentCueType = value
        } else if message.address.contains("/next/number") {
            nextCueNumber = value
        } else if message.address.contains("/next/name") {
            nextCueName = value
        } else if message.address.contains("/next/type") {
            nextCueType = value
        } else if message.address.localizedCaseInsensitiveContains("timecode") {
            timecode = value
        } else if message.address.localizedCaseInsensitiveContains("countdown") || message.address.localizedCaseInsensitiveContains("remaining") {
            countdown = value
            remaining = value
        } else if message.address.localizedCaseInsensitiveContains("elapsed") {
            elapsed = value
        } else if message.address.localizedCaseInsensitiveContains("prewait") || message.address.localizedCaseInsensitiveContains("preWait") {
            prewait = value
        } else if message.address.localizedCaseInsensitiveContains("progress") {
            if let p = message.firstNumberString.flatMap(Double.init) {
                progress = p
            }
        }
    }

    func setWorkspaceName(_ value: String) {
        workspaceName = value.isEmpty ? "Default Workspace" : value
    }

    func setCueListName(_ value: String) {
        cueListName = value.isEmpty ? "Default Cue List" : value
    }

    func setConnectionState(_ value: String) {
        connectionState = value
    }
}

struct OSCMessage {
    let address: String
    let arguments: [Any]

    var firstString: String? {
        arguments.compactMap { $0 as? String }.first
    }

    var firstNumberString: String? {
        if let value = arguments.compactMap({ $0 as? Double }).first {
            return Self.format(number: value)
        }
        if let value = arguments.compactMap({ $0 as? Int }).first {
            return String(value)
        }
        return nil
    }

    private static func format(number: Double) -> String {
        if number.rounded() == number { return String(Int(number)) }
        return String(format: "%.2f", number)
    }
}

enum OSCMessageParser {
    static func parse(_ data: Data) -> OSCMessage? {
        var offset = 0
        guard let address = readString(data, &offset) else { return nil }
        guard let types = readString(data, &offset), types.hasPrefix(",") else { return nil }
        var args: [Any] = []
        for type in types.dropFirst() {
            switch type {
            case "s":
                if let value = readString(data, &offset) { args.append(value) }
            case "i":
                guard let value = readInt32(data, &offset) else { return nil }
                args.append(Int(value))
            case "f":
                guard let value = readFloat(data, &offset) else { return nil }
                args.append(Double(value))
            case "T":
                args.append(true)
            case "F":
                args.append(false)
            case "N":
                args.append(NSNull())
            default:
                skipUnknownType(data, &offset)
            }
        }
        return OSCMessage(address: address, arguments: args)
    }

    private static func readString(_ data: Data, _ offset: inout Int) -> String? {
        guard offset < data.count else { return nil }
        var end = offset
        while end < data.count, data[end] != 0 { end += 1 }
        guard let value = String(data: data[offset..<end], encoding: .utf8) else { return nil }
        offset = ((end + 1 + 3) / 4) * 4
        return value
    }

    private static func readInt32(_ data: Data, _ offset: inout Int) -> Int32? {
        guard offset + 4 <= data.count else { return nil }
        let value = data[offset..<offset+4].withUnsafeBytes { $0.load(as: Int32.self) }
        offset += 4
        return Int32(bigEndian: value)
    }

    private static func readFloat(_ data: Data, _ offset: inout Int) -> Float? {
        guard offset + 4 <= data.count else { return nil }
        let bits = data[offset..<offset+4].withUnsafeBytes { $0.load(as: UInt32.self) }
        offset += 4
        return Float(bitPattern: UInt32(bigEndian: bits))
    }

    private static func skipUnknownType(_ data: Data, _ offset: inout Int) {
        offset = min(data.count, offset + 4)
    }
}
