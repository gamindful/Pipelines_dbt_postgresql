-- Singular test a business person would recognise: no client has a negative
-- credit limit. (Negative bill_amt* is legitimate — overpaid balance — but
-- a negative limit itself would be a data error.) Passes when this returns
-- zero rows.

select client_id, credit_limit
from {{ ref('fct_credit_default') }}
where credit_limit < 0
