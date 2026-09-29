-- ***************************************************************
--
-- GlobalCard case study for CS3543, Fall 2026
--
-- Instructor: Andrew McAllister
--
-- ***************************************************************

-- -------------------------------------------------------
-- Base Layer Tables (Core Profiles)
-- -------------------------------------------------------

-- ============================================================
-- 1. ADDRESS
--
-- Stores physical mailing and billing addresses.
--
-- Approximate production volume:
--     Hundreds of millions of addresses.
--
-- Typical operations:
--     Address maintenance, statement generation, cardholder
--     communication, fraud analysis.
--
-- DBA considerations:
--     Data quality, address standardization, international
--     formats, privacy regulations, indexing strategies.
-- ============================================================

CREATE TABLE address (
    address_id       BIGINT NOT NULL,
    address_line_1   VARCHAR(150) NOT NULL,
    address_line_2   VARCHAR(150),
    city             VARCHAR(100) NOT NULL,
    state_province   VARCHAR(100),
    postal_code      VARCHAR(20) NOT NULL,
    country_code     CHAR(2) NOT NULL, -- ISO-3166-1 alpha-2
    created_at       TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    PRIMARY KEY (address_id)
) ENGINE=InnoDB;


-- ============================================================
-- 2. PARTY
--
-- Unified Legal Entity Registry
-- 
-- Represents both card holders and merchants
--
-- ============================================================

CREATE TABLE party (
    party_id     BIGINT NOT NULL,
    party_type   ENUM('CARDHOLDER', 'MERCHANT') NOT NULL,
    created_at   TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    PRIMARY KEY (party_id)
) ENGINE=InnoDB;

-- ============================================================
-- 3. CARDHOLDER   (Subtype of Party)
--
-- Stores demographic and contact information for individuals
-- who do business with GlobalCard.
--
-- Approximate production volume:
--     150 million active customers worldwide.
--
-- Typical operations:
--     Customer lookup, profile updates, identity verification.
--
-- DBA considerations:
--     Data privacy, encryption, access controls, regulatory
--     compliance, customer-search performance, data retention.
-- ============================================================

CREATE TABLE cardholder (
    cardholder_id                 BIGINT NOT NULL,
    email                         VARCHAR(255) NOT NULL,
    first_name                    VARCHAR(100) NOT NULL,
    last_name                     VARCHAR(100) NOT NULL,

    -- Controlled Denormalization for addresses: Read Optimization

    -- Question for students: Should / Could we use UNIQUE
    -- and FOREIGN KEY constraints so the database can ensure
    -- the address id values here match existing 
    -- cardholder_id, address_id pairs in the party_address table?
    current_billing_address_id    BIGINT NULL,
    current_shipping_address_id   BIGINT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    PRIMARY KEY (cardholder_id),
    UNIQUE KEY uq_cardholder_email (email),
    CONSTRAINT fk_cardholder_party FOREIGN KEY (cardholder_id) 
                    REFERENCES party (party_id) ON DELETE CASCADE,
    CONSTRAINT fk_cardholder_billing_addr FOREIGN KEY (current_billing_address_id) 
                    REFERENCES address (address_id) ON DELETE SET NULL,
    CONSTRAINT fk_cardholder_shipping_addr FOREIGN KEY (current_shipping_address_id) 
                    REFERENCES address (address_id) ON DELETE SET NULL
) ENGINE=InnoDB;

-- ============================================================
-- 4. MERCHANT   (Subtype of Party)
--
-- Stores information about businesses that accept GlobalCard
-- payments.
--
-- Approximate production volume:
--     Tens of millions of merchants worldwide.
--
-- Typical operations:
--     Transaction authorization, fraud analysis, reporting.
--
-- DBA considerations:
--     Geographic reporting, merchant lookup performance,
--     dimensional-model design, indexing strategies.
--
-- ============================================================

CREATE TABLE merchant (
    merchant_id   BIGINT NOT NULL,
    legal_name    VARCHAR(150) NOT NULL,
    mcc_code      CHAR(4) NOT NULL, -- Merchant Category Code
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    PRIMARY KEY (merchant_id),
    CONSTRAINT fk_merchant_party FOREIGN KEY (merchant_id) 
                    REFERENCES party (party_id) ON DELETE CASCADE
) ENGINE=InnoDB;


-- ============================================================
-- 5. MERCHANT_LOCATION
--
-- Physical Storefront Branches 
--        (1:Many with merchant)
--
-- ============================================================

