# sherpa-onnx native runtime

The Android arm64 runtime uses sherpa-onnx 2.0.1, source revision `af2d8d81dbfa61c4cea4c568da78f3982edca005`. The build verifies the upstream AAR SHA-256 `07e042d97f3a6bd5b7fe74d4eef0513dc01a714b16c15a903250095aba43a575` before extracting its Java bindings and JNI library.

The pinned CMake dependencies are ONNX Runtime 1.28.2 (MIT and its third-party notices), Eigen 5.0.1 (MPL-2.0), OpenFst 1.8.5-2026-07-09 (Apache-2.0), kaldi-decoder 0.3.0 (Apache-2.0), kaldi-native-fbank 1.22.4 (Apache-2.0), simple-sentencepiece 0.7 (Apache-2.0), and nlohmann/json 3.12.0 (MIT). `NOTICES.txt` retains their upstream license text and notices with trailing whitespace normalized and is bundled in Settings acknowledgements.

The release dependency inventory records SHA-256 digests for the extracted JNI library and Java bindings, alongside Maven runtime artifacts. Model weights are separately downloaded and verified; see [model provenance](../Models/UPSTREAM.md).

| Notice | SHA-256 of upstream text | Pinned source |
| --- | --- | --- |
| sherpa-onnx-LICENSE.txt | `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30` | [Source](https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/af2d8d81dbfa61c4cea4c568da78f3982edca005/LICENSE) |
| onnxruntime-LICENSE.txt | `2f07c72751aed99790b8a4869cf2311df85a860b22ded05fa22803587a48922c` | [Source](https://raw.githubusercontent.com/microsoft/onnxruntime/v1.28.2/LICENSE) |
| onnxruntime-ThirdPartyNotices.txt | `0e07b95f3a8d6230037707c5c4a2b554d12c4cb67369669ac255635528ffcee2` | [Source](https://raw.githubusercontent.com/microsoft/onnxruntime/v1.28.2/ThirdPartyNotices.txt) |
| Eigen-MPL-2.0.txt | `66a3107d5ad6a058aab753eaac2047ccb2ed0e39465dd0fe5844da3e300d5172` | [Source](https://gitlab.com/libeigen/eigen/-/raw/5.0.1/COPYING.MPL2) |
| kaldi-decoder-LICENSE.txt | `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30` | [Source](https://raw.githubusercontent.com/k2-fsa/kaldi-decoder/v0.3.0/LICENSE) |
| kaldi-native-fbank-LICENSE.txt | `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30` | [Source](https://raw.githubusercontent.com/csukuangfj/kaldi-native-fbank/v1.22.4/LICENSE) |
| openfst-COPYING.txt | `4300529197035fd3452350718a0b8cee984e9412c9932d7f35fcde849fc97a4b` | [Source](https://raw.githubusercontent.com/csukuangfj/openfst/v1.8.5-2026-07-09/COPYING) |
| simple-sentencepiece-LICENSE.txt | `c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4` | [Source](https://raw.githubusercontent.com/pkufool/simple-sentencepiece/v0.7/LICENSE) |
| nlohmann-json-LICENSE.txt | `46a65cffd1ea955132d95a8dd921640714a8d6b537d2e4e482d31145ae95b603` | [Source](https://raw.githubusercontent.com/nlohmann/json/v3.12.0/LICENSE.MIT) |
