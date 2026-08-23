//
//  FFAudioLoader.swift
//  StoryAlign
//
//  Created by Rich Waters on 4/26/25.
//


import Foundation

#if os(macOS) || os(Linux)

struct FfAudioLoader : AudioLoader {
    let session: AlignmentSession

    func decode(from fileURL: URL) async throws -> [Float] {
        let audioData = try await FfMpegger(session: session).run(withArguments: [
            "-i", fileURL.path,
            "-f", "f32le",
            "-acodec", "pcm_f32le",
            "-ac", "\(AudioLoaderPCM.channels)",
            "-ar", "\(Int(AudioLoaderPCM.sampleRate))",
            "-"
        ])

        let sampleCount = audioData.count / MemoryLayout<Float>.size
        let floats: [Float] = audioData.withUnsafeBytes { rawBuffer in
            let floatBuffer = rawBuffer.bindMemory(to: Float.self)
            return Array(floatBuffer.prefix(sampleCount))
        }
        
        return floats
    }
    
    
    
    func extractAudio( from url:URL, using audioFileInfo:AudioFile ) async throws  {
        if url.pathExtension == "mp3" {
            try FileManager.default.copyItem(at: url, to: audioFileInfo.filePath)
            return
        }

        let args = [
            "-vn",
            "-ss",
            "\(audioFileInfo.startTmeInterval)",
            "-to",
            "\(audioFileInfo.endTmeInterval)",
            "-i",
            url.path(),
            "-c:a",
            "copy",
            audioFileInfo.filePath.path()
        ]
        
        try await FfMpegger(session: session).run(withArguments: args)
        return
    }
    
    func getTrackInfo( from url:URL ) async throws -> FfmpegTrackInfo {
        let ffTrackInfo:FfmpegTrackInfo = try await FfProber().run(withArguments: [
            "-i",
            url.absoluteString,
            "-show_format",
            "-of",
            "json",
            "-select_streams",
            "a:0",
            "-show_entries",
            "stream=codec_name"
        ])
        return ffTrackInfo
    }
    
    func getChapters( from url:URL ) async throws -> [ChapterInfo] {
        

        if url.pathExtension == "mp3" {
            let bookInfo = try await getTrackInfo(from: url)
            let title = bookInfo.format.tags?.title ?? url.lastPathComponent
            let duration = Double( bookInfo.format.duration ?? "0.0" ) ?? 0.0
            guard duration.isFinite && duration > 0 else {
                logger.log( .warn, "Cannot process mp3 \(title): No duration.")
                return []
            }
            let start = Double( bookInfo.format.startTime ?? "0.0" ) ?? 0.0
            let chapter = ChapterInfo( start: start, end: duration , title: title  )
            return [chapter]
        }

        let ffChapters:FfmpegChapters = try await FfProber().run(withArguments: [
            "-i",
            url.absoluteString,
            "-show_chapters",
            "-of",
            "json"
        ])
        let chapters = ffChapters.chapters.map {
            return ChapterInfo(start: Double($0.startTime) ?? 0 , end: Double($0.endTime) ?? 0, title:$0.tags?.title  )
        }
        return chapters
    }
    
    func loadAudio(url: URL) throws -> Data {
        return try Data(contentsOf: url)
    }
    
    func outputPathExtension(from url: URL) async throws -> String {
        if url.pathExtension == "mp3" {
            return url.pathExtension
        }
        let bookInfo = try await getTrackInfo(from: url)
        let codec = bookInfo.streams?.first?.codecName ?? "mp4"
        let pathExtension = AudioCodecsToExtensions.pathExtension(forCodec: codec) ?? "mp4"
        return pathExtension
    }
}


struct FfChapterInfo: Codable {
    let id: Int?
    let timeBase: String?
    let start: TimeInterval?
    let startTime: String
    let end: TimeInterval?
    let endTime: String
    let tags: Tags?

    enum CodingKeys: String, CodingKey {
        case id
        case timeBase = "time_base"
        case start
        case startTime = "start_time"
        case end
        case endTime = "end_time"
        case tags
    }

    struct Tags: Codable {
        let title: String?
    }
}

