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
CREATE TABLE IF NOT EXISTS review_history (
    review_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    design_id BIGINT NOT NULL
        REFERENCES designs(design_id),

    reviewer_id BIGINT NOT NULL
        REFERENCES reviewers(reviewer_id),

    decision VARCHAR(20) NOT NULL
        CHECK (decision IN ('approved', 'rejected')),

    note TEXT NOT NULL,

    reviewed_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT review_note_not_blank
        CHECK (LENGTH(TRIM(note)) > 0)
);

CREATE TABLE IF NOT EXISTS orders (
    order_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    design_id BIGINT NOT NULL
        REFERENCES designs(design_id),

    customer_name VARCHAR(150) NOT NULL,

    quantity INTEGER NOT NULL,

    unit_price NUMERIC(10,2) NOT NULL,

    total_amount NUMERIC(12,2)
        GENERATED ALWAYS AS (quantity * unit_price) STORED,

    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT orders_quantity_positive
        CHECK (quantity > 0),

    CONSTRAINT orders_price_nonnegative
        CHECK (unit_price >= 0),

    CONSTRAINT orders_customer_not_blank
        CHECK (LENGTH(TRIM(customer_name)) > 0)
);
CREATE TABLE IF NOT EXISTS designer_payouts (
    payout_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    order_id BIGINT NOT NULL UNIQUE
        REFERENCES orders(order_id),

    amount NUMERIC(12,2) NOT NULL,

    status payout_status NOT NULL DEFAULT 'pending',

    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT payouts_amount_nonnegative
        CHECK (amount >= 0)
);
