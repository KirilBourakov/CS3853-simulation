SELECT 
    a.account_id,
    a.account_number,
    a.current_balance
FROM account a
WHERE a.account_id IN (
    SELECT t.account_id
    FROM transaction t
    WHERE t.transaction_id IN (
        SELECT ra.transaction_id
        FROM risk_assessment ra
        WHERE ra.risk_score >= 25.0000
    )
);