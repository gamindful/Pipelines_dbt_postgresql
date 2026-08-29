-- Cast, rename, light cleanup only — no joins, no aggregation (those belong
-- downstream). Raw stays faithful to the source; anomalies are decoded here.
--
-- education is documented 1-4 but also contains 0, 5, 6 (345 rows).
-- marriage  is documented 1-3 but also contains 0 (54 rows).
-- Both sets of undocumented codes have wildly inconsistent default rates
-- against the documented codes — collapsed to 'other' rather than dropped.
-- Negative bill_amt* values are legitimate overpaid balances — not "fixed".

with source as (

    select * from {{ source('credit_risk', 'credit_default') }}

),

renamed as (

    select
        client_id::integer                     as client_id,
        limit_bal::numeric(14,2)                as credit_limit,

        case sex::smallint
            when 1 then 'male'
            when 2 then 'female'
            else 'unknown'
        end                                     as sex,

        education::smallint                     as education_code,
        case
            when education::smallint between 1 and 4 then
                case education::smallint
                    when 1 then 'graduate_school'
                    when 2 then 'university'
                    when 3 then 'high_school'
                    when 4 then 'other'
                end
            else 'other'  -- undocumented codes 0, 5, 6
        end                                     as education,

        marriage::smallint                      as marriage_code,
        case marriage::smallint
            when 1 then 'married'
            when 2 then 'single'
            when 3 then 'other'
            else 'other'  -- undocumented code 0
        end                                     as marriage,

        age::smallint                           as age,

        pay_0::smallint                         as repay_status_1,
        pay_2::smallint                         as repay_status_2,
        pay_3::smallint                         as repay_status_3,
        pay_4::smallint                         as repay_status_4,
        pay_5::smallint                         as repay_status_5,
        pay_6::smallint                         as repay_status_6,

        bill_amt1::numeric(14,2)                as bill_amt_1,
        bill_amt2::numeric(14,2)                as bill_amt_2,
        bill_amt3::numeric(14,2)                as bill_amt_3,
        bill_amt4::numeric(14,2)                as bill_amt_4,
        bill_amt5::numeric(14,2)                as bill_amt_5,
        bill_amt6::numeric(14,2)                as bill_amt_6,

        pay_amt1::numeric(14,2)                 as payment_amt_1,
        pay_amt2::numeric(14,2)                 as payment_amt_2,
        pay_amt3::numeric(14,2)                 as payment_amt_3,
        pay_amt4::numeric(14,2)                 as payment_amt_4,
        pay_amt5::numeric(14,2)                 as payment_amt_5,
        pay_amt6::numeric(14,2)                 as payment_amt_6,

        default_next_month::smallint            as default_next_month,
        source                                  as source_system,
        loaded_at                               as loaded_at

    from source

)

select * from renamed
