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
CREATE TABLE IF NOT EXISTS print_jobs (
    job_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    order_id BIGINT NOT NULL UNIQUE
        REFERENCES orders(order_id),

    priority INTEGER NOT NULL DEFAULT 3,

    status print_job_status NOT NULL DEFAULT 'pending',

    worker VARCHAR(100),

    lease_until TIMESTAMPTZ,

    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT print_priority_valid
        CHECK (priority BETWEEN 1 AND 5),

    CONSTRAINT print_worker_required
        CHECK (
            status NOT IN ('claimed', 'printing')
            OR (
                worker IS NOT NULL
                AND lease_until IS NOT NULL
            )
        )
);
CREATE OR REPLACE FUNCTION enforce_design_status_transition()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status = OLD.status THEN
        RETURN NEW;
    END IF;

    IF OLD.status = 'draft'
       AND NEW.status = 'pending_review' THEN
        RETURN NEW;
    END IF;

    IF OLD.status = 'pending_review'
       AND NEW.status IN ('approved', 'rejected') THEN
        RETURN NEW;
    END IF;

    IF OLD.status = 'rejected'
       AND NEW.status = 'draft' THEN
        RETURN NEW;
    END IF;

    RAISE EXCEPTION
        'Invalid design status transition: % -> %',
        OLD.status, NEW.status;
END;
$$;

DROP TRIGGER IF EXISTS trg_design_status_transition ON designs;

CREATE TRIGGER trg_design_status_transition
BEFORE UPDATE OF status ON designs
FOR EACH ROW
EXECUTE FUNCTION enforce_design_status_transition();

CREATE OR REPLACE FUNCTION apply_review_decision()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    current_status design_status;
BEGIN
    SELECT status INTO current_status
    FROM designs
    WHERE design_id = NEW.design_id
    FOR UPDATE;

    IF current_status IS DISTINCT FROM 'pending_review' THEN
        RAISE EXCEPTION
            'Design must be pending review before a decision';
    END IF;

    UPDATE designs
    SET status = NEW.decision::design_status
    WHERE design_id = NEW.design_id;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_apply_review_decision ON review_history;

CREATE TRIGGER trg_apply_review_decision
BEFORE INSERT ON review_history
FOR EACH ROW
EXECUTE FUNCTION apply_review_decision();

CREATE OR REPLACE FUNCTION enforce_print_job_transition()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status = OLD.status THEN
        RETURN NEW;
    END IF;

    IF OLD.status = 'pending'
       AND NEW.status IN ('claimed', 'cancelled') THEN
        RETURN NEW;
    END IF;

    IF OLD.status = 'claimed'
       AND NEW.status IN ('pending', 'printing', 'cancelled') THEN
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

DROP TRIGGER IF EXISTS trg_print_job_status_transition ON print_jobs;

CREATE TRIGGER trg_print_job_status_transition
BEFORE UPDATE OF status ON print_jobs
FOR EACH ROW
EXECUTE FUNCTION enforce_print_job_transition();

CREATE OR REPLACE FUNCTION set_print_job_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at := CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_print_job_updated_at ON print_jobs;

CREATE TRIGGER trg_print_job_updated_at
BEFORE UPDATE ON print_jobs
FOR EACH ROW
EXECUTE FUNCTION set_print_job_updated_at();
CREATE OR REPLACE FUNCTION enforce_payout_transition()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status = OLD.status THEN
        RETURN NEW;
    END IF;

    IF OLD.status = 'pending'
       AND NEW.status IN ('paid', 'failed') THEN
        RETURN NEW;
    END IF;

    IF OLD.status = 'failed'
       AND NEW.status = 'pending' THEN
        RETURN NEW;
    END IF;

    RAISE EXCEPTION
        'Invalid payout status transition: % -> %',
        OLD.status, NEW.status;
END;
$$;

DROP TRIGGER IF EXISTS trg_payout_status_transition
ON designer_payouts;

