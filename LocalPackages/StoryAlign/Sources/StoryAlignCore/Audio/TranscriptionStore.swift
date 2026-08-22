//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Rich Waters
//

import Foundation

public struct TranscriptionStoreContext {
    public let audioFileName: String
    public let audioFileIndex:Int
    public let pcmSamplesHash:String
    public let transcriberId:String
    public let transcriberConfigHash:String
}


public protocol TranscriptionStore : Sendable {
    func store(data: Data, key: String, context: TranscriptionStoreContext) async throws
    func fetch(key: String, context: TranscriptionStoreContext ) async throws -> Data?
}


extension TranscriptionStore {
    func buildKey( from context:TranscriptionStoreContext ) -> String {
        let key = "v1::\(context.pcmSamplesHash)::transcriberId:\(context.transcriberId)::options:\(context.transcriberConfigHash)"
        return key.sha256
    }
    
    func fetch( using context:TranscriptionStoreContext ) async throws -> RawTranscription? {
        let key = self.buildKey(from: context)
        guard let transcriptionData = try await self.fetch(key:key, context: context) else {
            return nil
        }
        let jsonData = try transcriptionData.gunzipped()
        let rawTranscription = try JSONDecoder().decode(RawTranscription.self, from: jsonData)
        return rawTranscription
    }
    
    func store( rawTranscription:RawTranscription, using context:TranscriptionStoreContext) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(rawTranscription).gzipped()
        let key = buildKey(from: context)
        try await self.store(data: data, key: key, context: context)
    }
}
