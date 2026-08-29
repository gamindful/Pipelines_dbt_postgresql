-- Credit-utilisation and payment-history logic, factored out of the mart so
-- it can be reused by more than one downstream model (e.g. a future
-- monthly-trend mart alongside the current snapshot mart). Ephemeral —
-- inlined at build time, never materialized on its own.

with staged as (

    select * from {{ ref('stg_credit_risk__credit_default') }}

),

utilization as (

    select
        client_id,

        -- Utilisation ratio per statement month. Negative bill amounts are
        -- legitimate overpaid balances (per the source's data-quality notes)
        -- and are kept as-is rather than floored at zero.
        bill_amt_1 / nullif(credit_limit, 0)   as utilization_ratio_1,
        bill_amt_2 / nullif(credit_limit, 0)   as utilization_ratio_2,
        bill_amt_3 / nullif(credit_limit, 0)   as utilization_ratio_3,
        bill_amt_4 / nullif(credit_limit, 0)   as utilization_ratio_4,
        bill_amt_5 / nullif(credit_limit, 0)   as utilization_ratio_5,
        bill_amt_6 / nullif(credit_limit, 0)   as utilization_ratio_6,

        (bill_amt_1 + bill_amt_2 + bill_amt_3 + bill_amt_4 + bill_amt_5 + bill_amt_6)
            / nullif(credit_limit * 6, 0)      as avg_utilization_ratio,

        (payment_amt_1 + payment_amt_2 + payment_amt_3
            + payment_amt_4 + payment_amt_5 + payment_amt_6)      as total_payments_6mo,
        (bill_amt_1 + bill_amt_2 + bill_amt_3
            + bill_amt_4 + bill_amt_5 + bill_amt_6)                as total_billed_6mo

    from staged

),

payment_history as (

    select
        client_id,

        -- repay_status_* > 0 means N months delinquent that period;
        -- -1/0 mean paid duly or no balance revolved.
        greatest(
            repay_status_1, repay_status_2, repay_status_3,
            repay_status_4, repay_status_5, repay_status_6
        )                                                          as max_delinquency_months,

        (
            (repay_status_1 > 0)::int + (repay_status_2 > 0)::int + (repay_status_3 > 0)::int
            + (repay_status_4 > 0)::int + (repay_status_5 > 0)::int + (repay_status_6 > 0)::int
        )                                                          as months_delinquent_count

    from staged

)

select
    s.*,
    u.utilization_ratio_1,
    u.utilization_ratio_2,
    u.utilization_ratio_3,
    u.utilization_ratio_4,
    u.utilization_ratio_5,
    u.utilization_ratio_6,
    u.avg_utilization_ratio,
    u.total_payments_6mo,
    u.total_billed_6mo,
    case when u.total_billed_6mo > 0
         then u.total_payments_6mo / u.total_billed_6mo
    end                                                              as payment_coverage_ratio,
    p.max_delinquency_months,
    p.months_delinquent_count

from staged s
join utilization u on u.client_id = s.client_id
join payment_history p on p.client_id = s.client_id
