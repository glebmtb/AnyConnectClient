import Darwin
import Foundation

public struct OcproxyScriptWrapper: Sendable {
    public let executablePath: String

    private let pidFilePath: String
    let routeImportFilePath: String
    private let directoryPath: String

    public static func install(realExecutablePath: String) throws -> OcproxyScriptWrapper {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnyConnectClient-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let script = directory.appendingPathComponent("ocproxy-wrapper")
        let pidFile = directory.appendingPathComponent("ocproxy.pid")
        let routeImportFile = directory.appendingPathComponent("route-import.env")
        let content = """
        #!/bin/sh
        echo "$$" > \(shellQuote(pidFile.path))
        route_import_tmp=\(shellQuote(routeImportFile.path + ".tmp"))".$$"
        (
            capture_value() {
                name="$1"
                eval "value=\\${$name-}"
                if [ -n "$value" ]; then
                    printf '%s=%s\\n' "$name" "$value"
                fi
            }

            capture_route_prefix() {
                prefix="$1"
                eval "count=\\${$prefix-}"
                case "$count" in
                    ''|*[!0-9]*) count=0 ;;
                esac
                if [ "$count" -gt 0 ]; then
                    printf '%s=%s\\n' "$prefix" "$count"
                fi

                i=0
                while [ "$i" -lt "$count" ]; do
                    capture_value "${prefix}_${i}_ADDR"
                    capture_value "${prefix}_${i}_MASK"
                    capture_value "${prefix}_${i}_MASKLEN"
                    capture_value "${prefix}_${i}_PROTOCOL"
                    capture_value "${prefix}_${i}_SPORT"
                    capture_value "${prefix}_${i}_DPORT"
                    i=$((i + 1))
                done
            }

            capture_route_prefix CISCO_SPLIT_INC
            capture_route_prefix CISCO_SPLIT_EXC
            capture_route_prefix CISCO_IPV6_SPLIT_INC
            capture_route_prefix CISCO_IPV6_SPLIT_EXC
        ) > "$route_import_tmp" 2>/dev/null
        /bin/mv "$route_import_tmp" \(shellQuote(routeImportFile.path))
        exec \(shellQuote(realExecutablePath)) "$@"
        """

        try content.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        return OcproxyScriptWrapper(
            executablePath: script.path,
            pidFilePath: pidFile.path,
            routeImportFilePath: routeImportFile.path,
            directoryPath: directory.path
        )
    }

    public func runtimePaths(from runtimePaths: RuntimePaths) -> RuntimePaths {
        RuntimePaths(
            openConnectExecutablePath: runtimePaths.openConnectExecutablePath,
            ocproxyExecutablePath: executablePath
        )
    }

    public func processIdentifier() -> pid_t? {
        readProcessIdentifier()
    }

    public func routeImportSnapshot() -> RouteImportSnapshot {
        guard let content = try? String(contentsOfFile: routeImportFilePath, encoding: .utf8) else {
            return RouteImportSnapshot()
        }
        return RouteImportParser().parse(content)
    }

    public func stop(gracePeriodNanoseconds: UInt64) async {
        if let processIdentifier = readProcessIdentifier(), processExists(processIdentifier) {
            Darwin.kill(processIdentifier, SIGTERM)
            try? await Task.sleep(nanoseconds: gracePeriodNanoseconds)

            if processExists(processIdentifier) {
                Darwin.kill(processIdentifier, SIGKILL)
            }
        }

        try? FileManager.default.removeItem(atPath: directoryPath)
    }

    private func readProcessIdentifier() -> pid_t? {
        guard let content = try? String(contentsOfFile: pidFilePath, encoding: .utf8),
              let processIdentifier = pid_t(content.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return nil
        }
        return processIdentifier
    }

    private func processExists(_ processIdentifier: pid_t) -> Bool {
        Darwin.kill(processIdentifier, 0) == 0
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
