import Foundation
import StoryAlignCore

@main
struct CTCAlignCommand {
    static func main() async throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--benchmark", arguments.count == 4 {
            let result = try await QuartzNetBenchmark.run(pcmURL: URL(fileURLWithPath: arguments[1]), modelDirectory: URL(fileURLWithPath: arguments[2]), outputDirectory: URL(fileURLWithPath: arguments[3], isDirectory: true))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            FileHandle.standardOutput.write(try encoder.encode(result))
            FileHandle.standardOutput.write(Data("\n".utf8))
            return
        }
        var provider: QuartzNetExecutionProvider?
        var overlap = 8.0
        var position = 0
        while position < arguments.count {
            let option = arguments[position]
            if option == "--provider" || option == "--overlap" {
                guard position + 1 < arguments.count else { throw argumentError("Missing value for \(option).") }
                let value = arguments[position + 1]
                if option == "--provider" {
                    guard let selected = QuartzNetExecutionProvider(rawValue: value) else { throw argumentError("Unknown execution provider: \(value).") }
                    provider = selected
                } else {
                    guard let selected = Double(value) else { throw argumentError("Invalid overlap duration.") }
                    overlap = selected
                }
                arguments.removeSubrange(position...(position + 1))
            } else {
                position += 1
            }
        }
        guard arguments.count == 4 || arguments.count == 6 else {
            FileHandle.standardError.write(Data("Usage: ctc-align EPUB AUDIO MODEL_DIRECTORY SESSION_DIRECTORY [PROBE_START PROBE_DURATION] [--provider cpu|xnnpack|coreMLAll|coreMLNeuralEngine] [--overlap SECONDS]\n       ctc-align --benchmark PCM MODEL_DIRECTORY OUTPUT_DIRECTORY\n".utf8))
            exit(2)
        }
        let epub = URL(fileURLWithPath: arguments[0])
        let audio = URL(fileURLWithPath: arguments[1])
        let models = URL(fileURLWithPath: arguments[2])
        let sessionDirectory = URL(fileURLWithPath: arguments[3], isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        if arguments.count == 6 {
            guard let start = Double(arguments[4]), let duration = Double(arguments[5]) else {
                throw argumentError("Invalid probe position or duration")
            }
            let result = try await StoryAligner().probeCTC(epubURL: epub, audioURL: audio, modelDirectory: models, sessionDirectory: sessionDirectory, start: start, duration: duration, executionProvider: provider)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            FileHandle.standardOutput.write(try encoder.encode(result))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } else {
            let request = try AlignmentRequest(epubURL: epub, audioBookURLs: [audio], sessionDir: sessionDirectory.path)
            let session = AlignmentSession(request: request, config: AlignmentConfig(concurrency: 1))
            let result = try await StoryAligner().alignStory(session: session, ctcConfiguration: CTCAlignmentConfiguration(modelDirectory: models, overlapDuration: overlap, executionProvider: provider))
            print(result.alignedEpubURL.path)
        }
    }

    private static func argumentError(_ message: String) -> NSError {
        NSError(domain: "CTCAlign", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }

}
