-- Brass Tacks — CockroachDB memory layer
--
-- Design notes:
--   * Money is ALWAYS integer cents (BIGINT). Never floats, never DECIMAL-as-float.
--   * Vector indexes use a `business_id` prefix column so tenant filtering happens
--     inside the index rather than as a post-filter.
--   * Embeddings are 1024-dim (Amazon Titan Text Embeddings V2 default output).
--   * Every agent action writes an `agent_run` row. The audit trail IS the product.
--
-- Requires: CockroachDB with vector index support enabled. See 00_cluster_settings.sql.

BEGIN;

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------

CREATE TYPE IF NOT EXISTS agent_kind AS ENUM (
  'mapper',    -- chat -> business profile
  'radar',     -- nightly observation sweep
  'analyst',   -- retrieval + reasoning -> a find with a prediction
  'maker',     -- produces the done-for-you artifact
  'meter',     -- verifies prior predictions against outcomes
  'ask'        -- owner Q&A, read-only, over the Cockroach MCP server
);

CREATE TYPE IF NOT EXISTS run_status AS ENUM ('running', 'ok', 'failed');

CREATE TYPE IF NOT EXISTS observation_kind AS ENUM (
  'review',        -- a customer review
  'rival_price',   -- a competitor's price point
  'rival_menu',    -- a competitor's menu / offering
  'trend',         -- search or foot-traffic trend signal
  'social',        -- forum / social mention
  'owner_upload'   -- something the owner handed us
);

CREATE TYPE IF NOT EXISTS fact_source AS ENUM (
  'owner_chat',    -- the owner told us directly ("what only the owner knows")
  'inferred',      -- the agent concluded it
  'observed'       -- derived from an observation
);

CREATE TYPE IF NOT EXISTS find_status AS ENUM (
  'proposed',      -- analyst surfaced it, owner hasn't decided
  'accepted',      -- owner said do it now
  'later',         -- owner put it in the Later jar
  'rejected',      -- owner declined
  'live',          -- shipped; the meter is watching it
  'retired',       -- pulled after the fact (e.g. it was a miss)
  -- The pipeline produced it and declined to show it. NOT an owner decision:
  -- she never saw it, so it must never reach the Analyst's "already proposed"
  -- list (see OWNER_SEEN_STATUSES in repository.py) and must never be
  -- accepted. It is stored rather than dropped because "why was the board
  -- empty on the 4th?" has to have an answer, and because the audit trail is
  -- the product.
  'withheld'
);

CREATE TYPE IF NOT EXISTS ledger_verdict AS ENUM (
  'verified',      -- measured against real outcome data
  'estimated',     -- modeled; not yet verifiable
  'miss'           -- it did not pay off. We publish these.
);

