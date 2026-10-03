import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Релизный ключ подписи. Файл key.properties лежит рядом (android/), ВНЕ
// репозитория (в .gitignore), пароли и путь к хранилищу — только в нём.
// Инструкция по созданию ключа и резервному копированию — docs/signing.md.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        keystorePropertiesFile.inputStream().use { load(it) }
    }
}

android {
    namespace = "com.example.dry_fog_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.dry_fog_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = keystoreProperties.getProperty("storeFile")?.let { file(it) }
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            // Релиз подписывается ТОЛЬКО релизным ключом. Отладочным ключом
            // (общеизвестный пароль) релиз больше не подписывается никогда.
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

// Если key.properties нет, release-сборка ПАДАЕТ с понятным сообщением, а не
// подписывается отладочным ключом молча. Отладочные сборки не затронуты.
gradle.taskGraph.whenReady {
    val releaseRequested = allTasks.any { task ->
        task.project == project && (
            (task.name.startsWith("assemble") || task.name.startsWith("bundle") ||
                task.name.startsWith("package")) && task.name.endsWith("Release")
            )
    }
    if (releaseRequested && !keystorePropertiesFile.exists()) {
        throw GradleException(
            "Релизная сборка требует android/key.properties с данными релизного " +
                "ключа подписи (его нет). Как создать ключ — docs/signing.md. " +
                "Подписывать релиз отладочным ключом запрещено."
        )
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Юнит-тесты CRC16 (задача "смена Slave ID CWT-BK-1616T-S") — обычные
    // локальные JVM-тесты (src/test), не требуют эмулятора/устройства.
    testImplementation("junit:junit:4.13.2")
}
