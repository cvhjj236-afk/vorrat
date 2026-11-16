# Vorrat

Einkaufs- und Vorrats-App für mehrere Haushalte: Einkäufe erfassen, Lagerbestand nach Lagerort oder Kategorie ansehen, Artikel mit einem Tipp entfernen oder wieder auf die Einkaufsliste setzen. Dazu gibt es eigene Rezepte, KI-Rezeptideen aus dem Vorrat und MHD-Erkennung per Foto. Läuft im Browser und lässt sich auf Android über Chrome als App installieren.

## Aufbau

- `index.html`: die ganze App in einer Datei, ohne Build-Schritt.
- `supabase.js`: Browser-Build von supabase-js 2.118.0 (lokal eingebunden, damit die App offline starten kann).
- `manifest.webmanifest`, `sw.js`, `icon-*.png`, `apple-touch-icon.png`: Installierbarkeit und Offline-Start der Oberfläche.

## KI-Fotoauswertung

Mit der Foto-Funktion kannst du einen Kassenbon oder eine Einkaufsliste fotografieren. Die App verkleinert das Bild im Browser auf maximal 1.600 Pixel Kantenlänge und sendet es als JPEG an die Supabase-Edge-Function `scan-receipt`. Die erkannten Artikel kannst du prüfen und bearbeiten, bevor sie in den Vorrat oder auf die Einkaufsliste übernommen werden.

Im Bereich „Rezepte" kannst du eigene Rezepte samt Zutaten speichern und Zutaten auswählen, die auf die Einkaufsliste sollen. Die KI kann außerdem Rezeptideen aus dem aktuellen Lagerbestand vorschlagen. Der „Essensplan" ordnet mehrere Rezepte den einzelnen Wochentagen zu. Bei einem Artikel kannst du das Haltbarkeitsdatum fotografieren und per Gemini erkennen lassen.

Die Beschreibung dieser Funktion wurde mit ChatGPT in die README aufgenommen. ChatGPT hat die Foto-KI-Funktion selbst nicht erstellt; sie war bereits in der App vorhanden.

Der Edge-Function-Code ist unter `supabase/functions/scan-receipt/index.ts` im Repository gespiegelt und wird in Supabase deployt. KI-Schlüssel bleiben als Secrets in Supabase.

## Daten und Zugriff

Daten und Login liegen in Supabase (Tabellen mit Präfix `vorrat_`, Row Level Security). Bestand, gespeicherte Rezepte und Essensplan sind pro Haushalt getrennt. Neue Mitglieder treten mit einem Einladungscode bei, den ein bestehendes Mitglied in der App unter „Haushalt" erzeugt. Der Code gilt 7 Tage und nur einmal.

Der Schlüssel in `index.html` ist der öffentliche „publishable key" und darf im Code stehen. Geheime Schlüssel gehören nie ins Repository.

## E-Mail-Prüfung für KI-Funktionen

Die Edge Function `scan-receipt` prüft vor jedem KI-Aufruf serverseitig mit `auth.getUser()` die Sitzung. Erforderlich sind eine bestätigte E-Mail-Adresse, ein passender Eintrag in der bestehenden, nur serverseitig lesbaren Tabelle `ai_allowlist` und eine Haushaltsmitgliedschaft. Das gilt für Kassenbon, Einkaufsliste, MHD und Rezeptvorschläge. Bei Fehlern der Freigabeprüfung wird der Zugriff abgewiesen. E-Mail-Adressen aus Request-Body oder `user_metadata` werden nicht zur Freigabe verwendet.

Die Freigabeliste wird ausschließlich durch den Backend-Administrator gepflegt. Neue Konten oder Haushalte erhalten dadurch keine automatische Berechtigung für kostenpflichtige KI-Aufrufe. Bestehende Haushaltsmitglieder benötigen ebenfalls einen Freigabeeintrag. Die normalen Vorratsfunktionen bleiben davon unabhängig.

Wichtig für den Betrieb: E-Mail-Bestätigung muss im gehosteten Supabase-Projekt aktiviert sein. Bei eingeschalteter automatischer Bestätigung beweist `email_confirmed_at` allein keinen Postfachzugriff. Diese Repository-Änderung verändert die gehosteten Auth-Einstellungen nicht. Die aktualisierte Edge Function muss separat in Supabase deployt werden; ein Cloudflare-Frontend-Deployment reicht dafür nicht. Die Freigabeliste ersetzt keine zusätzlichen Verbrauchsquoten für freigegebene Konten.

Gezielte lokale Regressionstests mit Node.js 24 oder neuer:

```sh
node tests/scanner-auth.cjs
```

Die Tests prüfen acht erlaubte beziehungsweise abgewiesene Zugriffswege mit simulierten Auth- und Datenbankantworten. Sie senden keine KI-Anfragen und verändern keine Live-Daten.

## Hosting

GitHub Pages, Branch `main`, Wurzelverzeichnis.
