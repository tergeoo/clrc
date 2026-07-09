//
//  PrivilegedInstall.swift
//  Clrc
//
//  Copies the bundled universal binaries into /usr/local/bin and writes the
//  relay launchd plist. The binary copy needs one admin prompt.
//

import Foundation
import ClrcInstallerCore

enum InstallError: LocalizedError {
    case bundledBinaryMissing(String)
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .bundledBinaryMissing(let n): return "Bundled binary '\(n)' is missing from the app."
        case .copyFailed(let msg): return msg
        }
    }
}

enum PrivilegedInstall {
    static let relayLabel = "xyz.clrc.relay"
    static var relayPlistPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(relayLabel).plist"
    }

    /// Copy bundled `clrc` (+ optionally `claude-relay`) to /usr/local/bin with one
    /// administrator prompt. `includeRelay` is true only for the hub role.
    static func installBinaries(includeRelay: Bool) throws {
        var names = ["clrc"]
        if includeRelay { names.append("claude-relay") }

        var cmds = ["mkdir -p /usr/local/bin"]
        for name in names {
            guard let src = Bundle.main.url(forResource: name, withExtension: nil) else {
                throw InstallError.bundledBinaryMissing(name)
            }
            cmds.append("cp '\(src.path)' /usr/local/bin/\(name)")
            cmds.append("chmod 755 /usr/local/bin/\(name)")
        }
        let shell = cmds.joined(separator: " && ")
        // AppleScript admin prompt. The shell string is composed only from
        // app-bundle paths and fixed literals — no user input flows in.
        let script = "do shell script \"\(shell.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw InstallError.copyFailed(msg.isEmpty ? "binary install failed" : msg)
        }
    }

    /// Write the relay launchd plist with secrets embedded as EnvironmentVariables
    /// (matches the project's existing launchd convention). Mode 0600.
    static func writeRelayPlist(secrets: HubSecrets, port: Int, files: FileWriter) throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(relayLabel)</string>
          <key>ProgramArguments</key>
          <array><string>/usr/local/bin/claude-relay</string></array>
          <key>EnvironmentVariables</key>
          <dict>
            <key>JWT_SECRET</key><string>\(secrets.jwtSecret)</string>
            <key>ADMIN_PASSWORD</key><string>\(secrets.adminPassword)</string>
            <key>AGENT_SECRET</key><string>\(secrets.agentSecret)</string>
            <key>PORT</key><string>\(port)</string>
          </dict>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><true/>
          <key>StandardOutPath</key><string>/tmp/claude-relay.log</string>
          <key>StandardErrorPath</key><string>/tmp/claude-relay.log</string>
        </dict>
        </plist>
        """
        try files.write(relayPlistPath, plist, mode: 0o600)
    }
}
