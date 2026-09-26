import Foundation

/// Moonshine Small Streaming English, from Moonshine 0.1.5's native dependency manifest. The
/// versioned CDN path and SHA-256 hashes are pinned so a changed or truncated file is never loaded.
enum MoonshineModel {
    private static let base = "https://download.moonshine.ai/model/small-streaming-en/quantized_26_08_21/"
    static let manifest = ModelManifest(id: "moonshine-small-streaming-en", files: [
        file("adapter.ort", "c665f742364febad597cc9ac1e0b341ffbee0e24a1466e2f3bde95e6e4771762"),
        file("cross_kv.ort", "e2d3417144e9514055ebfefe8dcc4c0a55a55adcb8530435844c75c53e352bf6"),
        file("decoder_kv.ort", "1a05465b1dd955858dfcbee039c0020fb5dd982b0f5094c34e61735d518d771b"),
        file("encoder.ort", "2d4d973e91e8aca08c51e7e7efa28a46ab265b63d809d5294d18b86bcd85b993"),
        file("frontend.model.ort", "09b1210ae30dc5f0f3e45f0ebab914c254741323114f53fbbe5ae62cca35058f"),
        file("frontend.weights.ort", "7ef97521bd4bad3928f5bb6808586f4fcc6e92bd5990394112eed7d4052ec338"),
        file("streaming_config.json", "26f02b6afb22d60871a5efd85c3d38e569cc0ddb6c5eb6e93d3260152ae8a47a"),
        file("tokenizer.bin", "6884b35fd6377d4c4d32336a0bc152f36b64d1e45b6503683cdc238250a8472d"),
    ])

    private static func file(_ name: String, _ hash: String) -> ModelManifest.File {
        .init(name: name, url: URL(string: base + name)!, sha256: hash)
    }
}
