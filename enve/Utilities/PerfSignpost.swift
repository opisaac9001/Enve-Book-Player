import Foundation
import os

enum PerfSignpost {
    static let log = OSLog(subsystem: "com.enve.perf", category: .pointsOfInterest)
    private static let signposter = OSSignposter(logHandle: log)

    struct Handle {
        let state: OSSignpostIntervalState
        let name: StaticString
    }

    static func begin(_ name: StaticString, _ message: String = "") -> Handle {
        let id = signposter.makeSignpostID()
        let state: OSSignpostIntervalState
        if message.isEmpty {
            state = signposter.beginInterval(name, id: id)
        } else {
            state = signposter.beginInterval(name, id: id, "\(message)")
        }
        return Handle(state: state, name: name)
    }

    static func end(_ handle: Handle) {
        signposter.endInterval(handle.name, handle.state)
    }

    static func measure<T>(_ name: StaticString, _ message: String = "", _ body: () async throws -> T) async rethrows -> T {
        let handle = begin(name, message)
        defer { end(handle) }
        return try await body()
    }

    static func event(_ name: StaticString, _ message: String = "") {
        if message.isEmpty {
            signposter.emitEvent(name)
        } else {
            signposter.emitEvent(name, "\(message)")
        }
    }

    static func residentMemoryMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Int(info.phys_footprint / (1024 * 1024))
    }
}