-- ---------------------------------------------------------------------------
-- Tenant + profile
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS business (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name         STRING NOT NULL,
  category     STRING NOT NULL,              -- 'restaurant', 'salon', ...
  city         STRING,
  region       STRING,
  goal_monthly_cents BIGINT,                 -- the locked goal, e.g. +$8,000/mo
  goal_note    STRING,                       -- 'by fall'
  -- Where to look for rivals. Per business, not per deployment: the moment a
  -- second tenant signs up, an environment-wide PLACES_LATITUDE would point
  -- both of them at the same street. Geocoded from the address at signup.
  latitude     FLOAT,
  longitude    FLOAT,
  -- Structured business brief used by the profile editor. Contact details stay
  -- on owner_account and are never embedded or exposed to other tenants.
  profile_data JSONB NOT NULL DEFAULT '{}'::JSONB,
  profile_updated_at TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

-- CREATE TABLE IF NOT EXISTS does nothing to a table that already exists, so a
-- cluster provisioned before these columns existed needs them added explicitly.
-- Deleting a tenant's rows does not drop the table.
ALTER TABLE business ADD COLUMN IF NOT EXISTS latitude FLOAT;
ALTER TABLE business ADD COLUMN IF NOT EXISTS longitude FLOAT;
ALTER TABLE business ADD COLUMN IF NOT EXISTS profile_data JSONB NOT NULL DEFAULT '{}'::JSONB;
ALTER TABLE business ADD COLUMN IF NOT EXISTS profile_updated_at TIMESTAMPTZ;

-- "The leash you hold" — constraints the autopilot obeys on every run.
CREATE TABLE IF NOT EXISTS owner_rule (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id  UUID NOT NULL REFERENCES business(id) ON DELETE CASCADE,
  rule         STRING NOT NULL,
  enabled      BOOL NOT NULL DEFAULT true,
  cap_cents    BIGINT,                       -- optional spend cap for this rule
  created_at   TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  INDEX (business_id, enabled)
);

-- Profile memory: durable facts about the business. Facts change over time, so
-- they are superseded rather than mutated — the history is part of the memory.
CREATE TABLE IF NOT EXISTS business_fact (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id   UUID NOT NULL REFERENCES business(id) ON DELETE CASCADE,
  fact          STRING NOT NULL,
  source        fact_source NOT NULL,
  confidence    FLOAT NOT NULL DEFAULT 1.0,
  learned_at    TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  superseded_by UUID REFERENCES business_fact(id),
  -- True only for the bounded facts generated from the editable profile. This
  -- lets a profile edit supersede its own prior facts without retiring owner
  -- chat such as costs, capacity, or operational constraints.
  profile_managed BOOL NOT NULL DEFAULT false,
  embedding     VECTOR(1024),

  INDEX (business_id, superseded_by),
  INDEX (business_id, profile_managed, superseded_by),
  VECTOR INDEX business_fact_embed_idx (business_id, embedding vector_cosine_ops)
);
ALTER TABLE business_fact ADD COLUMN IF NOT EXISTS profile_managed BOOL NOT NULL DEFAULT false;
CREATE INDEX IF NOT EXISTS business_fact_profile_managed_idx
  ON business_fact (business_id, profile_managed, superseded_by, learned_at DESC);

-- ---------------------------------------------------------------------------
-- Audit trail
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS agent_run (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id   UUID NOT NULL REFERENCES business(id) ON DELETE CASCADE,
  agent         agent_kind NOT NULL,
  status        run_status NOT NULL DEFAULT 'running',
  started_at    TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  finished_at   TIMESTAMPTZ,
  model_id      STRING,                      -- e.g. the Bedrock model used
  input_tokens  INT,
  output_tokens INT,
  error         STRING,
  note          STRING,

  INDEX (business_id, agent, started_at DESC)
);

-- ---------------------------------------------------------------------------
-- Radar: what the agents observed
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS observation (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id   UUID NOT NULL REFERENCES business(id) ON DELETE CASCADE,
  run_id        UUID REFERENCES agent_run(id),
  kind          observation_kind NOT NULL,
  -- What the row ASSERTS, as opposed to `kind`, which says where it came from.
  -- Every web row Radar has ever written is kind='trend', so reviews, opening
  -- hours, dish prices, marketing copy and "This menu isn't available right
  -- now" were one label and nothing downstream could tell a fact that expires
  -- in minutes from one that is true next month. Nullable on purpose: rows
  -- written before typing existed keep NULL, which honestly means "we never
  -- looked" rather than a label nobody assigned. Values are the vocabulary in
  -- brasstacks.signals.STATEMENT_TYPES, kept as a STRING rather than an ENUM
  -- so refining that vocabulary does not need a type migration.
  statement_type STRING,
  content       STRING NOT NULL,             -- the text that gets embedded
  source_name   STRING,                      -- 'review site', 'forum', ...
  source_url    STRING,
  subject       STRING,                      -- which rival / which dish
  rating        FLOAT,                       -- for reviews, if present
  observed_at   TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  ingested_at   TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),

  -- Radar runs nightly and WILL re-see the same content. Dedup is part of the
  -- design, not an optimization.
  content_hash  STRING NOT NULL,

  embedding     VECTOR(1024),

  UNIQUE INDEX observation_dedup_idx (business_id, content_hash),
  INDEX (business_id, kind, observed_at DESC),
  VECTOR INDEX observation_embed_idx (business_id, embedding vector_cosine_ops)
);

-- The three live tenants' observation tables predate statement_type, and
-- CREATE TABLE IF NOT EXISTS does nothing to a table that already exists.
ALTER TABLE observation ADD COLUMN IF NOT EXISTS statement_type STRING;
CREATE INDEX IF NOT EXISTS observation_statement_idx
  ON observation (business_id, statement_type, observed_at DESC);

-- ---------------------------------------------------------------------------
-- Analyst: a find, and — critically — its prediction
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS find (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id           UUID NOT NULL REFERENCES business(id) ON DELETE CASCADE,
  run_id                UUID REFERENCES agent_run(id),

  emoji                 STRING,
  title                 STRING NOT NULL,     -- 'Tiramisu -> $9'
  -- One sentence, for the card face. The rationale is the agent's full
  -- argument and runs to a paragraph; putting that on a card built for the
  -- mock's short strings is what made the deck unreadable the first time real
  -- agent prose reached it.
  summary               STRING,
  rationale             STRING NOT NULL,     -- why the agent believes it
  move                  STRING,              -- what we will actually do
  -- Compact, bounded labels used by the For You decision surface: effort,
  -- category, move type, price point, goal, beneficiary, success signal and
  -- tags. Nullable for every find written before v40. The full argument and
  -- executable plan remain in rationale/move; this object never replaces them.
  feed_brief            JSONB,
  -- What the Coster says this move will cost: setup_cost_cents (once),
  -- recurring_daily_cost_cents (every day it runs), the basis sentence, and the
  -- priced lines behind both totals. Integer cents like every other money
  -- column here. NULL means nobody priced it — never that it is free, which is
  -- why an outage writes nothing rather than zeroes. `measured` is false until
  -- an owner confirms real spend: revenue is judged by the Meter, cost is not
  -- judged by anything yet, and the card must not imply otherwise.
  cost_estimate         JSONB,
  -- The strongest rival reading of the same evidence, and why the Analyst
  -- rejected it. Find 7c4a9124 called a Grubhub storefront broken on three
  -- fragments of one page fetched at 08:07, an hour before the restaurant
  -- opened; "the bot looked while we were shut" fits that evidence better and
  -- was never written down. NULL on every find older than 2026-08-03, and on
  -- any night the model skipped the field — absent, not "none considered".
  alternative_explanation STRING,

  -- The prediction. This is what makes the Meter possible.
  predicted_daily_cents BIGINT NOT NULL,
  confidence            FLOAT NOT NULL,
  verify_after          DATE NOT NULL,       -- do not judge this before then

  status                find_status NOT NULL DEFAULT 'proposed',
  -- Why a quality gate declined to show this one. NULL on everything that
  -- reached the board — "nothing withheld this", never an empty reason. Free
  -- text rather than a code because the useful part is the specific thing that
  -- failed ("capture taken 52 minutes before opening"), and a code would flatten
  -- nine different reasons into three the owner cannot act on.
  withheld_reason       STRING,
  -- The tier this was published at, after any demotion: current_state,
  -- pattern, opportunity or listing_fact. NULL on finds written before tiers
  -- existed — absent, never defaulted to a tier nobody assigned.
  claim_type            STRING,
  decided_at            TIMESTAMPTZ,
  -- The first owner decision is cycle 1. Reconsidering an accepted move opens
  -- a new cycle instead of erasing the original Do it, Maker task or receipt.
  decision_cycle        INT NOT NULL DEFAULT 1,
  reopened_at           TIMESTAMPTZ,
  reopen_reason_code    STRING,
  reopen_reason_note    STRING,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),

  INDEX (business_id, status, verify_after),
  INDEX (business_id, created_at DESC)
);

