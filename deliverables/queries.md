# Requêtes — SQL & NoSQL

Chaque requête répond à une question métier concrète et illustre les capacités du
système ciblé (OLTP transactionnel, OLAP analytique, NoSQL documentaire).

---

## Q1 — File de fraude temps réel *(OLTP — PostgreSQL)*

**Question métier :** quelles transactions en attente présentent un score de fraude
élevé ET une incohérence géographique (pays IP ≠ pays client) sur la dernière heure ?

On utilise le niveau d'isolation `REPEATABLE READ` : entre la lecture du score et une
éventuelle action, aucune mise à jour concurrente ne doit fausser la décision.

```sql
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;

SELECT  t.transaction_id,
        t.merchant_id,
        t.amount_cents,
        t.currency,
        t.fraud_score,
        ip.country_code   AS ip_country,
        cust.country_code AS customer_country,
        t.device_type
FROM        transactions t
JOIN        customers     c    ON c.customer_id  = t.customer_id
JOIN        countries     ip   ON ip.country_id  = t.ip_country_id
JOIN        countries     cust ON cust.country_id = c.country_id
WHERE       t.status     = 'pending'
  AND       t.fraud_score > 0.60
  AND       t.created_at > now() - interval '1 hour'
  AND       t.ip_country_id <> c.country_id        -- comparaison directe des FK
ORDER BY    t.fraud_score DESC
LIMIT       100;

COMMIT;
```

---

## Q2 — Chiffre d'affaires par tier marchand *(OLAP — Snowflake)*

**Question métier :** revenu brut, remboursements et taux de remboursement par
tier marchand et par pays, sur 2026.

Le schéma en étoile limite les jointures. Le filtre `is_current = true` est
**indispensable** sur la dimension SCD2 pour ne pas dédoubler les marchands ayant
changé de tier.

```sql
SELECT  d.year,
        d.month,
        m.tier,
        g.country_code,
        SUM(f.amount_usd)                                          AS gross_revenue,
        SUM(f.amount_usd) FILTER (WHERE f.status = 'refunded')     AS refunds,
        COUNT(DISTINCT f.merchant_sk)                              AS active_merchants,
        COUNT(*)                                                   AS txn_count,
        ROUND(100.0 * COUNT(*) FILTER (WHERE f.status='refunded')
              / COUNT(*), 2)                                       AS refund_rate_pct
FROM        fact_transactions f
JOIN        dim_date       d  ON d.date_id     = f.date_id
JOIN        dim_merchant   m  ON m.merchant_sk = f.merchant_sk
                             AND m.is_current  = true
JOIN        dim_geography  g  ON g.geo_id      = f.geo_id
WHERE       d.year = 2026
GROUP BY    1, 2, 3, 4
ORDER BY    1, 2, 3;
```

---

## Q3 — Segmentation RFM des clients *(OLAP — Snowflake)*

**Question métier :** classer les clients selon Récence / Fréquence / Montant
(Recency, Frequency, Monetary) sur 12 mois glissants.

Les CTE sont évaluées une seule fois ; `NTILE(5)` répartit en quintiles ;
le `CASE` final attribue le segment.

```sql
WITH rfm AS (
  SELECT  f.customer_sk,
          DATEDIFF('day', MAX(d.full_date), CURRENT_DATE) AS recency,
          COUNT(*)                                        AS frequency,
          SUM(f.amount_usd)                               AS monetary
  FROM    fact_transactions f
  JOIN    dim_date          d ON d.date_id = f.date_id
  WHERE   f.status    = 'succeeded'
    AND   d.full_date >= DATEADD('month', -12, CURRENT_DATE)
  GROUP BY 1
),
scored AS (
  SELECT  *,
          NTILE(5) OVER (ORDER BY recency   DESC) AS r,  -- récent = score haut
          NTILE(5) OVER (ORDER BY frequency ASC)  AS f,
          NTILE(5) OVER (ORDER BY monetary  ASC)  AS m
  FROM    rfm
)
SELECT  customer_sk, recency, frequency, monetary, r, f, m,
        CASE
          WHEN r >= 4 AND f >= 4 THEN 'Champions'
          WHEN r >= 3 AND f >= 3 THEN 'Loyal'
          WHEN r >= 4 AND f <= 2 THEN 'New customers'
          WHEN r <= 2 AND f >= 3 THEN 'At risk'
          ELSE 'Hibernating'
        END AS segment
FROM    scored;
```

