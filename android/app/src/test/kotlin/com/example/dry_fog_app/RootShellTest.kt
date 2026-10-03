package com.example.dry_fog_app

import org.junit.Assert.assertEquals
import org.junit.Test

// Цитирование аргументов для su/sh: в имени файла или параметре не должно быть
// возможности «выйти» из кавычек и выполнить лишнее.
class RootShellTest {
    @Test
    fun `plain argument is single-quoted`() {
        assertEquals("'abc'", RootShell.shQuote("abc"))
    }

    @Test
    fun `single quote is escaped`() {
        assertEquals("'a'\\''b'", RootShell.shQuote("a'b"))
    }

    @Test
    fun `shell metacharacters stay inside quotes`() {
        assertEquals("'x; rm -rf / \$(id) `id`'", RootShell.shQuote("x; rm -rf / \$(id) `id`"))
    }

    @Test
    fun `empty argument`() {
        assertEquals("''", RootShell.shQuote(""))
    }
}
