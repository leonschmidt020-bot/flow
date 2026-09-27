# ClipVault Sync – dein eigener Server in 5 Minuten

**Optional.** ClipVault läuft ohne diesen Server komplett lokal. Den Server brauchst du nur, wenn du einen Tresor mit
**einer** anderen Person teilen willst (Freund/Partner): Texte, Links, Bilder und Dateien bis 200 MB, live auf beiden Macs.

- Ende-zu-Ende verschlüsselt (AES-GCM-256). Der Server speichert nur Chiffrat, der Schlüssel liegt nur in den
  Schlüsselbunden eurer Macs.
- Es gibt **keinen** gemeinsamen Server der Flow-Macher. Jeder nimmt seinen eigenen, kostenlosen Cloudflare Worker.
- Standard nach der Installation: **Sync aus.**

> English summary: optional self-hosted sync for sharing one ClipVault vault with one friend. Deploy with
> `npx wrangler deploy`, set the required `INIT_SECRET` with `npx wrangler secret put INIT_SECRET`, then paste the
> worker URL + secret into Flow → ClipVault → Settings → Sharing. Only the person who creates the vault needs it.

## Was du brauchst

- Ein kostenloses Cloudflare-Konto (https://dash.cloudflare.com/sign-up). Der Free-Plan reicht
  (Durable Objects mit SQLite, 5 GB Speicher fürs Konto, ClipVault begrenzt jeden Tresor auf 3 GB).
- Node.js 20 oder neuer (`node -v`). Ohne Node: `brew install node` oder https://nodejs.org.

## Schritte (nur **einer** von euch beiden)

```bash
cd "$HOME/Library/Application Support/Flow/src/mac/clipvault/sync-worker"
npm install                          # lädt wrangler (~1 Min.)
npx wrangler login                   # öffnet den Browser, einmal bei Cloudflare anmelden
npx wrangler deploy                  # legt den Worker „flow-clipvault-sync“ an und zeigt seine URL:
                                     #   https://flow-clipvault-sync.<dein-konto>.workers.dev
openssl rand -hex 24                 # ein zufälliges Init-Geheimnis erzeugen und kopieren …
npx wrangler secret put INIT_SECRET  # … und hier einfügen (Pflicht, siehe unten)
curl https://flow-clipvault-sync.<dein-konto>.workers.dev/health   # → {"ok":true,…}
```

Dann in **Flow → ClipVault → Einstellungen → Teilen** die Worker-URL und das Init-Geheimnis einfügen und
„Speichern“ klicken. Oder im Terminal:

```bash
~/.config/flow-clipvault/clipvault sync setup https://flow-clipvault-sync.<dein-konto>.workers.dev <INIT_SECRET>
```

## Koppeln

1. Du: Hub → ClipVault → **Geteilt** → „Code anzeigen“ (oder `clipvault pair create "Name des Freundes"`).
2. Den Code (`cvpair1.…`, 15 Minuten gültig) **privat** schicken – er enthält den Tresor-Schlüssel.
3. Dein Freund: ClipVault-Panel (⌘⇧V) → Geteilt → „Koppeln …“ → Code einfügen, deinen Namen eintragen
   (oder `clipvault pair join <code> "Dein Name"`). Er braucht **keinen** eigenen Worker und kein Init-Geheimnis.

Getrennt wird mit „Trennen“ in den Einstellungen oder `clipvault unpair`.

## Warum INIT_SECRET Pflicht ist

Ohne Schutz könnte jeder, der die URL deines Workers kennt, auf deinem Cloudflare-Konto neue Tresore anlegen und
Speicher belegen (Audit-Befund #16). Deshalb legt der Worker einen Tresor nur an, wenn die Anfrage
`X-CV-Init-Secret` mit dem Wert von `INIT_SECRET` mitschickt:

| Worker-Antwort auf `init` | Bedeutung |
|---|---|
| `503 INIT_SECRET not configured` | `npx wrangler secret put INIT_SECRET` fehlt noch |
| `403 init secret wrong` | Geheimnis in Flow/ClipVault fehlt oder ist falsch |
| `201` / `200` | Tresor angelegt |

Das Geheimnis liegt auf dem Mac nur im Schlüsselbund (`app.flowdictation.clipvault.sync`, Konto `init-secret`),
nie in einer Datei. Beitreten (`join`) nutzt stattdessen das einmalige Geheimnis aus dem Kopplungscode.
Neues Geheimnis: `npx wrangler secret put INIT_SECRET` erneut ausführen und in Flow neu eintragen –
bestehende Tresore laufen weiter.

## Optionale Einstellungen (`wrangler.toml` › `[vars]` oder `--var`)

| Variable | Standard | Wirkung |
|---|---|---|
| `QUOTA_BYTES` | 3 000 000 000 | Kontingent pro Tresor |
| `BIG_TTL_SECONDS` | 604 800 (7 Tage) | Einträge > 20 MB, nicht angeheftet, verlieren danach ihre Teile auf dem Server |
| `INVITE_TTL_SECONDS` | 900 | Gültigkeit eines Kopplungscodes (höchstens 15 Min.) |

## Lokal testen (ohne Cloudflare)

```bash
npm install
npx wrangler dev --local --ip 127.0.0.1 --port 8787 --var INIT_SECRET:"$(openssl rand -hex 24 | tee /tmp/cv-init)"
~/.config/flow-clipvault/clipvault sync setup http://127.0.0.1:8787 "$(cat /tmp/cv-init)"
```

Protokoll und Endpunkte: `../PROTOCOL.md` und der Kopf von `src/index.ts`.

## Entfernen

`npx wrangler delete` löscht den Worker samt aller Tresore auf deinem Konto. Vorher auf beiden Macs `clipvault unpair`.
