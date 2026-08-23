package com.enve.app.ui.components

import androidx.annotation.DrawableRes
import androidx.compose.ui.graphics.Color
import com.enve.app.R

object GrimmoryAccentMatcher {

    private data class Accent(
        val r: Float,
        val g: Float,
        val b: Float,
        @DrawableRes val darkIcon: Int,
        @DrawableRes val lightIcon: Int,
    )

    private val accents: List<Accent> = listOf(
        Accent(0xF9 / 255f, 0x73 / 255f, 0x16 / 255f, R.drawable.grimmory_orange_dark, R.drawable.grimmory_orange_light),
        Accent(0xF5 / 255f, 0x9E / 255f, 0x0B / 255f, R.drawable.grimmory_amber_dark, R.drawable.grimmory_amber_light),
        Accent(0xEA / 255f, 0xB3 / 255f, 0x08 / 255f, R.drawable.grimmory_yellow_dark, R.drawable.grimmory_yellow_light),
        Accent(0x84 / 255f, 0xCC / 255f, 0x16 / 255f, R.drawable.grimmory_lime_dark, R.drawable.grimmory_lime_light),
        Accent(0x22 / 255f, 0xC5 / 255f, 0x5E / 255f, R.drawable.grimmory_green_dark, R.drawable.grimmory_green_light),
        Accent(0x10 / 255f, 0xB9 / 255f, 0x81 / 255f, R.drawable.grimmory_emerald_dark, R.drawable.grimmory_emerald_light),
        Accent(0x14 / 255f, 0xB8 / 255f, 0xA6 / 255f, R.drawable.grimmory_teal_dark, R.drawable.grimmory_teal_light),
        Accent(0x06 / 255f, 0xB6 / 255f, 0xD4 / 255f, R.drawable.grimmory_cyan_dark, R.drawable.grimmory_cyan_light),
        Accent(0x0E / 255f, 0xA5 / 255f, 0xE9 / 255f, R.drawable.grimmory_sky_dark, R.drawable.grimmory_sky_light),
        Accent(0x3B / 255f, 0x82 / 255f, 0xF6 / 255f, R.drawable.grimmory_blue_dark, R.drawable.grimmory_blue_light),
        Accent(0x63 / 255f, 0x66 / 255f, 0xF1 / 255f, R.drawable.grimmory_indigo_dark, R.drawable.grimmory_indigo_light),
        Accent(0x8B / 255f, 0x5C / 255f, 0xF6 / 255f, R.drawable.grimmory_violet_dark, R.drawable.grimmory_violet_light),
        Accent(0xA8 / 255f, 0x55 / 255f, 0xF7 / 255f, R.drawable.grimmory_purple_dark, R.drawable.grimmory_purple_light),
        Accent(0xD9 / 255f, 0x46 / 255f, 0xEF / 255f, R.drawable.grimmory_fuchsia_dark, R.drawable.grimmory_fuchsia_light),
        Accent(0xEC / 255f, 0x48 / 255f, 0x99 / 255f, R.drawable.grimmory_pink_dark, R.drawable.grimmory_pink_light),
        Accent(0xF4 / 255f, 0x3F / 255f, 0x5E / 255f, R.drawable.grimmory_rose_dark, R.drawable.grimmory_rose_light),
        Accent(0xEF / 255f, 0x44 / 255f, 0x44 / 255f, R.drawable.grimmory_red_dark, R.drawable.grimmory_red_light),
        Accent(0xEF / 255f, 0x75 / 255f, 0x50 / 255f, R.drawable.grimmory_coralsunset_dark, R.drawable.grimmory_coralsunset_light),
        Accent(0xED / 255f, 0x67 / 255f, 0x67 / 255f, R.drawable.grimmory_roseblush_dark, R.drawable.grimmory_roseblush_light),
        Accent(0xFF / 255f, 0x90 / 255f, 0xA2 / 255f, R.drawable.grimmory_melonblush_dark, R.drawable.grimmory_melonblush_light),
        Accent(0xFF / 255f, 0x86 / 255f, 0xBF / 255f, R.drawable.grimmory_cottoncandy_dark, R.drawable.grimmory_cottoncandy_light),
        Accent(0xFF / 255f, 0xAD / 255f, 0x68 / 255f, R.drawable.grimmory_apricotsunrise_dark, R.drawable.grimmory_apricotsunrise_light),
        Accent(0xB8 / 255f, 0x90 / 255f, 0x4F / 255f, R.drawable.grimmory_antiquebronze_dark, R.drawable.grimmory_antiquebronze_light),
        Accent(0xFF / 255f, 0xCF / 255f, 0x45 / 255f, R.drawable.grimmory_butteryyellow_dark, R.drawable.grimmory_butteryyellow_light),
        Accent(0xF1 / 255f, 0xC5 / 255f, 0x89 / 255f, R.drawable.grimmory_vanillacream_dark, R.drawable.grimmory_vanillacream_light),
        Accent(0x96 / 255f, 0xFF / 255f, 0x84 / 255f, R.drawable.grimmory_citrusmint_dark, R.drawable.grimmory_citrusmint_light),
        Accent(0x7F / 255f, 0xFF / 255f, 0xAE / 255f, R.drawable.grimmory_freshmint_dark, R.drawable.grimmory_freshmint_light),
        Accent(0x9F / 255f, 0xCF / 255f, 0xA8 / 255f, R.drawable.grimmory_sagepearl_dark, R.drawable.grimmory_sagepearl_light),
        Accent(0x6F / 255f, 0xC8 / 255f, 0xFF / 255f, R.drawable.grimmory_skyblue_dark, R.drawable.grimmory_skyblue_light),
        Accent(0x9F / 255f, 0xB2 / 255f, 0xFF / 255f, R.drawable.grimmory_periwinklecream_dark, R.drawable.grimmory_periwinklecream_light),
        Accent(0x63 / 255f, 0xAA / 255f, 0xFF / 255f, R.drawable.grimmory_pastelroyalblue_dark, R.drawable.grimmory_pastelroyalblue_light),
        Accent(0xB4 / 255f, 0x7F / 255f, 0xFF / 255f, R.drawable.grimmory_lavenderdream_dark, R.drawable.grimmory_lavenderdream_light),
        Accent(0xB3 / 255f, 0x9C / 255f, 0x85 / 255f, R.drawable.grimmory_dustyneutral_dark, R.drawable.grimmory_dustyneutral_light),
    )

    @DrawableRes
    fun closestIcon(to: Color, isDark: Boolean): Int {
        val r = to.red
        val g = to.green
        val b = to.blue

        val brightness = r * 0.299f + g * 0.587f + b * 0.114f
        if (brightness < 0.08f) {
            return if (isDark) R.drawable.grimmory_orange_dark else R.drawable.grimmory_orange_light
        }

        var best = accents.first()
        var bestDist = Float.MAX_VALUE
        for (a in accents) {
            val dr = r - a.r
            val dg = g - a.g
            val db = b - a.b
            val dist = dr * dr + dg * dg + db * db
            if (dist < bestDist) {
                bestDist = dist
                best = a
            }
        }
        return if (isDark) best.darkIcon else best.lightIcon
    }
}
