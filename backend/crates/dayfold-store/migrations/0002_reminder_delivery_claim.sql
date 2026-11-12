-- Reading or acknowledging SSE does not prove that a reminder was presented.
-- The client must atomically take delivery ownership before APNs starts a try.
ALTER TABLE notifications
    ADD COLUMN client_claimed boolean NOT NULL DEFAULT false,
    ADD CONSTRAINT client_claimed_requires_reminder
        CHECK (NOT client_claimed OR kind = 'reminder_due');
