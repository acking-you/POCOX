-- Pairing-code login: linked devices as users, with no GitHub identity.
--
-- Separate tables on purpose: users.github_id stays NOT NULL UNIQUE and existing
-- GitHub rows and tokens are not migrated. Relay key ids and namespaces are u64,
-- so they are canonical decimal TEXT, never a signed INTEGER. No plaintext device
-- secret, code or raw hardware identifier is stored anywhere here.

CREATE TABLE device_users (
    -- "du" + 32 hex characters, disjoint from users.id (32 hex characters), which
    -- GitHub sessions use for `sub` and credential ownership.
    id                  TEXT    PRIMARY KEY NOT NULL,
    -- The relay namespace: NULL until the first key, then fixed. UNIQUE because a
    -- backend talks to one relay; a conflict means the relay repeated a number.
    namespace           TEXT    UNIQUE,
    membership_revision INTEGER NOT NULL DEFAULT 0,
    created_at          INTEGER NOT NULL
) STRICT;

CREATE TABLE devices (
    id                    TEXT    PRIMARY KEY NOT NULL,
    user_id               TEXT    NOT NULL REFERENCES device_users(id),
    label                 TEXT    NOT NULL,
    platform              TEXT,
    -- Set at activation; the latest device to activate with a hint holds it.
    hardware_lookup       BLOB    UNIQUE,
    hardware_source       TEXT,
    session_generation    INTEGER NOT NULL,
    code_generation       INTEGER NOT NULL,
    code_lookup           BLOB    NOT NULL UNIQUE,
    code_issued_at        INTEGER NOT NULL,
    code_paused           INTEGER NOT NULL DEFAULT 0 CHECK (code_paused IN (0, 1)),
    -- Bumped on every pause, so resuming cannot revive a ticket from before it.
    code_pause_epoch      INTEGER NOT NULL DEFAULT 0,
    created_at            INTEGER NOT NULL,
    joined_at             INTEGER NOT NULL,
    activated_at          INTEGER,
    -- Never cleared, unlike activated_at, which a removal clears: retention tells a
    -- device that was once in use from a first screen nobody continued.
    first_activated_at    INTEGER,
    first_key_at          INTEGER,
    -- The session generation of the last key issued. A later key in this generation
    -- replaces one that merely ended, which nothing a fleet does can force.
    key_generation        INTEGER,
    -- Days since the unix epoch.
    last_active_day       INTEGER NOT NULL,
    last_transition_kind  TEXT    CHECK (last_transition_kind IN
                              ('linked', 'left', 'removed', 'restored', 'retaken')),
    last_transition_at    INTEGER,
    -- The durable operation moving this device, if any. Blocks competing changes
    -- and new key issue or renewal.
    pending_transition_id TEXT,
    retake_window_start   INTEGER,
    retake_count          INTEGER NOT NULL DEFAULT 0
) STRICT;

CREATE INDEX idx_devices_user ON devices(user_id);
CREATE INDEX idx_devices_pending ON devices(pending_transition_id)
    WHERE pending_transition_id IS NOT NULL;

CREATE TABLE device_sessions (
    device_id        TEXT    NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    generation       INTEGER NOT NULL,
    -- SHA-256 of the device secret. A membership move keeps it in historical rows;
    -- a restore takes the requester's and deletes that row in the same commit.
    secret_hash      BLOB    NOT NULL,
    original_user_id TEXT    NOT NULL,
    state            TEXT    NOT NULL CHECK (state IN ('current', 'grace', 'revoked')),
    -- Fixed when a replacement is prepared and never extended. On a 'current' row
    -- it means a replacement is under way: the session is already limited to it.
    grace_deadline   INTEGER,
    retired_at       INTEGER,
    created_at       INTEGER NOT NULL,
    PRIMARY KEY (device_id, generation)
) STRICT;

CREATE INDEX idx_device_sessions_hash ON device_sessions(secret_hash);
CREATE UNIQUE INDEX uq_device_sessions_current_device ON device_sessions(device_id)
    WHERE state = 'current';
CREATE UNIQUE INDEX uq_device_sessions_current_hash ON device_sessions(secret_hash)
    WHERE state = 'current';

CREATE TABLE pair_restore_requests (
    id                  TEXT    PRIMARY KEY NOT NULL,
    requester_device_id TEXT    NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    target_device_id    TEXT    NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    target_user_id      TEXT    NOT NULL,
    target_generation   INTEGER NOT NULL,
    target_revision     INTEGER NOT NULL,
    state               TEXT    NOT NULL CHECK (state IN
                            ('pending', 'approved', 'denied', 'expired', 'stale')),
    created_at          INTEGER NOT NULL,
    expires_at          INTEGER NOT NULL,
    approval_expires_at INTEGER,
    updated_at          INTEGER NOT NULL
) STRICT;

CREATE UNIQUE INDEX uq_restore_requester_open ON pair_restore_requests(requester_device_id)
    WHERE state IN ('pending', 'approved');
CREATE INDEX idx_restore_target ON pair_restore_requests(target_device_id, state);
CREATE INDEX idx_restore_target_user ON pair_restore_requests(target_user_id, state);

