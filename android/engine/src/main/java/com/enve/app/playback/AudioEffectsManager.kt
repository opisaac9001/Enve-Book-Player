package com.enve.app.playback

import android.media.audiofx.AudioEffect
import android.media.audiofx.BassBoost
import android.media.audiofx.Equalizer
import android.media.audiofx.LoudnessEnhancer
import android.os.Build
import android.util.Log
import com.enve.core.data.model.VolumeLevelingStrength
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import javax.inject.Inject
import javax.inject.Singleton

enum class EqPreset(val displayName: String, val bandGains: IntArray?) {
    FLAT("Flat", intArrayOf(0, 0, 0, 0, 0)),
    VOICE_BOOST("Voice", intArrayOf(-200, 100, 500, 600, 200)),
    BASS_HEAVY("Bass", intArrayOf(700, 500, 0, -100, -200)),
    TREBLE("Treble", intArrayOf(-200, -100, 0, 400, 600)),
    AUDIOBOOK("Audiobook", intArrayOf(-100, 200, 400, 500, 100)),
    PODCAST("Podcast", intArrayOf(0, 100, 500, 400, 0)),
    VOCAL_CLARITY("Clarity", intArrayOf(-300, 0, 600, 700, 300)),
    WARM("Warm", intArrayOf(400, 300, 100, -100, -300)),
    CUSTOM("Custom", null);

    companion object {
        fun fromString(name: String): EqPreset =
            entries.firstOrNull { it.name.equals(name, ignoreCase = true) } ?: FLAT
    }
}

data class EqualizerState(
    val isAttached: Boolean = false,
    val audioSessionActive: Boolean = false,
    val equalizerSupported: Boolean = false,
    val volumeBoostSupported: Boolean = false,
    val volumeLevelingSupported: Boolean = false,
    val bassBoostSupported: Boolean = false,
    val eqEnabled: Boolean = false,
    val preset: EqPreset = EqPreset.FLAT,
    val bandFrequencies: List<Int> = emptyList(),
    val bandLevels: List<Int> = emptyList(),
    val minBandLevel: Int = -1500,
    val maxBandLevel: Int = 1500,
    val numberOfBands: Int = 0,
    val volumeBoostEnabled: Boolean = false,
    val volumeBoostGainMb: Int = 0,
    val volumeLevelingStrength: VolumeLevelingStrength = VolumeLevelingStrength.OFF,
    val bassBoostEnabled: Boolean = false,
    val bassBoostStrength: Int = 0,
)

@Singleton
class AudioEffectsManager @Inject constructor() {

    companion object {
        private const val TAG = "AudioEffects"
        const val MAX_VOLUME_BOOST_MB = 2000
        const val MAX_BASS_BOOST = 1000
    }

    private var equalizer: Equalizer? = null
    private var loudnessEnhancer: LoudnessEnhancer? = null
    private var volumeLevelingEffect: VolumeLevelingEffect? = null
    private var bassBoost: BassBoost? = null
    private var currentSessionId: Int = -1

    private val _state = MutableStateFlow(EqualizerState())
    val state: StateFlow<EqualizerState> = _state.asStateFlow()

    fun attachToSession(audioSessionId: Int) {
        if (audioSessionId <= 0) {
            if (currentSessionId != -1) release()
            return
        }

        if (audioSessionId == currentSessionId) return
        release()
        currentSessionId = audioSessionId

        val equalizerSupported = isEffectTypeAvailable(AudioEffect.EFFECT_TYPE_EQUALIZER)
        _state.value = _state.value.copy(
            audioSessionActive = true,
            equalizerSupported = equalizerSupported,
            eqEnabled = if (equalizerSupported) _state.value.eqEnabled else false,
            volumeBoostSupported = isEffectTypeAvailable(AudioEffect.EFFECT_TYPE_LOUDNESS_ENHANCER),
            volumeLevelingSupported = isVolumeLevelingAvailable(),
            bassBoostSupported = isEffectTypeAvailable(AudioEffect.EFFECT_TYPE_BASS_BOOST),
        )

        if (equalizerSupported) {
            try {
                equalizer = Equalizer(0, audioSessionId).also { eq ->
                    val numBands = eq.numberOfBands.toInt()
                    val range = eq.bandLevelRange
                    val frequencies = (0 until numBands).map { eq.getCenterFreq(it.toShort()) / 1000 }
                    val levels = (0 until numBands).map { eq.getBandLevel(it.toShort()).toInt() }

                    _state.value = _state.value.copy(
                        isAttached = true,
                        numberOfBands = numBands,
                        bandFrequencies = frequencies,
                        bandLevels = levels,
                        minBandLevel = range[0].toInt(),
                        maxBandLevel = range[1].toInt(),
                    )
                }
            } catch (e: Exception) {
                Log.w(TAG, "Equalizer unavailable on this device", e)
                _state.value = _state.value.copy(equalizerSupported = false, eqEnabled = false)
            }
        }

        applyCurrentState()
    }

