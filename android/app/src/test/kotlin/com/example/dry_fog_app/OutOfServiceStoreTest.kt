package com.example.dry_fog_app

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files

// Хранилище признака "выведен из обслуживания" (задача "вывод аппарата из
// обслуживания", требования 2 и 5): запись переживает перезапуск, а
// повреждённая/недописанная запись читается как CORRUPT (fail-closed), в
// отличие от полностью отсутствующей (NONE — чистое первое включение).
class OutOfServiceStoreTest {

    private lateinit var dir: File
    private val logged = mutableListOf<String>()

    // Простейшая проверка "похоже на JSON-объект" вместо org.json — заглушки
    // android.jar в JVM-тесте не разбирают ничего.
    private fun store() = OutOfServiceStore(
        dir,
        isValidJson = { it.trim().startsWith("{") && it.trim().endsWith("}") },
        log = { logged.add(it) },
    )

    @Before
    fun setUp() {
        dir = Files.createTempDirectory("oos_test").toFile()
    }

    @After
    fun tearDown() {
        dir.deleteRecursively()
    }

    @Test
    fun `чистое первое включение — записи нет, это не ошибка`() {
        val r = store().read()
        assertEquals(OutOfServiceStore.Status.NONE, r.status)
        assertNull(r.json)
    }

    @Test
    fun `запись переживает пересоздание хранилища`() {
        val json = """{"code":"heater_no_power","at":"2026-10-01T00:00:00"}"""
        assertTrue(store().write(json))
        // новый экземпляр — как перезапуск приложения
        val r = store().read()
        assertEquals(OutOfServiceStore.Status.OK, r.status)
        assertEquals(json, r.json)
    }

    @Test
    fun `повторная запись заменяет старую целиком`() {
        assertTrue(store().write("""{"code":"a"}"""))
        assertTrue(store().write("""{"code":"b"}"""))
        assertEquals("""{"code":"b"}""", store().read().json)
        assertFalse(File(dir, OutOfServiceStore.TMP_NAME).exists())
    }

    @Test
    fun `испорченное содержимое — CORRUPT, а не NONE`() {
        assertTrue(store().write("""{"code":"x"}"""))
        val f = File(dir, OutOfServiceStore.FILE_NAME)
        val bytes = f.readBytes()
        // портим один байт тела — контрольная сумма не сойдётся
        bytes[bytes.size - 2] = (bytes[bytes.size - 2] + 1).toByte()
        f.writeBytes(bytes)
        assertEquals(OutOfServiceStore.Status.CORRUPT, store().read().status)
    }

    @Test
    fun `усечённая запись — CORRUPT`() {
        assertTrue(store().write("""{"code":"heater_no_power"}"""))
        val f = File(dir, OutOfServiceStore.FILE_NAME)
        f.writeBytes(f.readBytes().copyOf(5)) // обрезали посреди контрольной суммы
        assertEquals(OutOfServiceStore.Status.CORRUPT, store().read().status)
    }

    @Test
    fun `пустой файл — CORRUPT`() {
        File(dir, OutOfServiceStore.FILE_NAME).writeBytes(ByteArray(0))
        assertEquals(OutOfServiceStore.Status.CORRUPT, store().read().status)
    }

    @Test
    fun `недописанный временный файл без основного — CORRUPT, оборвали питание посреди записи`() {
        File(dir, OutOfServiceStore.TMP_NAME).writeText("abc\n{")
        assertEquals(OutOfServiceStore.Status.CORRUPT, store().read().status)
    }

    @Test
    fun `валидный основной файл с мусорным временным остаётся OK, мусор убирается`() {
        assertTrue(store().write("""{"code":"x"}"""))
        File(dir, OutOfServiceStore.TMP_NAME).writeText("мусор")
        val r = store().read()
        assertEquals(OutOfServiceStore.Status.OK, r.status)
        assertFalse(File(dir, OutOfServiceStore.TMP_NAME).exists())
    }

    @Test
    fun `снятие блокировки возвращает хранилище в чистое состояние`() {
        assertTrue(store().write("""{"code":"x"}"""))
        assertTrue(store().clear())
        assertEquals(OutOfServiceStore.Status.NONE, store().read().status)
    }

    @Test
    fun `снятие при отсутствующей записи — успех`() {
        assertTrue(store().clear())
    }

    @Test
    fun `запись в недоступный каталог — false, а не исключение`() {
        val bad = OutOfServiceStore(
            File(dir, "нет/такого/каталога"),
            isValidJson = { true },
            log = { logged.add(it) },
        )
        assertFalse(bad.write("""{"code":"x"}"""))
        assertTrue(logged.isNotEmpty())
    }
}
