# Repository Guidelines

## Astra working defaults

These instructions are tuned for GPT-6 Astra. They guide execution; they do not
change the selected runtime model or expand access and external-action authority.

- Infer the intended outcome from the full conversation. Treat actionable
  requests such as “can you fix” as authorization to do the scoped work. Continue
  through implementation and verification; answer pure advice questions as advice.
- Resolve routine choices from evidence and state material assumptions. Ask only
  when an unresolved answer changes scope, correctness, cost, or authority.
  Continue independent work while waiting; incorporate steering without restarting.
- Complete authorized preparation before seeking final approval. Reuse earlier
  authorization; preserve the explicit deployment, communication, purchase,
  privacy, and destructive-action limits below. Do not invent permission gates.
- User instructions outrank skill guidelines, subject to system/developer rules.
  If a skill blocks progress, link its exact `SKILL.md`, quote the relevant rule,
  and explain the concrete conflict; do not present an interpretation as a rule.
- Delegate independent investigations, disjoint edits, or reviews when parallel
  work saves time or improves quality. Give each worker a bounded outcome and
  file ownership; integrate centrally. Respect harness limits and explicit user
  model choices. Skip delegation overhead for a short, coupled task.
- Use the smallest meaningful verification for the change and complete applicable
  repository gates. For instruction-only edits, inspect conflicts, paths, diffs
  and secrets; skip application builds unless runtime behavior is affected.
  Repeat passing checks only after a relevant change or new evidence. Do not add
  tests that merely restate implementation or remove useful behavioral coverage.
- Lead with the result in concise, plain prose. Use lists when they help scanning;
  avoid canned summaries, jargon and performative narration. Report what changed,
  what was verified, and material limits; never turn a local check into a live claim.

## Project Structure & Module Organization
- Code: `app/` (Rails MVC, services, jobs, mailers, components), JS in `app/javascript/`, styles/assets in `app/assets/` (Tailwind, images, fonts).
- Config: `config/`, environment examples in `.env.local.example` and `.env.test.example`.
- Data: `db/` (migrations, seeds), fixtures in `test/fixtures/`.
- Tests: `test/` mirroring `app/` (e.g., `test/models/*_test.rb`).
- Tooling: `bin/` (project scripts), `docs/` (guides), `public/` (static), `lib/` (shared libs).

## Build, Test, and Development Commands
- Setup: `cp .env.local.example .env.local && bin/setup` — install deps, set DB, prepare app.
- Run app: `bin/dev` — starts Rails server and asset/watchers via `Procfile.dev`.
- Test suite: `bin/rails test` — run all Minitest tests; add `TEST=test/models/user_test.rb` to target a file.
- Lint Ruby: `bin/rubocop` — style checks; add `-A` to auto-correct safe cops.
- Lint/format JS/CSS: `npm run lint` and `npm run format` — uses Biome.
- Security scan: `bin/brakeman` — static analysis for common Rails issues.

## Coding Style & Naming Conventions
- Ruby: 2-space indent, `snake_case` for methods/vars, `CamelCase` for classes/modules. Follow Rails conventions for folders and file names.
- Views: ERB checked by `erb-lint` (see `.erb_lint.yml`). Avoid heavy logic in views; prefer helpers/components.
- JavaScript: `lowerCamelCase` for vars/functions, `PascalCase` for classes/components. Let Biome format code.
- Commit small, cohesive changes; keep diffs focused.

## Testing Guidelines
- Framework: Minitest (Rails). Name files `*_test.rb` and mirror `app/` structure.
- For runtime changes, run relevant Minitest coverage and the required CI gate
  before merge. Instruction-only edits require diff/link checks, not Rails boot.
- Fixtures/VCR: Use `test/fixtures` and existing VCR cassettes for HTTP. Prefer unit tests plus focused integration tests.

## Commit & Pull Request Guidelines
- Commits: Imperative subject ≤ 72 chars (e.g., "Add account balance validation"). Include rationale in body and reference issues (`#123`).
- PRs: Clear description, linked issues, screenshots for UI changes, and migration notes if applicable. Keep required CI green; add/update behavioral tests when behavior changes and
  run `rubocop`/Biome for affected code. Instruction-only edits use document checks.

## Security & Configuration Tips
- Never commit secrets. Start from `.env.local.example`; use `.env.local` for development only.
- Run `bin/brakeman` before major PRs. Prefer environment variables over hard-coded values.

## API Development Guidelines

### OpenAPI Documentation (MANDATORY)
When adding or modifying API endpoints in `app/controllers/api/v1/`, you **MUST** create or update corresponding OpenAPI request specs for **DOCUMENTATION ONLY**:

1. **Location**: `spec/requests/api/v1/{resource}_spec.rb`
2. **Framework**: RSpec with rswag for OpenAPI generation
3. **Schemas**: Define reusable schemas in `spec/swagger_helper.rb`
4. **Generated Docs**: `docs/api/openapi.yaml`
5. **Regenerate**: Run `RAILS_ENV=test bundle exec rake rswag:specs:swaggerize` after changes

