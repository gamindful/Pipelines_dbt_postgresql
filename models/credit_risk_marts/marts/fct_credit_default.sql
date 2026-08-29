-- What a person or BI tool queries. Grain: one row per credit card client.
-- Built on int_credit_default_enriched so utilisation/payment-history logic
-- stays defined once, not recomputed per mart.

select
    client_id,
    sex,
    education,
    education_code,
    marriage,
    marriage_code,
    age,
    credit_limit,
    avg_utilization_ratio,
    utilization_ratio_1        as latest_utilization_ratio,
    payment_coverage_ratio,
    max_delinquency_months,
    months_delinquent_count,
    total_billed_6mo,
    total_payments_6mo,
    default_next_month,
    source_system,
    loaded_at

from {{ ref('int_credit_default_enriched') }}
