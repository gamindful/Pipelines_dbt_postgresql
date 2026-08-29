-- Cast, rename, decode the A-code categoricals into readable labels — cast +
-- rename + light cleanup only, no joins/aggregation.
--
-- NOTE: the label mapping below follows the publicly documented UCI Statlog
-- German Credit codebook (german.doc, shipped inside the source zip) from
-- memory of that standard reference — it was not re-verified against this
-- run's actual extracted german.doc. Spot-check a few rows against the doc
-- before trusting this in an exam/portfolio context.

with source as (

    select * from {{ source('credit_risk', 'german_credit') }}

),

renamed as (

    select
        applicant_id::integer                  as applicant_id,

        case checking_status
            when 'A11' then 'lt_0_dm'
            when 'A12' then '0_to_200_dm'
            when 'A13' then 'gte_200_dm'
            when 'A14' then 'no_checking_account'
            else 'unknown'
        end                                     as checking_status,

        duration_months::smallint               as duration_months,

        case credit_history
            when 'A30' then 'no_credits_or_all_paid'
            when 'A31' then 'all_paid_this_bank'
            when 'A32' then 'existing_paid_duly'
            when 'A33' then 'past_delay'
            when 'A34' then 'critical_or_other_credits'
            else 'unknown'
        end                                     as credit_history,

        case purpose
            when 'A40'  then 'car_new'
            when 'A41'  then 'car_used'
            when 'A42'  then 'furniture_equipment'
            when 'A43'  then 'radio_television'
            when 'A44'  then 'domestic_appliances'
            when 'A45'  then 'repairs'
            when 'A46'  then 'education'
            when 'A47'  then 'vacation'
            when 'A48'  then 'retraining'
            when 'A49'  then 'business'
            when 'A410' then 'other'
            else 'unknown'
        end                                     as purpose,

        credit_amount::numeric(12,2)            as credit_amount,

        case savings_status
            when 'A61' then 'lt_100_dm'
            when 'A62' then '100_to_500_dm'
            when 'A63' then '500_to_1000_dm'
            when 'A64' then 'gte_1000_dm'
            when 'A65' then 'unknown_or_none'
            else 'unknown'
        end                                     as savings_status,

        case employment_since
            when 'A71' then 'unemployed'
            when 'A72' then 'lt_1_year'
            when 'A73' then '1_to_4_years'
            when 'A74' then '4_to_7_years'
            when 'A75' then 'gte_7_years'
            else 'unknown'
        end                                     as employment_since,

        installment_rate::smallint              as installment_rate_pct,

        case personal_status_sex
            when 'A91' then 'male_divorced_separated'
            when 'A92' then 'female_divorced_separated_married'
            when 'A93' then 'male_single'
            when 'A94' then 'male_married_widowed'
            when 'A95' then 'female_single'
            else 'unknown'
        end                                     as personal_status_sex,

        case other_debtors
            when 'A101' then 'none'
            when 'A102' then 'co_applicant'
            when 'A103' then 'guarantor'
            else 'unknown'
        end                                     as other_debtors,

        residence_since::smallint               as residence_since_years,

        case property_type
            when 'A121' then 'real_estate'
            when 'A122' then 'building_society_or_life_insurance'
            when 'A123' then 'car_or_other'
            when 'A124' then 'unknown_or_none'
            else 'unknown'
        end                                     as property_type,

        age_years::smallint                     as age_years,

        case other_installment_plans
            when 'A141' then 'bank'
            when 'A142' then 'stores'
            when 'A143' then 'none'
            else 'unknown'
        end                                     as other_installment_plans,

        case housing
            when 'A151' then 'rent'
            when 'A152' then 'own'
            when 'A153' then 'for_free'
            else 'unknown'
        end                                     as housing,

        existing_credits::smallint              as existing_credits,

        case job
            when 'A171' then 'unemployed_unskilled_nonresident'
            when 'A172' then 'unskilled_resident'
            when 'A173' then 'skilled_employee'
            when 'A174' then 'management_or_self_employed'
            else 'unknown'
        end                                     as job,

        dependents::smallint                    as dependents,

        case telephone
            when 'A191' then false
            when 'A192' then true
            else null
        end                                     as has_telephone,

        case foreign_worker
            when 'A201' then true
            when 'A202' then false
            else null
        end                                     as is_foreign_worker,

        credit_risk_class::smallint             as credit_risk_class_code,
        case credit_risk_class::smallint
            when 1 then 'good'
            when 2 then 'bad'
            else 'unknown'
        end                                     as credit_risk_class,

        source                                  as source_system,
        loaded_at                               as loaded_at

    from source

)

select * from renamed
