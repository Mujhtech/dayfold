-- A push endpoint belongs to one live installation in each APNs environment.
-- Never silently transfer it based solely on possession of another installation's
-- bearer token. Re-registration by the same installation remains permitted;
-- revocation releases the endpoint for an explicitly provisioned replacement.
-- Existing duplicate registrations intentionally fail this migration for operator
-- investigation rather than choosing an owner or silently deleting credentials.
CREATE UNIQUE INDEX devices_exclusive_push_registration
    ON devices (apns_environment, apns_token)
    WHERE revoked_at IS NULL AND apns_token IS NOT NULL;