CREATE TABLE merchant_location (
    merchant_location_id   BIGINT NOT NULL,
    merchant_id            BIGINT NOT NULL,
    address_id             BIGINT NOT NULL,
    store_number           VARCHAR(20) NOT NULL,
    location_name          VARCHAR(100) NOT NULL,
    -- Controlled Denormalization Cache: 
    --   Critical for real-time localized fraud sweeps
    cached_postal_code     VARCHAR(20) NOT NULL,
    cached_country_code    CHAR(2) NOT NULL,
    is_active              BOOLEAN DEFAULT TRUE NOT NULL,
    PRIMARY KEY (merchant_location_id),
    CONSTRAINT fk_location_merchant FOREIGN KEY (merchant_id) 
                    REFERENCES merchant (merchant_id) ON DELETE CASCADE,
    CONSTRAINT fk_location_address FOREIGN KEY (address_id) 
                    REFERENCES address (address_id) ON DELETE RESTRICT
) ENGINE=InnoDB;

--
-- ============================================================
-- 6. PARTY_ADDRESS
--
--     Represents the many-to-many relationship between parties and addresses,
--     including historical addresses
--
--    Allows a party to have multiple addresses and an
--    address to be associated with different party records.
--
-- Maintains address history.
--
-- Approximate production volume:
--     Larger than cardholder & merchant combined due to historical records.
--
-- Typical operations:
--     Current-address retrieval and historical reporting.
--
-- DBA considerations:
--     Temporal data management, effective-date queries,
--     indexing on date ranges, historical retention.
-- ============================================================

CREATE TABLE party_address (
    party_id           BIGINT NOT NULL,
    address_id         BIGINT NOT NULL,
    address_type       ENUM('MAILING', 'BILLING', 'SHIPPING', 'HQ', 'STOREFRONT') NOT NULL,
    is_default         BOOLEAN DEFAULT FALSE NOT NULL,
    valid_from TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    valid_to TIMESTAMP NULL DEFAULT NULL, -- NULL implies the active version
    
    -- Question for students - Does this PK mean the database can't store
    -- historical mailing addresses for a cardholder?
    PRIMARY KEY (party_id, address_id, address_type),
    CONSTRAINT fk_party_address_party FOREIGN KEY (party_id) 
                    REFERENCES party (party_id) ON DELETE CASCADE,
    CONSTRAINT fk_party_address_address FOREIGN KEY (address_id) 
                    REFERENCES address (address_id) ON DELETE RESTRICT
) ENGINE=InnoDB;

-- -------------------------------------------------------
-- The Core Account & Card Hierarchy
-- -------------------------------------------------------

-- ============================================================
-- 7. ACCOUNT
--
-- Represents a financial account to which one or more cards
-- may be attached. For example:
--    * When an account has multiple cardholders
--    * When compromised cards have been replaced
--
-- Approximate production volume:
--     Hundreds of millions of accounts.
--
-- Typical operations:
--     Balance inquiries, payment processing, statement
--     generation, account maintenance.
--
-- DBA considerations:
--     Transaction consistency, concurrency control,
--     availability, replication, account lookup performance.
--     High-Concurrency Read/Write Target
-- ============================================================

CREATE TABLE account (
    account_id        BIGINT NOT NULL,
    account_number    VARCHAR(34) NOT NULL, -- Accommodates standard IBAN formats
    -- TEACHING POINT: The central hotspot for row-level locks
    current_balance   DECIMAL(15,2) DEFAULT 0.00 NOT NULL,
    credit_limit      DECIMAL(15,2) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    PRIMARY KEY (account_id),
    UNIQUE KEY uq_account_number (account_number)
) ENGINE=InnoDB;

-- ============================================================
-- 8. CARD
--
-- A card represents a physical or virtual payment card issued
-- to a cardholder and associated with an account.
--
-- Approximate production volume:
--     Hundreds of millions of active cards.
--
-- Typical operations:
--     Authorization, activation, replacement, fraud review.
--
-- DBA considerations:
--     Payment Card Industry (PCI) compliance, tokenization, 
--     secure storage, access auditing, card lookup performance.
--
-- IMPORTANT SECURITY NOTE:
--
-- The actual Primary Account Number (PAN), commonly referred to
-- as the "credit card number", is NOT stored in the GlobalCard
-- operational database.
--
-- Instead, the PAN is stored in a separate highly secured
-- Card Vault system that is outside the scope of this schema.
--
-- The Card Vault would typically employ specialized controls
-- required by PCI-DSS (Payment Card Industry Data Security 
-- Standard), such as encryption, tokenization,
-- Hardware Security Modules (HSMs), key management,
-- restricted access, auditing, and network isolation.
--
-- The GlobalCard database stores only:
--
--   1. A token that uniquely identifies the card.
--   2. The final four digits of the PAN.
--
-- Customer service representatives, fraud analysts, and
-- cardholders typically identify a card using only the final
-- four digits.
--
-- The token can be supplied to the Card Vault whenever the
-- actual PAN is required by authorized systems.
-- ============================================================

