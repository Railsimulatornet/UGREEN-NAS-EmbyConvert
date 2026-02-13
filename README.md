# EmbyConvert für UGREEN DXP NAS (Intel QSV)

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

## Screenshots

| Mail-Report Beispiel |
|---|
| ![Mail-Report](de/Screens/Mail.jpg) |

## Releases

Empfohlen: ZIPs über **GitHub Releases** bereitstellen (DE/EN getrennt).
