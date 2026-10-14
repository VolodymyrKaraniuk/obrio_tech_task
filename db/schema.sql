-- Access-request storage (database "app", owner "app").
-- Applied automatically by the db-init service on every `docker compose up` (idempotent).

CREATE TABLE IF NOT EXISTS access_requests (
  request_ref          text PRIMARY KEY,               -- "<first message ts>#<n>"
  channel              text        NOT NULL,
  thread_ts            text        NOT NULL,
  source_message_ts    jsonb       NOT NULL,
  requester            text        NOT NULL,
  for_user             text,
  resource             text,
  environment          text,
  access_level         text,
  justification        text,
  duration             text,
  status               text        NOT NULL CHECK (status IN ('complete', 'incomplete')),
  missing_fields       jsonb       NOT NULL DEFAULT '[]',
  clarifying_question  text,
  flags                jsonb       NOT NULL,             -- LLM flags
  redacted             boolean     NOT NULL DEFAULT false, -- unused by obrio (no masking before the LLM); kept for compatibility
  is_risky             boolean     NOT NULL,
  risk_level           text        NOT NULL DEFAULT 'low' CHECK (risk_level IN ('low', 'medium', 'high')),
  risk_reasons         jsonb       NOT NULL DEFAULT '[]',
  route                text        NOT NULL CHECK (route IN ('standard_approval', 'devops_review', 'needs_clarification')),
  model                text,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now()
);
-- Added after the first version of the table.
ALTER TABLE access_requests ADD COLUMN IF NOT EXISTS risk_level text NOT NULL DEFAULT 'low'
  CHECK (risk_level IN ('low', 'medium', 'high'));
-- Decision recorded by the Slack flow (workflow "obrio"):
--   accepted: true = accepted, false = rejected, NULL = no decision yet (e.g. clarification asked).
ALTER TABLE access_requests ADD COLUMN IF NOT EXISTS accepted   boolean;
ALTER TABLE access_requests ADD COLUMN IF NOT EXISTS decision   text
  CHECK (decision IN ('auto_approved', 'approved_manually', 'rejected_manually', 'clarification_requested'));
ALTER TABLE access_requests ADD COLUMN IF NOT EXISTS decided_at timestamptz;
-- Who asks, readable (Slack users.info), so TechOps does not have to look up user IDs.
ALTER TABLE access_requests ADD COLUMN IF NOT EXISTS requester_name  text;
ALTER TABLE access_requests ADD COLUMN IF NOT EXISTS requester_email text;
CREATE INDEX IF NOT EXISTS access_requests_thread_idx ON access_requests (channel, thread_ts);
CREATE INDEX IF NOT EXISTS access_requests_route_idx  ON access_requests (route);

CREATE TABLE IF NOT EXISTS non_requests (
  channel     text        NOT NULL,
  thread_ts   text        NOT NULL,
  message_ts  text        NOT NULL,
  reason      text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (channel, message_ts)
);

-- parse_failures belonged to the removed polling pipeline.
DROP VIEW IF EXISTS request_report;
DROP TABLE IF EXISTS parse_failures;
CREATE VIEW request_report AS
SELECT
  (SELECT count(*) FROM access_requests)                                  AS total_requests,
  (SELECT count(*) FROM access_requests WHERE status = 'complete')        AS complete,
  (SELECT count(*) FROM access_requests WHERE status = 'incomplete')      AS incomplete,
  (SELECT count(*) FROM access_requests WHERE is_risky)                   AS risky,
  (SELECT count(*) FROM access_requests WHERE risk_level = 'high')        AS risk_high,
  (SELECT count(*) FROM access_requests WHERE accepted IS TRUE)           AS accepted,
  (SELECT count(*) FROM access_requests WHERE accepted IS FALSE)          AS rejected,
  (SELECT count(*) FROM access_requests WHERE accepted IS NULL)           AS pending_decision,
  (SELECT count(*) FROM non_requests)                                     AS non_requests,
  (SELECT count(*) FROM access_requests WHERE route = 'standard_approval')   AS route_standard_approval,
  (SELECT count(*) FROM access_requests WHERE route = 'devops_review')       AS route_devops_review,
  (SELECT count(*) FROM access_requests WHERE route = 'needs_clarification') AS route_needs_clarification;

-- One row per request, in the shape TechOps needs to actually grant the access.
DROP VIEW IF EXISTS access_to_grant;
CREATE VIEW access_to_grant AS
SELECT
  request_ref,
  coalesce(requester_name, requester)                     AS requested_by,
  requester_email,
  coalesce(for_user, requester_name, requester)           AS grant_to,
  resource,
  environment,
  access_level,
  CASE
    WHEN duration = 'permanent' THEN 'безстроково'
    WHEN duration ~ '^P[0-9YMWDTH]+$' THEN (duration::interval)::text
  END                                                     AS duration,
  CASE                                                    -- only for accepted requests
    WHEN accepted AND duration ~ '^P[0-9YMWDTH]+$' THEN decided_at + duration::interval
  END                                                     AS access_until,
  justification,
  accepted,
  decision,
  decided_at,
  risk_level,
  route,
  created_at
FROM access_requests
ORDER BY created_at DESC;

ALTER TABLE access_requests OWNER TO app;
ALTER TABLE non_requests    OWNER TO app;
ALTER VIEW request_report   OWNER TO app;
ALTER VIEW access_to_grant  OWNER TO app;