-- Which observations the vector search actually returned for this find, and how
-- close they were. This is the receipt proving retrieval drove the reasoning.
CREATE TABLE IF NOT EXISTS find_evidence (
  find_id        UUID NOT NULL REFERENCES find(id) ON DELETE CASCADE,
  observation_id UUID NOT NULL REFERENCES observation(id) ON DELETE CASCADE,
  similarity     FLOAT NOT NULL,             -- 1 - cosine_distance, at query time
  -- 0-based position in the merged, source-capped set the Analyst was shown.
  -- It held the order the model happened to cite in until 2026-08-03, which put
  -- a 0.088 row at rank 0 of find 8b4009e5 while its 0.299 row sat at rank 4 —
  -- and retrieval position is the claim the schema, the UI and a judge read it
  -- as making. Rows are therefore neither contiguous nor complete: a find that
  -- cites the 1st and 6th rows stores 0 and 5. Citation order is not kept.
  rank           INT NOT NULL,

  PRIMARY KEY (find_id, observation_id)
);

-- ---------------------------------------------------------------------------
-- Maker: the done-for-you artifact
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS artifact (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  find_id      UUID NOT NULL REFERENCES find(id) ON DELETE CASCADE,
  run_id       UUID REFERENCES agent_run(id),
  kind         STRING NOT NULL,              -- 'menu', 'review_reply', 'plan'
  title        STRING NOT NULL,
  s3_bucket    STRING,
  s3_key       STRING,
  preview      STRING,                       -- inline preview for the UI
  created_at   TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),

  INDEX (find_id)
);

-- ---------------------------------------------------------------------------
-- Meter: the ledger. Verified, estimated, and the honest misses.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS ledger_entry (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id           UUID NOT NULL REFERENCES business(id) ON DELETE CASCADE,
  find_id               UUID NOT NULL REFERENCES find(id) ON DELETE CASCADE,
  run_id                UUID REFERENCES agent_run(id),

  verdict               ledger_verdict NOT NULL,

  -- Snapshot of what we predicted, so the ledger stays honest even if the find
  -- is later edited. A miss must remain a miss.
  predicted_daily_cents BIGINT NOT NULL,
  -- NULL where nothing was measured. A measured 0 means the move earned
  -- nothing; NULL means nobody has checked. Collapsing the two is how a
  -- forecast gets reported back as a result — see the migration at the bottom.
  actual_daily_cents    BIGINT,

  measured_at           TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  period_start          DATE NOT NULL,
  period_end            DATE NOT NULL,
  method                STRING NOT NULL,     -- how we measured it
  note                  STRING,

  -- One verdict per find per measurement period.
  UNIQUE INDEX ledger_period_idx (find_id, period_start, period_end),
  INDEX (business_id, measured_at DESC)
);

-- ---------------------------------------------------------------------------
-- Owners: who may see a business, and how they prove it
-- ---------------------------------------------------------------------------

-- One login per business. Not a users table with a join table: a business has
-- exactly one owner here, and inventing team membership before anyone has asked
-- for it would be inventing a permissions model too.
CREATE TABLE IF NOT EXISTS owner_account (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  -- Nullable, and that is the point: signup is two steps, and the account
  -- exists from the first one. Carrying the password across a page navigation
  -- instead would mean putting it in sessionStorage or a URL, and a password in
  -- browser storage is the thing this design exists to avoid.
  business_id   UUID REFERENCES business(id) ON DELETE CASCADE,
  -- Stored casefolded. Usernames that differ only by case are the same person
  -- as far as anyone typing one is concerned, and letting both exist is a
  -- support problem disguised as a feature.
  username      STRING NOT NULL,
  -- scrypt, as 'scrypt$n$r$p$salt$hash'. Never the password itself, and never
  -- anything reversible.
  password_hash STRING NOT NULL,
  -- Owner contact data is deterministic profile state, not vector memory.
  display_name  STRING,
  email         STRING,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  last_login_at TIMESTAMPTZ,

  UNIQUE INDEX owner_account_username_idx (username)
);

