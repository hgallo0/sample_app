-- Pipeline stage a prospect moves through on the way to becoming a client.
CREATE TYPE prospect_stage AS ENUM (
  'lead',
  'contacted',
  'meeting_scheduled',
  'proposal_sent',
  'negotiation',
  'client',
  'lost'
);

CREATE TABLE advisors (
  id SERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  email TEXT NOT NULL UNIQUE
);

CREATE TABLE prospects (
  id SERIAL PRIMARY KEY,
  advisor_id INTEGER NOT NULL REFERENCES advisors(id) ON DELETE CASCADE,
  first_name TEXT NOT NULL CHECK (length(trim(first_name)) > 0),
  last_name TEXT NOT NULL CHECK (length(trim(last_name)) > 0),
  email TEXT NOT NULL UNIQUE CHECK (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  phone TEXT,
  stage prospect_stage NOT NULL DEFAULT 'lead',
  estimated_value NUMERIC(12, 2) CHECK (estimated_value IS NULL OR estimated_value >= 0),
  service_fee NUMERIC(3, 1) CHECK (service_fee IS NULL OR service_fee IN (0.2, 0.5)),
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT prospects_proposal_requires_fields CHECK (
    stage NOT IN ('proposal_sent', 'negotiation', 'client')
    OR (estimated_value IS NOT NULL AND service_fee IS NOT NULL)
  )
);

CREATE INDEX idx_prospects_stage ON prospects(stage);
CREATE INDEX idx_prospects_advisor ON prospects(advisor_id);

CREATE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_prospects_updated_at
BEFORE UPDATE ON prospects
FOR EACH ROW EXECUTE FUNCTION set_updated_at();
