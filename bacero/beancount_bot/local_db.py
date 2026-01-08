import asyncpg

DB_HOST = '/run/postgresql'
DB_NAME = 'beancount_bot'
DB_USER = 'beancount_bot'

conn = None

async def init_db():
    global conn
    conn = await asyncpg.connect(
        user=DB_USER,
        database=DB_NAME,
        host=DB_HOST
    )

    await conn.execute("""
    CREATE TABLE IF NOT EXISTS transactions (
        id SERIAL PRIMARY KEY,
        insert_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        user_id BIGINT NOT NULL,
        amount_cent INTEGER,
        currency TEXT,
        source_account TEXT,
        destination_account TEXT,
        description TEXT,
        archived BOOLEAN DEFAULT FALSE
    );
    """)


async def insert_transaction(user_id, amount_cent, currency, source_account, destination_account, description):
    await conn.execute('''
        INSERT INTO transactions
        (user_id, amount_cent, currency, source_account, destination_account, description)
        VALUES
        ($1, $2, $3, $4, $5, $6)
        ''',
        user_id, amount_cent, currency, source_account,
         destination_account, description)


async def get_transactions(user_id, archived=False):
    fields = ('user_id', 'insert_time', 'amount_cent', 'currency', 'source_account', 'destination_account', 'description')

    transactions = await conn.fetch(f"""
        SELECT {', '.join(fields)} FROM transactions
        WHERE archived = {archived}
          AND user_id = {user_id}""")

    return [dict(zip(fields, t)) for t in transactions]


async def get_last_transaction(user_id):
    fields = ('insert_time', 'amount_cent', 'currency', 'source_account', 'destination_account', 'description')

    transactions = await conn.fetch(f"""
        SELECT {', '.join(fields)} FROM transactions
        WHERE user_id = {user_id}
        ORDER BY id DESC LIMIT 1
    """)

    if transactions:
        return dict(zip(fields, transactions[0]))


async def delete_last_transaction(user_id):
    await conn.execute(f"""
        DELETE FROM transactions
        WHERE user_id = {user_id} \
          AND id = (
            SELECT id FROM transactions
            ORDER BY insert_time DESC
            LIMIT 1
          );
    """)


async def get_most_frequent_by_field(user_id, field, n):
    transactions = await conn.fetch(f"""
        SELECT {field}, COUNT({field}) AS value_occurrence
        FROM transactions
        WHERE user_id = {user_id}
        GROUP BY {field}
        ORDER BY value_occurrence DESC
        LIMIT {n};
    """)

    return [t[0] for t in transactions]


async def archive_all_transactions(user_id):
    await conn.execute(f"UPDATE transactions SET archived = TRUE WHERE user_id = {user_id}")