-- A login session. The token itself is never stored — only its SHA-256 — so
-- that read access to this table is not enough to impersonate an owner.
-- Existing demo tenants predate the profile fields. Seed the three current
-- owner workspaces with the requested review inbox; new signups overwrite this
-- with the email collected during onboarding. The address is deliberately not
-- unique because one operator may own more than one business.
ALTER TABLE owner_account ADD COLUMN IF NOT EXISTS display_name STRING;
ALTER TABLE owner_account ADD COLUMN IF NOT EXISTS email STRING;
CREATE INDEX IF NOT EXISTS owner_account_business_profile_idx
  ON owner_account (business_id, email);
UPDATE owner_account
SET display_name = username
WHERE business_id IS NOT NULL
  AND (display_name IS NULL OR trim(display_name) = '');
UPDATE owner_account
SET email = 'peter.flp.2006@gmail.com'
WHERE business_id IS NOT NULL
  AND (email IS NULL OR trim(email) = '');

-- Lives below owner_account on purpose: it references owner_account(id), and
-- on a fresh cluster the referenced table has to exist first.
-- What the owner actually counted. The only source of a verified verdict.
--
-- Without this table `NoOutcomeSource` is the only outcome source that exists,
-- every verdict the Meter can ever reach is ESTIMATED, and the published hit
-- rate is permanently undefined. A move is measured when the person who runs
-- the business says what it earned — item sales, covers, a POS export — so
-- that is what this stores.
--
-- Reported in the owner's own units, because nobody knows their takings per
-- day: `amount_cents` over `basis` is what they typed, and `daily_cents` is
-- the figure derived from them for the ledger to judge. Both are kept so the
-- number can be shown back the way it was entered.
--
-- Append-only. A corrected figure is a new row; the Meter reads the newest per
-- find. Overwriting would destroy the record of what was believed when a
-- verdict was reached, which is the one thing the ledger exists to preserve.
CREATE TABLE IF NOT EXISTS find_outcome (
  id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id            UUID NOT NULL REFERENCES business(id) ON DELETE CASCADE,
  find_id                UUID NOT NULL REFERENCES find(id) ON DELETE CASCADE,
  -- Who said so. NULL survives the account being deleted; the measurement is
  -- still a fact about the business.
  reported_by_account_id UUID REFERENCES owner_account(id) ON DELETE SET NULL,

  amount_cents           BIGINT NOT NULL,     -- as entered, integer cents
  basis                  STRING NOT NULL,     -- 'day' | 'week' | 'month'
  daily_cents            BIGINT NOT NULL,     -- derived; what the Meter judges
  note                   STRING,              -- how the owner knows

  reported_at            TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),

  -- The Meter's lookup: newest report per find, and the comparison against
  -- ledger_entry.measured_at that decides whether an estimate is stale.
  INDEX find_outcome_find_idx (find_id, reported_at DESC),
  INDEX (business_id, reported_at DESC)
);

CREATE TABLE IF NOT EXISTS owner_session (
  token_hash    STRING PRIMARY KEY,
  -- Nullable for the same reason as owner_account.business_id: the owner is
  -- signed in from the credentials page, before the business exists.
  business_id   UUID REFERENCES business(id) ON DELETE CASCADE,
  account_id    UUID NOT NULL REFERENCES owner_account(id) ON DELETE CASCADE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  expires_at    TIMESTAMPTZ NOT NULL,

  INDEX (business_id),
  INDEX (expires_at)
);

-- ---------------------------------------------------------------------------
-- Immutable owner decision history
-- ---------------------------------------------------------------------------

-- Append-only owner decision history. ``find.status`` is the current feed
-- projection; this table is the audit record that explains every Do it, Pass,
-- Undo Pass and Reconsider transition across decision cycles.
CREATE TABLE IF NOT EXISTS decision_event (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id        UUID NOT NULL REFERENCES business(id) ON DELETE CASCADE,
  find_id            UUID NOT NULL REFERENCES find(id) ON DELETE CASCADE,
  decision_cycle     INT NOT NULL,
  event_type         STRING NOT NULL,
  previous_status    STRING,
  new_status         STRING NOT NULL,
  actor_account_id   UUID REFERENCES owner_account(id) ON DELETE SET NULL,
  reason_code        STRING,
  reason_note        STRING,
  source             STRING NOT NULL DEFAULT 'owner_decision',
  data               JSONB NOT NULL DEFAULT '{}'::JSONB,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),

  INDEX decision_event_find_idx (find_id, created_at DESC),
  INDEX decision_event_business_idx (business_id, created_at DESC)
);

-- ---------------------------------------------------------------------------
-- Durable multi-tenant task control plane
-- ---------------------------------------------------------------------------

