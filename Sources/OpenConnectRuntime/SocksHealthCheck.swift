import Darwin
import Dispatch
import VPNCore

public protocol SocksHealthChecking: Sendable {
    func isListening(endpoint: SocksEndpoint) async -> Bool
    func waitUntilListening(
        endpoint: SocksEndpoint,
        timeoutNanoseconds: UInt64,
        pollIntervalNanoseconds: UInt64
    ) async -> Bool
}

public struct SocksHealthCheck: SocksHealthChecking {
    private let connectTimeoutMilliseconds: Int32

    public init(connectTimeoutMilliseconds: Int32 = 250) {
        self.connectTimeoutMilliseconds = connectTimeoutMilliseconds
    }

    public func isListening(endpoint: SocksEndpoint) async -> Bool {
        Self.canConnect(to: endpoint, timeoutMilliseconds: connectTimeoutMilliseconds)
    }

    public func waitUntilListening(
        endpoint: SocksEndpoint,
        timeoutNanoseconds: UInt64 = 15_000_000_000,
        pollIntervalNanoseconds: UInt64 = 200_000_000
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds

        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await isListening(endpoint: endpoint) {
                return true
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }

        return await isListening(endpoint: endpoint)
    }

    private static func canConnect(to endpoint: SocksEndpoint, timeoutMilliseconds: Int32) -> Bool {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(endpoint.host, String(endpoint.port), &hints, &result)
        guard status == 0, let result else {
            return false
        }
        defer { freeaddrinfo(result) }

        var address: UnsafeMutablePointer<addrinfo>? = result
        while let current = address {
            let descriptor = socket(current.pointee.ai_family, current.pointee.ai_socktype, current.pointee.ai_protocol)
            if descriptor >= 0 {
                defer { close(descriptor) }

                let flags = fcntl(descriptor, F_GETFL, 0)
                _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)

                let connectResult = Darwin.connect(
                    descriptor,
                    current.pointee.ai_addr,
                    current.pointee.ai_addrlen
                )

                if connectResult == 0 {
                    return true
                }

                if errno == EINPROGRESS {
                    var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                    let pollResult = poll(&pollDescriptor, 1, timeoutMilliseconds)
                    if pollResult > 0 {
                        var socketError: Int32 = 0
                        var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
                        let optionResult = getsockopt(
                            descriptor,
                            SOL_SOCKET,
                            SO_ERROR,
                            &socketError,
                            &socketErrorLength
                        )
                        if optionResult == 0, socketError == 0 {
                            return true
                        }
                    }
                }
            }

            address = current.pointee.ai_next
        }

        return false
    }
}
