# Installation

Build the whole system on a single Docker host, from scratch.

**Prerequisites**
- Docker + Docker Compose
- Caddy as a reverse proxy running with `network_mode: host`
- An internal DNS that resolves `*.home.arpa` (or your own domain) to the host
- An LLM API key
- Node.js on your desktop (for the Claude Desktop MCP bridge)

**Order:** 1. Cognee stack → 2. CouchDB → 3. Obsidian/LiveSync → 4. livesync-bridge →
5. Ingestion → 6. MCP clients → 7. Backup

All paths assume the stack lives in `${STACK_DIR}` (e.g. `/srv/docker`). Grab the config
templates from [`config/`](../config/) and [`compose/`](../compose/), copy each `.example`
to its real name, and fill in secrets.

```bash
# One-time: copy templates
cp .env.example .env
cp config/cognee/cognee.env.example config/cognee/cognee.env
mkdir -p config/livesync-bridge/dat
cp config/livesync-bridge/config.json.example config/livesync-bridge/dat/config.json
# then edit each file and fill in real values
```

---

## 1. Cognee stack

Configuration lives in [`config/cognee/cognee.env`](../config/cognee/cognee.env.example)
and the services in [`compose/docker-compose.yml`](../compose/docker-compose.yml)
(`cognee-postgres`, `ollama-cognee`, `cognee`, `cognee-mcp`).

Key points baked into those files:
- **Single-user mode** (`ENABLE_BACKEND_ACCESS_CONTROL=false`, `REQUIRE_AUTHENTICATION=false`) — no tokens.
- **Embeddings via Ollama** at `/api/embed` (not `/api/embeddings`), 768 dimensions.
- **Rate limiter on** — mandatory for a CPU-only, single-slot Ollama, or bulk ingestion
  cascades into timeouts.
- **`VECTOR_DB_*` mirrored explicitly** alongside `DB_*`.
- **Volume mounts under `/app/cognee/...`** (not `/app/...`) — the wrong path silently
  stores data ephemerally and you lose it on recreate.

Add the Caddy site blocks from [`config/caddy/Caddyfile`](../config/caddy/Caddyfile), then start:

```bash
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
docker compose up -d cognee-postgres ollama-cognee
docker exec -it ollama-cognee ollama pull nomic-embed-text
docker compose up -d cognee          # waits for migration (runs exclusively here!)
docker compose up -d cognee-mcp      # only after cognee is healthy
```

The ingest script talks to `127.0.0.1:8010` directly, bypassing Caddy. TLS goes through
Caddy's internal CA — its root CA must be trusted on clients (see step 2.3).

### Verify

```bash
curl -s http://127.0.0.1:8010/health                 # {"status":"ready",...}
curl -s http://127.0.0.1:8010/api/v1/datasets        # [] with no auth header
docker compose logs cognee | grep "auth posture"     # authentication=disabled
# Persistence test (do not skip!):
docker compose restart cognee && docker exec cognee ls /app/cognee/.data_storage
```

---

## 2. CouchDB (vault sync server)

Config: [`config/couchdb/local.ini`](../config/couchdb/local.ini). Service: `couchdb` in
the compose file. Caddy: the `couchdb.home.arpa` block.

**HTTPS is mandatory for iOS** — it blocks plain HTTP, which is why the Caddy block uses
`tls internal`.

### 2.3 Install the root CA on your devices

The CA lives at `${STACK_DIR}/caddy/data/caddy/pki/authorities/local/root.crt`.

- **macOS:**
  ```bash
  sudo security add-trusted-cert -d -r trustRoot \
    -k /Library/Keychains/System.keychain root.crt
  ```
- **iPhone:** AirDrop the cert → install the profile → **additionally**: Settings →
  General → About → Certificate Trust Settings → enable the toggle. Without this last
  step, TLS fails cryptically.

### Verify

```bash
# require_valid_user applies to EVERY endpoint, including /_up:
curl -s https://couchdb.home.arpa/_up                       # 401 = correct
curl -s -u "obsidian:<pw>" https://couchdb.home.arpa/_up    # {"status":"ok"}
```

---

## 3. Obsidian: set up LiveSync

Prerequisite: a **local** vault (not inside iCloud or another sync folder — one vault,
one sync mechanism). Back it up first: `zip -r ~/vault-backup-$(date +%F).zip <vault>`.

1. **Plugin "Self-hosted LiveSync":** Remote Databases → "+" → CouchDB,
   `https://couchdb.home.arpa`, user/password, DB name `secondbrain`. Run "Test
   Connection" + "Check database configuration" (fixes settings with one click).
2. **Enable E2EE** (passphrase → password manager) **before** the first upload. Note:
   "Path Obfuscation" is enabled together with it — the bridge then needs the same
   passphrase as `obfuscatePassphrase`.
3. Initial upload ("Rebuild everything" / overwrite remote with local).
4. **Set sync mode to "LiveSync"** — it tends to fall back to manual after wizard runs
   (known trap!).
5. **iPhone:** generate a Setup URI / QR from the desktop → create a new *local* vault
   (no iCloud) → plugin → "Use a Setup URI". Requires VPN/WLAN.

---

## 4. livesync-bridge (vault → plaintext mirror)