-- One row per unit of agent work. CockroachDB is authoritative; SQS and Step
-- Functions deliver and orchestrate this row but never replace it. The unique
-- idempotency key makes repeated Do it clicks, queue redelivery and reconciler
-- retries converge on the same task.
CREATE TABLE IF NOT EXISTS work_task (
  id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id              UUID NOT NULL REFERENCES business(id) ON DELETE CASCADE,
  find_id                  UUID REFERENCES find(id) ON DELETE CASCADE,
  requested_by_account_id  UUID REFERENCES owner_account(id) ON DELETE SET NULL,
  agent                    STRING NOT NULL,
  task_type                STRING NOT NULL,
  status                   STRING NOT NULL DEFAULT 'queued'
                           CHECK (status IN (
                             'queued', 'running', 'waiting_user', 'completed',
                             'retry', 'failed', 'cancelled'
                           )),
  priority                 INT NOT NULL DEFAULT 100,
  idempotency_key          STRING NOT NULL,
  resource_key             STRING NOT NULL,
  approval_state           STRING NOT NULL DEFAULT 'approved'
                           CHECK (approval_state IN (
                             'not_required', 'pending', 'approved', 'rejected'
                           )),
  approved_at              TIMESTAMPTZ,
  decision_cycle           INT NOT NULL DEFAULT 1,
  attempt_count            INT NOT NULL DEFAULT 0,
  dispatch_count           INT NOT NULL DEFAULT 0,
  claimed_by               STRING,
  claim_token              UUID,
  lease_expires_at         TIMESTAMPTZ,
  next_attempt_at          TIMESTAMPTZ,
  workflow_execution_arn   STRING,
  output_artifact_id       UUID,
  input_data               JSONB NOT NULL DEFAULT '{}'::JSONB,
  output_data              JSONB NOT NULL DEFAULT '{}'::JSONB,
  last_error               STRING,
  created_at               TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  updated_at               TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  started_at               TIMESTAMPTZ,
  completed_at             TIMESTAMPTZ,
  cancel_requested_at      TIMESTAMPTZ,
  cancelled_at             TIMESTAMPTZ,
  superseded_at            TIMESTAMPTZ,

  UNIQUE INDEX work_task_idempotency_idx (idempotency_key),
  INDEX work_task_business_status_idx (business_id, status, created_at DESC),
  INDEX work_task_dispatch_idx (status, next_attempt_at, priority, created_at),
  INDEX work_task_find_idx (find_id, task_type)
);

-- Append-only operational history. The UI can explain exactly who requested a
-- task, when a worker claimed it, which retry ran, and what external receipt was
-- produced without reconstructing history from mutable status columns.
CREATE TABLE IF NOT EXISTS task_event (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id      UUID NOT NULL REFERENCES work_task(id) ON DELETE CASCADE,
  business_id  UUID NOT NULL REFERENCES business(id) ON DELETE CASCADE,
  event_type   STRING NOT NULL,
  actor_type   STRING NOT NULL DEFAULT 'system',
  actor_id     STRING,
  data         JSONB NOT NULL DEFAULT '{}'::JSONB,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),

  INDEX task_event_task_idx (task_id, created_at),
  INDEX task_event_business_idx (business_id, created_at DESC)
);

-- Every tool side effect receives its own idempotency key and receipt. Models
-- never hold credentials; the deterministic tool adapter performs the action
-- and records the provider's reference here.
CREATE TABLE IF NOT EXISTS tool_execution (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id            UUID NOT NULL REFERENCES work_task(id) ON DELETE CASCADE,
  business_id        UUID NOT NULL REFERENCES business(id) ON DELETE CASCADE,
  tool_name          STRING NOT NULL,
  status             STRING NOT NULL DEFAULT 'running'
                     CHECK (status IN (
                       'running', 'succeeded', 'failed', 'skipped', 'cancelled'
                     )),
  idempotency_key    STRING NOT NULL,
  input_data         JSONB NOT NULL DEFAULT '{}'::JSONB,
  output_data        JSONB NOT NULL DEFAULT '{}'::JSONB,
  external_reference STRING,
  error              STRING,
  started_at         TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  finished_at        TIMESTAMPTZ,

  UNIQUE INDEX tool_execution_idempotency_idx (idempotency_key),
  INDEX tool_execution_task_idx (task_id, started_at DESC),
  INDEX tool_execution_business_idx (business_id, started_at DESC)
);

-- OAuth connections for constrained external actions. Refresh tokens are KMS
-- ciphertext; no plaintext credential is stored in CockroachDB. One provider
-- connection per tenant keeps destination selection deterministic.
CREATE TABLE IF NOT EXISTS external_connection (
  id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id            UUID NOT NULL REFERENCES business(id) ON DELETE CASCADE,
  provider               STRING NOT NULL,
  account_id             UUID NOT NULL REFERENCES owner_account(id) ON DELETE CASCADE,
  status                 STRING NOT NULL DEFAULT 'pending_selection'
                         CHECK (status IN ('pending_selection', 'connected', 'error', 'revoked')),
  token_ciphertext       STRING NOT NULL,
  scopes                 JSONB NOT NULL DEFAULT '[]'::JSONB,
  external_account_name  STRING,
  external_location_name STRING,
  display_name           STRING,
  metadata               JSONB NOT NULL DEFAULT '{}'::JSONB,
  last_error             STRING,
  connected_at           TIMESTAMPTZ,
  created_at             TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  updated_at             TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  UNIQUE INDEX external_connection_provider_idx (business_id, provider),
  INDEX external_connection_account_idx (account_id, updated_at DESC)
);

