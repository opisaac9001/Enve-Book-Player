//
// SafeDispatchQueue.swift
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Rich Waters

import Foundation

final class SafeDispatchQueue {
    let queue: DispatchQueue
    private let key = DispatchSpecificKey<Void>()

    init(label: String, qos: DispatchQoS = .unspecified) {
        self.queue = DispatchQueue(label: label, qos: qos)
        self.queue.setSpecific(key: key, value: ())
    }

    func async(_ block: @escaping @Sendable () -> Void) {
        queue.async(execute: block)
    }

    func sync<T>(_ block:@Sendable () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: key) != nil {
            return try block()
        }
        return try queue.sync(execute: block)
    }
}
