# Übergabe Vorrat

Gemeinsames Gedächtnis für alle, die an der App arbeiten (Simon, Claude, ChatGPT). Am Anfang jeder Sitzung lesen, nach jeder Arbeit unten einen Eintrag ergänzen.

## Aktueller Stand (2026-11-10)
- App: index.html, Service-Worker-Cache `vorrat-v13`
- Live: https://cvhjj236-afk.github.io/vorrat/ (Pages aus main, Deploy dauert 1–2 Min.)
- Supabase-Projekt "Urlaubsapp" (wpxoddfaczbhxnmfidoj), enthält auch Daten einer anderen App: nur `vorrat_*` und die Funktion `scan-receipt` anfassen
- Mehrere Haushalte pro Konto, Umschalter im Haushalt-Menü
- Foto-Scan über Edge Function `scan-receipt` mit Gemini (Modell gemini-3.5-flash-lite)
- Eigene Rezepte in `vorrat_recipes`, pro Haushalt mit RLS und Realtime; Feld `favorite` für gemeinsame Haushaltsfavoriten
- Rezeptkategorien: Frühstück, Hauptgerichte, Suppen & Eintöpfe, Salate & Beilagen, Snacks & Kleinigkeiten, Nachspeisen & Backen. Mehrfachauswahl; leere Liste = Ohne Kategorie. Filter in Bibliothek und Essensplan, KI schlägt Kategorien vor.
- Rezeptbibliothek: Gespeichert / ★ Favoriten / KI-Ideen, kompakte Karten mit „Rezept öffnen“, Zutaten/Zubereitung und Bearbeiten; auch KI-Ideen können vor dem Speichern bearbeitet werden
- Essensplan: mehrere gespeicherte Rezepte pro Wochentag in `vorrat_mealplan`, pro Haushalt mit RLS und Realtime
- Rezeptauswahl im Essensplan über „+ Rezepte“: durchsuchbare Checkboxliste, mehrere Rezepte gemeinsam hinzufügen
- Gemini-Modi für Rezeptideen und MHD-Erkennung zusätzlich zum Foto-Scan
- `supabase/functions/scan-receipt/index.ts` entspricht deployter Version 13; Verify JWT ist aktiv; Bon-/Einkaufszettel-Flow wie Version 10

## Datenbank
Tabellen: vorrat_households, vorrat_members (mehrere Zeilen pro Konto möglich), vorrat_active, vorrat_invites, vorrat_items, vorrat_products (PK household_id + key), vorrat_recipes, vorrat_mealplan (PK household_id + plan_date + recipe_name). Rezepte, Essensplan und Vorratstabellen mit RLS: sichtbar nur, wenn household_id = vorrat_my_household(). `vorrat_recipes`, `vorrat_mealplan` und `vorrat_items` sind in `supabase_realtime`.
Funktionen: vorrat_my_household, vorrat_my_households, vorrat_switch_household, vorrat_create_household, vorrat_rename_household, vorrat_leave_household, vorrat_join, vorrat_create_invite, vorrat_is_member.
Item-Status: "in" Lager, "list" Einkaufsliste, "used"/"gone" entnommen bzw. übernommen.

## Regeln
- Simon hat am 2026-11-10 festgelegt: fertige, getestete Änderungen an Vorrat immer direkt live schalten; keine zusätzliche Release-Rückfrage nötig.
- Bei jeder Änderung an index.html die Cache-Version in sw.js erhöhen
- Datenbankänderungen: SQL vorher zeigen, bestehende Daten und die Trennung pro Haushalt nie gefährden, hier eintragen
- Secrets (GOOGLE_API_KEY, GEMINI_MODEL) nie ausgeben oder in Code schreiben, "Verify JWT" der Funktion bleibt an
- Eine einzelne index.html, keine Frameworks, deutsche Texte in Du-Form

## Offene Punkte
- Gemini-Prompt (`const prompt =` in scan-receipt) verbessern, sobald Simon falsch gelesene Beispiele sammelt
- KI-Rezeptideen und MHD-Erkennung mit echten Fotos bzw. Vorratsbeispielen prüfen

## Verlauf
- 2026-11-10 (Claude): Mehrere Haushalte pro Konto (Datenbank-Migration + Umschalter), Cache v6, bestehende Daten in Haushalt "Unser Haushalt" übernommen
- 2026-11-10 (ChatGPT): Deployte `scan-receipt`-Edge-Function Version 10 unverändert unter `supabase/functions/scan-receipt/index.ts` abgelegt; Übergabe aktualisiert, veralteten offenen Punkt entfernt
- 2026-11-10 (ChatGPT): KI-Rezeptideen, eigene Rezepte mit wählbaren Zutaten, Verbrauchte Artikel auf die Einkaufsliste setzen und MHD-Fotoerkennung ergänzt; Tabelle `vorrat_recipes` mit RLS/Realtime; Edge Function Version 12 mit unverändertem Bon-/Einkaufszettel-Flow; Cache v7
- 2026-11-10 (ChatGPT): Wochen-Essensplan ergänzt, mehrere Rezepte pro Tag; neue Tabelle `vorrat_mealplan` mit Haushalts-RLS/Realtime; Cache v8

