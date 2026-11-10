# Übergabe Vorrat

Gemeinsames Gedächtnis für alle, die an der App arbeiten (Simon, Claude, ChatGPT). Am Anfang jeder Sitzung lesen, nach jeder Arbeit unten einen Eintrag ergänzen.

## Aktueller Stand (2026-11-10)
- App: index.html, Service-Worker-Cache `vorrat-v10`
- Live: https://cvhjj236-afk.github.io/vorrat/ (Pages aus main, Deploy dauert 1–2 Min.)
- Supabase-Projekt "Urlaubsapp" (wpxoddfaczbhxnmfidoj), enthält auch Daten einer anderen App: nur `vorrat_*` und die Funktion `scan-receipt` anfassen
- Mehrere Haushalte pro Konto, Umschalter im Haushalt-Menü
- Foto-Scan über Edge Function `scan-receipt` mit Gemini (Modell gemini-3.5-flash-lite)
- Eigene Rezepte in `vorrat_recipes`, pro Haushalt mit RLS und Realtime
- Essensplan: mehrere gespeicherte Rezepte pro Wochentag in `vorrat_mealplan`, pro Haushalt mit RLS und Realtime
- Gemini-Modi für Rezeptideen und MHD-Erkennung zusätzlich zum Foto-Scan
- `supabase/functions/scan-receipt/index.ts` entspricht deployter Version 12; Verify JWT ist aktiv; Bon-/Einkaufszettel-Flow wie Version 10

## Datenbank
Tabellen: vorrat_households, vorrat_members (mehrere Zeilen pro Konto möglich), vorrat_active, vorrat_invites, vorrat_items, vorrat_products (PK household_id + key), vorrat_recipes, vorrat_mealplan (PK household_id + plan_date + recipe_name). Rezepte, Essensplan und Vorratstabellen mit RLS: sichtbar nur, wenn household_id = vorrat_my_household(). `vorrat_recipes`, `vorrat_mealplan` und `vorrat_items` sind in `supabase_realtime`.
Funktionen: vorrat_my_household, vorrat_my_households, vorrat_switch_household, vorrat_create_household, vorrat_rename_household, vorrat_leave_household, vorrat_join, vorrat_create_invite, vorrat_is_member.
Item-Status: "in" Lager, "list" Einkaufsliste, "used"/"gone" entnommen bzw. übernommen.

## Regeln
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
