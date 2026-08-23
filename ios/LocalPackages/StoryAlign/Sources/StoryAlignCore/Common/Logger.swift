//
// Logger.swift
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Rich Waters
//

import Foundation

public enum LogLevel: String , OrderedCaseIterable, Codable, Sendable {
    case debug
    case info
    case timestamp
    case warn
    case error

    public static let orderedCases: [LogLevel] = [.debug, .info, .timestamp, .warn, .error]
}


public protocol Logger : Sendable {
    func log(_ level: LogLevel, _ message: @autoclosure () -> String, file: String, function: String , line: Int , indentLevel: Int)
}


public extension Logger {
    // Keep this signature different than the protocol sig, otherwise it defeats the purpose of the protocol. IndentLevel is in a diff position
    func log(_ level: LogLevel = .info, _ message: @autoclosure () -> String, indentLevel: Int = 0, file: String = #file, function: String = #function, line: Int = #line ) {
        self.log(level, message(), file: file, function: function, line: line, indentLevel: indentLevel)
    }
    
    func formattedTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }

    func fileName(from path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}


public struct NullLogger:Logger, Sendable{
    public init() {}
    public func log(_ level: LogLevel, _ message: @autoclosure () -> String, file: String, function: String, line: Int, indentLevel: Int) {
    }
}

public struct StderrLogger: Logger, Sendable {
    public let minimumLevel: LogLevel

    public init(minimumLevel: LogLevel = .info, isEnabled: Bool = true) {
        self.minimumLevel = minimumLevel
    }

    public func log(
        _ level: LogLevel = .info,
        _ message: @autoclosure () -> String,
        file: String = #file,
        function: String = #function,
        line: Int = #line,
        indentLevel: Int = 0
    ) {
        guard level >= minimumLevel else { return }
        let indent = String(repeating: " ", count: indentLevel * 2)
        let msg = "\(indent)[\(level.rawValue.uppercased())] \(message())\n"
        FileHandle.standardError.write(msg.data(using: .utf8) ?? Data())
    }
}