CREATE TABLE card (
    card_id         BIGINT NOT NULL,
    account_id      BIGINT NOT NULL,
    cardholder_id   BIGINT NOT NULL,  -- account member instead ????????

    -- Token generated by the Card Vault.
    -- This value has no mathematical relationship to the 
    -- Primary Account Number (PAN), more commonly referred to
    -- as the "credit card number" that appears on a physical
    -- card.
    -- The pan_token exists solely as a secure reference to the real card.
    pan_token            CHAR(64) NOT NULL,

    -- Final four digits of the PAN.
    -- Used for customer service, fraud investigations,
    -- statement display, and user interfaces.
    pan_last_four        CHAR(4) NOT NULL,
    -- Managing historical transitions (e.g., Compromised, Expired, Active)
    card_status     ENUM('ACTIVE', 'SUSPENDED', 'COMPROMISED', 'EXPIRED', 'REPLACED') NOT NULL,
    valid_from      TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    valid_to        TIMESTAMP NULL DEFAULT NULL, -- NULL denotes active instrument
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    PRIMARY KEY (card_id),
    --    Ensure the card table has a composite unique constraint 
    --    guaranteeing that a card_id is hard-locked to its account_id.
    --       The constraint UQ_card_account does not exist to enforce 
    --    uniqueness in the card table. It exists entirely to allow a 
    --    Composite Foreign Key to reference this combination of fields
    --    from a related table.
    CONSTRAINT UQ_card_account UNIQUE (card_id, account_id),
    CONSTRAINT fk_card_account FOREIGN KEY (account_id) 
                    REFERENCES account (account_id) ON DELETE RESTRICT,
    CONSTRAINT fk_card_cardholder FOREIGN KEY (cardholder_id) 
                    REFERENCES cardholder (cardholder_id) ON DELETE RESTRICT
) ENGINE=InnoDB;

-- ============================================================================
-- 9. transaction - PARENT SUPERTYPE TABLE
--
--     Represents the attributes that are common to all types of
--     financial transactions involving a credit card account
--
-- Potentially enormous table.
-- This is intentionally the central table for many
-- potential performance-related exercises.
--
-- Central transaction fact table containing purchases,
-- payments, refunds, fees, and other account activity.
--
-- Approximate production volume:
--     40+ billion new rows annually.
--
-- Typical operations:
--     Real-time authorization, customer inquiries,
--     fraud detection, regulatory reporting, analytics.
--
-- DBA considerations:
--     Partitioning, indexing, clustering, archival,
--     backup, replication, query optimization,
--     storage management, disaster recovery.
--
-- This table is intentionally designed to become the largest
-- and most performance-sensitive table in the system.
--
-- ============================================================================

CREATE TABLE `transaction` (
    transaction_id     BIGINT NOT NULL,
    account_id         BIGINT NOT NULL,
    -- Values for transaction_type are restricted using a CHECK constraint below
    transaction_type   VARCHAR(20) NOT NULL,
    amount             DECIMAL(15,2) NOT NULL, -- Negative values handle reversals if needed, 
                                   -- or determined by type
    transaction_date   TIMESTAMP NOT NULL,
    posted_date        TIMESTAMP NOT NULL,
    description        VARCHAR(255) NOT NULL,
    is_disputed        BOOLEAN DEFAULT FALSE NOT NULL,
    
    -- Enforce valid transaction categories
    CONSTRAINT CHK_transaction_type CHECK (
        transaction_type IN ('PURCHASE', 'CASH_ADVANCE', 'FEE', 'INTEREST_CHARGE', 
                             'PAYMENT', 'REFUND', 'ADJUSTMENT')
    ),
    
    -- Primary Key remains transaction_id for lookup efficiency
    CONSTRAINT PK_transaction PRIMARY KEY (transaction_id),
 
    CONSTRAINT fk_transaction_account FOREIGN KEY (account_id) 
                    REFERENCES account (account_id) ON DELETE RESTRICT,
   
    -- CRITICAL FOR INTEGRITY: A unique constraint on (id, type, account). 
    -- This allows child subtype tables to include and validate the type & account columns.
    CONSTRAINT UQ_transaction_account_identity 
          UNIQUE (transaction_id, transaction_type, account_id),
    -- MySQL requires an index matching the referenced columns exactly
    -- for subtype foreign keys that do not include account_id.
    CONSTRAINT UQ_transaction_type_identity
          UNIQUE (transaction_id, transaction_type)

);

-- Indexing for quick sweeps of transactions by account
CREATE INDEX IX_transaction_account_date ON `transaction` (account_id, posted_date);

-- ============================================================================
-- 10. & 11. PEER SUBTYPE TABLES (CARD-BASED TRANSACTIONS)
--       Notice both of these include card_id
-- ============================================================================

