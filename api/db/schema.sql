CREATE TYPE design_status AS ENUM (
    'draft',
    'pending_review',
    'approved',
    'rejected'
);

CREATE TYPE print_job_status AS ENUM (
    'pending',
    'printing',
    'completed',
    'failed',
    'cancelled'
);

CREATE TYPE payout_status AS ENUM (
    'pending',
    'paid',
    'failed'
);

CREATE TABLE designers (
    designer_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(255) NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE designs (
    design_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    designer_id BIGINT NOT NULL
        REFERENCES designers(designer_id),
    title VARCHAR(200) NOT NULL,
    description TEXT,
    price NUMERIC(10, 2) NOT NULL DEFAULT 0,
    status design_status NOT NULL DEFAULT 'draft',
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE print_jobs (
    job_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    design_id BIGINT NOT NULL REFERENCES designs(design_id),
    status print_job_status NOT NULL DEFAULT 'pending',
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE sales (
    sale_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    design_id BIGINT NOT NULL REFERENCES designs(design_id),
    quantity INTEGER NOT NULL,
    unit_price NUMERIC(10, 2) NOT NULL,
    sold_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE designer_payouts (
    payout_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    designer_id BIGINT NOT NULL REFERENCES designers(designer_id),
    sale_id BIGINT NOT NULL UNIQUE REFERENCES sales(sale_id),
    amount NUMERIC(10, 2) NOT NULL,
    status payout_status NOT NULL DEFAULT 'pending',
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE designs
    ADD CONSTRAINT designs_price_nonnegative
    CHECK (price >= 0);

ALTER TABLE designs
    ADD CONSTRAINT designs_title_not_blank
    CHECK (LENGTH(TRIM(title)) > 0);

ALTER TABLE sales
    ADD CONSTRAINT sales_quantity_positive
    CHECK (quantity > 0);

ALTER TABLE sales
    ADD CONSTRAINT sales_unit_price_nonnegative
    CHECK (unit_price >= 0);

ALTER TABLE designer_payouts
    ADD CONSTRAINT payouts_amount_nonnegative
    CHECK (amount >= 0);

ALTER TABLE designs
    ADD CONSTRAINT designs_content_present
    CHECK (
        description IS NOT NULL
        AND LENGTH(TRIM(description)) > 0
    );


CREATE OR REPLACE FUNCTION set_print_job_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at := CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_print_job_updated_at
BEFORE UPDATE ON print_jobs
FOR EACH ROW
EXECUTE FUNCTION set_print_job_updated_at();