---

## Q4 — Revenu glissant 7 jours et croissance *(OLAP — Snowflake)*

**Question métier :** pour chaque marchand, revenu quotidien, moyenne glissante 7 jours
et croissance vs semaine précédente (Week-over-Week).

On interroge la **vue matérialisée** `mv_daily_revenue` (et non la table de faits brute)
pour éviter de re-scanner des millions de lignes. Les fonctions fenêtre `SUM ... OVER`
et `LAG` évitent les self-joins coûteux.

```sql
SELECT  merchant_sk,
        date_id,
        gross_revenue                                       AS daily_revenue,
        SUM(gross_revenue) OVER (
            PARTITION BY merchant_sk
            ORDER BY date_id
            ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
        )                                                   AS rolling_7d_revenue,
        ROUND(100.0 * (gross_revenue -
              LAG(gross_revenue, 7) OVER (PARTITION BY merchant_sk ORDER BY date_id))
            / NULLIF(LAG(gross_revenue, 7) OVER (PARTITION BY merchant_sk ORDER BY date_id), 0)
        , 2)                                                AS wow_growth_pct
FROM    mv_daily_revenue
WHERE   date_id >= 20260101
ORDER BY merchant_sk, date_id;
```

---

## Q5 — Historique d'audit d'une transaction *(NoSQL — MongoDB)*

**Question métier :** retracer tous les changements d'état d'une transaction donnée,
dans l'ordre chronologique.

Fonctionne même après une suppression RGPD du client : tout est embarqué, aucune
référence cassée.

```javascript
db.audit_log.find({
  "entity.type": "transaction",
  "entity.id":   "txn_01J2K8F3A9XYZ"
}).sort({ ts: 1 })
```

---

## Q6 — Analyse du tunnel de paiement *(NoSQL — MongoDB)*

**Question métier :** combien d'événements et de sessions uniques par étape du checkout
depuis le 1er mai 2026 ?

On filtre sur `bucket: 1` (documents racine), on déplie les événements avec `$unwind`,
puis on agrège par type d'événement.

```javascript
db.user_sessions.aggregate([
  { $match: {
      started_at: { $gte: ISODate("2026-05-01") },
      bucket: 1
  }},
  { $unwind: "$events" },
  { $group: {
      _id:             "$events.type",
      event_count:     { $sum: 1 },
      unique_sessions: { $addToSet: "$_id" }
  }},
  { $addFields: { unique_count: { $size: "$unique_sessions" } } },
  { $project:  { _id: 1, event_count: 1, unique_count: 1 } },
  { $sort:     { event_count: -1 } }
])
```

---

## Q7 — Clients à risque pour le scoring *(NoSQL — MongoDB)*

**Question métier :** récupérer en un seul accès le profil de risque d'un client avant
de scorer sa transaction (latence critique < 50 ms).

Tout étant embarqué dans `customer_profiles`, une seule lecture suffit.

```javascript
db.customer_profiles.findOne(
  { _id: "cus_01HY..." },
  { segment: 1, "risk": 1, "stats.chargeback_count": 1 }
)
```

---

## Q8 — Taux de chargeback par tier *(OLTP — PostgreSQL)*

**Question métier :** vérité terrain pour le monitoring du modèle de fraude — taux de
litiges (chargebacks) par tier marchand sur 90 jours.

```sql
SELECT  m.tier,
        COUNT(DISTINCT t.transaction_id)                          AS total_txn,
        COUNT(DISTINCT d.dispute_id)                              AS disputes,
        ROUND(100.0 * COUNT(DISTINCT d.dispute_id)
              / NULLIF(COUNT(DISTINCT t.transaction_id), 0), 3)   AS chargeback_rate_pct
FROM        transactions t
JOIN        merchants    m ON m.merchant_id = t.merchant_id
LEFT JOIN   disputes     d ON d.transaction_id = t.transaction_id
WHERE       t.created_at > now() - interval '90 days'
GROUP BY    m.tier
ORDER BY    chargeback_rate_pct DESC;
```
