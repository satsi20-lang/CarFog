package com.example.dry_fog_app

import android.content.ComponentName
import android.content.Context

// Имена компонентов приложения, не зависящие от applicationId.
//
// Класс/алиас в манифесте объявлен относительно namespace
// (android:name=".KioskHomeAlias" → "<namespace>.KioskHomeAlias"), а
// applicationId (имя пакета на устройстве) может отличаться от namespace:
// после смены applicationId строка "$packageName.KioskHomeAlias" указывала бы
// на несуществующий компонент и ломала включение киоска. Здесь пакет берётся
// из контекста (applicationId), а имя класса — из namespace Kotlin-кода.
object ComponentNames {
    private val namespace: String =
        MainActivity::class.java.`package`!!.name

    // Полное имя класса в namespace (чистая функция — проверяется тестом).
    internal fun className(namespace: String, simple: String): String =
        "$namespace.$simple"

    fun mainActivityClass(): String = className(namespace, "MainActivity")
    fun kioskAliasClass(): String = className(namespace, "KioskHomeAlias")

    fun kioskHomeAlias(context: Context): ComponentName =
        ComponentName(context.packageName, kioskAliasClass())
}
