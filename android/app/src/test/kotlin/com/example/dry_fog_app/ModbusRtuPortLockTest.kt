package com.example.dry_fog_app

import java.io.File
import java.io.RandomAccessFile
import java.nio.channels.OverlappingFileLockException
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

// Проверяет сам механизм эксклюзивности (задача "эксклюзивное открытие
// последовательного порта"), а не ModbusRtu.open() целиком — тот требует
// реального tty и рабочего stty, недоступных в локальном JVM-тесте (как и
// android.os.Process в ModbusRtu — см. try/catch в конструкторе). Здесь —
// ровно та же операция (RandomAccessFile → FileChannel.tryLock()) на
// обычном временном файле, ровно то же исключение, которое open() ловит.
//
// Кросс-процессную блокировку (два разных PID) через голый adb не
// проверить: shell-утилита `flock` использует системный flock(), а
// FileChannel.tryLock() на Android/Linux реализован поверх fcntl(F_SETLK)
// — два независимых механизма ядра, не видят друг друга. Здесь проверяется
// то, что реально доступно проверить из JVM: конфликт в пределах процесса
// (Java спе­циально бросает OverlappingFileLockException для этого случая,
// поверх обычной POSIX-семантики, где fcntl-локи одного процесса друг с
// другом не конфликтуют) — ModbusRtu.open() ловит это исключение точно так
// же, как и "null" от чужого процесса, и в обоих случаях уходит в Busy.
class ModbusRtuPortLockTest {

    @Test
    fun `второй tryLock на тот же файл получает отказ`() {
        val file = File.createTempFile("modbus_lock_test", ".tmp")
        file.deleteOnExit()

        val raf1 = RandomAccessFile(file, "rw")
        val lock1 = raf1.channel.tryLock()
        assertNotNull("первая блокировка должна пройти", lock1)

        val raf2 = RandomAccessFile(file, "rw")
        var secondFailed = false
        try {
            val lock2 = raf2.channel.tryLock()
            // На некоторых JVM/ОС комбинациях второй tryLock из ТОГО ЖЕ
            // процесса может вернуть null вместо исключения — обе формы
            // отказа одинаково обрабатываются в ModbusRtu.open() (оба пути
            // ведут в Busy), поэтому тест принимает любую из них.
            secondFailed = lock2 == null
        } catch (e: OverlappingFileLockException) {
            secondFailed = true
        }
        assertTrue("вторая попытка обязана получить отказ", secondFailed)

        lock1?.release()
        raf1.close()
        raf2.close()
    }

    @Test
    fun `после освобождения повторная блокировка проходит`() {
        val file = File.createTempFile("modbus_lock_test", ".tmp")
        file.deleteOnExit()

        val raf1 = RandomAccessFile(file, "rw")
        val lock1 = raf1.channel.tryLock()
        assertNotNull(lock1)
        lock1?.release()
        raf1.close()

        val raf2 = RandomAccessFile(file, "rw")
        val lock2 = raf2.channel.tryLock()
        assertNotNull("после освобождения блокировка должна пройти снова", lock2)
        lock2?.release()
        raf2.close()
    }

    @Test
    fun `закрытие дескриптора без явного release снимает блокировку`() {
        // Соответствует сценарию "осиротевший процесс сам освободит порт,
        // когда его убьют" — ОС снимает блокировку при закрытии файлового
        // дескриптора независимо от того, вызывался ли release() явно.
        val file = File.createTempFile("modbus_lock_test", ".tmp")
        file.deleteOnExit()

        val raf1 = RandomAccessFile(file, "rw")
        raf1.channel.tryLock()
        raf1.close() // без release()

        val raf2 = RandomAccessFile(file, "rw")
        val lock2 = raf2.channel.tryLock()
        assertNotNull("блокировка должна была освободиться при закрытии fd", lock2)
        lock2?.release()
        raf2.close()
    }
}