-- ============================================================================
-- 10. TX_PURCHASE
--       Represents purchase transactions.
--
-- ============================================================================
CREATE TABLE tx_purchase (
    transaction_id          BIGINT NOT NULL,
    transaction_type        VARCHAR(20) DEFAULT 'PURCHASE' NOT NULL,
    account_id              BIGINT NOT NULL,  -- Brought down to act as a relational bridge
    card_id                 BIGINT NOT NULL,
    merchant_id             BIGINT NOT NULL,
    terminal_id             VARCHAR(50) NULL,
    auth_code               CHAR(6) NOT NULL,            -- Point-of-sale clearance code
    is_recurring            BOOLEAN DEFAULT FALSE NOT NULL,
    
    CONSTRAINT CHK_tx_purchase_type CHECK (transaction_type = 'PURCHASE'),
    CONSTRAINT PK_tx_purchase PRIMARY KEY (transaction_id),

    CONSTRAINT fk_tx_purchase_merchant FOREIGN KEY (merchant_id) 
                    REFERENCES merchant (merchant_id) ON DELETE CASCADE,
    
    -- COMPOSITE FK 1: Verifies that the transaction ID, type, AND account 
    -- match the parent ledger perfectly.
    CONSTRAINT FK_tx_purchase_supertype 
        FOREIGN KEY (transaction_id, transaction_type, account_id) 
        REFERENCES `transaction` (transaction_id, transaction_type, account_id) ON DELETE CASCADE,
        
    -- COMPOSITE FK 2: Verifies that the card being used ACTUALLY belongs 
    -- to that exact same account_id.
    CONSTRAINT FK_tx_purchase_to_card_account_validation
        FOREIGN KEY (card_id, account_id) 
        REFERENCES card (card_id, account_id) ON DELETE CASCADE
);

-- ============================================================================
-- 11. TX_CASH_ADVANCE
--       Represents cash advance transactions.
--
-- ============================================================================
CREATE TABLE tx_cash_advance (
    transaction_id             BIGINT NOT NULL,
    transaction_type           VARCHAR(20) DEFAULT 'CASH_ADVANCE' NOT NULL,
    account_id                 BIGINT NOT NULL,  -- Brought down to act as a relational bridge
    card_id                    BIGINT NOT NULL,
    atm_id                     VARCHAR(50) NULL,
    atm_network                VARCHAR(30) NULL,           -- e.g., 'PLUS', 'CIRRUS'
    cash_advance_fee_applied   DECIMAL(12,2) NOT NULL, -- Track specific upfront processing fees

    CONSTRAINT CHK_tx_cash_advance_type CHECK (transaction_type = 'CASH_ADVANCE'),
    CONSTRAINT PK_tx_cash_advance PRIMARY KEY (transaction_id),

    -- COMPOSITE FK 1: Verifies that the transaction ID, type, AND account 
    -- match the parent ledger perfectly.
    CONSTRAINT FK_tx_cash_advance_supertype 
        FOREIGN KEY (transaction_id, transaction_type, account_id) 
        REFERENCES `transaction` (transaction_id, transaction_type, account_id) ON DELETE CASCADE,
        
    -- COMPOSITE FK 2: Verifies that the card being used ACTUALLY belongs 
    -- to that exact same account_id.
    CONSTRAINT FK_tx_cash_advance_to_card_account_validation
        FOREIGN KEY (card_id, account_id) 
        REFERENCES card (card_id, account_id) ON DELETE CASCADE
);

-- ============================================================================
-- 12. to 16.  PEER SUBTYPE TABLES (ACCOUNT / SYSTEM-BASED TRANSACTIONS)
--       Notice none of these include card_id
-- ============================================================================

-- ============================================================
-- 12. TX_FEE
--
-- Records fees assessed against customer accounts.
--
-- Approximate production volume:
--     Significant but much smaller than transaction volume.
--
-- Typical operations:
--     Account servicing, reporting, customer inquiries.
--
-- DBA considerations:
--     Reporting efficiency, historical retention,
--     reconciliation and auditing.
-- ============================================================

CREATE TABLE tx_fee (
    transaction_id BIGINT NOT NULL,
    transaction_type VARCHAR(20) DEFAULT 'FEE' NOT NULL,
    fee_code VARCHAR(20) NOT NULL,           -- e.g., 'ANNUAL_FEE', 'LATE_FEE', 'OVER_LIMIT'
    waivable_indicator BOOLEAN DEFAULT TRUE NOT NULL,
    
    CONSTRAINT CHK_tx_fee_type CHECK (transaction_type = 'FEE'),
    CONSTRAINT PK_tx_fee PRIMARY KEY (transaction_id),
    
    CONSTRAINT FK_tx_fee_supertype 
        FOREIGN KEY (transaction_id, transaction_type) 
        REFERENCES `transaction` (transaction_id, transaction_type) ON DELETE CASCADE
);

