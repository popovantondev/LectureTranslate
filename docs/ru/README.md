<!-- ppk-readme:head:start -->
<a href="https://popovantondev.github.io/LectureTranslate/index-ru.html"><picture><source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/popovantondev/LectureTranslate/main/docs/readme/header-ru-dark.18475cdc.svg"><img src="https://raw.githubusercontent.com/popovantondev/LectureTranslate/main/docs/readme/header-ru-light.f2348d5a.svg" width="880" height="188" alt="LectureTranslate — Переводит немецкие SRT-субтитры на русский. macOS 15+ · Apple Silicon, Выпуск 3.5.1"></picture></a>
<!-- ppk-readme:head:end -->

# LectureTranslate · Руководство пользователя

<!-- public-release:start -->
Переводит немецкие SRT-субтитры на русский с сохранением таймкодов, очередью и проверкой черновика.

**macOS 15+ · Apple Silicon · Выпуск 3.5.1**

**[Скачать](https://github.com/popovantondev/LectureTranslate/releases/tag/v3.5.1)** · **[Инструкция](https://popovantondev.github.io/LectureTranslate/Guide-ru.html)** · **[Сообщить об ошибке](https://github.com/popovantondev/LectureTranslate/issues/new/choose)**

**Требования и ограничения:** Нужны отдельное подключение и вход во внешний сервис перевода. FFmpeg/ffprobe необязательны для отдельных медиафункций.

**Первые шаги:** Распакуйте архив приложения, настройте подключение по руководству и добавьте немецкие .srt. Проверяйте перевод перед использованием.

**Файлы приложения:**

- [`lecture_translate-v3.5.1-app.zip`](https://github.com/popovantondev/LectureTranslate/releases/download/v3.5.1/lecture_translate-v3.5.1-app.zip)

**Контрольные суммы:** [`SHA256SUMS`](https://github.com/popovantondev/LectureTranslate/releases/download/v3.5.1/SHA256SUMS)
<!-- public-release:end -->

[Немецкая версия](../de/README.md) · [Русская версия](README.md) · [Английская версия](../en/README.md) · [Обзор проекта](../../README.ru.md)

<!-- ppk-readme:body:start -->
<p>
<a href="https://github.com/popovantondev/LectureTranslate/releases/tag/v3.5.1"><picture><source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/popovantondev/LectureTranslate/main/docs/readme/btn-download-ru-dark.0b229bad.svg"><img src="https://raw.githubusercontent.com/popovantondev/LectureTranslate/main/docs/readme/btn-download-ru-light.008a5da5.svg" width="120" height="36" alt="Скачать"></picture></a>
<a href="https://popovantondev.github.io/LectureTranslate/index-ru.html"><picture><source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/popovantondev/LectureTranslate/main/docs/readme/btn-website-ru-dark.b19ca91a.svg"><img src="https://raw.githubusercontent.com/popovantondev/LectureTranslate/main/docs/readme/btn-website-ru-light.9a3836ae.svg" width="92" height="36" alt="Сайт"></picture></a>
<a href="https://popovantondev.github.io/LectureTranslate/Guide-ru.html"><picture><source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/popovantondev/LectureTranslate/main/docs/readme/btn-guide-ru-dark.c5d8fca4.svg"><img src="https://raw.githubusercontent.com/popovantondev/LectureTranslate/main/docs/readme/btn-guide-ru-light.053c272f.svg" width="161" height="36" alt="Руководство"></picture></a>
<a href="https://popovantondev.github.io/LectureTranslate/index-ru.html#demo"><picture><source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/popovantondev/LectureTranslate/main/docs/readme/btn-demo-ru-dark.346b0509.svg"><img src="https://raw.githubusercontent.com/popovantondev/LectureTranslate/main/docs/readme/btn-demo-ru-light.d6b1ff03.svg" width="261" height="36" alt="Попробовать в браузере"></picture></a>
<a href="https://github.com/popovantondev/LectureTranslate/issues/new/choose"><picture><source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/popovantondev/LectureTranslate/main/docs/readme/btn-bug-ru-dark.473eba6c.svg"><img src="https://raw.githubusercontent.com/popovantondev/LectureTranslate/main/docs/readme/btn-bug-ru-light.6fea1755.svg" width="234" height="36" alt="Сообщить об ошибке"></picture></a>
</p>

<p><a href="https://raw.githubusercontent.com/popovantondev/LectureTranslate/main/docs/screenshots/ru/light-large.png"><picture><source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/popovantondev/LectureTranslate/main/docs/readme/preview-ru-dark.8c75a02a.webp"><img src="https://raw.githubusercontent.com/popovantondev/LectureTranslate/main/docs/readme/preview-ru-light.bd004472.webp" width="880" height="516" alt="Интерфейс программы LectureTranslate"></picture></a><br>
<sub><a href="https://raw.githubusercontent.com/popovantondev/LectureTranslate/main/docs/screenshots/ru/light-large.png">Снимок целиком</a></sub></p>

<picture><source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/popovantondev/LectureTranslate/main/docs/readme/divider-dark.9c6c8b18.svg"><img src="https://raw.githubusercontent.com/popovantondev/LectureTranslate/main/docs/readme/divider-light.9e9eec0f.svg" width="880" height="6" alt="Разделитель"></picture>
<!-- ppk-readme:body:end -->

**Версия 3.5.1 · build 16.** Релиз опубликован. Ранее выполненные проверки используют искусственные данные и изолированные GUI-сценарии. [Скачать релиз 3.5.1](https://github.com/popovantondev/LectureTranslate/releases/tag/v3.5.1).

LectureTranslate — нативная программа для macOS, переводящая немецкие субтитры лекций (`.srt`) на русский. ID реплик и таймкоды сохраняются. В программе есть очередь с паузой и продолжением, локальные замечания и экспорт в `название.ru.srt`.

**Требования:** macOS 15 или новее на Apple Silicon (arm64). Для перевода и проверки нужны отдельное подключение и вход во внешний сервис перевода. Настройка: [BUILD.md](BUILD.md). FFmpeg/ffprobe необязательны и нужны лишь для отдельных локальных функций работы с медиа.

## Снимки программы

Используются только искусственные данные; в режиме демонстрации запросы к моделям и доступ к аккаунту отключены.

| Светлая тема · компактное окно | Светлая тема · большое окно |
|---|---|
| [LectureTranslate на русском, светлое компактное окно](../screenshots/ru/light-compact.png) | [LectureTranslate на русском, светлое большое окно](../screenshots/ru/light-large.png) |

| Тёмная тема · компактное окно | Тёмная тема · большое окно |
|---|---|
| [LectureTranslate на русском, тёмное компактное окно](../screenshots/ru/dark-compact.png) | [LectureTranslate на русском, тёмное большое окно](../screenshots/ru/dark-large.png) |

## Перевод

1. Добавьте немецкий файл `.srt` или папку с субтитрами.
2. Выберите профиль, формат текста и место сохранения.
3. Запустите очередь. Готовые ответы сохраняются по ходу работы; очередь можно приостановить и продолжить.

Сначала создаётся черновик перевода, затем проверяются выбранные рискованные места. Части одной лекции обрабатываются последовательно; разные лекции могут переводиться параллельно. Неизвестные или устаревшие сведения о лимите не разрешают новые запросы перевода; общий максимум — 50.

## Проверка и сохранение

ID реплик и таймкоды должны сохраняться из немецкого оригинала. Обычный результат — UTF-8 SRT с окончанием `.ru.srt`. Перед сохранением проверьте папку назначения и подтверждение замены существующего файла. Проект может дополнительно хранить очередь, переводы и локальные заметки.

Статусы «переведено», «сохранено» и «проверено для озвучки» различаются. Экспорт с открытыми замечаниями не подтверждает точность перевода или произношения. Сверяйте с оригиналом имена, неясное распознавание, числа, единицы, дозировки, отрицания и медицинские утверждения. Локальная проверка может отметить подозрительные символы, но не гарантирует правильное произношение в Silero или Siri.

Для Silero / Kseniya выбирайте режим текста для озвучки, если он доступен: числа, единицы и однозначные сокращения должны записываться словами. Не упрощайте и не угадывайте сложные термины; неясную транскрипцию сверяйте с источником. Знаки ударения для синтезатора не вставляются в экранные субтитры.

## Лимиты, пауза и продолжение

Сведения о лимитах программа получает через авторизованное подключение к сервису перевода; API-стоимость не рассчитывается. Резерв — это страховка, а не точная гарантия: уже запущенные запросы продолжают расходовать лимит. Не запускайте копию программы для обхода ограничений.

Ручная пауза важнее автоматического продолжения. После остановки откройте сохранённое состояние и продолжите очередь; готовые сохранённые ответы не должны запрашиваться повторно. Если лимит отсутствует, устарел или недостоверен, новые запросы перевода не запускаются.

## Видео и локальные данные

Если с замечанием связано локальное видео, программа может открыть фрагмент около нужного времени. Доступность зависит от файла и вспомогательных программ. Ранее выбранное видео нельзя незаметно заменять похожим файлом, если оно не найдено.

Очередь, журналы, данные об использовании и словарь хранятся локально в `~/Library/Application Support/LectureTranslator2/`. Проект может содержать тексты субтитров, переводы, заметки и локальные пути; медиа и данные входа в сервис автоматически не включаются. Считайте эти файлы приватными.

## Приватность и права

Текст перевода и проверки передаётся внешнему сервису через авторизованное подключение. Не прикладывайте к публичным обращениям настоящие лекции, проектные архивы, журналы, данные доступа, персональные пути или личные снимки экрана. Открытая лицензия на исходный код не предоставляется; неизменённый релизный бинарник разрешено использовать лично. Подробности: [права](RIGHTS.md) и [уведомления о сторонних компонентах](THIRD-PARTY-NOTICES.md).

## Дополнительно

[Сборка и тесты](BUILD.md) · [История изменений](CHANGELOG.md) · [Права](RIGHTS.md) · [Сторонние компоненты](THIRD-PARTY-NOTICES.md)
