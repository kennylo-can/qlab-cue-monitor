import Foundation
import Network

final class OSCReceiver {
    private let port: UInt16
    private let useTCP: Bool
    private var listener: NWListener?
    private let onPacket: (Data) -> Void

    init(port: UInt16, useTCP: Bool, onPacket: @escaping (Data) -> Void) {
        self.port = port
        self.useTCP = useTCP
        self.onPacket = onPacket
    }

    func start() {
        do {
            let params = useTCP ? NWParameters.tcp : NWParameters.udp
            let nwPort = NWEndpoint.Port(rawValue: port)!
            listener = try NWListener(using: params, on: nwPort)
            listener?.newConnectionHandler = { connection in
                connection.start(queue: .global())
                self.receive(on: connection)
            }
            listener?.start(queue: .global())
        } catch {
            print("OSC receiver failed: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func receive(on connection: NWConnection) {
        if useTCP {
            receiveTCP(on: connection, buffer: Data())
        } else {
            connection.receiveMessage { data, _, _, error in
                if let data = data {
                    self.onPacket(data)
                }
                if error == nil {
                    self.receive(on: connection)
                } else {
                    connection.cancel()
                }
            }
        }
    }

    private func receiveTCP(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65535) { data, _, isComplete, error in
            var nextBuffer = buffer
            if let data = data, !data.isEmpty {
                nextBuffer.append(data)
                self.drainTCPBuffer(&nextBuffer)
            }
            if error == nil && !isComplete {
                self.receiveTCP(on: connection, buffer: nextBuffer)
            } else {
                connection.cancel()
            }
        }
    }

    private func drainTCPBuffer(_ buffer: inout Data) {
        while buffer.count >= 4 {
            let size = Int(buffer.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            guard buffer.count >= size + 4 else { return }
            let packet = buffer.subdata(in: 4..<(4 + size))
            onPacket(packet)
            buffer.removeFirst(4 + size)
        }
    }
}
