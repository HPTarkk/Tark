-- Deleting an account from the website, for someone who can't use the app.
-- The website asks for an email; the account's address gets a one-time
-- link, and opening it proves control of the inbox, as a password reset
-- does. The flow is an auth_flows row like the others, with its own purpose.
ALTER TABLE auth_flows DROP CONSTRAINT auth_flows_purpose_check;
ALTER TABLE auth_flows ADD CONSTRAINT auth_flows_purpose_check
    CHECK (purpose IN ('register', 'password_reset', 'email_change', 'account_delete'));
