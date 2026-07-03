# Runbook

Day-2 operating procedures for the Cognee stack and the vault pipeline.
Replace `home.arpa` and `${STACK_DIR}` (e.g. `/srv/docker`) with your own values.

## Routine operations

### Ingestion run (currently manual)

```bash
${STACK_DIR}/cognee/vault-ingest.sh
```

- Runs against the bridge mirror, ingests only whitelisted folders, only new/changed
  files (SHA-256 state at `${STACK_DIR}/cognee/ingest-state.txt`).
- Deleted/renamed notes are only logged (`DELETED (orphaned in graph)`) — v1 behaviour;
  clean up via a dataset rebuild (below).
- To automate: `0 3 * * * ${STACK_DIR}/cognee/vault-ingest.sh >> /var/log/vault-ingest.log 2>&1`

### Health checks

```bash
curl -s http://127.0.0.1:8010/health                          # cognee: status ready
curl -s http://127.0.0.1:8011/health                          # cognee-mcp: ok
curl -s -u "obsidian:<pw>" https://couchdb.home.arpa/_up      # couchdb (401 without auth = correct)
docker compose ps couchdb livesync-bridge cognee cognee-mcp cognee-postgres ollama-cognee
```

### End-to-end test of the vault pipeline

1. Create a test note in Obsidian.
2. Within seconds: `find ${STACK_DIR}/livesync-bridge/data/vault -name "TestNote.md"`
3. Delete the note → it disappears from the mirror.
4. Stuck? See Troubleshooting "Note doesn't reach the mirror".

---

## Maintenance procedures

### LiveSync remote rebuild (after E2EE / structure changes)

After **every** "Rebuild remote database" in the plugin:

1. **Recreate `_design/replicate`** (deleted by the rebuild; without it the bridge feed
   dies instantly):
   ```bash
   curl -s -u "obsidian:<pw>" -X PUT http://127.0.0.1:5984/secondbrain/_design/replicate \
     -H "Content-Type: application/json" \
     -d '{"filters":{"pull":"function (doc, req) { return true; }","push":"function (doc, req) { return true; }"}}'
   ```
2. Pull the change on the phone (Tweaks-mismatch dialog → accept remote).
3. **Check the sync mode** — it likes to fall back to manual after a wizard/rebuild → set
   it to "LiveSync".
4. Bridge rescan: `docker compose stop livesync-bridge` → delete the state in `dat/`
   except `config.json` → `up -d`.
5. Mirror completeness: `find .../data/vault -name "*.md" | wc -l` vs. the desktop count
   (subtract hidden folders).

### Update Cognee images

**Always both together** (independent release cycles → drift):

```bash
docker compose pull cognee cognee-mcp
docker compose up -d cognee cognee-mcp
# then restart Claude Desktop (MCP session invalid)
```

Migrations run exclusively in the `cognee` container (API mode). After the update, spot-check
persistence (`docker exec cognee ls /app/cognee/.data_storage` — the data must be there).

### Update livesync-bridge

Only needed if decryption errors appear after a LiveSync plugin update:

```bash
cd ${STACK_DIR}/livesync-bridge-src && git pull --recurse-submodules
cd ${STACK_DIR} && docker compose build livesync-bridge
docker compose up -d --force-recreate livesync-bridge
```

### Dataset rebuild (rebuild the graph)

For too many orphaned entries or a model change. Cost: one full LLM run (note the
reference figure from your initial load).

```bash
# Delete the dataset (via API or forget), reset the state:
rm ${STACK_DIR}/cognee/ingest-state.txt
${STACK_DIR}/cognee/vault-ingest.sh    # full ingest, optionally folder-by-folder
```

### Switch the LLM model

Edit `LLM_MODEL` in `config/cognee/cognee.env` → `docker compose up -d --force-recreate
cognee`. The existing graph stays usable; for a quality comparison, rebuild into a second
dataset.

### Backup restore (short form)

- **Volumes:** restore from your backup into `/var/lib/docker/volumes/<name>/_data/`
  (container stopped).
- **Databases:** restore the `cognee_db` dump — the DB user must exist first (Compose init).
- **Cognee consistency:** the `cognee_pg_data` dump and `cognee_system` (Kuzu) must be
  from the same run (they reference each other). Emergency alternative: rebuild the graph
  from the vault entirely — you only lose the `remember` session memory.