    fun release() {
        runCatching { equalizer?.release() }
        runCatching { loudnessEnhancer?.release() }
        runCatching { volumeLevelingEffect?.release() }
        runCatching { bassBoost?.release() }
        equalizer = null
        loudnessEnhancer = null
        volumeLevelingEffect = null
        bassBoost = null
        currentSessionId = -1
        _state.value = _state.value.copy(
            isAttached = false,
            audioSessionActive = false,
            equalizerSupported = false,
            volumeBoostSupported = false,
            volumeLevelingSupported = false,
            bassBoostSupported = false,
        )
    }

    fun setEqualizerEnabled(enabled: Boolean) {
        if (enabled && currentSessionId > 0 && !_state.value.equalizerSupported) {
            _state.value = _state.value.copy(eqEnabled = false)
            return
        }
        _state.value = _state.value.copy(eqEnabled = enabled)
        equalizer?.enabled = enabled
    }

    fun setPreset(preset: EqPreset) {
        val eq = equalizer ?: return
        val numBands = eq.numberOfBands.toInt()

        if (preset != EqPreset.CUSTOM && preset.bandGains != null) {
            val min = _state.value.minBandLevel
            val max = _state.value.maxBandLevel
            val adjusted = (0 until numBands).map { band ->
                preset.bandGains.getOrElse(band) { 0 }.coerceIn(min, max)
            }
            adjusted.forEachIndexed { band, level ->
                runCatching { eq.setBandLevel(band.toShort(), level.toShort()) }
            }
            _state.value = _state.value.copy(preset = preset, bandLevels = adjusted)
        } else {
            _state.value = _state.value.copy(preset = preset)
        }
    }

    fun setBandLevel(band: Int, level: Int) {
        val eq = equalizer ?: return
        val clamped = level.coerceIn(_state.value.minBandLevel, _state.value.maxBandLevel)
        runCatching { eq.setBandLevel(band.toShort(), clamped.toShort()) }
        val updated = _state.value.bandLevels.toMutableList()
        if (band in updated.indices) updated[band] = clamped
        _state.value = _state.value.copy(bandLevels = updated, preset = EqPreset.CUSTOM)
    }

    fun setVolumeBoost(enabled: Boolean, gainMb: Int = _state.value.volumeBoostGainMb) {
        val clamped = gainMb.coerceIn(0, MAX_VOLUME_BOOST_MB)
        if (enabled && currentSessionId > 0 && !_state.value.volumeBoostSupported) {
            _state.value = _state.value.copy(volumeBoostEnabled = false, volumeBoostGainMb = clamped)
            return
        }
        _state.value = _state.value.copy(volumeBoostEnabled = enabled, volumeBoostGainMb = clamped)
        val enhancer = if (enabled) loudnessEnhancer ?: createLoudnessEnhancer() else loudnessEnhancer
        enhancer?.let {
            it.enabled = enabled
            if (enabled) it.setTargetGain(clamped)
        }
    }

    fun setVolumeBoostGain(gainMb: Int) = setVolumeBoost(_state.value.volumeBoostEnabled, gainMb)

    fun setVolumeLevelingStrength(strength: VolumeLevelingStrength) {
        _state.value = _state.value.copy(volumeLevelingStrength = strength)
        if (strength == VolumeLevelingStrength.OFF) {
            volumeLevelingEffect?.setEnabled(false)
            return
        }
        if (currentSessionId <= 0 || !_state.value.volumeLevelingSupported) return

        val effect = volumeLevelingEffect ?: createVolumeLevelingEffect() ?: return
        applyVolumeLeveling(effect, strength)
    }

    fun setBassBoost(enabled: Boolean, strength: Int = _state.value.bassBoostStrength) {
        val clamped = strength.coerceIn(0, MAX_BASS_BOOST)
        if (enabled && currentSessionId > 0 && !_state.value.bassBoostSupported) {
            _state.value = _state.value.copy(bassBoostEnabled = false, bassBoostStrength = clamped)
            return
        }
        _state.value = _state.value.copy(bassBoostEnabled = enabled, bassBoostStrength = clamped)
        val boost = if (enabled) bassBoost ?: createBassBoost() else bassBoost
        boost?.let {
            it.enabled = enabled
            if (enabled) runCatching { it.setStrength(clamped.toShort()) }
        }
    }

