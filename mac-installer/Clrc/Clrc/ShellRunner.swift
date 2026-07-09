//
//  ShellRunner.swift
//  Clrc
//
//  Concrete CommandRunner backed by Process. Args-array only — never sh -c.
//

import Foundation
import ClrcInstallerCore

struct ShellRunner: CommandRunner {
    func run(_ tool: String, _ args: [String], stdin: String?) async throws -> CommandResult {
        let path = Self.resolve(tool)
        return try await withCheckedThrowingContinuation { cont in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = args
            let out = Pipe()
            let err = Pipe()
            proc.standardOutput = out
            proc.standardError = err
            if let stdin {
                let inPipe = Pipe()
                proc.standardInput = inPipe
                inPipe.fileHandleForWriting.write(Data(stdin.utf8))
                inPipe.fileHandleForWriting.closeFile()
            }
            proc.terminationHandler = { p in
                let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                cont.resume(returning: CommandResult(exitCode: p.terminationStatus, stdout: o, stderr: e))
            }
            do {
                try proc.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    /// Resolve a bare tool name to an absolute path. Process requires an absolute
    /// executableURL, so bare names like "tailscale" must be located on disk.
    static func resolve(_ tool: String) -> String {
        if tool.hasPrefix("/") { return tool }
        var candidates: [String] = []
        for base in ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/", "/bin/"] {
            candidates.append(base + tool)
        }
        if tool == "tailscale" {
            // Standalone / App Store Tailscale ships its CLI inside the app bundle.
            candidates.append("/Applications/Tailscale.app/Contents/MacOS/Tailscale")
        }
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        // Fall back to the first homebrew guess; the resulting error will be clear.
        return candidates.first ?? tool
    }
}