### Post-commit API consistency (LLM checklist)
After every API endpoint commit, ensure: (1) **Minitest** behavioral coverage in `test/controllers/api/v1/{resource}_controller_test.rb` (no behavioral assertions in rswag); (2) **rswag** remains docs-only (no `expect`/`assert_*` in `spec/requests/api/v1/`); (3) **rswag auth** uses the same API key pattern everywhere (`X-Api-Key`, not OAuth/Bearer). Full checklist: [.cursor/rules/api-endpoint-consistency.mdc](.cursor/rules/api-endpoint-consistency.mdc).

## Design System Hygiene (UI PRs)

When a PR touches `.erb`, view components, or `.css`:

1. **Tokens, not palette.** Use functional tokens from `app/assets/tailwind/sure-design-system.css` (`bg-warning/10`, `text-destructive`, `bg-container`, `text-primary`, `border-primary`). No raw Tailwind palette (`bg-blue-50`, `text-red-500`, hex literals).
2. **Reach for `DS::*` first.** Check `app/components/DS/` (`DS::Alert`, `DS::Button`, `DS::Disclosure`, `DS::Dialog`, `DS::Menu`, etc.) before writing an alert, badge, button, disclosure, dialog, or input shape.
3. **Two copies → lift to DS.** Same hand-rolled shape ≥2× in a diff with no DS equivalent → propose a new `DS::*` primitive before the second copy lands.
4. **Conventions.** Use the `icon` helper (never `lucide_icon` directly), no raw SVG outside DS primitives, user-facing strings via `t()`, avoid arbitrary `*-[Npx]` values when a scale token fits.

Reviewers escalate violations of (2)–(3) to close/rewrite; (1) and (4) are request-changes.

## Securities Providers

If you need to add a new securities price provider (Tiingo, EODHD, Binance-style crypto, etc.), see [adding-a-securities-provider.md](./docs/llm-guides/adding-a-securities-provider.md) for the full walkthrough — provider class, registry wiring, MIC handling, settings UI, locales, and tests.

## Debug Logging for Provider Syncs

When a provider sync/import path hits a recoverable error or suspicious partial response that support may need to inspect later, prefer `DebugLogEntry.capture(...)` over `Rails.logger.*`.

- Record support-relevant diagnostics in the debug log so they surface in the super-admin-friendly `/settings/debug` UI.
- Include `category`, `level`, `message`, `source`, `provider_key`, and useful structured `metadata`.
- Attach `family` and `account_provider` when available so support can filter and trace the affected connection.
- Reserve raw Rails logging for low-value local noise; anything operators may need should go to the debug log.

## Providers: Pending Transactions and FX Metadata (SimpleFIN/Plaid/Lunchflow)

- Pending detection
  - SimpleFIN: pending when provider sends `pending: true`, or when `posted` is blank/0 and `transacted_at` is present.
  - Plaid: pending when Plaid sends `pending: true` (stored at `transaction.extra["plaid"]["pending"]` for bank/credit transactions imported via `PlaidEntry::Processor`).
  - Lunchflow: pending when API returns `isPending: true` in transaction response (stored at `transaction.extra["lunchflow"]["pending"]`).
- Storage (extras)
  - Provider metadata lives on `Transaction#extra`, namespaced (e.g., `extra["simplefin"]["pending"]`).
  - SimpleFIN FX: `extra["simplefin"]["fx_from"]`, `extra["simplefin"]["fx_date"]`.
- UI
  - Shows a small “Pending” badge when `transaction.pending?` is true.
- Variability
  - Some providers don’t expose pendings; in that case nothing is shown.
- Configuration (default-off)
  - SimpleFIN runtime toggles live in `config/initializers/simplefin.rb` via `Rails.configuration.x.simplefin.*`.
  - Lunchflow runtime toggles live in `config/initializers/lunchflow.rb` via `Rails.configuration.x.lunchflow.*`.
  - ENV-backed keys:
    - `SIMPLEFIN_INCLUDE_PENDING=1` (forces `pending=1` on SimpleFIN fetches when caller didn’t specify a `pending:` arg)
    - `SIMPLEFIN_DEBUG_RAW=1` (logs raw payload returned by SimpleFIN)
    - `LUNCHFLOW_INCLUDE_PENDING=1` (forces `include_pending=true` on Lunchflow API requests)
    - `LUNCHFLOW_DEBUG_RAW=1` (logs raw payload returned by Lunchflow)

### Provider support notes

- SimpleFIN: supports pending + FX metadata; stored under `extra["simplefin"]`.
- Plaid: supports pending when the upstream Plaid payload includes `pending: true`; stored under `extra["plaid"]`.
- Plaid investments: investment transactions currently do not store pending metadata.
- Lunchflow: supports pending via `include_pending` query parameter; stored under `extra["lunchflow"]`.
- Manual/CSV imports: no pending concept.