-- A durable membership change. Outlives the devices it names, so it has no foreign
-- keys: a result stays readable after a restore deletes its requester.
CREATE TABLE pair_operations (
    id                     TEXT    PRIMARY KEY NOT NULL,
    kind                   TEXT    NOT NULL CHECK (kind IN
                               ('link', 'leave', 'remove', 'restore', 'retake', 'rotate', 'decide')),
    -- Hash of the exact request, so reusing an id with other input fails.
    fingerprint            BLOB    NOT NULL,
    actor_device_id        TEXT    NOT NULL,
    -- Results are authorized to this secret, which survives every move of the actor.
    actor_secret_hash      BLOB    NOT NULL,
    subject_device_id      TEXT    NOT NULL,
    subject_generation     INTEGER NOT NULL,
    source_user_id         TEXT    NOT NULL,
    source_revision        INTEGER NOT NULL,
    destination_user_id    TEXT,
    destination_revision   INTEGER,
    -- The device whose code authorized this, and that code's generation.
    code_device_id         TEXT,
    code_generation        INTEGER,
    code_pause_epoch       INTEGER,
    request_id             TEXT,
    -- The single-device user a leave or removal creates.
    new_user_id            TEXT,
    hardware_lookup        BLOB,
    hardware_source        TEXT,
    grace_deadline         INTEGER,
    state                  TEXT    NOT NULL CHECK (state IN
                               ('prepared', 'relay_applied', 'committed', 'failed')),
    -- Set before the first relay call: a failure after it can no longer undo.
    relay_started          INTEGER NOT NULL DEFAULT 0 CHECK (relay_started IN (0, 1)),
    -- It committed without moving anyone. One such row per device and kind is kept.
    no_op                  INTEGER NOT NULL DEFAULT 0 CHECK (no_op IN (0, 1)),
    result_code            TEXT,
    result_device_id       TEXT,
    attempts               INTEGER NOT NULL DEFAULT 0,
    next_attempt_at        INTEGER,
    created_at             INTEGER NOT NULL,
    updated_at             INTEGER NOT NULL,
    completed_at           INTEGER
) STRICT;

CREATE INDEX idx_pair_operations_open ON pair_operations(state)
    WHERE state IN ('prepared', 'relay_applied');
CREATE INDEX idx_pair_operations_done ON pair_operations(completed_at)
    WHERE completed_at IS NOT NULL;

-- Every relay key that may still authenticate. Outlives its device on purpose: a
-- purge must not forget a key that still works.
CREATE TABLE device_relay_keys (
    -- The grant operation: persisted before the relay is called and named in the
    -- key's label, which is how a lost response is found again.
    grant_id       TEXT    PRIMARY KEY NOT NULL,
    device_id      TEXT    NOT NULL,
    generation     INTEGER NOT NULL,
    user_id        TEXT    NOT NULL,
    namespace      TEXT    NOT NULL,
    relay_instance TEXT    NOT NULL,
    label          TEXT    NOT NULL,
    -- NULL until the relay's answer is persisted.
    key_id         TEXT,
    -- In the relay's clock, as its last answer stated. Only ever compared with
    -- another of the relay's answers, so no clock agreement is needed.
    expires_at     INTEGER,
    -- The same moment in the backend's clock, from the lifetime it asked for. Good
    -- enough to never lengthen a key; a deadline is enforced by the relay's own timer.
    local_end      INTEGER,
    -- The backend-clock moment this key must never outlive.
    hard_cutoff    INTEGER,
    -- The relay has not yet confirmed that cutoff. It stays owed through a failed
    -- operation, so an old key cannot run on to its full life.
    cutoff_pending INTEGER NOT NULL DEFAULT 0 CHECK (cutoff_pending IN (0, 1)),
    state          TEXT    NOT NULL CHECK (state IN
                       ('granting', 'active', 'revoked', 'expired', 'dead')),
    created_at     INTEGER NOT NULL,
    updated_at     INTEGER NOT NULL,
    ended_at       INTEGER
) STRICT;

CREATE UNIQUE INDEX uq_relay_keys_id ON device_relay_keys(relay_instance, key_id)
    WHERE key_id IS NOT NULL;
CREATE UNIQUE INDEX uq_relay_keys_generation ON device_relay_keys(device_id, generation)
    WHERE state IN ('granting', 'active');
CREATE INDEX idx_relay_keys_device ON device_relay_keys(device_id, state);
CREATE INDEX idx_relay_keys_open ON device_relay_keys(state)
    WHERE state IN ('granting', 'active');

CREATE TABLE retired_codes (
    code_lookup BLOB    PRIMARY KEY NOT NULL,
    retired_at  INTEGER NOT NULL
) STRICT;

-- Non-secret verification of the pairing key, to catch an accidental change.
CREATE TABLE pairing_metadata (
    key   TEXT PRIMARY KEY NOT NULL,
    value BLOB NOT NULL
) STRICT;

-- Backend-wide admission budgets. In the database because every process sharing
-- this database must draw from one budget, not multiply it.
CREATE TABLE pairing_budgets (
    name         TEXT    PRIMARY KEY NOT NULL,
    window_start INTEGER NOT NULL,
    used         INTEGER NOT NULL
) STRICT;
