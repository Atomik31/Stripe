# Modèle NoSQL — MongoDB

Base orientée **documents** choisie pour sa flexibilité de schéma et sa capacité à
stocker des données semi-structurées (logs, sessions, features ML) avec un accès
rapide par clé.

**Principe directeur :** on réutilise les **mêmes identifiants canoniques** que l'OLTP
(`transaction_id`, `customer_id`, `merchant_id`) pour garantir la transversalité entre
les trois bases. Le choix *embedding vs referencing* dépend du mode d'accès dominant.

| Collection | Stratégie | Raison |
|---|---|---|
| `transaction_events` | référence + embed léger | lu massivement, contexte figé au moment T |
| `customer_profiles` | embed | lu en un seul accès lors du scoring |
| `user_sessions` | embed + bucketing | clickstream volumineux, append-only |
| `ml_features` | embed + versioning | feature store, reproductibilité |
| `audit_log` | embed complet + TTL | immuable, conformité, autonome |

---

## 1. `transaction_events`

Reflet temps réel d'une transaction enrichie. Référence le client et le marchand
(qui vivent ailleurs), mais **embarque le contexte figé** au moment de la transaction
(taux de change, device, signaux de fraude) car ces valeurs ne doivent jamais changer
a posteriori.

```json
{
  "_id": "txn_01J2K8F3A9XYZ",
  "merchant_id": "mer_01HZ...",
  "customer_id": "cus_01HY...",
  "amount_cents": 4990,
  "currency": "EUR",
  "fx_rate_to_usd": 1.0824,
  "status": "succeeded",
  "device": {
    "type": "mobile",
    "os": "iOS 18.1",
    "ip": "84.12.x.x",
    "ip_country": "FR"
  },
  "fraud_signals": {
    "score": 0.0731,
    "velocity_10m": 2,
    "geo_mismatch": false,
    "new_device": true
  },
  "created_at": "2026-05-30T14:22:09.512Z"
}
```

**Index :** `{ merchant_id: 1, created_at: -1 }`, `{ "fraud_signals.score": -1 }`

---

## 2. `customer_profiles`

Profil agrégé d'un client, **mis à jour par le pipeline ML**. Tout est embarqué pour
être lu en **un seul accès disque** au moment du scoring de fraude (performance critique).

```json
{
  "_id": "cus_01HY...",
  "merchant_id": "mer_01HZ...",
  "segment": "loyal",
  "stats": {
    "txn_count_90d": 47,
    "avg_amount_cents": 3120,
    "total_spent_usd": 1684.50,
    "chargeback_count": 0
  },
  "risk": {
    "baseline_score": 0.08,
    "trusted_devices": ["dev_a1", "dev_b2"],
    "usual_countries": ["FR", "BE"]
  },
  "updated_at": "2026-05-30T03:00:00Z"
}
```

**Index :** `{ merchant_id: 1, segment: 1 }`

---

## 3. `user_sessions`

Clickstream du tunnel de paiement. Le volume d'événements par session peut être très
grand → on applique le **bucket pattern** : un nouveau document enfant est créé quand
`event_count` atteint 100, pour éviter le document illimité (limite MongoDB de 16 Mo).

```json
{
  "_id": "ses_01J2K...",
  "customer_id": "cus_01HY...",
  "bucket": 1,
  "started_at": "2026-05-30T14:18:00Z",
  "event_count": 23,
  "events": [
    { "type": "page_view",   "page": "/checkout", "ts": "2026-05-30T14:18:00Z" },
    { "type": "field_focus", "field": "card",     "ts": "2026-05-30T14:18:11Z" },
    { "type": "submit",      "result": "success", "ts": "2026-05-30T14:22:09Z" }
  ]
}
```

**Index :** `{ customer_id: 1, started_at: -1 }`, `{ started_at: 1, bucket: 1 }`

---

## 4. `ml_features`

Feature store pour l'inférence et le ré-entraînement. **Versionné** : chaque calcul de
features pointe vers la version précédente pour la traçabilité et la reproductibilité.

```json
{
  "_id": "feat_cus_01HY_v12",
  "customer_id": "cus_01HY...",
  "version": 12,
  "previous_version": "feat_cus_01HY_v11",
  "features": {
    "amount_zscore": 1.34,
    "velocity_1h": 3,
    "country_entropy": 0.12,
    "hour_of_day_sin": 0.87,
    "is_new_payment_method": 0
  },
  "computed_at": "2026-05-30T14:22:08Z",
  "model_version": "fraud-rf-2026.05"
}
```

**Index :** `{ customer_id: 1, version: -1 }`

---

## 5. `audit_log`

Journal **immuable** des changements sur les entités sensibles. **Tout est embarqué**
(état avant/après) pour rester lisible même après une suppression RGPD du client —
aucune référence pendante. Un **TTL** purge MongoDB après X jours, mais le log est
d'abord archivé sur S3 (mode *compliance*, non-effaçable).

```json
{
  "_id": "aud_01J2K...",
  "entity": { "type": "transaction", "id": "txn_01J2K8F3A9XYZ" },
  "action": "status_change",
  "actor": "fraud-engine",
  "before": { "status": "pending",  "fraud_score": 0.07 },
  "after":  { "status": "blocked",  "fraud_score": 0.91 },
  "ts": "2026-05-30T14:22:10Z",
  "expire_at": "2026-08-28T14:22:10Z"
}
```

**Index :** `{ "entity.type": 1, "entity.id": 1, ts: 1 }`,
TTL : `{ expire_at: 1 }, expireAfterSeconds: 0`

---

## Intégration avec OLTP / OLAP

- **Clés partagées** : les `_id` MongoDB reprennent les UUID de l'OLTP → jointure
  logique possible entre les systèmes sans duplication d'identité.
- **Alimentation** : MongoDB est peuplé par Kafka (voir pipeline), pas par écriture
  directe applicative → cohérence éventuelle assumée.
- **Vers l'OLAP** : `customer_profiles.segment` et `ltv` remontent dans `dim_customer`
  lors du batch nocturne.