-- Immutable provider delivery events for each review email. EventBridge is
-- best-effort and may duplicate or reorder events, so the provider event id is
-- unique and the UI derives delivery state from the full timeline.
CREATE TABLE IF NOT EXISTS email_event (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_event_id   STRING NOT NULL,
  tool_execution_id   UUID NOT NULL REFERENCES tool_execution(id) ON DELETE CASCADE,
  task_id             UUID NOT NULL REFERENCES work_task(id) ON DELETE CASCADE,
  business_id         UUID NOT NULL REFERENCES business(id) ON DELETE CASCADE,
  message_id          STRING NOT NULL,
  event_type          STRING NOT NULL,
  event_at            TIMESTAMPTZ NOT NULL,
  recipient           STRING,
  link                STRING,
  data                JSONB NOT NULL DEFAULT '{}'::JSONB,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),

  UNIQUE INDEX email_event_provider_idx (provider_event_id),
  INDEX email_event_tool_idx (tool_execution_id, event_at),
  INDEX email_event_message_idx (message_id, event_at),
  INDEX email_event_business_idx (business_id, event_at DESC)
);

-- Artifact identity is task-scoped. A Lambda retry may call insert twice after
-- the first write succeeded but before the task row was completed; this unique
-- key returns the first artifact instead of producing a duplicate draft.
ALTER TABLE artifact ADD COLUMN IF NOT EXISTS task_id UUID REFERENCES work_task(id) ON DELETE SET NULL;
ALTER TABLE artifact ADD COLUMN IF NOT EXISTS idempotency_key STRING;
ALTER TABLE artifact ADD COLUMN IF NOT EXISTS body STRING;
ALTER TABLE artifact ADD COLUMN IF NOT EXISTS summary STRING;
ALTER TABLE artifact ADD COLUMN IF NOT EXISTS owner_action STRING;
ALTER TABLE artifact ADD COLUMN IF NOT EXISTS review_state STRING NOT NULL DEFAULT 'ready_for_review';
ALTER TABLE artifact ADD COLUMN IF NOT EXISTS metadata JSONB NOT NULL DEFAULT '{}'::JSONB;
ALTER TABLE artifact ADD COLUMN IF NOT EXISTS revision INT NOT NULL DEFAULT 1;
ALTER TABLE artifact ADD COLUMN IF NOT EXISTS parent_artifact_id UUID REFERENCES artifact(id) ON DELETE SET NULL;
ALTER TABLE artifact ADD COLUMN IF NOT EXISTS decision_cycle INT NOT NULL DEFAULT 1;
ALTER TABLE artifact ADD COLUMN IF NOT EXISTS superseded_at TIMESTAMPTZ;
ALTER TABLE work_task ADD COLUMN IF NOT EXISTS decision_cycle INT NOT NULL DEFAULT 1;
ALTER TABLE work_task ADD COLUMN IF NOT EXISTS cancel_requested_at TIMESTAMPTZ;
ALTER TABLE work_task ADD COLUMN IF NOT EXISTS cancelled_at TIMESTAMPTZ;
ALTER TABLE work_task ADD COLUMN IF NOT EXISTS superseded_at TIMESTAMPTZ;
ALTER TABLE find ADD COLUMN IF NOT EXISTS decision_cycle INT NOT NULL DEFAULT 1;
ALTER TABLE find ADD COLUMN IF NOT EXISTS reopened_at TIMESTAMPTZ;
ALTER TABLE find ADD COLUMN IF NOT EXISTS reopen_reason_code STRING;
ALTER TABLE find ADD COLUMN IF NOT EXISTS reopen_reason_note STRING;
CREATE UNIQUE INDEX IF NOT EXISTS artifact_idempotency_idx
  ON artifact (idempotency_key);
CREATE INDEX IF NOT EXISTS artifact_task_idx ON artifact (task_id, created_at DESC);
CREATE INDEX IF NOT EXISTS artifact_current_idx
  ON artifact (find_id, superseded_at, created_at DESC);
CREATE INDEX IF NOT EXISTS work_task_cycle_idx
  ON work_task (find_id, decision_cycle, created_at DESC);
CREATE INDEX IF NOT EXISTS find_reopened_idx
  ON find (business_id, reopened_at DESC);

-- ---------------------------------------------------------------------------
-- Additive migrations for clusters provisioned before a column existed.
-- CREATE TABLE IF NOT EXISTS does nothing to a table that already exists, and
-- deleting a tenant's rows does not drop the table. These run last, so every
-- table they name has certainly been created above.
-- ---------------------------------------------------------------------------

ALTER TABLE find ADD COLUMN IF NOT EXISTS summary STRING;
ALTER TABLE find ADD COLUMN IF NOT EXISTS feed_brief JSONB;
ALTER TABLE find ADD COLUMN IF NOT EXISTS cost_estimate JSONB;

-- An account is created before its business (see owner_account above). Clusters
-- provisioned when this was NOT NULL need the constraint dropped.
ALTER TABLE owner_account ALTER COLUMN business_id DROP NOT NULL;
ALTER TABLE owner_session ALTER COLUMN business_id DROP NOT NULL;

-- The operator. Not a role system: there is one privilege in this product and
-- it is "may read every tenant", which is the Memory Engine's whole job. A
-- boolean is the honest shape until there is a second privilege to name.
ALTER TABLE owner_account ADD COLUMN IF NOT EXISTS is_admin BOOL NOT NULL DEFAULT false;

-- Whether the agents work for this business tonight. Every active tenant costs
-- a Tavily search, ~50 embeddings and a Claude call per night, so this is a
-- spend control as much as a lifecycle flag. Defaults to active: a business
-- that just signed up wants a night.
ALTER TABLE business ADD COLUMN IF NOT EXISTS status STRING NOT NULL DEFAULT 'active';

