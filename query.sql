SELECT 
    t.transaction_id,
    t.transaction_date,
    t.posted_date,
    t.amount,
    tp.terminal_id,
    tp.auth_code,
    m.legal_name
FROM transaction t
JOIN tx_purchase tp 
    ON t.transaction_id = tp.transaction_id
JOIN merchant m 
    ON tp.merchant_id = m.merchant_id
WHERE t.account_id = 1004529
  AND t.posted_date >= '2026-06-01 00:00:00'
  AND t.posted_date <  '2026-07-01 00:00:00'
  AND t.is_disputed = FALSE
ORDER BY t.posted_date DESC
LIMIT 25;