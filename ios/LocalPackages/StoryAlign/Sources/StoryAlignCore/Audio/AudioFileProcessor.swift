//
//  AudioFileProcessor.swift
//  StoryAlign
//
//  Created by Rich Waters on 2/16/26.
//

import Foundation

public struct AudioFileProcessor : AlignmentSessionProviding, Sendable {
    public static let supportedExtensions = ["m4b", "mp4", "mp3" ]

    public let session: AlignmentSession
    public init(session: AlignmentSession) {
        self.session = session
    }
    
    public func process( audioURLs:[URL], epub:EpubDocument ) async throws -> AudioBook {
        try Task.checkCancellation()
        
        guard audioURLs.count > 0 else {
            throw StoryAlignError( "No audio files to process")
        }
        
        var tmpDir:URL? = nil

        let audioURLs = try {
            guard audioURLs[0].pathExtension == "zip" else {
                return audioURLs
            }
            tmpDir = session.request.sessionDir.appendingPathComponent(audioURLs[0].lastPathComponent)
            try FileManager.default.unzipItem(at: audioURLs[0], to: tmpDir!, overwrite: true)
            let files = try FileManager.default.contentsOfDirectory(at:tmpDir!, includingPropertiesForKeys: nil)
                .filter { Self.supportedExtensions.contains($0.pathExtension) }
                .sorted {
                    $0.lastPathComponent.compare($1.lastPathComponent, options: [.numeric]) == .orderedAscending
                }
            return files
        }()
        
        let audioLoader = AudioLoaderFactory.audioLoader(for:session)

        let rootPath = epub.opfURL.deletingLastPathComponent()
        let dstDirName = "\(AssetPaths.audio)"
        let dstDirPath = rootPath.appending(component: dstDirName)
        
        
        try? FileManager.default.removeItem(at: dstDirPath)
        try FileManager.default.createDirectory(at: dstDirPath, withIntermediateDirectories: true )
        
        
        let audioUrlChapters = try await audioURLs.asyncCompactMap { url in
            let chapters = try await audioLoader.getChapters(from: url)
            let pathExtension = try await audioLoader.outputPathExtension(from: url)
            return (url, chapters, pathExtension)
        }

        var startIndex = 0
        let audioUrlFiles = audioUrlChapters.map { (url, chapters, pathExtension) in
            let audioFiles = chapters.enumerated().map { (index,chapter) in
                let fileName = String(format: "%05d-%05d.\(pathExtension)", 0, startIndex + index + 1)
                let filePath = dstDirPath.appending(component: fileName)
                let audioFile = AudioFile( startTmeInterval: chapter.start, endTmeInterval: chapter.end, filePath: filePath, index:startIndex + index)
                return audioFile
            }
            startIndex += audioFiles.count
            return( url, audioFiles )
        }
            
        let totalFiles = audioUrlFiles.reduce(0) { $0 + $1.1.count }
        progressTracker.updateProgress(for: .audio, event: .start, total: totalFiles)
        
        let nThreads = sessionConfig.concurrency
        let extractedAudioUrlFiles = try await audioUrlFiles.asyncMap( concurrency: nThreads ) { (url,audioFiles) in
            let extractedAudioFiles = try await audioFiles.asyncMap { audioFile in
                try Task.checkCancellation()

                try await audioLoader.extractAudio(from: url, using: audioFile)
                progressTracker.updateProgress(for: .audio, increment: 1, item:audioFile.filePath.lastPathComponent)
                return audioFile
            }
            return (url, extractedAudioFiles)
        }
        let allAudioFiles = extractedAudioUrlFiles.flatMap { $0.1 }
        
        if let tmpDir {
            try FileManager.default.removeItem(at: tmpDir)
        }
        progressTracker.updateProgress(for: .audio, event: .end)
        
        
        return AudioBook( audioFiles: allAudioFiles )
    }
}

struct AudioCodecsToExtensions {
    static let codecsToExtensions: [String: String] = [
        "aac": "m4a",
        "alac": "m4a",
        "mp3": "mp3",
        "mp4": "mp4",
        "opus": "opus",
        "flac": "flac",
        "vorbis": "ogg",
        "pcm_s16le": "wav",
        "pcm_s24le": "wav",
        "pcm_f32le": "wav"
    ]
    
    static func pathExtension( forCodec: String ) -> String? {
        return codecsToExtensions[forCodec]
    }
}