struct FfAudioBookStream: Decodable {
    let codecName: String?
    
    enum CodingKeys: String, CodingKey {
        case codecName = "codec_name"
    }
}

struct FfAudioBookInfo: Codable {
    let filename: String?
    let nbStreams: Int?
    let nbPrograms: Int?
    let formatName: String?
    let formatLongName: String?
    let startTime: String?
    let duration: String?
    let size: String?
    let bitRate: String?
    let probeScore: Int?
    let tags: FfTags?
    
    enum CodingKeys: String, CodingKey {
        case filename
        case nbStreams = "nb_streams"
        case nbPrograms = "nb_programs"
        case formatName = "format_name"
        case formatLongName = "format_long_name"
        case startTime = "start_time"
        case duration
        case size
        case bitRate = "bit_rate"
        case probeScore = "probe_score"
        case tags
    }
}

struct FfTags: Codable {
    let majorBrand: String?
    let minorVersion: String?
    let compatibleBrands: String?
    let title: String?
    let track: String?
    let album: String?
    let genre: String?
    let artist: String?
    let encoder: String?
    let mediaType: String?
    
    enum CodingKeys: String, CodingKey {
        case majorBrand = "major_brand"
        case minorVersion = "minor_version"
        case compatibleBrands = "compatible_brands"
        case title
        case track
        case album
        case genre
        case artist
        case encoder
        case mediaType = "media_type"
    }
}




////////////////////////////////////////
// MARK: FfProber
//

struct FfmpegTrackInfo: Decodable {
    let format: FfAudioBookInfo
    let streams:[FfAudioBookStream]?
}
struct FfmpegChapters: Decodable {
    let chapters: [FfChapterInfo]
}

struct FfProber {
    func run<T:Decodable>( withArguments args:[String] ) async throws -> T {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let logArgs = ["-loglevel", "quiet"]
        process.arguments = ["ffprobe"] + logArgs + args
        
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        
        try process.run()
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                }
                else {
                    var reason = "ffprobe terminated with a non-zero status"
                    if process.terminationStatus == 127 {
                        reason = "Command ffprob not found"
                    }
                    continuation.resume(throwing: NSError(domain: "runFfProbe",
                                                          code: Int(proc.terminationStatus),
                                                          userInfo: [NSLocalizedDescriptionKey: reason] ) )
                }
            }
        }
        
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let json = try JSONDecoder().decode(T.self, from: data)
        return json as T
    }


}

struct FfMpegger {
    let session:AlignmentSession
    var logger:Logger { session.logger }
    
    @discardableResult func run( withArguments args:[String] ) async throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        
        let logArgs = ["-loglevel", "quiet", "-hide_banner" ]
        let noStdinArgs = ["-y", "-nostdin"]
        process.arguments = ["ffmpeg"] + noStdinArgs + logArgs + args
        
        logger.log( .debug,  "Running: \(process.arguments!.joined(separator: " "))" )

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        let handle = outputPipe.fileHandleForReading
        try process.run()
        var fullData = Data()
        let bufferSize = 16*1024
        
        while process.isRunning {
            let chunk = handle.readData(ofLength: bufferSize)
            if chunk.isEmpty { break }
            fullData.append(chunk)
        }
        let remaining = handle.readDataToEndOfFile()
        fullData.append(remaining)

        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw StoryAlignError( "Error using FFMPEG to decode audio: \(process.terminationStatus)")
        }
        
        return fullData
    }

}

#else
struct FfAudioLoader : AudioLoader {
    let session: AlignmentSession
    
    func decode(from fileURL: URL) async throws -> [Float] {
        throw( StoryAlignError("FFmpeg not available") )
    }
    
    func getChapters(from url: URL) async throws -> [ChapterInfo] {
        throw( StoryAlignError("FFmpeg not available") )

    }
    
    func extractAudio(from url: URL, using audioFileInfo: AudioFile) async throws {
        throw( StoryAlignError("FFmpeg not available") )
    }
    
    func outputPathExtension(from url: URL) async throws -> String {
        throw( StoryAlignError("FFmpeg not available") )

    }

}

#endif