-- The ledger's actual column was NOT NULL DEFAULT 0, so an estimated verdict
-- had to store *some* number — and the Meter stored the prediction, which put
-- the agent's own forecast in a column the owner reads as measured. The column
-- has to be able to say nothing. Dropping the default as well as the
-- constraint: a default of 0 would silently reinstate the same lie, because 0
-- is the measurable outcome of a move that flopped.
ALTER TABLE ledger_entry ALTER COLUMN actual_daily_cents DROP NOT NULL;
ALTER TABLE ledger_entry ALTER COLUMN actual_daily_cents DROP DEFAULT;

-- The rival reading the Analyst rejected, stored beside the prediction it
-- survived. Also in decision_schema.py's request-time bootstrap, because the
-- night now names this column in every INSERT INTO find: a cluster without it
-- would store no finds at all until someone ran this file.
ALTER TABLE find ADD COLUMN IF NOT EXISTS alternative_explanation STRING;

-- The reason a quality gate declined to show a find. Also in
-- decision_schema.py, because the night names this column in its INSERT INTO
-- find alongside the status.
ALTER TABLE find ADD COLUMN IF NOT EXISTS withheld_reason STRING;
ALTER TABLE find ADD COLUMN IF NOT EXISTS claim_type STRING;

-- ---------------------------------------------------------------------------
-- Sign in with Google
-- ---------------------------------------------------------------------------

-- How this account proves who it is. 'password' for everyone who typed one,
-- 'google' for everyone who did not. Defaulting to 'password' is what makes
-- this additive: every account that already exists got here with a password.
ALTER TABLE owner_account ADD COLUMN IF NOT EXISTS auth_provider STRING NOT NULL DEFAULT 'password';

-- The provider's stable identifier for the person — Google's `sub`. This and
-- not the email is the account key: people change their address and keep being
-- themselves, and `owner_account.email` is not unique anyway (the seed UPDATEs
-- above give several tenants the same inbox), so it identifies nobody.
ALTER TABLE owner_account ADD COLUMN IF NOT EXISTS provider_subject STRING;

-- An account that signs in through Google has no password to store. NULL, not
-- an empty string or an unguessable placeholder: a placeholder is a value that
-- could in principle be hashed to, and NULL is the honest statement that there
-- is nothing here. `verify_password` refuses it, and login.py pays the decoy
-- hash anyway so the refusal is not faster than a real one.
ALTER TABLE owner_account ALTER COLUMN password_hash DROP NOT NULL;

-- One account per external identity. Partial, so the many rows with a NULL
-- subject — every password account — do not collide with each other.
CREATE UNIQUE INDEX IF NOT EXISTS owner_account_provider_idx
  ON owner_account (auth_provider, provider_subject)
  WHERE provider_subject IS NOT NULL;

