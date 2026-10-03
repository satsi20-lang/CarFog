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

// Имена классов собираются из namespace, а не из applicationId: при пакете
// ee.carfog.dryfog класс остаётся com.example.dry_fog_app.MainActivity.
class ComponentNamesTest {
    @Test
    fun `class name uses namespace`() {
        assertEquals(
            "com.example.dry_fog_app.MainActivity",
            ComponentNames.className("com.example.dry_fog_app", "MainActivity")
        )
        assertEquals(
            "x.y.KioskHomeAlias",
            ComponentNames.className("x.y", "KioskHomeAlias")
        )
    }

    @Test
    fun `namespace of compiled classes matches manifest relative names`() {
        assertEquals("com.example.dry_fog_app.MainActivity", ComponentNames.mainActivityClass())
        assertEquals("com.example.dry_fog_app.KioskHomeAlias", ComponentNames.kioskAliasClass())
    }
}
