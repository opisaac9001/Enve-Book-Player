import Foundation

enum CTCDecodeAhead {
    static func forEach<Input: Sendable, Output: Sendable>(inputs: [Input], load: @escaping @Sendable (Input) async throws -> Output, consume: (Input, Output) async throws -> Void) async throws {
        guard let first = inputs.first else { return }
        try await withThrowingTaskGroup(of: Output.self) { group in
            group.addTask { try await load(first) }
            for index in inputs.indices {
                try Task.checkCancellation()
                guard let output = try await group.next() else { return }
                try Task.checkCancellation()
                if index + 1 < inputs.count {
                    let next = inputs[index + 1]
                    group.addTask { try await load(next) }
                }
                try await consume(inputs[index], output)
            }
        }
    }
}
