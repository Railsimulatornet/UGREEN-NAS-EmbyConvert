# EmbyConvert für UGREEN DXP NAS (Intel QSV)

[![Quality](https://github.com/Railsimulatornet/UGREEN-NAS-EmbyConvert/actions/workflows/quality.yml/badge.svg?branch=main)](https://github.com/Railsimulatornet/UGREEN-NAS-EmbyConvert/actions/workflows/quality.yml)
[![CodeQL](https://github.com/Railsimulatornet/UGREEN-NAS-EmbyConvert/actions/workflows/codeql.yml/badge.svg?branch=main)](https://github.com/Railsimulatornet/UGREEN-NAS-EmbyConvert/actions/workflows/codeql.yml)

![EmbyConvert](Screens/EmbyConvert.png)

Dieses Projekt ist ein fertiges **DockerPack** für UGREEN **DXP**-Modelle (Intel iGPU), um Medienbibliotheken automatisiert nach **HEVC (H.265)** zu konvertieren und regelmäßige **E-Mail-Reports** zu versenden.

- Sprache: **Deutsch** (siehe `README_EN.md` für Englisch)
- Zielsystem: **UGREEN DXP (Intel QSV / /dev/dri)**

## Inhalt

- **Docker Compose** für `linuxserver/ffmpeg` mit Intel **Quick Sync (QSV)**
- Batch-Konvertierung: `hevc_batch.sh` (Resume/Watch)
- Report-Skripte: Duplikate-Report + Wochenreport (Python)
- Handbuch als PDF (DE/EN)
- Screenshot-Beispiel für Mail-Report

## Ordnerstruktur

- `de/` – deutsches Paket inkl. PDF-Handbuch und Screenshots
- `en/` – englisches Paket inkl. PDF-Handbuch und Screenshots
- `release-assets/` – fertige ZIPs für GitHub Releases (werden nicht committed)

## Schnellstart (UGREEN Docker App)

1. Dieses Repo in dein Docker-Verzeichnis kopieren (z.B. `/volume2/docker/EmbyConvert`).
2. In `de/EmbyConvert/embyconvert_mail.env` deine Werte anpassen (UID/GID, SMTP, Pfade).
3. Projekt in der UGREEN Docker App importieren (Compose) und starten.
4. Details und Beispiele findest du im PDF-Handbuch:
   - DE: `de/EmbyConvert_Anleitung_DE_v1.1.pdf`
   - EN: `en/EmbyConvert_Manual_EN_v1.1.pdf`

## Prüfung der Ausgabedateien

Mit `VERIFY_OUTPUT=1` werden Bild und Ton vor dem Übernehmen der temporären
Ausgabedatei vollständig dekodiert. Dekodierfehler oder eine abweichende Laufzeit der Hauptvideospur
verwerfen den neuen Output; eine bereits vorhandene Zieldatei bleibt erhalten.
Für Zeitstempel und Paketgrenzen beträgt die Laufzeittoleranz 1 %, mindestens
0,25 und höchstens 2 Sekunden. Verglichen wird die Spanne der Präsentationszeitstempel
von `v:0`, einschließlich der letzten Paketdauer. Längere abgewählte Audiospuren
und verschobene Startzeitstempel beeinflussen diesen Vergleich nicht; eine fehlende
Container- oder Stream-Dauerangabe bei MKV ist ebenfalls unproblematisch.
Nicht zuverlässig ermittelbare Videozeitspannen werden abgelehnt. Die vollständige Prüfung benötigt zusätzliche
CPU-Zeit. Die Quelldateien bleiben im Compose-Paket schreibgeschützt eingebunden.

Die automatisierten Tests verwenden ausschließlich künstliche Miniclips und
einen simulierten Encoder: `python3 -m unittest discover -s tests -v`.

## Screenshots

| Mail-Report Beispiel |
|---|
| ![Mail-Report](de/Screens/Mail.jpg) |

