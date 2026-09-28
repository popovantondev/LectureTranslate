# Build und lokale Tests

## Voraussetzungen

macOS 15 oder neuer, Apple Silicon, Apple Command Line Tools (Swift), Bash und Ruby. Für Übersetzung und Review wird das lokal installierte Codex CLI mit ChatGPT-Anmeldung benötigt. Die lokale Build- und Test-Suite ruft keine Modelle auf. FFmpeg/ffprobe sind optional und werden nur für bestimmte Medienfunktionen verwendet.

## Bekannter Stand dieses Checkouts

`VERSION`, `BUILD_NUMBER` und `Info.plist` stimmen mit **3.5.1 / Build 16** überein. Der letzte gespeicherte Release davor ist 3.4.3 / Build 13; ältere Release-Verzeichnisse bleiben unverändert.

Der vollständige Offline-Testlauf bestand aus 2473 lokalen Prüfungen, darunter 64 Video-Preview- und 14 Release-Validierungen. Die zwölf Demo-Fenster (3 Sprachen × 2 Themes × 2 Größen) wurden echt geöffnet; zusätzliche isolierte Szenarien prüften Diagnose, Einstellungen, Export mit Warnung, Dateiersetzung mit Sicherung sowie Speichern und Fortsetzen eines Projekts. Nutzerdaten wurden nicht verwendet.

## Lokale Befehle

Im Projektverzeichnis:

```sh
bash Scripts/test-all.sh
bash Scripts/build.sh --preview
```

Tests verwenden synthetische Daten und isolierte temporäre Zustände. Sie starten keine Übersetzung, lesen keinen Account und ändern keine Benutzerdaten.

- `bash Scripts/test-all.sh` — verbundene lokale Test-Suite.
- `bash Scripts/test-model.sh` — Pause und Fortsetzen mit einer isolierten Testwarteschlange, ohne Modellaufruf.
- `bash Scripts/test-quota.sh` — CLI-Pfad, Fehlerdiagnose, Timeout und Abbruch anhand lokaler Fixtures.
- `bash Scripts/test-speech.sh` — lokale Erkennung verdächtiger Zahlen, Einheiten, Abkürzungen und Zeichen.
- `bash Scripts/test-project.sh` — Speichern, Integritätsprüfung und Öffnen von `.lectureproject`.
- `bash Scripts/test-instance-lock.sh` — Instanzsperre und Owner-Suche.
- `ruby Tests/ReleaseTests.rb` — Release- und Archivprüfungen ohne Modell.
- `bash Scripts/build.sh --preview` — isolierte Preview-App unter `.build`; überschreibt keinen Release-Ordner.

Bereits erstellte `dist/vX.Y.Z`- und `releases/vX.Y.Z`-Ordner nicht manuell ändern. Release-Builds verweigern das Überschreiben vorhandener Ziele.

## macOS-Hinweis

Das geplante ZIP ist nicht mit Developer ID signiert und nicht von Apple notarisiert; macOS kann beim ersten Öffnen warnen. Eine lokale Ad-hoc-Signatur ersetzt weder Developer ID noch Notarisierung.

Weitere Details stehen in der deutschen [Projektübersicht](README.md). Das interne Prüfprotokoll ist nicht Teil dieses öffentlichen Dokumentationssatzes.
