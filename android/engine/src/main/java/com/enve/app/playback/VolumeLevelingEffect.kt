package com.enve.app.playback

import android.media.audiofx.AudioEffect
import android.media.audiofx.DynamicsProcessing
import androidx.annotation.RequiresApi
import com.enve.core.data.model.VolumeLevelingStrength

internal interface VolumeLevelingEffect {
    fun setStrength(strength: VolumeLevelingStrength)
    fun setEnabled(enabled: Boolean)
    fun release()
}

@RequiresApi(28)
internal class PlatformVolumeLevelingEffect(
    audioSessionId: Int,
) : VolumeLevelingEffect {
    private val effect = DynamicsProcessing(audioSessionId)

    override fun setStrength(strength: VolumeLevelingStrength) {
        val parameters = strength.parameters ?: run {
            effect.enabled = false
            return
        }
        repeat(effect.config.mbcBandCount) { bandIndex ->
            val currentBand = effect.getMbcBandByChannelIndex(0, bandIndex)
            effect.setMbcBandAllChannelsTo(
                bandIndex,
                DynamicsProcessing.MbcBand(
                    true,
                    currentBand.cutoffFrequency,
                    parameters.attackMs,
                    parameters.releaseMs,
                    parameters.ratio,
                    parameters.thresholdDb,
                    KNEE_WIDTH_DB,
                    NOISE_GATE_DB,
                    EXPANDER_RATIO,
                    0f,
                    parameters.makeupGainDb,
                ),
            )
        }
        effect.enabled = true
    }

    override fun setEnabled(enabled: Boolean) {
        effect.enabled = enabled
    }

    override fun release() {
        effect.release()
    }

    companion object {
        fun isAvailable(): Boolean =
            runCatching {
                AudioEffect.queryEffects().any {
                    it.type == AudioEffect.EFFECT_TYPE_DYNAMICS_PROCESSING
                }
            }.getOrDefault(false)

        private const val KNEE_WIDTH_DB = 6f
        private const val NOISE_GATE_DB = -90f
        private const val EXPANDER_RATIO = 1f
    }
}

private data class VolumeLevelingParameters(
    val thresholdDb: Float,
    val ratio: Float,
    val attackMs: Float,
    val releaseMs: Float,
    val makeupGainDb: Float,
)

private val VolumeLevelingStrength.parameters: VolumeLevelingParameters?
    get() = when (this) {
        VolumeLevelingStrength.OFF -> null
        VolumeLevelingStrength.LOW -> VolumeLevelingParameters(-18f, 2f, 1f, 200f, 4f)
        VolumeLevelingStrength.MEDIUM -> VolumeLevelingParameters(-24f, 3f, 1f, 200f, 7f)
        VolumeLevelingStrength.HIGH -> VolumeLevelingParameters(-30f, 4f, 1f, 200f, 10f)
    }
