# Подключение Syntholoc OTA в мобильных приложениях

Первое подключение требует обычного релиза приложения с SDK и встроенными переводами.
После этого Syntholoc доставляет обновления переводов без новой сборки приложения.
Встроенные переводы остаются обязательным fallback для первого запуска и работы без сети.

## Получение SDK

SDK распространяются публично и не требуют доступа к приватному проекту Syntholoc,
GitHub-аккаунта или токена для скачивания. Нативные пакеты не связаны с npm:

- Android: готовые Maven-артефакты `com.syntholoc:ota:0.1.1` и
  `com.syntholoc:ota-compose:0.1.1`, исходники и теги в
  [syntholoc-sdk-android](https://github.com/SergiyIva/syntholoc-sdk-android).
- iOS: SwiftPM из [syntholoc-sdk-ios](https://github.com/SergiyIva/syntholoc-sdk-ios),
  продукты `SyntholocOTA` и `SyntholocOTASwiftUI`, версия `0.1.1`.
- Новые версии SDK публикуются автоматически при изменениях SDK в основном проекте.
  Приложение явно обновляет закреплённую версию зависимости.

Android SDK проверен на эмуляторе. Swift-ядро проверено на Linux; сборка Apple/SwiftUI
в Xcode и проверка iOS UI пока не выполнены и обязательны перед production-интеграцией.

## 1. Подготовить distribution в кабинете

В проекте Syntholoc открыть **Translation delivery** и создать distribution для
соответствующего приложения. Мобильной команде передать следующие настройки:

| Параметр           | Значение                                                           |
| ------------------ | ------------------------------------------------------------------ |
| Origin             | `https://api.syntholoc.com`                                        |
| Distribution ID    | Публичный ID из кабинета                                           |
| Channel            | `staging` для QA, затем `production`                               |
| Catalog version    | Например, `android-v1` или `ios-v1`                                |
| Locale key         | Например, `ru`; должен совпадать с mapping в distribution          |
| Fallback locales   | Например, `en`; все запрошенные локали должны входить в публикацию |
| Bundles/namespaces | Например, `app`; полный набор должен соответствовать приложению    |
| Доступ             | PUBLIC либо PROTECTED с отдельным delivery key                     |

Для distribution нужен baseline: исходные ключи и строки именно установленной версии
приложения, включая placeholders. Создание distribution фиксирует этот контракт.
`catalogVersion` обозначает контракт каталога, а не версию SDK или npm-пакета.
При несовместимом изменении ключей, placeholders или структуры каталогов потребуется
новый контракт и соответствующая сборка приложения.

Выбрать source files, namespaces и явные locale mappings. Состав `bundles` в клиенте
должен включать все обязательные bundles distribution. Дополнительный `master` нужен
только приложениям, которые действительно используют этот каталог.

Для JSON политика `OMIT` позволяет отсутствующим переводам использовать встроенные
строки. Для неполных нативных шаблонов, включая `.xcstrings`, использовать `SOURCE`:
`OMIT` для них не поддерживается. При `SOURCE` отсутствующий перевод заполняется
исходным текстом. Несовместимые placeholders и форматирование исправлять через обычный
review; не отмечать такие переводы массово как APPROVED.

## 2. Подключить Android

### Зависимости

Требования приложения: Android API 24+, Java 17, Kotlin 2.2 или совместимый новее.
Готовые AAR не требуют самостоятельной сборки SDK. Исходники собираются с Gradle 8.13
и Android SDK 35; для Compose используется линия AndroidX Compose 1.6.8.

В `settings.gradle.kts` приложения добавить публичный Maven-репозиторий:

```kotlin
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        maven {
            url = uri("https://raw.githubusercontent.com/SergiyIva/syntholoc-sdk-android/maven")
            content { includeGroup("com.syntholoc") }
        }
    }
}
```

В `build.gradle.kts` app-модуля:

```kotlin
dependencies {
    implementation("com.syntholoc:ota:0.1.1")

    // Если используется Compose:
    implementation("com.syntholoc:ota-compose:0.1.1")
}
```

Эта конфигурация работает одинаково локально и на CI без credentials и `mavenLocal()`.
Не использовать динамическую версию `+`. Версии и контрольные суммы доступны в
[публичном Maven](https://github.com/SergiyIva/syntholoc-sdk-android/tree/maven/com/syntholoc).

В `AndroidManifest.xml` приложения требуется разрешение:

```xml
<uses-permission android:name="android.permission.INTERNET" />
```

### Создание клиента и обновление

Создать один клиент на выбранный язык и канал, например в application-scoped DI.
Кеш и сетевые операции выполнять вне main thread:

```kotlin
import android.content.Context
import com.syntholoc.ota.OtaClient
import com.syntholoc.ota.OtaConfig
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

suspend fun initializeOta(context: Context): OtaClient =
    withContext(Dispatchers.IO) {
        OtaClient(
            OtaConfig(
                baseUrl = "https://api.syntholoc.com",
                distributionId = "DISTRIBUTION_PUBLIC_ID",
                channel = "staging",
                catalogVersion = "android-v1",
                localeKey = "ru",
                fallbackLocaleKeys = listOf("en"),
                bundles = setOf("app")
            ),
            File(context.filesDir, "syntholoc-ota")
        ).also { it.loadCached() }
    }

suspend fun refreshOta(ota: OtaClient) = withContext(Dispatchers.IO) {
    val update = ota.checkForUpdates()
    if (update.status == "available") {
        ota.activate(requireNotNull(update.releaseId))
    }
}
```

Coroutines в примере принадлежат приложению: core SDK не добавляет эту зависимость.
Сначала приложение может показать встроенные строки. После `initializeOta` установить
клиент в localization provider/UI state, затем проверять сеть в фоне. Пример активирует
обновление сразу; в production вызов `activate` можно отложить до выбранной границы UI.

### Подключение к существующему provider

Для JSON-каталогов поставить OTA lookup перед встроенным lookup:

```kotlin
fun localized(key: String): String =
    ota.string("app", key) {
        bundledLookup(key)
    }
```

`bundledLookup` — существующая функция чтения встроенного каталога. Она должна работать
напрямую, без повторного обращения к OTA, иначе получится рекурсия. Существующее
форматирование строк сохранить после lookup. Ключи с точками, например `screen.title`,
передавать без преобразования в Android resource names.

Проверить приоритет существующих локальных overrides: они не должны незаметно
перекрывать активированные OTA-переводы.

В существующем Composable использовать snapshot, чтобы экран обновлялся после активации:

```kotlin
import com.syntholoc.ota.compose.rememberOtaSnapshot

val snapshot = rememberOtaSnapshot(ota)

Text(
    snapshot.string("app", "screen.title") {
        bundledTitle
    }
)
```

Здесь `bundledTitle` — встроенный текст выбранной локали. Клиент передаётся из DI или
состояния приложения; не создавать его заново при каждой recomposition.

Для приложений на `R.string` предусмотрены `OtaResources` и Compose-функция
`rememberOtaResources`. При XML inflation дополнительно вызывать
`provider.localize(view, attrs)` из существующего `LayoutInflater.Factory2` после
создания каждого View. Сохранить AppCompat/Fragment factory как создателя View.
После активации существующие Views нужно явно обновить либо пересоздать.

При смене языка/канала создать новый клиент и переключить provider/UI state.
Старый клиент закрыть через `close()`.

## 3. Подключить iOS

### Swift Package

Минимум: iOS 15, Swift tools 5.9.

В Xcode → **Add Package Dependencies** добавить публичный HTTPS URL:

```text
https://github.com/SergiyIva/syntholoc-sdk-ios.git
```

Выбрать **Exact Version: 0.1.1**. Подключить продукт `SyntholocOTA`;
для SwiftUI дополнительно `SyntholocOTASwiftUI`. Вход в GitHub не нужен.

Для проекта с `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/SergiyIva/syntholoc-sdk-ios.git", exact: "0.1.1")
]
// В dependencies нужного target:
// .product(name: "SyntholocOTA", package: "syntholoc-sdk-ios")
// .product(name: "SyntholocOTASwiftUI", package: "syntholoc-sdk-ios")
```

Зафиксировать `Package.resolved` в проекте приложения, чтобы CI использовал ту же версию.

### Клиент и существующий localization provider

Создать один actor-клиент на выбранный язык и канал:

```swift
import Foundation
import SyntholocOTA

let support = try FileManager.default.url(
    for: .applicationSupportDirectory,
    in: .userDomainMask,
    appropriateFor: nil,
    create: true
)

let ota = try OtaClient(
    configuration: OtaConfiguration(
        baseURL: URL(string: "https://api.syntholoc.com")!,
        distributionId: "DISTRIBUTION_PUBLIC_ID",
        channel: "staging",
        catalogVersion: "ios-v1",
        localeKey: "ru",
        bundles: ["app"],
        fallbackLocaleKeys: ["en"]
    ),
    cacheDirectory: support.appendingPathComponent("syntholoc-ota")
)
```

В асинхронной инициализации загрузить кеш и создать синхронный provider из snapshot:

```swift
await ota.loadCached()

let snapshot = await ota.snapshot()
let provider = snapshot.provider(
    bundle: .main,
    tables: ["Localizable": "app"]
)

let title = provider.localizedString(forKey: "screen.title")
```

Подключить provider в существующую функцию локализации приложения. Хранить provider
в UI state на MainActor. Таблицы Bundle сопоставлять с namespaces явно; встроенный
Bundle lookup остаётся fallback.

Проверка и активация:

```swift
if case let .available(releaseId) = await ota.checkForUpdates() {
    try await ota.activate(releaseId)

    let updatedSnapshot = await ota.snapshot()
    let updatedProvider = updatedSnapshot.provider(
        bundle: .main,
        tables: ["Localizable": "app"]
    )
    // Установить updatedProvider в UI state на MainActor и обновить экран.
}
```

Snapshot неизменяемый: старый provider не начинает читать новый release автоматически.
Можно подписаться на `await ota.activations()` и пересоздавать provider после активации.
При смене языка или канала создать новый клиент и переключить localization provider.

### SwiftUI

Создать `OtaLocalization(client: ota)` на MainActor как объект приложения и передать
его через `.environmentObject(localization)`. Он загружает кеш и наблюдает активации.

```swift
import SyntholocOTASwiftUI

OtaText(
    "screen.title",
    namespace: "app",
    fallback: Bundle.main.localizedString(
        forKey: "screen.title",
        value: nil,
        table: "Localizable"
    )
)
```

Обновление выполняется через `localization.stageUpdates()`, активация — через
`localization.activate(releaseId)`. Adapter обновляет snapshot для SwiftUI.

Для строк с аргументами использовать typed formatting, например:

```swift
let message = snapshot.formatted(
    namespace: "app",
    key: "items",
    arguments: [.integer(3)],
    fallback: bundledFormattedMessage
)
```

`bundledFormattedMessage` должен быть уже отформатированным встроенным значением.
Доступны `.integer(Int64)`, `.number(Double)`, `.decimal(String)` и `.string(String)`.
Для device variations передавать действительный `OtaDevice`, например `.iphone`.

## 4. Жизненный цикл, доступ и fallback

- Показывать встроенные строки сразу, затем загружать кеш и проверять сеть в фоне.
  Не делать запуск приложения зависимым от ответа OTA.
- Проверять обновления при запуске и возврате в foreground. SDK учитывает интервал
  проверок: по умолчанию 15 минут. Постоянный таймер SDK не создаёт.
- Скачивание создаёт candidate. UI меняется только после явного `activate`.
  Выбрать безопасную границу активации, например перед открытием следующего экрана.
- Для PROTECTED передать `credential` callback в конфигурацию: синхронный на Android,
  async/throwing на Swift. Он должен возвращать delivery key для чтения каталога.
  npm-токен и административный API key в приложение не добавлять.
- Delivery key в установленном приложении извлекаем; он ограничивает чтение каталога
  и не должен давать административные права. После замены ключа вызвать
  `resetFailureState()` и повторить проверку.
- При ошибках сети, кеша или проверки целостности сохраняется последняя рабочая
  локализация; при отсутствии рабочего OTA-кеша используются встроенные строки.
- Для ручной QA-проверки доступен `checkForUpdates(forceRefresh: true)` на Swift и
  `checkForUpdates(forceRefresh = true)` на Android. Этот флаг не отменяет auth suspension,
  server backoff и проверки целостности.
- В диагностике сохранять release ID, язык, канал, catalog version и код ошибки.
  Не записывать delivery key в логи.

## 5. QA и включение production

В кабинете выполнить **Build → READY → публикация в `staging`**.
`staging` и `production` — каналы одного origin; отдельный staging-сервер не нужен.

Проверить на приложении:

1. Первый запуск без сети показывает встроенные строки.
2. После проверки обновления текст меняется только при активации.
3. Активированный перевод сохраняется между запусками без сети.
4. Отсутствующий JSON-ключ использует bundled fallback согласно выбранной политике.
5. Форматирование, plurals, device variations и смена языка работают.
6. Rollback канала возвращает предыдущие переводы после проверки и активации клиентом.
7. Ошибка сети или доступа сохраняет последнюю рабочую локализацию.
8. Сборка iOS проходит в Xcode; нативные adapters проверены на устройстве/эмуляторе.

После QA продвинуть **тот же release ID** в `production`.
Production-сборка приложения должна читать канал `production` и соответствующую
distribution/catalog version.

