# Downloadable model provenance

Enve offers downloads but does not bundle these weights in the APK or app bundle. Download URLs are revision-pinned, and the app verifies the completed file's SHA-256 digest before installation.

## Qwen3 0.6B LiteRT-LM

- Model repository: https://huggingface.co/litert-community/Qwen3-0.6B
- Repository revision: `8414150f2e9dcc82449bcc9c5abc404b399a4d06`
- File: `Qwen3-0.6B.litertlm`
- Size: `614236160` bytes
- SHA-256: `555579ff2f4fd13379abe69c1c3ab5200f7338bc92471557f1d6614a6e5ab0b4`
- Base model: https://huggingface.co/Qwen/Qwen3-0.6B
- License: Apache-2.0, retained in `BuildSupport/Licenses/Apache-2.0.txt`

## Whisper tiny.en

- Model repository: https://huggingface.co/ggerganov/whisper.cpp
- Repository revision: `5359861c739e955e79d9a303bcbc70fb988958b1`
- File: `ggml-tiny.en.bin`
- Size: `77704715` bytes
- SHA-256: `921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f`
- License: MIT, retained with the vendored whisper.cpp license

## Reader narration

The Android reader downloads quantized models from the [sherpa-onnx TTS model release](https://github.com/k2-fsa/sherpa-onnx/releases/tag/tts-models). The pack manifest in `engine/src/main/java/com/enve/app/readium/narrator/NarratorPack.kt` pins the exact byte length and SHA-256 of each archive, each retained archive member, and each separately downloaded asset. The app rejects substituted files even if the upstream release tag moves.

| Pack | Upstream model | Supplemental assets |
| --- | --- | --- |
| Kokoro | [hexgrad/Kokoro-82M v1.0](https://huggingface.co/hexgrad/Kokoro-82M), Apache-2.0 | [Misaki English lexicon and ONNX G2P](https://huggingface.co/nekwo/misaki-en-us-g2p-onnx/tree/4b3a605d2f605318ab4f762ab9855c44106528b7), Apache-2.0 |
| Supertonic 3 | [Supertone/supertonic-3](https://huggingface.co/Supertone/supertonic-3/tree/3cadd1ee6394adea1bd021217a0e650ede09a323), BigScience OpenRAIL-M | Ten upstream speaker styles |
| Pocket TTS | [Kyutai Pocket TTS](https://huggingface.co/kyutai/pocket-tts/tree/db04f0e653473e5c7333c69686ac92b7460b0c1d), CC BY 4.0 | [Alba MacKenna, casual reference](https://huggingface.co/kyutai/tts-voices/blob/323332d33f997de8394f24a193e1a76df720e01a/alba-mackenna/casual.wav), CC BY 4.0 |

The app bundles the arm64 JNI library and Java bindings from [sherpa-onnx v2.0.1](https://github.com/k2-fsa/sherpa-onnx/releases/tag/v2.0.1). Build-time and runtime artifact details are in the third-party notices.
