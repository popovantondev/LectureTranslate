# LectureTranslate · Benutzerhandbuch

<!-- public-release:start -->
Übersetzt deutsche SRT-Untertitel ins Russische mit Zeitcodes, Warteschlange und Entwurfsprüfung.

**macOS 15+ · Apple Silicon · Release 3.5.1**

**[Herunterladen](https://github.com/popovantondev/LectureTranslate/releases/tag/v3.5.1)** · **[Anleitung](https://popovantondev.github.io/LectureTranslate/Guide-de.html)** · **[Fehler melden](https://github.com/popovantondev/LectureTranslate/issues/new/choose)**

**Voraussetzungen und Grenzen:** Separate Verbindung und Anmeldung beim externen Übersetzungsdienst nötig. FFmpeg/ffprobe sind für einzelne Medienfunktionen optional.

**Erste Schritte:** App-Archiv entpacken, Verbindung nach Anleitung einrichten und deutsche .srt hinzufügen. Übersetzungen vor Verwendung prüfen.

**App-Dateien:**

- [`lecture_translate-v3.5.1-app.zip`](https://github.com/popovantondev/LectureTranslate/releases/download/v3.5.1/lecture_translate-v3.5.1-app.zip)

**Prüfsummen:** [`SHA256SUMS`](https://github.com/popovantondev/LectureTranslate/releases/download/v3.5.1/SHA256SUMS)
<!-- public-release:end -->

[Deutsch](README.md) · [Russisch](../ru/README.md) · [Englisch](../en/README.md) · [Zur Projektübersicht](../../README.md)

**Version 3.5.1 · Build 16.** Der Release ist veröffentlicht. Die bisherigen Prüfungen verwenden synthetische Daten und isolierte GUI-Szenarien. [Release 3.5.1 herunterladen](https://github.com/popovantondev/LectureTranslate/releases/tag/v3.5.1).

LectureTranslate ist eine native macOS-App zum Übersetzen deutscher Vorlesungsuntertitel (`.srt`) ins Russische. Cue-IDs und Zeitcodes bleiben erhalten. Die App bietet eine pausierbare Warteschlange, lokale Prüfhinweise und Export als `name.ru.srt`.

**Voraussetzungen:** macOS 15 oder neuer auf Apple Silicon (arm64). Übersetzung und Review benötigen eine separate Verbindung und Anmeldung beim externen Übersetzungsdienst. Einrichtung: [BUILD.md](BUILD.md). FFmpeg/ffprobe sind optional und nur für bestimmte lokale Medienfunktionen erforderlich.

## Screenshots

Die Beispiele verwenden ausschließlich synthetische Daten; Übersetzungsanfragen und Kontozugriff sind im Demo-Modus deaktiviert.

| Helles Design · kompakt | Helles Design · groß |
|---|---|
| ![LectureTranslate auf Deutsch, helles kompaktes Fenster](../screenshots/de/light-compact.png) | ![LectureTranslate auf Deutsch, helles großes Fenster](../screenshots/de/light-large.png) |

| Dunkles Design · kompakt | Dunkles Design · groß |
|---|---|
| ![LectureTranslate auf Deutsch, dunkles kompaktes Fenster](../screenshots/de/dark-compact.png) | ![LectureTranslate auf Deutsch, dunkles großes Fenster](../screenshots/de/dark-large.png) |

## Übersetzen

1. Eine deutsche `.srt`-Datei oder einen Ordner mit Untertiteln hinzufügen.
2. Profil, Textausgabe und Speicherort auswählen.
3. Die Warteschlange starten. Fertige Antworten werden während der Arbeit gesichert; die Warteschlange lässt sich pausieren und fortsetzen.

Zuerst entsteht ein Übersetzungsentwurf; ausgewählte Risikostellen werden anschließend geprüft. Teile derselben Vorlesung werden nacheinander verarbeitet. Verschiedene Vorlesungen können parallel laufen. Unbekannte oder veraltete Kontingentdaten geben keine neuen Übersetzungsanfragen frei; der gemeinsame Höchstwert beträgt 50.

## Prüfen und speichern

Cue-IDs und Zeitcodes sollen aus dem deutschen Original erhalten bleiben. Das normale Ergebnis ist eine UTF-8-SRT-Datei mit dem Suffix `.ru.srt`. Vor dem Speichern Ziele und Bestätigung zum Ersetzen vorhandener Dateien prüfen. Projektdateien können zusätzlich Warteschlange, Übersetzungen und lokale Notizen sichern.

„Übersetzt“, „gespeichert“ und „für Sprachsynthese geprüft“ sind getrennte Zustände. Ein Export mit offenen Hinweisen bestätigt weder Übersetzungsqualität noch Aussprache. Namen, unklare Erkennung, Zahlen, Einheiten, Dosierungen, Negationen und medizinische Aussagen mit dem deutschen Original abgleichen. Lokale Prüfungen können Auffälligkeiten markieren, garantieren aber keine korrekte Aussprache in Silero oder Siri.

Für Silero / Kseniya den Sprachmodus wählen, sofern verfügbar: Zahlen, Einheiten und eindeutige Abkürzungen sollen ausgeschrieben werden. Schwierige Fachbegriffe nicht vereinfachen oder erraten; unklare Erkennung anhand der Quelle klären. Aussprachemarkierungen gehören nicht ins sichtbare SRT.

## Kontingent, Pause und Fortsetzung

Kontingentdaten werden über die angemeldete Verbindung zum Übersetzungsdienst gelesen; API-Kosten zeigt die App nicht an. Der Reservewert ist ein Schutz, keine exakte Garantie, weil laufende Anfragen weiter Kontingent verbrauchen. Keine zweite App-Kopie zum Umgehen von Grenzen starten.

Eine manuelle Pause hat Vorrang vor automatischer Fortsetzung. Nach einer Unterbrechung den gespeicherten Stand öffnen und die Warteschlange fortsetzen; bereits abgeschlossene gespeicherte Antworten sollen nicht erneut angefordert werden. Bei fehlenden, veralteten oder ungültigen Kontingentdaten keine neuen Übersetzungsanfragen starten.

## Video und lokale Daten

Wenn ein lokales Video mit einem Hinweis verknüpft ist, kann die App einen Ausschnitt in der Nähe der betreffenden Stelle öffnen. Verfügbarkeit und Formate hängen von der Datei und den installierten Hilfsprogrammen ab. Ein fehlendes gespeichertes Video darf nicht still durch eine ähnlich benannte Datei ersetzt werden.

Warteschlange, Journale, Nutzungsdaten und Begriffssammlung liegen lokal unter `~/Library/Application Support/LectureTranslator2/`. Projektdateien können Untertiteltexte, Übersetzungen, Notizen und lokale Pfade enthalten; Medien und Zugangsdaten des Übersetzungsdienstes werden nicht automatisch eingepackt. Diese Dateien vertraulich behandeln.

## Datenschutz und Rechte

Übersetzungs- und Review-Texte werden über die angemeldete Verbindung an den externen Dienst übermittelt. Keine echten Vorlesungen, Projektarchive, Logs, Zugangsdaten, persönlichen Pfade oder privaten Screenshots in öffentliche Issues hochladen. Für den Quellcode wird keine offene Lizenz erteilt; ein unverändertes Release-Binary darf persönlich genutzt werden. Details: [Rechte](RIGHTS.md) und [Drittanbieterhinweise](THIRD-PARTY-NOTICES.md).

## Weitere Informationen

[Build und Tests](BUILD.md) · [Änderungen](CHANGELOG.md) · [Rechte](RIGHTS.md) · [Drittanbieterhinweise](THIRD-PARTY-NOTICES.md)
