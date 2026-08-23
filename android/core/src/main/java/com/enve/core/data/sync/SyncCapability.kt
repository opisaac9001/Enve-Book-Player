package com.enve.core.data.sync

enum class SyncCapabilityFlag {
    PULL_PROGRESS,
    PUSH_PROGRESS,
    PUSH_FINISHED,
    PUSH_ANNOTATIONS,
    PULL_ANNOTATIONS,
}

data class SyncCapability(val flags: Set<SyncCapabilityFlag> = emptySet()) {
    fun supports(flag: SyncCapabilityFlag) = flag in flags

    companion object {
        val NONE = SyncCapability(emptySet())

        val FULL = SyncCapability(
            setOf(
                SyncCapabilityFlag.PULL_PROGRESS,
                SyncCapabilityFlag.PUSH_PROGRESS,
                SyncCapabilityFlag.PUSH_FINISHED,
                SyncCapabilityFlag.PUSH_ANNOTATIONS,
                SyncCapabilityFlag.PULL_ANNOTATIONS,
            )
        )

        val READ_WRITE = SyncCapability(
            setOf(
                SyncCapabilityFlag.PULL_PROGRESS,
                SyncCapabilityFlag.PUSH_PROGRESS,
                SyncCapabilityFlag.PUSH_FINISHED,
            )
        )
    }
}
