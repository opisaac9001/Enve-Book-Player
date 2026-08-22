//
// StoryAlignError.swift
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Rich Waters

import Foundation


struct StoryAlignError: Error, CustomStringConvertible {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var description: String { message }
}
