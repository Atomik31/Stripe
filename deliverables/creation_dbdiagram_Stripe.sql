/////////////////////////////////////////////////////////
// STRIPE BUSINESS CASE - OLTP & OLAP MODEL (DBML/dbdiagram)
// Importer sur https://dbdiagram.io
/////////////////////////////////////////////////////////

// ---------- OLTP SECTION — PostgreSQL (3NF) ----------

Table countries {
  country_id    int          [pk, increment]
  country_code  char(2)      [unique, not null, note: "ISO 3166-1 alpha-2"]
  country_name  varchar(100) [not null]
  currency_code char(3)      [not null, note: "ISO 4217"]
}

Table merchants {
  merchant_id  uuid         [pk, note: "ULID — triable par date de création"]
  legal_name   varchar(255) [not null]
  tier         varchar(20)  [not null, note: "starter | growth | enterprise"]
  country_id   int          [ref: > countries.country_id, not null]
  mcc          char(4)      [note: "Merchant Category Code"]
  created_at   timestamptz  [not null]
  updated_at   timestamptz  [not null]
}

Table customers {
  customer_id  uuid         [pk]
  merchant_id  uuid         [not null, ref: > merchants.merchant_id]
  email_hash   varchar(64)  [note: "SHA-256 — PII jamais stockée en clair"]
  country_id   int          [ref: > countries.country_id]
  created_at   timestamptz  [not null]
}

Table payment_methods {
  payment_method_id uuid         [pk]
  customer_id       uuid         [ref: > customers.customer_id, not null]
  type              varchar(20)  [not null, note: "card | bank_transfer | wallet"]
  brand             varchar(50)  [note: "visa | mastercard | amex"]
  last4             char(4)
  fingerprint       varchar(255) [unique, note: "empreinte tokenisée pour dédoublonnage"]
  exp_month         smallint
  exp_year          smallint
  created_at        timestamptz  [not null]
}

Table transactions {
  transaction_id    uuid         [pk]
  merchant_id       uuid         [not null, ref: > merchants.merchant_id]
  customer_id       uuid         [ref: > customers.customer_id]
  payment_method_id uuid         [ref: > payment_methods.payment_method_id]
  amount_cents      bigint       [not null, note: "montant en centimes — jamais de float"]
  currency          char(3)      [not null]
  status            varchar(20)  [not null, note: "pending | succeeded | failed | refunded"]
  ip_country_id     int          [ref: > countries.country_id, note: "géoloc IP"]
  device_type       varchar(50)  [note: "mobile | desktop | api"]
  fraud_score       decimal(5,4) [note: "0.0000 à 1.0000 — rempli par le scoring ML"]
  created_at        timestamptz  [not null]
  updated_at        timestamptz  [not null]
}

// outbox_events n'a pas de ref: déclarée (aggregate_id est polymorphe — transaction,
// remboursement, litige...). Sur dbdiagram.io, la table atterrit donc isolée par
// l'auto-layout : faire glisser son bloc à côté de "transactions" avant l'export PNG.
Table outbox_events {
  event_id     uuid         [pk]
  aggregate_id uuid         [not null, note: "ID canonique de l'entité modifiée"]
  event_type   varchar(100) [not null, note: "ex: transaction.succeeded"]
  payload      jsonb        [not null]
  published    boolean      [not null, default: false]
  created_at   timestamptz  [not null]
  Note: "Transactional Outbox Pattern — source du CDC (Debezium → Kafka)"
}

Table refunds {
  refund_id      uuid         [pk]
  transaction_id uuid         [not null, ref: > transactions.transaction_id]
  amount_cents   bigint       [not null]
  reason         varchar(255)
  status         varchar(20)  [not null, note: "pending | succeeded | failed"]
  created_at     timestamptz  [not null]
}

Table disputes {
  dispute_id     uuid         [pk]
  transaction_id uuid         [not null, ref: > transactions.transaction_id]
  reason_code    varchar(50)  [note: "fraudulent | product_not_received | duplicate"]
  amount_cents   bigint       [not null]
  status         varchar(20)  [note: "needs_response | won | lost"]
  opened_at      timestamptz  [not null]
  Note: "Chargebacks — vérité terrain pour le monitoring du modèle de fraude"
}

// ---------- OLAP SECTION — Snowflake (Star Schema) ----------

Table fact_transactions {
  transaction_id    varchar      [pk, note: "même UUID canonique que l'OLTP"]
  merchant_sk       int          [ref: > dim_merchant.merchant_sk]
  customer_sk       int          [ref: > dim_customer.customer_sk]
  payment_method_sk int          [ref: > dim_payment_method.payment_method_sk]
  date_id           int          [ref: > dim_date.date_id]
  geo_id            int          [ref: > dim_geography.geo_id]
  amount_usd        decimal(18,4)[note: "converti en USD via taux du jour"]
  original_amount   bigint
  original_currency char(3)
  status            varchar(20)
  fraud_score       decimal(5,4)
  is_refunded       boolean
  is_disputed       boolean
  loaded_at         timestamptz
  Note: "Table de faits centrale — clustering sur (date_id, merchant_sk)"
}

Table dim_merchant {
  merchant_sk  int          [pk, increment, note: "surrogate key"]
  merchant_id  varchar      [not null, note: "clé naturelle = UUID OLTP"]
  legal_name   varchar(255)
  tier         varchar(20)
  country_code char(2)
  valid_from   date         [note: "SCD Type-2 — début de validité"]
  valid_to     date         [note: "SCD Type-2 — fin (null = version courante)"]
  is_current   boolean
  Note: "Dimension SCD2 — historise les changements de tier"
}

Table dim_customer {
  customer_sk  int           [pk, increment]
  customer_id  varchar       [not null]
  segment      varchar(50)   [note: "champions | loyal | at_risk | hibernating"]
  ltv_usd      decimal(18,4) [note: "lifetime value — mis à jour par le pipeline ML"]
  country_code char(2)
  valid_from   date
  valid_to     date
  is_current   boolean
}

Table dim_payment_method {
  payment_method_sk int        [pk, increment]
  payment_method_id varchar    [not null]
  type              varchar(20)
  brand             varchar(50)
  wallet_name       varchar(50)
}

Table dim_date {
  date_id     int     [pk, note: "format AAAAMMJJ"]
  full_date   date    [not null]
  day_of_week int
  week        int
  month       int
  quarter     int
  year        int
  is_weekend  boolean
  is_holiday  boolean
}

Table dim_geography {
  geo_id       int          [pk, increment]
  country_code char(2)      [not null]
  country_name varchar(100)
  region       varchar(100)
  continent    varchar(50)
}

Table mv_daily_revenue {
  date_id         int           [ref: > dim_date.date_id]
  merchant_sk     int           [ref: > dim_merchant.merchant_sk]
  tier            varchar(20)
  country_code    char(2)
  gross_revenue   decimal(18,4)
  net_revenue     decimal(18,4)
  refund_amount   decimal(18,4)
  txn_count       int
  avg_fraud_score decimal(5,4)
  Note: "Vue matérialisée pré-agrégée — rafraîchie toutes les 15 min par Airflow"
}

// ---------- Regroupement visuel pour un export propre ----------

TableGroup oltp_postgresql [color: #3C3489] {
  countries
  merchants
  customers
  payment_methods
  transactions
  outbox_events
  refunds
  disputes
}

TableGroup olap_snowflake [color: #085041] {
  fact_transactions
  dim_merchant
  dim_customer
  dim_payment_method
  dim_date
  dim_geography
  mv_daily_revenue
}
