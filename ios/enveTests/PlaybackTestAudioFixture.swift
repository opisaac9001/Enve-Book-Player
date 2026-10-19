import Foundation

enum PlaybackTestAudioFixture {
    static func wave(seconds: Int) -> Data {
        let sampleRate: UInt32 = 8000
        let length = UInt32(seconds) * sampleRate * 2
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var encoded = value.littleEndian
            withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8); append(length + 36)
        data.append(contentsOf: "WAVEfmt ".utf8); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)); append(sampleRate)
        append(sampleRate * 2); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: "data".utf8); append(length)
        data.append(Data(repeating: 0, count: Int(length)))
        return data
    }
}