- 2026-11-10 (ChatGPT): Mobile UI korrigiert: Navigation unter 600 px in zwei Reihen, Wochensteuerung umgebrochen, MHD-Feld über volle Formularbreite, schmale Rezept-/Planfelder und Verbrauchshinweis angepasst; ausgeblendete Aktionsbuttons wirklich verborgen; Cache v9. Vollständige angemeldete Browser-Funktionstests noch offen (Testsitzung nicht angemeldet).

- 2026-11-10 (ChatGPT): Angemeldeter Browsertest: Artikel anlegen/entnehmen, Nachkaufen, Gekauft erfolgreich; Rezepteditor geöffnet, zwei Rezepte am selben Tag zugeordnet und Testzuordnungen entfernt. Testartikel und Produktvorlage bereinigt. Essensplan-Auswahl bleibt bei Realtime-Neurendern erhalten, doppelte Rezeptnamen im Auswahlmenü entfernt; Cache v10. Haushaltswechsel mangels zweitem Haushalt nicht getestet; Fotoauswertung mit echten Bildern weiterhin offen.

- 2026-11-10 (ChatGPT): Dropdowns im Essensplan durch aufklappbare Rezeptauswahl je Tag ersetzt: Suche, große Checkboxzeilen, Mehrfachauswahl und gemeinsames Hinzufügen mit einem Insert. Bereits eingeplante Rezepte werden ausgeblendet; Suche/Auswahl bleiben beim Neurendern erhalten. Abbrechen und Wochen-/Haushaltswechsel verwerfen den Auswahlentwurf; Speicherfehler erscheinen direkt bei der Auswahl. Cache v11. Browserprüfung mit lokalen, rein speicherinternen Testdaten: Suche, Mehrfachauswahl, Hinzufügen/Entfernen, Abbrechen, Wochenwechsel und Neurendern erfolgreich; bei 320/390 px kein horizontaler Überlauf, auch bei langem Rezeptnamen. Keine DB-/Edge-Function-Änderung. Offene Prüfungen mit echten Bildern und zweitem Haushalt bleiben bestehen.

- 2026-11-10 (ChatGPT): Rezeptbibliothek klar in Gespeichert, ★ Favoriten und KI-Ideen getrennt. Gespeicherte Rezepte aufklappbar und bearbeitbar; Stern an gespeicherten Rezepten und KI-Ideen (speichert sie als Favorit). Speichern zeigt direkt den Bereich Gespeichert und bestätigt erst nach Rückgabe des DB-Datensatzes; Fehler auch außerhalb des Editors sichtbar. Favoriten bleiben beim Bearbeiten erhalten. Ladefehler mit Erneut-laden, Haushaltswechsel verwirft Editor und laufende Rezeptantworten. Migration `20261110124508_add_vorrat_recipe_favorites.sql` deployed: `favorite boolean not null default false`; alle sechs bestehenden Rezepte erhalten, RLS unverändert. DB-Leseprüfung als Mitglied: sechs Rezepte/Favoritenfeld sichtbar; ohne Mitgliedschaft: null. Cache v12. Browsertests mit lokalen Testdaten: Anlegen, KI-Rezept speichern (inkl. Fehlerfall), Öffnen, Bearbeiten, Favorisieren/Entfavorisieren, Realtime-Neuladen, Zutaten auf Einkaufsliste, Artikel anlegen/entnehmen, Nachkaufen, Gekauft, Fotoauswahl. Anmeldung und echter Haushaltswechsel nicht erneut prüfbar: Testbrowser hat keine angemeldete Sitzung; echte KI-/Fotoerkennung weiterhin offen.

- 2026-11-10 (ChatGPT): Sechs Rezeptkategorien als Mehrfachauswahl im Editor ergänzt, Kategorieetiketten und Filter in Gespeichert/Favoriten/KI-Ideen sowie der Rezeptauswahl im Essensplan. Kategorie ist keine Tages-/Mahlzeitbeschränkung; Mehrfachauswahl bleibt beim Wechsel des Planfilters erhalten. Neue Migration `20261110130035_add_vorrat_recipe_categories.sql` deployed: `categories text[] not null default {}` mit erlaubten Kategorien; alle sechs Bestandsrezepte unverändert unter Ohne Kategorie. Haushalts-RLS unverändert und als Mitglied (6 sichtbar) / ohne Mitgliedschaft (0) geprüft. `scan-receipt` Version 13 deployed: ausschließlich Rezept-Prompt/Antwort um Kategorien ergänzt, unbekannte Werte verworfen. Verify JWT aktiv; Bon-/Einkaufszettel-Code bytegleich mit Version 12, MHD-Anfrage/Antwort ebenfalls unverändert im lokalen Handlervergleich. Lokale Edge-Datei entspricht deploytem Stand. Cache v13. Browser mit Testdaten: Kategorien mehrfach auswählen/speichern/neu laden/alle entfernen, Ohne Kategorie filtern, KI-Kategorien speichern, Essensplan über mehrere Kategorien zuordnen, Artikel anlegen/entnehmen, Nachkaufen, Gekauft, Foto-Dateiauswahl; 320/390 px ohne horizontalen Überlauf, keine App-Konsolenfehler. JavaScript-/TypeScript-Syntax sowie Edge-Handler mit gemocktem Gemini geprüft. Anmeldung/echter Haushaltswechsel und echter Gemini-Aufruf mangels angemeldeter Testsitzung weiterhin nicht end-to-end geprüft.