**A self-build is mandatory** — the community image (`canardconfit/livesync-bridge`) is
incompatible with the E2EE/obfuscation of current plugin versions (symptom:
`OUT OF TARGET FOLDER` for every document).

```bash
cd ${STACK_DIR}
git clone --recursive https://github.com/vrtmrz/livesync-bridge.git livesync-bridge-src
mkdir -p config/livesync-bridge/dat livesync-bridge/data/vault
```

Put your filled-in [`config.json`](../config/livesync-bridge/config.json.example) at
`config/livesync-bridge/dat/config.json`. The `livesync-bridge` service is already in the
compose file (build context `./livesync-bridge-src`, mounts `/app/dat` + `/app/data`).

**Two mandatory steps before starting:**

```bash
# 1. Ownership: the bridge runs as a non-root user (the Deno user's UID, e.g. 1993)
sudo chown -R 1993:1993 ${STACK_DIR}/livesync-bridge/data ${STACK_DIR}/config/livesync-bridge/dat
chmod 700 ${STACK_DIR}/livesync-bridge/data   # plaintext!

# 2. Design document — the bridge changes feed needs it; LiveSync no longer creates it.
#    MUST BE REPEATED AFTER EVERY REMOTE REBUILD:
curl -s -u "obsidian:<pw>" -X PUT http://127.0.0.1:5984/secondbrain/_design/replicate \
  -H "Content-Type: application/json" \
  -d '{"filters":{"pull":"function (doc, req) { return true; }","push":"function (doc, req) { return true; }"}}'
```

```bash
docker compose build livesync-bridge
docker compose up -d livesync-bridge
docker compose logs -f livesync-bridge   # expect plaintext paths, no f:<hash> SKIPs
find ${STACK_DIR}/livesync-bridge/data/vault -name "*.md" | wc -l
```

Notes: the bridge is **bidirectional** (never write to the mirror!). Hidden files
(`.obsidian/`, `.claude/`) are not synced by LiveSync by default — count differences vs.
the desktop are normal. Full rescan: delete the state in `dat/` except `config.json`
(or use the `--reset` flag).

---

## 5. Ingestion (mirror → Cognee)

Install [`scripts/vault-ingest.sh`](../scripts/vault-ingest.sh) at
`${STACK_DIR}/cognee/vault-ingest.sh` and edit its `WHITELIST` to match your vault.

```bash
chmod +x ${STACK_DIR}/cognee/vault-ingest.sh
```

Core principles (already implemented in the script):
- **Whitelist, not blacklist:** new folders are OUT by default — keep sensitive folders
  unindexed by simply not listing them.
- **Initial load folder-by-folder** (grow `WHITELIST` step by step) to spread the
  embedding load.
- **Hash, not mtime:** sync tools change mtimes without changing content.
- **One `cognify` per run** (the expensive LLM step), not per file.
- **State written only on success**; reruns are cost-neutral thanks to add-dedup.

Dry check before the first run: run the script's `find` command manually and eyeball the
file list for whitelist conformance.

---

## 6. MCP clients

### Claude Desktop
No native HTTP MCP → uses the `mcp-remote` bridge. See
[`config/claude/claude_desktop_config.json.example`](../config/claude/claude_desktop_config.json.example).

- **Pin the version!** An unpinned `mcp-remote` is silently updated on an npx cache miss —
  version 0.1.37 was broken (initialize never answered). Update deliberately: bump the
  version, test, then adopt.
- **`NODE_EXTRA_CA_CERTS`:** Node does not read the macOS keychain (its own CA store); the
  Caddy root CA must be referenced as a PEM file:
  ```bash
  security find-certificate -a -c "Caddy" -p > ~/.certs/caddy-root.pem
  ```
  Use an **absolute path** in the config — `~` is not expanded in JSON.
- After config changes: quit the app **completely** (Cmd+Q). Also restart after every
  `cognee-mcp` container recreate (MCP session IDs become invalid → 404/502).

### Claude Code (native HTTP)
Provide the root CA via the shell environment, then add the server:

```bash
# in ~/.zshrc:
export NODE_EXTRA_CA_CERTS="$HOME/.certs/caddy-root.pem"

claude mcp add --transport http --scope user cognee https://cognee-mcp.home.arpa/mcp
```

**Function test:** chat 1: "Remember with the cognee tool: test key X." → new chat: "What
is my test key? Use cognee recall."

---

## 7. Backup (borgmatic)

Back up the bind-mounted config **and** the named volumes; dump databases rather than
copying hot files.

```yaml
source_directories:
    - /srv/docker
    - /var/lib/docker/volumes        # named volumes live here, NOT under /srv/docker

exclude_patterns:
    - /var/lib/docker/volumes/docker_cognee_pg_data   # dumped separately, not as hot files
    - /var/lib/docker/volumes/docker_ollama_data      # reproducible

postgresql_databases:
    - name: cognee_db
      hostname: localhost
      port: 5433        # requires "127.0.0.1:5433:5432" on cognee-postgres
      username: cognee
      password: <pw>
      format: custom
      options: --no-owner --no-privileges
```

`--no-owner --no-privileges`: restore assumes the DB users already exist (they come from
Compose init). Acceptance: `borgmatic config validate` → `borgmatic create --dry-run
--verbosity 1` (runs the DB dumps for real!) → `borgmatic create --stats`.
