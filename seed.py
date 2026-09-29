import os
import random
from datetime import datetime, timedelta
import mysql.connector

# MySQL init daemon listens on local UNIX socket without TCP networking
socket_path = "/var/run/mysqld/mysqld.sock"

DB_CONFIG = {
    'user': 'root',
    'password': os.environ.get('MYSQL_ROOT_PASSWORD', 'rootpassword'),
    'database': os.environ.get('MYSQL_DATABASE', 'globalcard'),
}

if os.path.exists(socket_path):
    DB_CONFIG['unix_socket'] = socket_path
else:
    DB_CONFIG['host'] = '127.0.0.1'

conn = mysql.connector.connect(**DB_CONFIG)
cursor = conn.cursor()

# Temporary bypass for mass-loading speed
cursor.execute("SET foreign_key_checks = 0;")
cursor.execute("SET unique_checks = 0;")

TARGET_ACCOUNT_ID = 1004529
NUM_ACCOUNTS = 5000
NUM_MERCHANTS = 1000
BACKGROUND_TX_COUNT = 500000
BATCH_SIZE = 10000

print("[1/5] Seeding Parties, Merchants, Accounts, and Cards...", flush=True)

# 1. Merchants & Parties
party_rows = []
merchant_rows = []
for m_id in range(1, NUM_MERCHANTS + 1):
    party_rows.append((m_id, 'MERCHANT'))
    merchant_rows.append((m_id, f"Merchant {m_id} Corp", f"{1000 + (m_id % 9000)}"))

# 2. Cardholders & Accounts
account_rows = []
card_rows = []
account_ids = [TARGET_ACCOUNT_ID] + list(range(2000001, 2000001 + NUM_ACCOUNTS - 1))

for idx, acc_id in enumerate(account_ids):
    p_id = NUM_MERCHANTS + idx + 1
    party_rows.append((p_id, 'CARDHOLDER'))
    account_rows.append((acc_id, f"IBAN-ACC-{acc_id}", 0.00, 5000.00))
    card_rows.append((idx + 1, acc_id, p_id, f"token_{acc_id}", f"{acc_id % 10000:04d}", 'ACTIVE'))

cursor.executemany("INSERT INTO party (party_id, party_type) VALUES (%s, %s);", party_rows)
cursor.executemany("INSERT INTO merchant (merchant_id, legal_name, mcc_code) VALUES (%s, %s, %s);", merchant_rows)
cursor.executemany("INSERT INTO account (account_id, account_number, current_balance, credit_limit) VALUES (%s, %s, %s, %s);", account_rows)
cursor.executemany("INSERT INTO card (card_id, account_id, cardholder_id, pan_token, pan_last_four, card_status) VALUES (%s, %s, %s, %s, %s, %s);", card_rows)
conn.commit()

print(f"[2/5] Seeding Target Account {TARGET_ACCOUNT_ID}...", flush=True)

target_tx_batch = []
target_purchase_batch = []
tx_id_seq = 1

june_start = datetime(2026, 6, 1)

for i in range(1500):
    t_date = june_start + timedelta(seconds=random.randint(0, 30 * 86400 - 1))
    p_date = t_date + timedelta(hours=random.randint(1, 24))
    amt = round(random.uniform(5.0, 500.0), 2)
    disputed = (random.random() < 0.02)

    target_tx_batch.append((tx_id_seq, TARGET_ACCOUNT_ID, 'PURCHASE', amt, t_date, p_date, 'Target Account Tx', disputed))
    target_purchase_batch.append((tx_id_seq, 'PURCHASE', TARGET_ACCOUNT_ID, 1, random.randint(1, NUM_MERCHANTS), f"TERM-{random.randint(100, 999)}", "AUTH01", False))
    tx_id_seq += 1

cursor.executemany("""
    INSERT INTO transaction (transaction_id, account_id, transaction_type, amount, transaction_date, posted_date, description, is_disputed)
    VALUES (%s, %s, %s, %s, %s, %s, %s, %s);
""", target_tx_batch)

cursor.executemany("""
    INSERT INTO tx_purchase (transaction_id, transaction_type, account_id, card_id, merchant_id, terminal_id, auth_code, is_recurring)
    VALUES (%s, %s, %s, %s, %s, %s, %s, %s);
""", target_purchase_batch)
conn.commit()

print(f"[3/5] Seeding {BACKGROUND_TX_COUNT} background rows in batches of {BATCH_SIZE}...", flush=True)

bg_start = datetime(2025, 1, 1)
total_inserted = 0

while total_inserted < BACKGROUND_TX_COUNT:
    current_tx = []
    current_tp = []
    
    for _ in range(BATCH_SIZE):
        acc = random.choice(account_ids[1:])
        t_date = bg_start + timedelta(seconds=random.randint(0, 500 * 86400))
        p_date = t_date + timedelta(hours=random.randint(1, 48))
        amt = round(random.uniform(2.0, 1200.0), 2)
        
        current_tx.append((tx_id_seq, acc, 'PURCHASE', amt, t_date, p_date, 'Background Purchase', False))
        current_tp.append((tx_id_seq, 'PURCHASE', acc, 2, random.randint(1, NUM_MERCHANTS), 'POS-REG', 'AUTH99', False))
        tx_id_seq += 1

    cursor.executemany("""
        INSERT INTO transaction (transaction_id, account_id, transaction_type, amount, transaction_date, posted_date, description, is_disputed)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s);
    """, current_tx)

    cursor.executemany("""
        INSERT INTO tx_purchase (transaction_id, transaction_type, account_id, card_id, merchant_id, terminal_id, auth_code, is_recurring)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s);
    """, current_tp)

    conn.commit()
    total_inserted += BATCH_SIZE
    print(f"   -> Inserted {total_inserted}/{BACKGROUND_TX_COUNT} background rows...", flush=True)

print("[4/5] Restoring constraints...", flush=True)
cursor.execute("SET foreign_key_checks = 1;")
cursor.execute("SET unique_checks = 1;")
conn.commit()

print("[5/5] Running ANALYZE TABLE to recalculate CBO statistics...", flush=True)
cursor.execute("ANALYZE TABLE transaction, tx_purchase, merchant, account, card;")
cursor.fetchall()
conn.commit()

cursor.close()
conn.close()
print("All seeding successfully finished!", flush=True)