    fun setBassBoostStrength(strength: Int) = setBassBoost(_state.value.bassBoostEnabled, strength)

    fun restoreState(
        eqEnabled: Boolean,
        preset: EqPreset,
        bandLevels: List<Int>,
        volumeBoostEnabled: Boolean,
        volumeBoostGainMb: Int,
        volumeLevelingStrength: VolumeLevelingStrength,
        bassBoostEnabled: Boolean,
        bassBoostStrength: Int,
    ) {
        _state.value = _state.value.copy(
            eqEnabled = eqEnabled,
            preset = preset,
            bandLevels = if (bandLevels.isNotEmpty()) bandLevels else _state.value.bandLevels,
            volumeBoostEnabled = volumeBoostEnabled,
            volumeBoostGainMb = volumeBoostGainMb,
            volumeLevelingStrength = volumeLevelingStrength,
            bassBoostEnabled = bassBoostEnabled,
            bassBoostStrength = bassBoostStrength,
        )
        applyCurrentState()
    }

    fun resetAll() {
        setEqualizerEnabled(false)
        setPreset(EqPreset.FLAT)
        setVolumeBoost(enabled = false, gainMb = 0)
        setVolumeLevelingStrength(VolumeLevelingStrength.OFF)
        setBassBoost(enabled = false, strength = 0)
    }

    private fun applyCurrentState() {
        val s = _state.value
        equalizer?.enabled = s.eqEnabled
        if (s.eqEnabled) {
            if (s.preset != EqPreset.CUSTOM) {
                setPreset(s.preset)
            } else {
                s.bandLevels.forEachIndexed { band, level ->
                    runCatching { equalizer?.setBandLevel(band.toShort(), level.toShort()) }
                }
            }
        }
        setVolumeBoost(s.volumeBoostEnabled, s.volumeBoostGainMb)
        setVolumeLevelingStrength(s.volumeLevelingStrength)
        setBassBoost(s.bassBoostEnabled, s.bassBoostStrength)
    }

    private fun createVolumeLevelingEffect(): VolumeLevelingEffect? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P || currentSessionId <= 0) return null
        return try {
            PlatformVolumeLevelingEffect(currentSessionId).also { volumeLevelingEffect = it }
        } catch (e: Exception) {
            Log.w(TAG, "Volume leveling unavailable", e)
            _state.value = _state.value.copy(volumeLevelingSupported = false)
            null
        }
    }

    private fun applyVolumeLeveling(
        effect: VolumeLevelingEffect,
        strength: VolumeLevelingStrength,
    ) {
        try {
            effect.setStrength(strength)
        } catch (e: Exception) {
            Log.w(TAG, "Unable to apply volume leveling", e)
            runCatching { effect.setEnabled(false) }
            _state.value = _state.value.copy(volumeLevelingSupported = false)
        }
    }

    private fun createLoudnessEnhancer(): LoudnessEnhancer? {
        if (currentSessionId <= 0 || !isEffectTypeAvailable(AudioEffect.EFFECT_TYPE_LOUDNESS_ENHANCER)) return null
        return try {
            LoudnessEnhancer(currentSessionId).also { loudnessEnhancer = it }
        } catch (e: Exception) {
            Log.w(TAG, "LoudnessEnhancer unavailable", e)
            _state.value = _state.value.copy(volumeBoostSupported = false, volumeBoostEnabled = false)
            null
        }
    }

    private fun createBassBoost(): BassBoost? {
        if (currentSessionId <= 0 || !isEffectTypeAvailable(AudioEffect.EFFECT_TYPE_BASS_BOOST)) return null
        return try {
            BassBoost(0, currentSessionId).also { bassBoost = it }
        } catch (e: Exception) {
            Log.w(TAG, "BassBoost unavailable", e)
            _state.value = _state.value.copy(bassBoostSupported = false, bassBoostEnabled = false)
            null
        }
    }

    private fun isEffectTypeAvailable(type: java.util.UUID): Boolean =
        runCatching { AudioEffect.queryEffects().any { it.type == type } }.getOrDefault(false)

    private fun isVolumeLevelingAvailable(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
            PlatformVolumeLevelingEffect.isAvailable()
}
