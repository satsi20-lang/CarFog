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
}
