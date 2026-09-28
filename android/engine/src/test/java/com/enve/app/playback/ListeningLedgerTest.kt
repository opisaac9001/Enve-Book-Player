package com.enve.app.playback

import org.junit.Assert.assertEquals
import org.junit.Test

class ListeningLedgerTest {

    @Test
    fun eachSyncCarriesOnlyTimeSinceTheLastAcknowledgedSync() {
        val ledger = ListeningLedger()

        ledger.add(30_000L)
        val first = ledger.unsyncedMs
        ledger.acknowledge(first)
        ledger.add(12_000L)

        assertEquals(30_000L, first)
        assertEquals(12_000L, ledger.unsyncedMs)
        assertEquals(42_000L, ledger.totalMs)
    }

    @Test
    fun failedSyncKeepsTimeForTheNextAttempt() {
        val ledger = ListeningLedger()

        ledger.add(10_000L)
        ledger.add(5_000L)

        assertEquals(15_000L, ledger.unsyncedMs)
        ledger.acknowledge(ledger.unsyncedMs)
        assertEquals(0L, ledger.unsyncedMs)
    }

    @Test
    fun listeningDuringAnInFlightSyncIsNotLost() {
        val ledger = ListeningLedger()

        ledger.add(20_000L)
        val inFlight = ledger.unsyncedMs
        ledger.add(3_000L)
        ledger.acknowledge(inFlight)

        assertEquals(3_000L, ledger.unsyncedMs)
    }

    @Test
    fun ignoresNegativeIntervalsAndOverAcknowledgement() {
        val ledger = ListeningLedger()

        ledger.add(-5_000L)
        ledger.add(4_000L)
        ledger.acknowledge(10_000L)

        assertEquals(4_000L, ledger.totalMs)
        assertEquals(0L, ledger.unsyncedMs)
    }
}
