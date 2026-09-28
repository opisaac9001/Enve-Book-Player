package com.enve.core.data.util

const val FINISHED_PROGRESS_THRESHOLD = 0.99f

fun Double.reachesFinishedThreshold(): Boolean = toFloat() >= FINISHED_PROGRESS_THRESHOLD