- **Vault emergency:** the mirror + desktop + phone are full plaintext copies; CouchDB can
  be restored from any device via "Overwrite remote" (then run the rebuild procedure above!).

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Note doesn't reach the mirror, `update_seq` in CouchDB unchanged | Sync mode fell back to manual on the device | Plugin → Sync Settings → mode "LiveSync"; test: Command Palette → "Replicate now" |
| `update_seq` rises, mirror stays empty, bridge log stale | Bridge changes feed fell asleep | `docker compose restart livesync-bridge` |
| Bridge log: `CONNECTION HAS BEEN CLOSED, RECONNECTING` loop | `_design/replicate` missing (e.g. after rebuild) | Create the design document (see Maintenance) |
| Bridge log: `SKIP f:<hash>` / `OUT OF TARGET FOLDER` | Path Obfuscation not decryptable: `obfuscatePassphrase` missing/wrong **or** bridge build too old for plugin crypto | Check the passphrase in `config.json`; otherwise rebuild the bridge (self-build, never the community image) |
| Bridge log: `EACCES` on write | Mount dirs owned by root instead of the container UID | `chown -R 1993:1993 .../data .../dat` |
| Bridge won't start: `readfile './dat/config.json'` ENOENT | Wrong mount targets | Self-build uses `/app/dat` + `/app/data` |
| Bridge doesn't process old changes | Checkpoint survives in `dat/` | Delete state except `config.json` (or `--reset`) |
| cognee: `TimeoutError` OllamaEmbeddingEngine on bulk ingest | Single-slot CPU Ollama overloaded | `EMBEDDING_RATE_LIMIT_*` in `.env` (30/60); initial load folder-by-folder |
| cognee: `model "nomic-embed-text" not found` | Model not in the Ollama volume | `docker exec -it ollama-cognee ollama pull nomic-embed-text` |
| cognee: `Embedding test did not return a valid vector` | Wrong endpoint (`/api/embeddings`) | Set `EMBEDDING_ENDPOINT` to `/api/embed` |
| cognee: `FileNotFoundError ... .data_storage` after recreate; graph empty | Volume mounts on `/app/...` instead of `/app/cognee/...` → data was ephemeral | Fix the mounts; reset volumes + state, re-ingest |
| cognee-mcp: `MigrationError` / `Can't locate revision` | Direct mode + image version drift | Use API mode (`API_URL=http://cognee:8000`); pull images together |
| MCP: `421 Invalid Host header` | DNS-rebinding protection | Add the domain to `MCP_ALLOWED_HOSTS` |
| MCP: `404` on `/mcp` after container restart | Client holds a stale session ID | Restart Claude Desktop completely (Cmd+Q) |
| MCP: "Could not attach", `initialize` never answers — yet `curl` against `/mcp` responds instantly | Broken/incompatible `mcp-remote` version (silent npx update; 0.1.37 was broken) | Pin the version (`mcp-remote@0.1.36`); diagnose by piping an initialize-JSON followed by `sleep 15` into `npx -y mcp-remote@<ver> <url>` — no `[Remote→Local]` means the version is broken |
| mcp-remote: `UNABLE_TO_VERIFY_LEAF_SIGNATURE` | Node doesn't read the macOS keychain (own CA store) | Point `NODE_EXTRA_CA_CERTS` at the Caddy root PEM — Desktop: `env` in the config (absolute path, no `~`); Code: export in `~/.zshrc` |
| Claude Desktop: "no valid MCP server configuration" | `"url"` is not supported in `claude_desktop_config.json` | Use the `mcp-remote` wrapper (`command`/`args`) |
| `502 Bad Gateway` via Caddy | Wrong upstream (container DNS instead of `127.0.0.1:<hostport>` — Caddy is in the host network) or container still starting | Caddyfile: `reverse_proxy 127.0.0.1:<port>`; mind host-port ≠ container-port |
| `308 Permanent Redirect` on an internal HTTP service | Caddy auto-HTTPS | `http://` prefix in the site block (or intentionally: `tls internal` + CA on devices) |
| iOS won't connect to CouchDB | Plain HTTP (blocked by iOS) or incomplete CA trust | `tls internal` + install the root CA **and** enable the certificate-trust toggle |
| CouchDB `/_up` returns 401 | `require_valid_user` applies to all endpoints | Expected; test with `-u` |

## Known quirks (by design)

- **The bridge is bidirectional** — never write to the mirror manually; deletions there
  propagate back into the vault!
- **Hidden files** (`.obsidian/`, `.claude/`) aren't synced by LiveSync → mirror count <
  desktop count is normal.
- **Plaintext points in the chain:** the mirror on the host + the LLM API during
  extraction — the whitelist is your control point for both.
- **Locale trap in file-list comparisons:** always `LC_ALL=C sort` on both sides.
- **No JWT/token topics anymore** (single-user mode) — any guide mentioning `API_TOKEN` /
  api-keys is outdated.
- **Run `mcp-remote` version-pinned only** — unpinned, npx pulls the latest on a cache
  miss; a broken release (0.1.37) once broke the Desktop client. Update deliberately: bump
  the version, verify via the pipe test, then adopt.
```
