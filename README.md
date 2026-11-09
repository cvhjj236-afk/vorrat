# Vorrat

Einkaufs- und Vorrats-App für den Haushalt: Einkäufe erfassen, Lagerbestand nach Lagerort oder Kategorie ansehen, Artikel mit einem Tipp entfernen, ganzes Lager auf einmal leeren (mit Rückgängig). Läuft im Browser und lässt sich auf Android über Chrome als App installieren.

## Aufbau

- `index.html`: die ganze App in einer Datei, ohne Build-Schritt.
- `supabase.js`: Browser-Build von supabase-js 2.118.0 (lokal eingebunden, damit die App offline starten kann).
- `manifest.webmanifest`, `sw.js`, `icon-*.png`, `apple-touch-icon.png`: Installierbarkeit und Offline-Start der Oberfläche.

## KI-Fotoauswertung

Mit der Foto-Funktion kannst du einen Kassenbon oder eine Einkaufsliste fotografieren. Die App verkleinert das Bild im Browser auf maximal 1.600 Pixel Kantenlänge und sendet es als JPEG an die Supabase-Edge-Function `scan-receipt`. Die erkannten Artikel kannst du prüfen und bearbeiten, bevor sie in den Vorrat oder auf die Einkaufsliste übernommen werden.

Die Foto-KI-Funktion ist mit Unterstützung von ChatGPT entstanden. Der Edge-Function-Code und die verwendete KI-Konfiguration liegen in Supabase, nicht in diesem Repository.

## Daten und Zugriff

Daten und Login liegen in Supabase (Tabellen mit Präfix `vorrat_`, Row Level Security). Den Bestand sehen nur Mitglieder des Haushalts. Neue Mitglieder treten mit einem Einladungscode bei, den ein bestehendes Mitglied in der App unter „Haushalt" erzeugt. Der Code gilt 7 Tage und nur einmal.

Der Schlüssel in `index.html` ist der öffentliche „publishable key" und darf im Code stehen. Geheime Schlüssel gehören nie ins Repository.

## Hosting

GitHub Pages, Branch `main`, Wurzelverzeichnis.