-- ============================================================
-- 13. TX_INTEREST_CHARGE
--
-- Records interest calculations applied to accounts.
--
-- Approximate production volume:
--     Potentially billions of rows over time.
--
-- Typical operations:
--     Statement generation, audits, financial reporting.
--
-- DBA considerations:
--     Financial accuracy, historical retention,
--     auditability, reconciliation.
-- ============================================================

CREATE TABLE tx_interest_charge (
    transaction_id BIGINT NOT NULL,
    transaction_type VARCHAR(20) DEFAULT 'INTEREST_CHARGE' NOT NULL,
    annual_percentage_rate DECIMAL(5,2) NOT NULL, -- The APR applied to calculate this specific charge
    
    CONSTRAINT CHK_tx_interest_type CHECK (transaction_type = 'INTEREST_CHARGE'),
    -- Prevent calculation cross-contamination
    CONSTRAINT PK_tx_interest PRIMARY KEY (transaction_id),
    
    CONSTRAINT FK_tx_interest_supertype 
        FOREIGN KEY (transaction_id, transaction_type) 
        REFERENCES `transaction` (transaction_id, transaction_type) ON DELETE CASCADE
);

-- ============================================================
-- 14. TX_PAYMENT
--
-- Records customer payments made toward account balances.
--
-- Approximate production volume:
--     Billions of rows over time.
--
-- Typical operations:
--     Balance updates, statement generation, reporting.
--
-- DBA considerations:
--     Transaction consistency, concurrency, batch processing,
--     reporting workloads.
-- ============================================================

CREATE TABLE tx_payment (
    transaction_id BIGINT NOT NULL,
    transaction_type VARCHAR(20) DEFAULT 'PAYMENT' NOT NULL,
    payment_method VARCHAR(20) NOT NULL,    -- 'ACH', 'CHECK', 'BRANCH_CASH', 'DEBIT_CARD'
    clearing_routing_number VARCHAR(9) NULL,  -- For bank draft validations
    clearing_account_number VARCHAR(50) NULL,
    is_minimum_met BOOLEAN DEFAULT TRUE NOT NULL,
    
    CONSTRAINT CHK_tx_payment_type CHECK (transaction_type = 'PAYMENT'),
    CONSTRAINT PK_tx_payment PRIMARY KEY (transaction_id),
    
    CONSTRAINT FK_tx_payment_supertype 
        FOREIGN KEY (transaction_id, transaction_type) 
        REFERENCES `transaction` (transaction_id, transaction_type) ON DELETE CASCADE
);

-- ============================================================
-- 15. TX_REFUND
--
-- Records refund activity linked to original purchases.
--
-- Approximate production volume:
--     Small percentage of transaction volume.
--
-- Typical operations:
--     Dispute resolution, customer service, reconciliation.
--
-- DBA considerations:
--     Referential integrity, transaction tracing,
--     reporting performance.
-- ============================================================

CREATE TABLE tx_refund (
    transaction_id BIGINT NOT NULL,
    transaction_type VARCHAR(20) DEFAULT 'REFUND' NOT NULL,
    original_purchase_tx_id BIGINT NULL,  -- Self-referencing link back to the 
                                          -- matching purchase (if traceable)
    merchant_id BIGINT NOT NULL,  -- Who provided the refund, 
                                  -- even if the original tx id is null
    is_chargeback_dispute BOOLEAN DEFAULT FALSE NOT NULL,
    
    CONSTRAINT CHK_tx_refund_type CHECK (transaction_type = 'REFUND'),
    CONSTRAINT PK_tx_refund PRIMARY KEY (transaction_id),

    CONSTRAINT fk_tx_refund_merchant FOREIGN KEY (merchant_id) 
                    REFERENCES merchant (merchant_id) ON DELETE CASCADE,
    
    CONSTRAINT FK_tx_refund_supertype 
        FOREIGN KEY (transaction_id, transaction_type) 
        REFERENCES `transaction` (transaction_id, transaction_type) ON DELETE CASCADE,
        
    -- Highly useful DBA constraint mapping back to original purchase history
    CONSTRAINT FK_tx_refund_to_original_purchase
        FOREIGN KEY (original_purchase_tx_id) 
        REFERENCES tx_purchase (transaction_id)
);

-- ============================================================
-- 16. TX_ADJUSTMENT
--
-- Records manual adjustments made to account balances for a 
-- variety of reasons, such as customer service courtesy,
-- fraud reversal, dispute resolution. and so on.
--
-- Approximate production volume:
--     Small percentage of transaction volume.
--
-- Typical operations:
--     Dispute resolution, customer service, reconciliation.
--
-- ============================================================

