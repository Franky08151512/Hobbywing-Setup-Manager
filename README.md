# Hobbywing Setup Manager – iOS-Projekt

Dieses Repository enthält ein iOS-App-Grundgerüst für den Hobbywing Setup Manager (EZRUN MINI28 / Mini-Z).

## Enthalten
- SwiftUI-App-Shell mit lokal gebündelter Oberfläche
- Projektdefinition für XcodeGen
- GitHub Actions Workflow für einen macOS/iOS-Build

## Build
Der Workflow baut ein **unsigniertes** iOS-Artefakt (`HobbywingSetupManager-unsigned.ipa`). Das ist noch keine installierbare, signierte App. Signierung und Installation auf dem iPhone müssen separat eingerichtet und auf dem konkreten Gerät getestet werden.

## Status / bekannte Einschränkung
Dies ist ein technisches Grundgerüst, kein fertig getestetes Produkt. Insbesondere Dateiimport, dauerhafte lokale Speicherung und Export/Backup müssen im nativen iOS-Kontext verifiziert und gegebenenfalls in Swift implementiert werden. Die eingebettete HTML-Oberfläche stammt aus dem bisherigen Prototyp.

Persönliche Hobbywing-TXT-Setups und Backups gehören **nicht** in dieses öffentliche Repository.