-- The one-time code that stands in for a session across the OAuth redirect.
--
-- Why this table exists at all: the OAuth callback is a browser redirect, so
-- anything it returns ends up in a URL, and a URL reaches browser history, the
-- next request's Referer header, and access logs. CLAUDE.md rejected capability
-- URLs for exactly that reason. So the callback stores a code here and the
-- landing page POSTs it back for the real token.
--
-- Only the code's SHA-256 is stored, on the same rule as owner_session: a read
-- of this table must not yield anything redeemable.
CREATE TABLE IF NOT EXISTS oauth_handoff (
  code_hash  STRING PRIMARY KEY,
  account_id UUID NOT NULL REFERENCES owner_account(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  -- Minutes, not days. The page redeems this on load; the window only has to
  -- cover a redirect.
  expires_at TIMESTAMPTZ NOT NULL,

  INDEX (expires_at)
);

COMMIT;

-- ---------------------------------------------------------------------------
-- Outside the transaction on purpose.
--
-- CockroachDB refuses ALTER TYPE ... ADD VALUE inside a multi-statement
-- transaction. Left above the COMMIT it does not fail alone — it fails the
-- entire file, so a cluster provisioned before 2026-08-04 would get none of
-- the migrations above it either. CREATE TYPE IF NOT EXISTS does nothing to a
-- type that already exists, which is why the value added to the enum
-- declaration near the top of this file does not reach the three live tenants.
-- ---------------------------------------------------------------------------

ALTER TYPE find_status ADD VALUE IF NOT EXISTS 'withheld';

-- A real external action starts the measurement clock. Nullable keeps every
-- pre-execution and legacy recommendation valid.
ALTER TABLE find ADD COLUMN IF NOT EXISTS executed_at TIMESTAMPTZ;
ALTER TABLE find ADD COLUMN IF NOT EXISTS execution_tool_id UUID REFERENCES tool_execution(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS find_execution_idx ON find (business_id, executed_at DESC);

-- ---------------------------------------------------------------------------
-- Quartermaster storage (2026-08-08). The DoorDash screen stops being a
-- preview: standing orders, spend authorities, stock estimates and order
-- records become per-tenant rows. The store itself stays simulated until
-- DoorDash access lands, and the screen says so; what is real is the memory.
-- Everything money-shaped is integer cents (BIGINT), never a float.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS standing_order (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id   UUID NOT NULL REFERENCES business(id) ON DELETE CASCADE,
  name          STRING NOT NULL,
  -- [["tomatoes", 8], ...] -- the same (name, quantity) pairs OrderRequest takes.
  items         JSONB NOT NULL,
  weekday       INT,
  interval_days INT,
  last_run_on   DATE,
  enabled       BOOL NOT NULL DEFAULT true,
  paused_until  DATE,
  category      STRING,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  INDEX (business_id)
);

CREATE TABLE IF NOT EXISTS purchase_authority (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id          UUID NOT NULL REFERENCES business(id) ON DELETE CASCADE,
  scope                STRING NOT NULL,
  -- ask_always | ask_if_over | auto, the Level enum in purchase_authority.py.
  level                STRING NOT NULL,
  per_order_cap_cents  BIGINT NOT NULL,
  auto_threshold_cents BIGINT,
  period_cap_cents     BIGINT,
  period_days          INT NOT NULL DEFAULT 7,
  enabled              BOOL NOT NULL DEFAULT true,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  INDEX (business_id)
);

CREATE TABLE IF NOT EXISTS stock_item (
  id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id              UUID NOT NULL REFERENCES business(id) ON DELETE CASCADE,
  name                     STRING NOT NULL,
  reorder_at               INT NOT NULL,
  usage_per_week           INT NOT NULL,
  reorder_quantity         INT NOT NULL DEFAULT 1,
  last_purchased_on        DATE,
  last_purchased_quantity  INT,
  category                 STRING,
  created_at               TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  INDEX (business_id)
);

CREATE TABLE IF NOT EXISTS supply_order (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id        UUID NOT NULL REFERENCES business(id) ON DELETE CASCADE,
  title              STRING NOT NULL,
  -- owner_instruction | standing_order | stock_threshold | find.
  trigger            STRING NOT NULL,
  -- placed | awaiting_approval | failed | rejected.
  status             STRING NOT NULL,
  items              JSONB NOT NULL,
  category           STRING,
  -- The priced cart the owner saw, for the approval screen and the receipt.
  cart               JSONB,
  total_cents        BIGINT,
  reason             STRING,
  -- Binds an approval to the exact cart at the exact price (ordering.py).
  fingerprint        STRING,
  external_reference STRING,
  payment_reference  STRING,
  -- stripe | simulated -- the UI labels the receipt with which one was real.
  payment_provider   STRING,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  decided_at         TIMESTAMPTZ,
  INDEX (business_id, status),
  INDEX (business_id, created_at DESC)
);

-- Which shop the Quartermaster talks to (2026-08-08): simulated by default,
-- doordash when the waitlist clears, or the owner's supplier by email. One
-- row per business; absence means simulated, so a fresh tenant can never
-- accidentally send a real order anywhere.
CREATE TABLE IF NOT EXISTS orders_setting (
  business_id    UUID PRIMARY KEY REFERENCES business(id) ON DELETE CASCADE,
  supplier       STRING NOT NULL DEFAULT 'simulated',
  supplier_email STRING,
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

-- The humans who supply the business: the produce rep, the fish guy. A row
-- here is what lets the agent draft them a message; the category is how
-- "my produce rep" resolves to a person.
CREATE TABLE IF NOT EXISTS supplier_contact (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES business(id) ON DELETE CASCADE,
  name        STRING NOT NULL,
  -- At least one of email / phone, enforced by the store: a rep the agent
  -- cannot reach on any channel is not a contact.
  email       STRING,
  phone       STRING,
  category    STRING,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  INDEX supplier_contact_by_business (business_id)
);

-- CREATE TABLE IF NOT EXISTS does nothing to a table that already exists.
ALTER TABLE supplier_contact ADD COLUMN IF NOT EXISTS phone STRING;
ALTER TABLE supplier_contact ALTER COLUMN email DROP NOT NULL;

-- Messages the agent drafted for a rep. status: draft | sent | discarded.
-- A draft costs nothing; only the owner's explicit send moves it to 'sent',
-- and the transition is guarded WHERE status = 'draft' so it happens once.
CREATE TABLE IF NOT EXISTS supplier_message (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id        UUID NOT NULL REFERENCES business(id) ON DELETE CASCADE,
  contact_id         UUID NOT NULL REFERENCES supplier_contact(id)
                     ON DELETE CASCADE,
  subject            STRING NOT NULL,
  body               STRING NOT NULL,
  -- email | whatsapp. iMessage is deliberately absent: Apple offers no API
  -- a server could call, so offering it would be a simulation wearing the
  -- wrong name.
  channel            STRING NOT NULL DEFAULT 'email',
  status             STRING NOT NULL DEFAULT 'draft',
  external_reference STRING,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  sent_at            TIMESTAMPTZ,
  INDEX supplier_message_by_business (business_id, created_at DESC)
);

ALTER TABLE supplier_message
  ADD COLUMN IF NOT EXISTS channel STRING NOT NULL DEFAULT 'email';
-- Order-by-email folded into rep messaging: a message may carry a priced
-- cart (kind = 'order'), estimates at last known prices. The supplier
-- invoices directly, so no card is ever charged on this path.
ALTER TABLE supplier_message
  ADD COLUMN IF NOT EXISTS kind STRING NOT NULL DEFAULT 'note';
ALTER TABLE supplier_message ADD COLUMN IF NOT EXISTS cart JSONB;
ALTER TABLE supplier_message ADD COLUMN IF NOT EXISTS total_cents INT8;