CREATE TABLE tx_adjustment (
    transaction_id BIGINT NOT NULL,
    transaction_type VARCHAR(20) DEFAULT 'ADJUSTMENT' NOT NULL,
    reason_code VARCHAR(30) NOT NULL,       -- 'CUSTOMER_SERVICE_COURTESY', 'FRAUD_REVERSAL', 'GL_CORRECTION'
    authorized_by_employee_id INT NOT NULL,
    impact_direction CHAR(1) NOT NULL,      -- 'C' (Credit/Reduce balance) or 'D' (Debit/Increase balance)
    
    CONSTRAINT CHK_tx_adjustment_type CHECK (transaction_type = 'ADJUSTMENT'),
    CONSTRAINT CHK_tx_adjustment_direction CHECK (impact_direction IN ('C', 'D')),
    CONSTRAINT PK_tx_adjustment PRIMARY KEY (transaction_id),
    
    CONSTRAINT FK_tx_adjustment_supertype 
        FOREIGN KEY (transaction_id, transaction_type) 
        REFERENCES `transaction` (transaction_id, transaction_type) ON DELETE CASCADE
);

-- ============================================================
-- 17. FRAUD_ALERT
--
-- Stores fraud alerts generated by fraud-detection systems.
--
-- Approximate production volume:
--     Millions of alerts annually.
--
-- Typical operations:
--     Fraud investigation, alert management, reporting.
--
-- DBA considerations:
--     High-ingest workloads, alert prioritization,
--     real-time access, retention policies.
-- ============================================================

CREATE TABLE fraud_alert (
    fraud_alert_id       BIGINT UNSIGNED NOT NULL,
    transaction_id       BIGINT NOT NULL,
    alert_timestamp      DATETIME(6) NOT NULL,
    alert_type            VARCHAR(40) NOT NULL,

          -- ----  risk_score  ----
          -- Risk score assigned by fraud-detection models.
          --
          -- Higher values indicate increased probability
          -- that the transaction is fraudulent.
          --
          -- The specific scoring algorithm is outside the
          -- scope of this schema.
    risk_score            DECIMAL(7,4) NOT NULL,
    alert_status          VARCHAR(20) NOT NULL,
    resolution_code      VARCHAR(40) NULL,
    resolved_timestamp   DATETIME(6) NULL,

    CONSTRAINT pk_fraud_alert
        PRIMARY KEY (fraud_alert_id),

    CONSTRAINT fk_fraud_transaction
        FOREIGN KEY (transaction_id)
        REFERENCES `transaction`(transaction_id),

    CONSTRAINT ck_fraud_risk_score
        CHECK (risk_score >= 0 AND risk_score <= 100),

    CONSTRAINT ck_fraud_status
        CHECK (alert_status IN
               ('OPEN', 'UNDER_REVIEW', 'CONFIRMED',
                'FALSE_POSITIVE', 'CLOSED')),

    CONSTRAINT ck_fraud_resolution
        CHECK (resolved_timestamp IS NULL
               OR resolved_timestamp >= alert_timestamp)
);


-- ============================================================
-- 18. RISK_ASSESSMENT
--
-- Stores machine-learning risk evaluations associated with
-- financial transactions.
--
-- Approximate production volume:
--     Potentially one or more rows per transaction.
--
-- Typical operations:
--     Authorization support, fraud analysis, model auditing.
--
-- DBA considerations:
--     High write volume, model traceability,
--     analytical reporting, storage growth.
-- ============================================================

CREATE TABLE risk_assessment (
    risk_assessment_id   BIGINT UNSIGNED NOT NULL,
    transaction_id       BIGINT NOT NULL,
    assessment_timestamp DATETIME(6) NOT NULL,

          -- ----  model_version  ----
          -- Version of the machine-learning model
          -- responsible for generating the risk score.
          --
          -- Model version tracking supports auditing,
          -- explainability, regulatory review, and
          -- model performance analysis.
    model_version        VARCHAR(30) NOT NULL,
    risk_score           DECIMAL(7,4) NOT NULL,
    decision             VARCHAR(20) NOT NULL,

          -- ----  processing_time_ms  ----
          -- Time required by the risk engine to evaluate
          -- the transaction.
          --
          -- Useful for performance monitoring because
          -- transaction authorization is typically a
          -- latency-sensitive workload.
    processing_time_ms   INTEGER UNSIGNED NOT NULL,

    CONSTRAINT pk_risk_assessment
        PRIMARY KEY (risk_assessment_id),

    CONSTRAINT fk_risk_transaction
        FOREIGN KEY (transaction_id)
        REFERENCES `transaction`(transaction_id),

          -- risk_score = 0 indicates no risk
          -- risk_score = 100 indicates highest risk
    CONSTRAINT ck_risk_score
        CHECK (risk_score >= 0 AND risk_score <= 100),

    CONSTRAINT ck_risk_decision
        CHECK (decision IN
               ('APPROVE', 'DECLINE', 'REVIEW')),

    CONSTRAINT ck_risk_processing_time
        CHECK (processing_time_ms >= 0)
);


