//
// AudioLoader.swift
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Rich Waters
//

import Foundation

public enum AudioLoaderType: String, Codable, CaseIterable,Sendable {
    case avfoundation
    case ffmpeg
}

enum AudioLoaderPCM {
    static let sampleRate: Double = 16_000
    static let channels: Int = 1
}

protocol AudioLoader : AlignmentSessionProviding , Sendable {
    func decode( from fileURL: URL ) async throws -> [Float]
    func getChapters( from url:URL ) async throws -> [ChapterInfo]
    func extractAudio( from url:URL, using audioFileInfo:AudioFile ) async throws
    func outputPathExtension( from url:URL) async throws -> String
}

struct AudioLoaderFactory {
    static func audioLoader( for session:AlignmentSession ) -> AudioLoader {
        switch session.config.audioLoaderType {
            case .ffmpeg:
                return FfAudioLoader(session:session)
            case .avfoundation:
                return AvAudioLoader(session: session)
        }
    }
}
