-- What a person or BI tool queries. Grain: one row per loan applicant.
-- Different shape and grain from fct_credit_default — genuinely a separate
-- population, not unioned with it.

select
    applicant_id,
    checking_status,
    duration_months,
    credit_history,
    purpose,
    credit_amount,
    credit_amount / nullif(duration_months, 0)  as credit_amount_per_month,
    savings_status,
    employment_since,
    installment_rate_pct,
    personal_status_sex,
    other_debtors,
    residence_since_years,
    property_type,
    age_years,
    other_installment_plans,
    housing,
    existing_credits,
    job,
    dependents,
    has_telephone,
    is_foreign_worker,
    credit_risk_class,
    credit_risk_class_code,
    source_system,
    loaded_at

from {{ ref('stg_credit_risk__german_credit') }}
