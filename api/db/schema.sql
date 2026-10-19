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


CREATE OR REPLACE FUNCTION enforce_print_job_transition()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status = OLD.status THEN
        RETURN NEW;
    END IF;

    IF OLD.status = 'pending'
       AND NEW.status IN ('printing', 'cancelled') THEN
        RETURN NEW;
    END IF;

    IF OLD.status = 'printing'
       AND NEW.status IN ('completed', 'failed', 'cancelled') THEN
        RETURN NEW;
    END IF;

    IF OLD.status = 'failed'
       AND NEW.status IN ('pending', 'cancelled') THEN
        RETURN NEW;
    END IF;

    RAISE EXCEPTION
        'Invalid print job status transition: % -> %',
        OLD.status, NEW.status;
END;
$$;

CREATE TRIGGER trg_print_job_status_transition
BEFORE UPDATE OF status ON print_jobs
FOR EACH ROW
EXECUTE FUNCTION enforce_print_job_transition();


CREATE INDEX IF NOT EXISTS idx_designs_designer_id
ON designs(designer_id);

CREATE INDEX IF NOT EXISTS idx_designs_status
ON designs(status);

CREATE INDEX IF NOT EXISTS idx_print_jobs_design_id
ON print_jobs(design_id);

CREATE INDEX IF NOT EXISTS idx_print_jobs_status
ON print_jobs(status);

CREATE INDEX IF NOT EXISTS idx_sales_design_id
ON sales(design_id);

CREATE INDEX IF NOT EXISTS idx_designer_payouts_designer_id
ON designer_payouts(designer_id);

CREATE OR REPLACE VIEW designer_stats AS
SELECT
    d.designer_id,
    d.name,
    COUNT(DISTINCT ds.design_id) AS total_designs,
    COUNT(DISTINCT CASE
        WHEN ds.status = 'approved' THEN ds.design_id
    END) AS approved_designs,
    COUNT(DISTINCT pj.job_id) AS total_print_jobs,
    COUNT(DISTINCT CASE
        WHEN pj.status = 'completed' THEN pj.job_id
    END) AS completed_print_jobs,
    COUNT(DISTINCT s.sale_id) AS total_sales,
    COALESCE(SUM(s.quantity * s.unit_price), 0) AS total_sales_amount,
    COALESCE(SUM(dp.amount), 0) AS total_payouts
FROM designers d
LEFT JOIN designs ds
    ON d.designer_id = ds.designer_id
LEFT JOIN print_jobs pj
    ON ds.design_id = pj.design_id
LEFT JOIN sales s
    ON ds.design_id = s.design_id
LEFT JOIN designer_payouts dp
    ON d.designer_id = dp.designer_id
GROUP BY d.designer_id, d.name;
