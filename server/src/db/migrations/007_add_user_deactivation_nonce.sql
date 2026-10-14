-- Self-service deactivation trusted the app API key alone: that static key
-- is extractable from any app build and never proved the request came from
-- the account owner, so anyone holding it could disable any user by guessing
-- a userId. Deactivation now follows a challenge-response - the user's
-- registered wallet must sign a short-lived server-issued nonce before
-- anything is disabled - so users needs a place to store the current
-- challenge.
alter table users add column if not exists deactivate_nonce text;
alter table users add column if not exists deactivate_nonce_expires_at timestamptz;
