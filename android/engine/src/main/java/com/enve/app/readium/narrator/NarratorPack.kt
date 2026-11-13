package com.enve.app.readium.narrator

import com.enve.engine.impl.BuildConfig
import java.security.MessageDigest
import java.util.Locale

enum class NarratorPack(
    val title: String,
    val voices: List<String>,
    val license: String,
    val termsUrl: String,
    val terms: String,
    internal val speakerIds: List<Int>,
    internal val languages: Set<String>,
    internal val assets: NarratorAssets,
) {
    KOKORO(
        title = "Kokoro",
        voices = listOf("af_heart", "af_bella", "am_michael", "am_puck"),
        license = "Apache-2.0",
        termsUrl = "https://huggingface.co/hexgrad/Kokoro-82M/blob/f3ff3571791e39611d31c381e3a41a3af07b4987/README.md",
        terms = "Kokoro-82M by hexgrad and its English pronunciation files are licensed under Apache-2.0.",
        speakerIds = listOf(3, 2, 16, 18),
        languages = setOf("en"),
        assets = NarratorAssets(
            archive = NarratorArchive(
                url = "$SHERPA_MODELS/kokoro-int8-multi-lang-v1_0.tar.bz2",
                bytes = 132_353_410,
                sha256 = "72c347230107ef8a31098ec4d468a605244beef5f1ed00db97efa13518800653",
                root = "kokoro-int8-multi-lang-v1_0",
            ),
            files = listOf(
                NarratorFile("model.int8.onnx", 114_202_993, "75635ea3b85a32d00094dcdd61a258aba87c160f7c264c304a7b3ae9d734195e"),
                NarratorFile("voices.bin", 28_200_960, "1c5a5b983d3d50d8586d437a51f3faa2da7919ce76a013c081e65671a3447c29"),
                NarratorFile("tokens.txt", 687, "6ebb6bb288f20f3ae8d004d3c2ca27697da27c037d75e81a60e2a6a663f95425"),
                NarratorFile("misaki-en_us-g2p.onnx", 3_438_244, "757759c3e3ccb0bf59c379b1671c9834a27543ceaefd6846850823633b9665a1",
                    url = "$KOKORO_FRONTEND/misaki-en_us-g2p.onnx"),
                NarratorFile("misaki-en_us-g2p.json", 5_724_857, "8a8e3350713b0a00102425a5d5bd6b58b34854c74a3e8d837589f55212c51658",
                    url = "$KOKORO_FRONTEND/misaki-en_us-g2p.json"),
                NarratorFile("LICENSE", 11_358, "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"),
            ),
        ),
    ),
    SUPERTONIC(
        title = "Supertonic 3",
        voices = listOf("F1", "F2", "F3", "F4", "F5", "M1", "M2", "M3", "M4", "M5"),
        license = "BigScience OpenRAIL-M",
        termsUrl = "https://huggingface.co/Supertone/supertonic-3/blob/3cadd1ee6394adea1bd021217a0e650ede09a323/LICENSE",
        terms = "Supertonic 3’s weights and voice styles by Supertone Inc. are licensed under the BigScience OpenRAIL-M license, including its use restrictions. You agree to follow those restrictions whenever you use this narrator.",
        speakerIds = (0..9).toList(),
        languages = setOf(
            "ar", "bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr",
            "hi", "hr", "hu", "id", "it", "ja", "ko", "lt", "lv", "nl", "pl",
            "pt", "ro", "ru", "sk", "sl", "sv", "tr", "uk", "vi",
        ),
        assets = NarratorAssets(
            archive = NarratorArchive(
                url = "$SHERPA_MODELS/sherpa-onnx-supertonic-3-tts-int8-2026-05-11.tar.bz2",
                bytes = 128_774_318,
                sha256 = "82fa96f91c4ef8abaae3a14a3f4153facf88bed821d1f7331cec2700f432c427",
                root = "sherpa-onnx-supertonic-3-tts-int8-2026-05-11",
            ),
            files = listOf(
                NarratorFile("duration_predictor.int8.onnx", 3_700_147, "c3eb91414d5ff8a7a239b7fe9e34e7e2bf8a8140d8375ffb14718b1c639325db"),
                NarratorFile("text_encoder.int8.onnx", 36_416_150, "c7befd5ea8c3119769e8a6c1486c4edc6a3bc8365c67621c881bbb774b9902ff"),
                NarratorFile("vector_estimator.int8.onnx", 78_400_833, "20cd86fa5c6effedfda0e7cffe5b0569ca401c440a0c3a1d72bf39286c0db3fd"),
                NarratorFile("vocoder.int8.onnx", 25_991_073, "e923d60f53f95eb1ce235f1dc33ec56d9c057823c96fa6f8acf98f32b0da6152"),
                NarratorFile("tts.json", 8_253, "42078d3aef1cd43ab43021f3c54f47d2d75ceb4e75f627f118890128b06a0d09"),
                NarratorFile("unicode_indexer.bin", 262_144, "8402ca48e5189a8950138580b0fff64db6f072f24ac07cd54ba8b2fbb9883b30"),
                NarratorFile("voice.bin", 517_168, "67d5209b0ee8ce6c74105ffbe12fe6a7628aea3b4ba2fcb308a4a67938a93ce8"),
                NarratorFile("LICENSE", 1_070, "0dfe0d0ba84416fe3879d9a34f4909d8d0137c78d1e95834177b0414ac096fa2"),
            ),
        ),
    ),
    POCKET(
        title = "Pocket TTS",
        voices = listOf("alba"),
        license = "CC-BY-4.0",
        termsUrl = "https://huggingface.co/kyutai/pocket-tts/blob/db04f0e653473e5c7333c69686ac92b7460b0c1d/README.md",
        terms = "Pocket TTS by Kyutai and Alba MacKenna’s voice are licensed under CC BY 4.0. Kyutai prohibits voice impersonation or cloning without consent, and deceptive or unlawful use.",
        speakerIds = listOf(0),
        languages = setOf("en"),
        assets = NarratorAssets(
            archive = NarratorArchive(
                url = "$SHERPA_MODELS/sherpa-onnx-pocket-tts-int8-2026-01-26.tar.bz2",
                bytes = 98_336_520,
                sha256 = "2f3b88823cbbb9bf0b2477ec8ae7b3fec417b3a87b6bb5f256dba66f2ad967cb",
                root = "sherpa-onnx-pocket-tts-int8-2026-01-26",
            ),
            files = listOf(
                NarratorFile("lm_flow.int8.onnx", 9_962_530, "8d627d235c44a597da908e1085ebe241cbbe358964c502c5a5063d18851a5529"),
                NarratorFile("lm_main.int8.onnx", 76_341_079, "bfc0c7e7e3d72864fa3bb2ee499f62f21ddc1474b885f5f3ca570f8be73e787e"),
                NarratorFile("encoder.onnx", 72_713_165, "e8f2f6d301ffb96e398b138a7dc6d3038622d236044636b73d920bab85890260"),
                NarratorFile("decoder.int8.onnx", 22_693_618, "12b0857402d31aead94df19d6783b4350d1f740e811f3a3202c70ad89ae11eea"),
                NarratorFile("text_conditioner.onnx", 16_388_343, "0b84e837d7bfaf2c896627b03e3f080320309f37f4fc7df7698c644f7ba5e6b1"),
                NarratorFile("vocab.json", 69_478, "6fb646346cf931016f70c4921aab0900ce7a304b893cb02135c74e294abfea01"),
                NarratorFile("token_scores.json", 123_616, "5be2f278caf9b9800741f0fd82bff677f4943ec764c356f907213434b622d958"),
                NarratorFile("LICENSE", 18_655, "fe7b4ce83b8381cc5b216bbb4af73c570688d1b819c73bbaed8ca401f4677cd6"),
                NarratorFile(
                    name = POCKET_VOICE,
                    bytes = 958_542,
                    sha256 = "46264e83cb99115c3d210260e029117566d9c64f20266d10daa78107759ede3e",
                    url = "https://huggingface.co/kyutai/tts-voices/resolve/323332d33f997de8394f24a193e1a76df720e01a/alba-mackenna/casual.wav",
                ),
            ),
        ),
    ),
    PHONON(
        title = "Phonon",
        voices = listOf("spencer", "hugh"),
        license = "Apache-2.0",
        termsUrl = "https://huggingface.co/gradium/phonon-31m-en/blob/92741c5b07d085ff840e26fea8ce43110b87852f/README.md",
        terms = "Phonon 31M English and the Spencer and Hugh voices by Gradium are licensed under Apache 2.0.",
        speakerIds = emptyList(),
        languages = setOf("en"),
        assets = NarratorAssets(
            files = listOf(
                NarratorFile("model.q8.gguf", 64_512_352, "a7d9aad2cd6dc66473f24a08bc6d2939030ef4d751ef82349361fbef3272dbae",
                    url = "$PHONON_MODEL/model.q8.gguf"),
                NarratorFile("config.json", 4_634, "b5d0f88353638370d94035b7d73d7d6577c0554d78f8d7ecfd40490aae39ae85",
                    url = "$PHONON_MODEL/config.json"),
                NarratorFile("tokenizer.json", 277_967, "691a00068fa7b989f2f3e5ae5daa2d1a5bb319f2d5360deafcfb19a8bb6e7936",
                    url = "$PHONON_MODEL/tokenizer.json"),
                NarratorFile("voices/spencer.safetensors", 256_136, "cc9ac1107b0ffce282374a19beb7bfa95847724e6b7afbac991b4ae4277d5e6d",
                    url = "$PHONON_VOICES/JOW0vchyswkQUMDS.safetensors"),
                NarratorFile("voices/hugh.safetensors", 256_136, "3169d74b47a54d1eb15e4c243f56393abe9fe90c7e1c308ecf96ee67618b152a",
                    url = "$PHONON_VOICES/YyKcxPG7iIgS3jsK.safetensors"),
            ),
        ),
    ),
    WOOF(
        title = "Underdog Woof",
        voices = listOf("juno", "mira"),
        license = "Underdog Woof License",
        termsUrl = "https://huggingface.co/ConwayResearch/Underdog-Woof/blob/be702960539777fc3f698e54335276a8391b00f9/LICENSE",
        terms = "Woof is available in this build for private, noncommercial evaluation under the Underdog Woof License.",
        speakerIds = emptyList(),
        languages = setOf("en"),
        assets = NarratorAssets(
            files = listOf(
                NarratorFile(WOOF_WEIGHTS, 40_595_426, "d895fbbe84b8f4f461e3e94ab48b1164353b1988ce8d365f5aa8263d0de1203e",
                    url = "$WOOF_MODEL/$WOOF_WEIGHTS"),
                NarratorFile("LICENSE", 7_612, "784c4a353d15f370ff387f74bde64f50a2041df9c6f2338c3d8a2f781b944de5",
                    url = "$WOOF_MODEL/LICENSE"),
                NarratorFile("NOTICE", 919, "0849de251c109869d24f8a0b520260afa10594334ae3d0c06b75e68be1e2c623",
                    url = "$WOOF_MODEL/NOTICE"),
            ),
        ),
    );

    val downloadBytes: Long get() = (assets.archive?.bytes ?: 0) + assets.downloads.sumOf { it.bytes }

    internal val id: String get() = name.lowercase(Locale.ROOT)

    internal fun languageCode(language: String): String {
        val code = baseLanguage(language)
        if (code in UNDETERMINED_LANGUAGES) {
            return baseLanguage(Locale.getDefault().toLanguageTag()).takeIf { it in languages } ?: DEFAULT_LANGUAGE
        }
        require(code in languages) { "$title does not support language \"$language\"" }
        return code
    }

    companion object {
        val available: List<NarratorPack> = entries.filter { pack ->
            when (pack) {
                PHONON -> BuildConfig.PHONON_AVAILABLE
                WOOF -> WoofBackend.available
                else -> true
            }
        }
    }

    private fun baseLanguage(tag: String): String {
        val code = tag.trim().substringBefore('-').substringBefore('_').lowercase(Locale.ROOT)
        return languages.firstOrNull { Locale.forLanguageTag(it).isO3Language == code } ?: code
    }
}

