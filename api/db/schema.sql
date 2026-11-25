DO $$ BEGIN
    CREATE TYPE design_status AS ENUM (
        'draft',
        'pending_review',
        'approved',
        'rejected'
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE TYPE print_job_status AS ENUM (
        'pending',
        'claimed',
        'printing',
        'completed',
        'failed',
        'cancelled'
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
DO $$ BEGIN
    CREATE TYPE payout_status AS ENUM (
        'pending',
        'paid',
        'failed'
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS designers (
    designer_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(255) NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT designers_name_not_blank
        CHECK (LENGTH(TRIM(name)) > 0)
);

CREATE TABLE IF NOT EXISTS reviewers (
    reviewer_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name VARCHAR(100) NOT NULL UNIQUE,
    email VARCHAR(255) UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT reviewers_name_not_blank
        CHECK (LENGTH(TRIM(name)) > 0)
);

CREATE TABLE IF NOT EXISTS designs (
    design_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    designer_id BIGINT NOT NULL
        REFERENCES designers(designer_id),

    title VARCHAR(200) NOT NULL,
    description TEXT NOT NULL,

    price NUMERIC(10,2) NOT NULL DEFAULT 0,

    status design_status NOT NULL DEFAULT 'draft',

    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT designs_price_nonnegative
        CHECK (price >= 0),

    CONSTRAINT designs_title_not_blank
        CHECK (LENGTH(TRIM(title)) > 0),

    CONSTRAINT designs_content_present
        CHECK (LENGTH(TRIM(description)) > 0)
);
