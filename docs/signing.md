# Ключ подписи приложения (простыми словами)

Android ставит обновление поверх установленного приложения, только если оно
подписано **тем же ключом**. Поэтому ключ — самое ценное в проекте:

* потеряли ключ → обновить аппараты «по воздуху» нельзя, только удалить
  приложение и поставить заново (данные аппарата пропадут);
* ключ украли и знают пароль → кто-то может выпустить «обновление» для ваших
  аппаратов.

Сейчас релиз подписывается **отладочным** ключом Android с общеизвестным
паролем `android` — так нельзя. Сборка `release` теперь **не запустится**, пока
нет файла `android/key.properties` с настоящим ключом.

## 1. Создайте ключ (один раз)

В терминале (Java берётся из Android Studio). Пути зависят от системы:

| | macOS | Linux | Windows (PowerShell) |
|---|---|---|---|
| Java | `/Applications/Android Studio.app/Contents/jbr/Contents/Home` | `~/android-studio/jbr` (или `/opt/android-studio/jbr`) | `C:\Program Files\Android\Android Studio\jbr` |
| Папка ключей | `~/carfog-keys` | `~/carfog-keys` | `$HOME\carfog-keys` |
| apksigner | `~/Library/Android/sdk/build-tools/<версия>/apksigner` | `~/Android/Sdk/build-tools/<версия>/apksigner` | `$env:LOCALAPPDATA\Android\Sdk\build-tools\<версия>\apksigner.bat` |

macOS / Linux:

```
export JAVA_HOME="<путь Java из таблицы>"
mkdir -p ~/carfog-keys
"$JAVA_HOME/bin/keytool" -genkeypair -v \
  -keystore ~/carfog-keys/carfog-release.jks \
  -alias carfog -keyalg RSA -keysize 4096 -validity 10000
```

Windows (PowerShell):

```
$env:JAVA_HOME = "C:\Program Files\Android\Android Studio\jbr"
New-Item -ItemType Directory -Force "$HOME\carfog-keys"
& "$env:JAVA_HOME\bin\keytool.exe" -genkeypair -v `
  -keystore "$HOME\carfog-keys\carfog-release.jks" `
  -alias carfog -keyalg RSA -keysize 4096 -validity 10000
```

`-validity 10000` — это 10 000 дней, около 27 лет (должно пережить аппараты).
Программа спросит **пароль хранилища** и **пароль ключа** (можно один и тот же)
и ваше имя/организацию. Придумайте длинный пароль (20+ знаков) и сразу сохраните
его в менеджере паролей. **Пароль нигде не пишите в репозиторий, чат и журнал.**

## 2. Сделайте резервные копии (до первой сборки!)

Минимум **две копии файла `carfog-release.jks`** в разных местах:

1. внешний диск/флешка, лежащая **офлайн** (не подключена к компьютеру);
2. зашифрованное облако или менеджер паролей, который умеет хранить файлы.

Пароль — в менеджере паролей (не рядом с файлом). Проверьте, что копию можно
открыть: `keytool -list -keystore <копия> ` (спросит пароль).

## 3. Подключите ключ к сборке

Создайте файл `android/key.properties` (он в `.gitignore`, в репозиторий не
попадёт):

```
storeFile=/Users/<вы>/carfog-keys/carfog-release.jks
# Linux: /home/<вы>/carfog-keys/carfog-release.jks
# Windows: C:/Users/<вы>/carfog-keys/carfog-release.jks  (слэши прямые, не \)
storePassword=<пароль хранилища>
keyAlias=carfog
keyPassword=<пароль ключа>
```

После этого `flutter build apk --release` подписывает релиз вашим ключом.
Без этого файла сборка `release` останавливается с понятным сообщением.

## 4. Проверка

```
~/Library/Android/sdk/build-tools/<версия>/apksigner verify --print-certs \
  build/app/outputs/flutter-apk/app-release.apk
```

В ответе должен быть ваш сертификат (не `CN=Android Debug`). **Отпечаток SHA-256
сертификата (строка `Signer #1 certificate SHA-256 digest`) обязательно
запишите** в надёжное место (менеджер паролей, рядом с резервными копиями
ключа, но не в репозиторий): по нему потом сверяют подлинность обновлений и
проверяют, что ключ не подменили.

## Чего никогда не делать

* не коммитить `key.properties`, `*.jks`, `*.keystore` (они в `.gitignore`);
* не пересылать ключ и пароль в чатах и письмах;
* не менять ключ после выпуска аппаратов без ротации подписи.
