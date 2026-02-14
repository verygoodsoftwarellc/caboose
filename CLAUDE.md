# Caboose

Rails debugging/observability gem. Tracks requests, queries, jobs, cache, views, and more using OpenTelemetry.

## Architecture

Two pieces:

- **caboose** (this repo) - Ruby gem installed in the user's Rails app. Instruments via OpenTelemetry, stores spans in local SQLite, flushes aggregated metrics to caboose-web.
- **caboose-web** - Hosted Rails app at caboose.dev. Receives metrics, manages projects/auth, provides the CLI auth flow.

## Environment Behavior

The gem behaves differently per environment:

| | Development | Production | Test |
|---|---|---|---|
| **Spans** (local SQLite) | ON | OFF | OFF |
| **Metrics** (aggregated, sent to caboose-web) | ON | ON | OFF |
| **Dashboard UI** (`/caboose`) | auto-mounted | not mounted | auto-mounted |

### Spans (Development only)

Spans are detailed trace data (every SQL query, cache hit, view render, etc.) stored in a local SQLite database at `db/caboose.sqlite3`. The `SQLiteExporter` writes spans via the OTel `BatchSpanProcessor`. Spans are auto-pruned based on `retention_hours` (default: 24h) and `max_spans` (default: 10,000). This is too expensive for production.

The dashboard at `/caboose` reads from this SQLite database to show requests, jobs, queries, cache, views, HTTP calls, mail, and exceptions with waterfall visualizations.

### Metrics (All environments except test)

Metrics are lightweight aggregated counters computed from spans in-memory. The `MetricSpanProcessor` (an OTel span processor) extracts metrics from every span as it finishes, bucketed by minute into a `MetricStorage` (thread-safe `Concurrent::Map`). Categories:

- **web** - HTTP requests (namespace=web, service=rails, target=controller, operation=method)
- **background** - Jobs (namespace=background, service=activejob/sidekiq, target=job class, operation=action)
- **db** - Database queries (namespace=db, service=sqlite/postgresql/etc, target=table, operation=SELECT/INSERT/etc)
- **http** - Outgoing HTTP calls (namespace=http, service=host, target=path, operation=GET/POST/etc)

The `MetricFlusher` drains the storage every 60s and the `MetricSubmitter` posts gzipped JSON to `POST {url}/api/metrics` with `Authorization: Bearer {CABOOSE_KEY}`. Only runs if both `url` and `key` are configured.

### Fork Safety

The gem detects forking (Puma workers, Passenger, etc.) inline on every span end. When `$$` changes, it calls `Caboose.after_fork` which restarts the `MetricFlusher` timer thread. Same pattern as Flipper.

## Setup Flow (CLI + caboose-web)

Users run `bundle exec caboose setup` from their Rails app root. The command does three things:

### 1. Authentication (OAuth-style flow with caboose-web)

- Generates a PKCE code challenge (`state`, `code_verifier`, `code_challenge`)
- Starts a local TCP server on a random port (127.0.0.1)
- Opens the browser to `caboose.dev/cli/authorize?state=...&port=...&code_challenge=...`
- User logs in / authorizes on caboose-web
- caboose-web redirects back to the local TCP server at `/callback?state=...&code=...`
- CLI verifies state matches, then exchanges the auth code for a token via `POST caboose.dev/api/cli/exchange` (sending `code` + `code_verifier`)
- User chooses where to save the `CABOOSE_KEY` token: `.env` file, Rails credentials, or print to stdout

### 2. Create initializer

Writes `config/initializers/caboose.rb` with commented config options (retention, max spans, database path, ignore patterns, subscribe patterns).

### 3. Update .gitignore

Adds `.env` and `/db/caboose.sqlite3*` to `.gitignore` if not already present.

## Key Configuration

- `CABOOSE_KEY` - API key for metrics submission (set via env var or Rails credentials at `caboose.key`)
- `CABOOSE_URL` - Metrics endpoint (defaults to `https://caboose.dev`, overridable via env var or credentials at `caboose.url`)
- `CABOOSE_HOST` - Used only by the CLI for the auth flow (defaults to `https://caboose.dev`)
- `CABOOSE_DEBUG` - Set to `1` to enable debug logging

The engine loads `CABOOSE_KEY` from Rails credentials automatically if the env var isn't set (see `engine.rb` initializer `caboose.defaults`).

## Engine Initialization Order

The `Caboose::Engine` runs initializers in a specific order:

1. `caboose.defaults` (before `load_config_initializers`) - loads `CABOOSE_KEY` from Rails credentials if not in ENV
2. `caboose.static_assets` - serves `/caboose-assets` from engine's `public/` directory
3. `caboose.opentelemetry` (before `build_middleware_stack`) - configures OTel SDK and instrumentations so Rack/ActionPack middleware gets inserted
4. `caboose.routes` (before `add_routing_paths`) - auto-mounts engine at `/caboose` in development/test
5. `config.after_initialize` - starts the `MetricFlusher` (after user initializers have run so config is applied)

## OTel Instrumentations

Auto-configured instrumentations:
- `Rack` - HTTP requests (ignores `/caboose` paths and user-configured ignore patterns)
- `Net::HTTP` - outgoing HTTP calls
- `ActiveSupport` - notifications (SQL, cache, mailer)
- `ActionPack` - controller actions (if ActionController is defined)
- `ActionView` - view rendering (if ActionView is defined)
- `ActiveJob` - background jobs (if ActiveJob is defined)

Additionally subscribes to specific `ActiveSupport::Notifications` patterns: `sql.active_record`, `instantiation.active_record`, `cache_*.active_support`, `deliver.action_mailer`, `process.action_mailer`, and any custom prefixes (default: `app.*`).

## Custom Instrumentation

Users instrument their code with `ActiveSupport::Notifications.instrument("app.whatever")` using the `app.` prefix. Works in all environments. In dev, Caboose auto-subscribes and creates spans. In production, it's essentially a no-op unless the user adds custom subscribers.

## CLI

`exe/caboose` - entry point. Commands: `setup`, `version`, `help`.

`--force` flag on setup re-runs auth even if `CABOOSE_KEY` exists in `.env`.

## Development

```
bundle install
rake test
```

Tests use Minitest. The test helper loads core library classes directly without Rails to keep unit tests fast. Use `RAILS_VERSION` env var to test against different Rails versions.

## File Structure

- `lib/caboose.rb` - main module, OTel configuration, notification subscriptions
- `lib/caboose/engine.rb` - Rails engine (routes, initializers, middleware)
- `lib/caboose/configuration.rb` - all config options and environment defaults
- `lib/caboose/cli.rb` - CLI command router
- `lib/caboose/cli/setup_command.rb` - setup/auth flow
- `lib/caboose/sqlite_exporter.rb` - OTel span exporter that writes to SQLite
- `lib/caboose/metric_span_processor.rb` - OTel span processor that extracts metrics
- `lib/caboose/metric_storage.rb` - thread-safe in-memory metric aggregation
- `lib/caboose/metric_flusher.rb` - background timer that drains and submits metrics
- `lib/caboose/metric_submitter.rb` - HTTP client for posting metrics to caboose-web
- `lib/caboose/source_location.rb` - finds app code location that triggered a span
- `app/` - Rails engine controllers/views for the dashboard UI
- `config/routes.rb` - engine routes (requests, jobs, spans by category)
