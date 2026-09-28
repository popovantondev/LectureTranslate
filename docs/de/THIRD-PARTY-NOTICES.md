# Hinweise zu Drittanbietern

LectureTranslate erteilt keine Open-Source-Lizenz für den eigenen Quellcode. Die folgenden Werkzeuge und Plattformkomponenten sind separate Produkte und werden nur dann mit Quellarchiv oder App ausgeliefert, wenn ein Release dies ausdrücklich angibt. Die Nutzungsrechte am eigenen Code und an unveränderten Release-Binärdateien stehen in [Rechte und erlaubte Nutzung](RIGHTS.md).

| Komponente | Verwendung | Bereitstellung und Bedingungen |
|---|---|---|
| macOS, Swift, SwiftUI, AppKit, AVKit | Betriebssystem, Compiler, Oberfläche und Videowiedergabe | Von Apple bereitgestellt; es gelten Apples jeweilige Software- und Plattformbedingungen. |
| Codex CLI | Lokale Kommandozeilenintegration für Übersetzung und Prüfung | Separat vom Benutzer installiert; unterliegt den jeweils geltenden OpenAI-Produktbedingungen und Kontingenten. Nicht Teil von LectureTranslate. |
| ChatGPT | Anmeldung und Modellzugriff über Codex CLI | OpenAI-Dienst; Konto und Kontingente unterliegen den Dienstbedingungen. |
| FFmpeg und ffprobe | Optionale lokale Audio-/Videoverarbeitung | Separat installiert; die Lizenz eines FFmpeg-Builds hängt von seiner Konfiguration ab. Bedingungen und Hinweise des verwendeten Builds prüfen. |

LectureTranslate enthält keine Modellgewichte, Vorlesungsaufnahmen oder die genannten optionalen Werkzeuge. Das Projekt beansprucht keine Rechte an Marken Dritter.