-- ============================================================
-- 19. AUTHENTICATION_EVENT
--
-- Records cardholder authentication attempts across web,
-- mobile, and other channels.
--
-- Approximate production volume:
--     Hundreds of millions of events annually.
--
-- Typical operations:
--     Security monitoring, fraud detection,
--     customer support investigations.
--
-- DBA considerations:
--     Append-only workloads, partitioning,
--     security monitoring, long-term retention,
--     anomaly detection queries.
-- ============================================================

CREATE TABLE authentication_event (
    authentication_event_id BIGINT UNSIGNED NOT NULL,
    cardholder_id        BIGINT NULL,
    event_timestamp      DATETIME(6) NOT NULL,
    authentication_type  VARCHAR(30) NOT NULL,
    result               VARCHAR(20) NOT NULL,
    ip_address            VARCHAR(45) NULL,

          -- ----  device_identifier  ----
          -- Identifier associated with a browser,
          -- mobile device, or application instance.
          --
          -- Used for fraud detection, device reputation,
          -- and recognition of previously trusted devices.
    device_identifier    VARCHAR(100) NULL,
    country_code         CHAR(2) NULL,
    failure_reason       VARCHAR(100) NULL,

    CONSTRAINT pk_authentication_event
        PRIMARY KEY (authentication_event_id),

    CONSTRAINT fk_authentication_customer
        FOREIGN KEY (cardholder_id)
        REFERENCES cardholder(cardholder_id),

    CONSTRAINT fk_authentication_cardholder
        FOREIGN KEY (cardholder_id)
        REFERENCES cardholder(cardholder_id),

    CONSTRAINT ck_authentication_type
        CHECK (authentication_type IN
               ('PASSWORD',
                'MFA',
                'BIOMETRIC',
                'SECURITY_QUESTION',
                'CARD_VERIFICATION')),

    CONSTRAINT ck_authentication_result
        CHECK (result IN
               ('SUCCESS', 'FAILURE', 'CHALLENGE'))
);


-- ============================================================
-- 20. CARDHOLDER_SERVICE_INTERACTION
--
-- Records interactions between cardholders and service
-- representatives.
--
-- Approximate production volume:
--     Tens to hundreds of millions of rows.
--
-- Typical operations:
--     Customer support, complaint resolution,
--     service analytics.
--
-- DBA considerations:
--     Text-search requirements, reporting,
--     retention policies, privacy concerns.
-- ============================================================

CREATE TABLE cardholder_service_interaction (
    interaction_id       BIGINT UNSIGNED NOT NULL,
    cardholder_id        BIGINT NOT NULL,
    account_id           BIGINT NULL,
    interaction_timestamp DATETIME(6) NOT NULL,
    interaction_channel  VARCHAR(20) NOT NULL,
    interaction_type     VARCHAR(40) NOT NULL,
    employee_identifier  VARCHAR(30) NULL,
    resolution_status    VARCHAR(20) NOT NULL,
    notes                TEXT NULL,

    CONSTRAINT pk_customer_service_interaction
        PRIMARY KEY (interaction_id),

    CONSTRAINT fk_interaction_customer
        FOREIGN KEY (cardholder_id)
        REFERENCES cardholder(cardholder_id),

    CONSTRAINT fk_interaction_account
        FOREIGN KEY (account_id)
        REFERENCES account(account_id),

    CONSTRAINT ck_interaction_channel
        CHECK (interaction_channel IN
               ('PHONE', 'WEB', 'MOBILE', 'EMAIL', 'CHAT', 'BRANCH')),

    CONSTRAINT ck_interaction_status
        CHECK (resolution_status IN
               ('OPEN', 'IN_PROGRESS', 'RESOLVED', 'ESCALATED'))
);