internal class NarratorArchive(val url: String, val bytes: Long, val sha256: String, val root: String) {
    val fileName: String get() = url.substringAfterLast('/')
}

internal class NarratorFile(val name: String, val bytes: Long, val sha256: String, val url: String? = null)

internal class NarratorAssets(val archive: NarratorArchive? = null, val files: List<NarratorFile>) {
    val version: String = archive?.sha256 ?: MessageDigest.getInstance("SHA-256")
        .digest(files.joinToString("\n") { "${it.name}:${it.sha256}" }.toByteArray())
        .joinToString("") { "%02x".format(it) }

    val extracted: List<NarratorFile> get() = files.filter { it.url == null }
    val downloads: List<NarratorFile> get() = files.filter { it.url != null }
}

internal const val POCKET_VOICE = "alba.wav"
private const val SHERPA_MODELS = "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models"
private const val DEFAULT_LANGUAGE = "en"
private val UNDETERMINED_LANGUAGES = setOf("und", "mul")

private const val KOKORO_FRONTEND = "https://huggingface.co/nekwo/misaki-en-us-g2p-onnx/resolve/4b3a605d2f605318ab4f762ab9855c44106528b7"

internal const val WOOF_WEIGHTS = "woof_int8.npz"
private const val WOOF_MODEL = "https://huggingface.co/ConwayResearch/Underdog-Woof/resolve/be702960539777fc3f698e54335276a8391b00f9"
private const val PHONON_MODEL = "https://huggingface.co/gradium/phonon-31m-en/resolve/92741c5b07d085ff840e26fea8ce43110b87852f"
private const val PHONON_VOICES = "https://huggingface.co/gradium/phonon-voices/resolve/da6c9ec0d47be8df5c87c730a3aa97187f3229c3/voices"
