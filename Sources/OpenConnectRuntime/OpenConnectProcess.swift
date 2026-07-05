@preconcurrency import Foundation
import Darwin
import VPNCore

public actor OpenConnectProcess {
    private var currentProcess: Process?

    public init() {}

    public var isRunning: Bool {
        currentProcess?.isRunning == true
    }

    public func processIdentifier() -> Int32? {
        currentProcess?.processIdentifier
    }

    public func start(
        invocation: CommandInvocation,
        standardInput: String? = nil,
        redactor: Redactor = .default,
        parser: OpenConnectLogParser = OpenConnectLogParser()
    ) throws -> AsyncStream<OpenConnectProcessEvent> {
        if let currentProcess, currentProcess.isRunning {
            throw OpenConnectProcessError.alreadyRunning
        }

        guard FileManager.default.isExecutableFile(atPath: invocation.executablePath) else {
            throw OpenConnectProcessError.executableNotFound(invocation.executablePath)
        }

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: invocation.executablePath)
        process.arguments = invocation.arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = inputPipe

        let streamPair = AsyncStream<OpenConnectProcessEvent>.makeStream()
        let stream = streamPair.stream
        let continuation = streamPair.continuation

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            Self.emitAvailableData(
                from: handle,
                stream: .standardOutput,
                redactor: redactor,
                parser: parser,
                continuation: continuation
            )
        }

        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            Self.emitAvailableData(
                from: handle,
                stream: .standardError,
                redactor: redactor,
                parser: parser,
                continuation: continuation
            )
        }

        process.terminationHandler = { terminatedProcess in
            Self.emitAvailableData(
                from: outputPipe.fileHandleForReading,
                stream: .standardOutput,
                redactor: redactor,
                parser: parser,
                continuation: continuation
            )
            Self.emitAvailableData(
                from: errorPipe.fileHandleForReading,
                stream: .standardError,
                redactor: redactor,
                parser: parser,
                continuation: continuation
            )
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            continuation.yield(.exited(status: terminatedProcess.terminationStatus))
            continuation.finish()
            Task { await self.clearIfCurrent(processIdentifier: terminatedProcess.processIdentifier) }
        }

        continuation.onTermination = { @Sendable _ in
            Task { await self.stop() }
        }

        do {
            try process.run()
        } catch {
            throw OpenConnectProcessError.launchFailed(error.localizedDescription)
        }

        currentProcess = process
        continuation.yield(.started(processIdentifier: process.processIdentifier))

        if let standardInput {
            let input = standardInput.hasSuffix("\n") ? standardInput : standardInput + "\n"
            inputPipe.fileHandleForWriting.write(Data(input.utf8))
        }
        try? inputPipe.fileHandleForWriting.close()

        return stream
    }

    public func stop(gracePeriodNanoseconds: UInt64 = 2_000_000_000) async {
        guard let process = currentProcess else {
            return
        }

        if process.isRunning {
            process.terminate()
            try? await Task.sleep(nanoseconds: gracePeriodNanoseconds)

            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }

        currentProcess = nil
    }

    public func cancel() async {
        await stop()
    }

    private func clearIfCurrent(processIdentifier: Int32) {
        guard currentProcess?.processIdentifier == processIdentifier else {
            return
        }
        currentProcess = nil
    }

    private static func emitAvailableData(
        from handle: FileHandle,
        stream: ProcessOutputStream,
        redactor: Redactor,
        parser: OpenConnectLogParser,
        continuation: AsyncStream<OpenConnectProcessEvent>.Continuation
    ) {
        let data = handle.availableData
        guard !data.isEmpty else {
            return
        }
        emit(
            data,
            stream: stream,
            redactor: redactor,
            parser: parser,
            continuation: continuation
        )
    }

    private static func emit(
        _ data: Data,
        stream: ProcessOutputStream,
        redactor: Redactor,
        parser: OpenConnectLogParser,
        continuation: AsyncStream<OpenConnectProcessEvent>.Continuation
    ) {
        let text = String(decoding: data, as: UTF8.self)
        for pin in ServerCertificatePinParser().pins(in: text) {
            continuation.yield(.serverCertificatePinSuggested(pin))
        }

        let redactedText = redactor.redact(text)
        continuation.yield(.output(stream: stream, text: redactedText))

        for line in redactedText.split(whereSeparator: \.isNewline) {
            if let state = parser.parseLine(String(line)) {
                continuation.yield(.stateChanged(state))
            }
        }
    }
}
