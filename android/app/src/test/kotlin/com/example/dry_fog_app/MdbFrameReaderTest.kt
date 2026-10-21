package com.example.dry_fog_app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class MdbFrameReaderTest {

    // Имитация порта: каждый read «длится» timeoutMs по фальшивым часам и
    // возвращает байты, запланированные на этот момент.
    private class FakePort(private val script: Map<Long, String>, private val endAt: Long) : MdbBytePort {
        var now = 0L
        lateinit var reader: MdbFrameReader
        override fun read(buf: ByteArray, timeoutMs: Int): Int {
            now += timeoutMs
            if (now >= endAt) reader.stop()
            val chunk = script[now] ?: return 0
            val b = chunk.toByteArray(Charsets.US_ASCII)
            b.copyInto(buf)
            return b.size
        }
    }

    private fun run(script: Map<Long, String>, endAt: Long): List<Triple<String, Long, Long>> {
        val frames = mutableListOf<Triple<String, Long, Long>>()
        val port = FakePort(script, endAt)
        val reader = MdbFrameReader(
            port = port,
            onFrame = { d, f, l -> frames += Triple(String(d, Charsets.US_ASCII), f, l) },
            onError = { throw AssertionError("ошибки быть не должно") },
            clock = { port.now },
        )
        port.reader = reader
        reader.run()
        return frames
    }

    @Test
    fun chunksWithinGapAreJoined() {
        // «0101097201» и «02070D94» с разрывом 40 мс < 60 мс — одно сообщение.
        val frames = run(mapOf(20L to "0101097201", 60L to "02070D94"), 400)
        assertEquals(listOf(Triple("010109720102070D94", 20L, 60L)), frames)
    }

    @Test
    fun pauseSplitsMessages() {
        val frames = run(mapOf(20L to "03FFFE", 200L to "07"), 400)
        assertEquals(listOf("03FFFE", "07"), frames.map { it.first })
    }

    @Test
    fun eventsFasterThanGapGlueTogetherButTimesShowIt() {
        // Два события через 40 мс склеиваются — поэтому журнал показывает время
        // первого и последнего байта.
        val frames = run(mapOf(20L to "05000A", 60L to "07"), 400)
        assertEquals(1, frames.size)
        assertEquals("05000A07", frames[0].first)
        assertEquals(40L, frames[0].third - frames[0].second)
    }

    @Test
    fun portLostDuringReadKeepsDataAndReportsError() {
        var calls = 0
        val frames = mutableListOf<String>()
        val errors = mutableListOf<IOException>()
        val reader = MdbFrameReader(
            port = { buf, _ ->
                calls++
                if (calls == 1) {
                    "0707".toByteArray().copyInto(buf); 4
                } else throw IOException("USB отключён")
            },
            onFrame = { d, _, _ -> frames += String(d) },
            onError = { errors += it },
        )
        reader.run()
        assertEquals(listOf("0707"), frames)
        assertEquals(1, errors.size)
    }

    @Test
    fun closeWhileBlockedInReadStopsWithoutError() {
        // Настоящий поток: порт блокируется в read, затем «закрывается»
        // (stop + IOException, как у usb-serial при close()).
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val errors = mutableListOf<IOException>()
        val reader = MdbFrameReader(
            port = { _, _ ->
                entered.countDown()
                release.await()
                throw IOException("порт закрыт")
            },
            onFrame = { _, _, _ -> },
            onError = { errors += it },
        )
        val t = Thread(reader::run).apply { start() }
        assertTrue(entered.await(2, TimeUnit.SECONDS))
        reader.stop()
        release.countDown()
        t.join(2000)
        assertTrue(!t.isAlive)
        assertTrue("штатное закрытие не считается ошибкой", errors.isEmpty())
    }

    @Test
    fun benchLogRingBufferAndFile() {
        val f = File.createTempFile("mdb_bench", ".log").apply { deleteOnExit() }
        val log = MdbBenchLog(f, capacity = 3)
        for (i in 1..5) log.info(0, "строка $i")
        assertEquals(listOf(3L, 4L, 5L), log.all().map { it.seq })
        assertEquals(listOf(5L), log.since(4).map { it.seq })
        assertEquals(5, f.readLines().size)
        log.rx(0, 40, "07".toByteArray(), "разбор")
        val line = log.all().last().line
        assertTrue(line, line.contains("<- hex: 07 | ascii: 07 | байты: 30 37 | первый байт"))
        assertTrue(line, line.contains("+40 мс"))
    }

    // ---- реальные кадры адаптера Wafer (1.10.11) ----

    // Порт как настоящий read: блокируется до прихода данных или таймаута.
    // script — (время прихода, байты).
    private class BlockingFakePort(script: List<Pair<Long, String>>, private val endAt: Long) : MdbBytePort {
        private val queue = ArrayDeque(script)
        var now = 0L
        lateinit var reader: MdbFrameReader
        override fun read(buf: ByteArray, timeoutMs: Int): Int {
            val next = queue.firstOrNull()
            if (next != null && next.first <= now + timeoutMs) {
                queue.removeFirst()
                now = maxOf(now, next.first)
                val b = next.second.toByteArray(Charsets.US_ASCII)
                b.copyInto(buf)
                return b.size
            }
            now += timeoutMs
            if (now >= endAt) reader.stop()
            return 0
        }
    }

    private fun runBlocking(script: List<Pair<Long, String>>, readTimeoutMs: Int = 20): List<Triple<String, Long, Long>> {
        val frames = mutableListOf<Triple<String, Long, Long>>()
        val port = BlockingFakePort(script, 2000)
        val reader = MdbFrameReader(
            port = port,
            onFrame = { d, f, l -> frames += Triple(String(d, Charsets.US_ASCII), f, l) },
            onError = { throw AssertionError("ошибки быть не должно") },
            clock = { port.now },
            readTimeoutMs = readTimeoutMs,
        )
        port.reader = reader
        reader.run()
        return frames
    }

    @Test
    fun ackThenEndSession85msApartAreTwoFrames() {
        // С железа: "00", через ~85 мс "10 07".
        val frames = runBlocking(listOf(100L to "00\r\n", 185L to "10 07\r\n"))
        assertEquals(listOf("00\r\n", "10 07\r\n"), frames.map { it.first })
        assertEquals(MdbCashlessProtocol.Event.Ack, MdbCashlessProtocol.parseFrame(frames[0].first))
        assertEquals(MdbCashlessProtocol.Event.EndSession, MdbCashlessProtocol.parseFrame(frames[1].first))
    }

    @Test
    fun framesWithoutCrLf85msApartAreSplitByPause() {
        val frames = runBlocking(listOf(100L to "00", 185L to "10 07"))
        assertEquals(listOf("00", "10 07"), frames.map { it.first })
    }

    @Test
    fun pauseInsideOneLongReadStillSplits() {
        // Таймаут чтения длиннее паузы: между кадрами нет ни одного пустого
        // чтения — раньше такие кадры склеивались.
        val frames = runBlocking(listOf(100L to "00", 185L to "10 07"), readTimeoutMs = 200)
        assertEquals(listOf("00", "10 07"), frames.map { it.first })
    }

    @Test
    fun twoFramesInOneUsbPacketAreSplitByCrLf() {
        val frames = runBlocking(listOf(100L to "00\r\n10 07\r\n"))
        assertEquals(listOf("00\r\n", "10 07\r\n"), frames.map { it.first })
    }

    @Test
    fun frameSplitAcrossPacketsIsJoined() {
        val frames = runBlocking(listOf(100L to "01 01 19 78 ", 104L to "01 02 78 0D 1B\r\n"))
        assertEquals(listOf("01 01 19 78 01 02 78 0D 1B\r\n"), frames.map { it.first })
        assertEquals(1, MdbCashlessProtocol.parseSetupReply(frames[0].first)!!.scale)
    }

    @Test
    fun incompleteFrameIsFlushedByPauseAndNotRecognized() {
        val frames = runBlocking(listOf(100L to "10 0"))
        assertEquals(listOf("10 0"), frames.map { it.first })
        assertTrue(MdbCashlessProtocol.parseFrame(frames[0].first) is MdbCashlessProtocol.Event.Unrecognized)
    }
}
