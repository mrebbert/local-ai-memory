# local-ai-memory

A self-hosted **"second brain"**: your Obsidian notes are continuously synced to a
server, mirrored to plain files, and fed into a [Cognee](https://github.com/topoteretes/cognee)
knowledge graph. Claude (Desktop, Code, or mobile via MCP) can then query that graph
semantically — and use it as persistent conversation memory (`remember` / `recall`).

Everything runs on hardware you control. The only external dependency is an LLM API
(used purely for entity/relation extraction and answer phrasing); embeddings run locally.

```mermaid
flowchart TB
    subgraph devices["Your devices"]
        MAC["Desktop: Obsidian vault"]
        PHONE["Phone: Obsidian<br>(LAN / VPN)"]
        CLAUDE["Claude Desktop / Code"]
    end

    subgraph host["Docker host"]
        CADDY["Caddy reverse proxy<br>network_mode: host<br>TLS via internal CA"]
        subgraph couchnet["couchdb-net"]
            COUCH[("CouchDB<br>vault sync, E2EE")]
            BRIDGE["livesync-bridge<br>(format translator)"]
        end
        MIRROR["Plaintext mirror<br>data/vault"]
        SCRIPT["vault-ingest.sh<br>whitelist + hash state"]
        subgraph cogneenet["cognee-net"]
            MCP["cognee-mcp<br>(API mode)"]
            COG["cognee API"]
            OLL["Ollama<br>nomic-embed-text"]
            PG[("pgvector / pg17")]
            KUZU[("Kuzu graph")]
        end
    end

    LLM["LLM API<br>(entity extraction)"]
    BACKUP["borgmatic → offsite"]

    MAC <-->|"LiveSync (continuous)"| CADDY
    PHONE <-->|"LiveSync"| CADDY
    CLAUDE -->|"MCP (HTTP / mcp-remote)"| CADDY
    CADDY <--> COUCH
    CADDY -->|"127.0.0.1:8011"| MCP
    COUCH <-->|"changes feed"| BRIDGE
    BRIDGE <--> MIRROR
    MIRROR --> SCRIPT
    SCRIPT -->|"/add + /cognify"| COG
    MCP -->|"REST"| COG
    COG --> OLL
    COG --> LLM
    COG --> PG
    COG --> KUZU
    COUCH -.-> BACKUP
    PG -.->|"pg_dump"| BACKUP
    KUZU -.-> BACKUP
```

## How it works, in one breath

1. You edit notes in Obsidian. **Self-hosted LiveSync** pushes them (end-to-end
   encrypted) into **CouchDB** within seconds.
2. **livesync-bridge** watches CouchDB's changes feed, decrypts, and writes plain
   `.md` files into a **mirror** directory on the host.
3. **`vault-ingest.sh`** picks up new/changed whitelisted files (SHA-256 change
   detection) and sends them to **Cognee** (`/add` + one `/cognify`).
4. Cognee chunks each note, extracts entities & relations via the **LLM API**,
   embeds them locally with **Ollama**, and stores vectors in **pgvector** and the
   graph in **Kuzu**.
5. Claude connects to **cognee-mcp** and calls `recall` (semantic search over the
   graph) or `remember` (persist a fact).

Data flows **one way**: vault → graph. Cognee never writes back to your vault.
Obsidian stays the single source of truth; the graph is reproducible at any time
(cost: one LLM rebuild).

## Repository layout

| Path | What it is |
|---|---|
| [`docs/01-architecture.md`](docs/01-architecture.md) | Components, diagrams, security model, design decisions |
| [`docs/02-installation.md`](docs/02-installation.md) | Step-by-step build from scratch |
| [`docs/03-runbook.md`](docs/03-runbook.md) | Day-2 operations & troubleshooting |
| [`compose/docker-compose.yml`](compose/docker-compose.yml) | All services in one file |
| [`config/`](config/) | Config templates: cognee env, CouchDB, Caddy, bridge, Claude |
| [`scripts/vault-ingest.sh`](scripts/vault-ingest.sh) | Mirror → Cognee ingestion |
| [`.env.example`](.env.example) | Secrets consumed by Compose |

## Conventions used in this documentation

- **Domain:** examples use `home.arpa` (the RFC 8375 domain reserved for home
  networks). Replace it with your own internal domain everywhere.
- **Base directory:** the stack lives in `/srv/docker` (`${STACK_DIR}`). Adjust to taste.
- **Secrets:** any file ending in `.example` contains placeholders — copy it, drop the
  suffix, and fill in real values. Never commit the filled-in copies.

## Component responsibilities

| Component | Its one job |
|---|---|
| Obsidian + LiveSync plugin | Author notes; continuous sync (mode: LiveSync) |
| CouchDB | Sync source of truth in LiveSync format (chunked, E2EE-encrypted) |
| livesync-bridge | Translate LiveSync format ↔ filesystem; decrypt with the E2EE passphrase; bidirectional |
| Plaintext mirror | Decoupled file view of the vault on the host (read-only by convention) |
| vault-ingest.sh | Whitelist scope, hash-based change detection, `/add` + one `/cognify` per run |
| cognee | Pipelines: chunk → LLM extraction → embed → persist; search |
| cognee-mcp | MCP interface (`remember` / `recall` / `forget`); API mode, never touches the DBs |
| Ollama | Local embeddings (768-dim), rate-limited for CPU-only hosts |
| LLM API | Entity/relation extraction and answer phrasing on recall |
| pgvector / Kuzu | Vector + metadata store / knowledge graph (file-based) |

See [`docs/01-architecture.md`](docs/01-architecture.md) for the full picture and the
reasoning behind each choice.