-- ============================================================
-- 21. AUDIT_EVENT
--
-- Records security-sensitive and administrative activities
-- occurring throughout the GlobalCard ecosystem.
--
-- AUDIT_EVENT is deliberately separate from TRANSACTION.
-- A financial transaction represents a business event that changes
-- a customer's financial position; an audit event records the fact
-- that some activity occurred in the system, who or what performed
-- it, and when it occurred. An audit event answers "What did someone 
-- or something do in the system?"
--
-- The two tables therefore have substantially different purposes,
-- workloads, retention requirements, and access patterns.
--
-- For example, a purchase might produce a FINANCIAL_TRANSACTION row:
--     Card 1234 purchased $84.37 from Merchant X.
--
-- The system might eventually generate several AUDIT_EVENT rows  
-- associated with activity surrounding that transaction:
--     Authorization service accessed transaction.
--     Fraud engine evaluated transaction.
--     Employee viewed transaction.
--     Employee modified a dispute record.
--     System administrator changed a user's permissions.
--
-- TRANSACTION is primarily an operational (OLTP) table:
-- it is continuously inserted into and is frequently queried for
-- current customer and account operations.
--
-- AUDIT_EVENT is primarily append-only. Audit records are rarely
-- updated or deleted and may need to be retained for many years
-- for regulatory compliance, security investigations, and
-- forensic analysis.
--
-- This distinction may lead a DBA to use different strategies
-- for the two tables, including different indexes, partitioning
-- schemes, storage arrangements, archival policies, backup
-- strategies, and access controls.
--
-- The large volume and long retention period of audit data can
-- also make it undesirable to store audit information directly
-- in the operational transaction tables.
--
-- Not every audit event has a corresponding financial transaction. 
-- Many important audit events won't — for example, a failed login, 
-- a password change, a change to a user's privileges, or someone 
-- viewing sensitive customer information. That is another strong 
-- reason for defining AUDIT_EVENT as its own entity rather than 
-- embedding audit information in TRANSACTION.
--
-- Potential DBA questions include:
--   * Should audit data be partitioned by time?
--   * How long should different categories of audit data be kept?
--   * Should old audit data be moved to cheaper archival storage?
--   * Should audit records be replicated to a separate system?
--   * How can audit records be protected against unauthorized
--     modification or deletion?
--   * What indexes are appropriate for primarily append-only data?
--   * How should audit queries avoid interfering with OLTP workloads?
--
-- ============================================================

CREATE TABLE audit_event (
    audit_event_id       BIGINT UNSIGNED NOT NULL,
    event_timestamp      DATETIME(6) NOT NULL,
    actor_type           VARCHAR(20) NOT NULL,
    actor_identifier     VARCHAR(100) NULL,
    event_type           VARCHAR(40) NOT NULL,
    entity_type          VARCHAR(40) NOT NULL,
    entity_id            VARCHAR(100) NULL,
    source_system        VARCHAR(50) NULL,
    ip_address           VARCHAR(45) NULL,
    outcome              VARCHAR(20) NOT NULL,
    event_details        TEXT NULL,

    CONSTRAINT pk_audit_event
        PRIMARY KEY (audit_event_id),

    CONSTRAINT ck_audit_actor_type
        CHECK (actor_type IN
               ('CARDHOLDER', 'EMPLOYEE', 'SYSTEM', 'SERVICE')),

    CONSTRAINT ck_audit_outcome
        CHECK (outcome IN
               ('SUCCESS', 'FAILURE', 'DENIED'))
);

-- ============================================================
-- 22. ACCOUNT_STATEMENT
--
-- Represents a periodic statement issued for an account.
--
-- Approximate production volume:
--     Billions of rows accumulated over many years.
--
-- Typical operations:
--     Statement retrieval and historical reporting.
--
-- The transactions belonging to a statement are determined by
-- the transaction's POSTING DATE, not by transaction_id and not
-- necessarily by the date on which the underlying financial
-- activity occurred.
--
-- A transaction belongs to a statement when:
--
--     statement_start_date <= posting_date
--     AND
--     posting_date <= statement_end_date
--
-- Thus, the statement period provides the business rule for
-- determining which TRANSACTION rows are included.
--
-- transaction_id is intentionally NOT stored in this table.
-- It identifies an individual transaction but does not define
-- the chronological boundaries of a statement.
--
-- The transaction_date and posting_date may differ. For example,
-- a purchase made on July 31 may not be posted until August 1
-- and would therefore appear on the August statement.
--
-- Statements are historical financial documents. Once issued,
-- the statement and the transactions underlying it should be
-- treated as an auditable historical record rather than as a
-- dynamically changing query result.
--
-- DBA considerations include statement generation, indexing
-- transactions by account and posting date, historical retention,
-- archival, partitioning, and efficient retrieval of statements.
-- ============================================================

CREATE TABLE account_statement (
    statement_id         BIGINT UNSIGNED NOT NULL,
    account_id           BIGINT NOT NULL,
    statement_start_date DATE NOT NULL,
    statement_end_date   DATE NOT NULL,
    statement_date       DATE NOT NULL,
    opening_balance      DECIMAL(19,4) NOT NULL,
    closing_balance      DECIMAL(19,4) NOT NULL,
    minimum_payment      DECIMAL(19,4) NOT NULL,
    statement_status     VARCHAR(20) NOT NULL,

    CONSTRAINT pk_account_statement
        PRIMARY KEY (statement_id),

    CONSTRAINT fk_statement_account
        FOREIGN KEY (account_id)
        REFERENCES account(account_id),

    CONSTRAINT ck_statement_dates
        CHECK (statement_end_date >= statement_start_date),

    CONSTRAINT ck_statement_status
        CHECK (statement_status IN
               ('GENERATED', 'SENT', 'REISSUED'))
);