CREATE TRIGGER trg_payout_status_transition
BEFORE UPDATE OF status ON designer_payouts
FOR EACH ROW
EXECUTE FUNCTION enforce_payout_transition();
CREATE INDEX IF NOT EXISTS idx_designs_designer_id
ON designs(designer_id);

CREATE INDEX IF NOT EXISTS idx_designs_status
ON designs(status);

CREATE INDEX IF NOT EXISTS idx_review_history_design
ON review_history(design_id);

CREATE INDEX IF NOT EXISTS idx_review_history_reviewer
ON review_history(reviewer_id);

CREATE INDEX IF NOT EXISTS idx_orders_design_id
ON orders(design_id);

CREATE INDEX IF NOT EXISTS idx_orders_created_at
ON orders(created_at);

CREATE INDEX IF NOT EXISTS idx_print_jobs_queue
ON print_jobs(status, priority, created_at);

CREATE INDEX IF NOT EXISTS idx_print_jobs_order
ON print_jobs(order_id);

CREATE INDEX IF NOT EXISTS idx_print_jobs_lease
ON print_jobs(lease_until);

CREATE INDEX IF NOT EXISTS idx_payouts_status
ON designer_payouts(status);
CREATE OR REPLACE VIEW designer_stats AS

WITH design_data AS (
    SELECT
        designer_id,
        COUNT(*) AS total_designs,
        COUNT(*) FILTER (
            WHERE status = 'approved'
        ) AS approved_designs
    FROM designs
    GROUP BY designer_id
),

review_data AS (
    SELECT
        ds.designer_id,
        COUNT(rh.review_id) AS total_reviews
    FROM designs ds
    LEFT JOIN review_history rh
        ON ds.design_id = rh.design_id
    GROUP BY ds.designer_id
),

sales_data AS (
    SELECT
        ds.designer_id,
        COUNT(o.order_id) AS total_sales,
        COALESCE(SUM(o.total_amount), 0) AS total_sales_amount
    FROM designs ds
    LEFT JOIN orders o
        ON ds.design_id = o.design_id
    GROUP BY ds.designer_id
),

print_data AS (
    SELECT
        ds.designer_id,
        COUNT(pj.job_id) AS total_print_jobs,
        COUNT(pj.job_id) FILTER (
            WHERE pj.status = 'completed'
        ) AS completed_print_jobs
    FROM designs ds
    LEFT JOIN orders o
        ON ds.design_id = o.design_id
    LEFT JOIN print_jobs pj
        ON o.order_id = pj.order_id
    GROUP BY ds.designer_id
),

payout_data AS (
    SELECT
        ds.designer_id,
        COALESCE(SUM(dp.amount), 0) AS total_payouts
    FROM designs ds
    LEFT JOIN orders o
        ON ds.design_id = o.design_id
    LEFT JOIN designer_payouts dp
        ON o.order_id = dp.order_id
    GROUP BY ds.designer_id
)

SELECT
    d.designer_id,
    d.name,
    d.email,

    COALESCE(dd.total_designs, 0) AS total_designs,
    COALESCE(dd.approved_designs, 0) AS approved_designs,

    COALESCE(rd.total_reviews, 0) AS total_reviews,

    COALESCE(pd.total_print_jobs, 0) AS total_print_jobs,
    COALESCE(pd.completed_print_jobs, 0) AS completed_print_jobs,

    COALESCE(sd.total_sales, 0) AS total_sales,
    COALESCE(sd.total_sales_amount, 0) AS total_sales_amount,

    COALESCE(pyd.total_payouts, 0) AS total_payouts

FROM designers d

LEFT JOIN design_data dd
    ON d.designer_id = dd.designer_id

LEFT JOIN review_data rd
    ON d.designer_id = rd.designer_id

LEFT JOIN sales_data sd
    ON d.designer_id = sd.designer_id

LEFT JOIN print_data pd
    ON d.designer_id = pd.designer_id

LEFT JOIN payout_data pyd
    ON d.designer_id = pyd.designer_id;
