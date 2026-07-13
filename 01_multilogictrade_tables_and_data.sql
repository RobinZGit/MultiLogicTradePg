-- ============================================
-- MultiLogicTrade — шаг 1: таблицы и справочники
-- Версия: v37 (идемпотентный запуск)
-- ============================================
-- Подключение: база multilogictrade
-- Можно выполнять многократно: объекты и строки не дублируются.
-- Используются CREATE IF NOT EXISTS и INSERT ... ON CONFLICT DO NOTHING/UPDATE.
--
-- ================================================================
-- ПЕРЕД ЗАПУСКОМ ЭТОГО СКРИПТА
-- ================================================================
--
-- 1. Выполнен 00_create_database.sql (база multilogictrade создана).
-- 2. Query Tool / psql подключены к multilogictrade, НЕ к postgres.
-- 3. Расширения PostgreSQL для этого шага НЕ нужны
--    (ни http, ни postgis, ни pg_cron).
--
-- Следующий шаг после успешного выполнения:
--   02_multilogictrade_functions_and_procedures.sql
--   Перед HTTP-блоком в 02 — установить pgsql-http (см. комментарии в 02).
--
-- psql:
--   psql -U postgres -d multilogictrade -f 01_multilogictrade_tables_and_data.sql
-- ================================================================
-- ============================================

-- ============================================

-- Блок миграции: v36 — стоп-лосс (security_resume), is_shadow, pause/resume по бумаге
-- ============================================
DO $$
BEGIN
    ALTER TABLE logic_stops DROP CONSTRAINT IF EXISTS logic_stops_scope_type_check;
    ALTER TABLE logic_stops ADD CONSTRAINT logic_stops_scope_type_check
        CHECK (scope_type IN ('security', 'security_resume', 'portfolio'));
EXCEPTION
    WHEN undefined_table THEN NULL;
    WHEN duplicate_object THEN NULL;
END $$;

-- Блок миграции: обновление существующей схемы v16 → v17
-- ============================================
DO $$
BEGIN
    NULL;
END $$;

-- Блок миграции: обновление существующей схемы v15 → v16
-- ============================================
DO $$
BEGIN
    NULL;
END $$;

-- Блок миграции: обновление существующей схемы v14 → v15
-- ============================================
DO $$
BEGIN
    UPDATE logic_stops SET scope_type = 'security' WHERE scope_type = 'logic';
EXCEPTION
    WHEN undefined_table THEN NULL;
END $$;

DO $$
BEGIN
    ALTER TABLE logic_stops DROP CONSTRAINT IF EXISTS logic_stops_scope_type_check;
    ALTER TABLE logic_stops ADD CONSTRAINT logic_stops_scope_type_check
        CHECK (scope_type IN ('security', 'security_resume', 'portfolio'));
EXCEPTION
    WHEN undefined_table THEN NULL;
    WHEN duplicate_object THEN NULL;
END $$;

-- Блок миграции: обновление существующей схемы v13 → v14
-- ============================================
DO $$
BEGIN
    NULL;
END $$;

-- Блок миграции: обновление существующей схемы v12 → v13
-- ============================================
DO $$
BEGIN
    NULL;
END $$;

-- Блок миграции: обновление существующей схемы v11 → v12
-- ============================================
DO $$
BEGIN
    -- Убираем глобальный UNIQUE(prefix): один тикер может быть у акции и фьючерса
    IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'security_prefixes_prefix_key'
          AND conrelid = 'security_prefixes'::regclass
    ) THEN
        ALTER TABLE security_prefixes DROP CONSTRAINT security_prefixes_prefix_key;
    END IF;
EXCEPTION
    WHEN undefined_table THEN NULL;
END $$;

-- ============================================
-- Таблица: security_types (типы ценных бумаг)
-- ============================================
CREATE TABLE IF NOT EXISTS security_types (
    id SERIAL PRIMARY KEY,
    name VARCHAR(50) NOT NULL UNIQUE,
    note VARCHAR(100)
);

INSERT INTO security_types (name, note) VALUES
    ('Stock', 'Акции'),
    ('Bond', 'Облигации'),
    ('Futures', 'Фьючерсы'),
    ('Options', 'Опционы'),
    ('ETF', 'Биржевые фонды'),
    ('CFD', 'Контракты на разницу'),
    ('Warrant', 'Варранты'),
    ('Swap', 'Свопы'),
    ('Commodity', 'Товары/сырьё'),
    ('Index', 'Индексы'),
    ('Forex', 'Валютные пары'),
    ('MutualFund', 'Паевые фонды'),
    ('PreferredStock', 'Привилегированные акции'),
    ('ConvertibleBond', 'Конвертируемые облигации')
ON CONFLICT (name) DO NOTHING;

COMMENT ON TABLE security_types IS 'Таблица типов ценных бумаг';

-- ============================================
-- Таблица: exchanges (торговые площадки)
-- ============================================
CREATE TABLE IF NOT EXISTS exchanges (
    id SERIAL PRIMARY KEY,
    name VARCHAR(50) NOT NULL UNIQUE
);

INSERT INTO exchanges (name) VALUES ('MOEX'), ('SPB')
ON CONFLICT (name) DO NOTHING;

COMMENT ON TABLE exchanges IS 'Таблица торговых площадок';

-- ============================================
-- Таблица: securities (ценные бумаги)
-- ============================================
CREATE TABLE IF NOT EXISTS securities (
    id SERIAL PRIMARY KEY,
    name VARCHAR(200) NOT NULL,
    security_type_id INTEGER REFERENCES security_types(id)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_securities_name_unique ON securities(name);

COMMENT ON TABLE securities IS 'Таблица ценных бумаг';

-- ============================================
-- Таблица: security_prefixes (тикеры на площадках)
-- ============================================
-- Решение для одинаковых тикеров (VTBR, LKOH у акции и фьючерса):
--   • UNIQUE(security_id, exchange_id) — одна запись на инструмент и биржу
--   • instrument_market — рынок: stock / futures / bonds / index
--   • prefix — тикер MOEX; у акции и фьючерса может совпадать
--   • tbank_figi — FIGI для T-Bank API (для акций заполняется, для фьючерсов — в futures_expirations)
-- ============================================
CREATE TABLE IF NOT EXISTS security_prefixes (
    id SERIAL PRIMARY KEY,
    security_id INTEGER NOT NULL REFERENCES securities(id) ON DELETE CASCADE,
    exchange_id INTEGER NOT NULL REFERENCES exchanges(id) ON DELETE CASCADE,
    prefix VARCHAR(50) NOT NULL,
    instrument_market VARCHAR(20) NOT NULL DEFAULT 'stock'
        CHECK (instrument_market IN ('stock', 'futures', 'bonds', 'index', 'other')),
    tbank_figi VARCHAR(50),
    note VARCHAR(200)
);

UPDATE security_prefixes SET instrument_market = 'stock' WHERE instrument_market IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_security_prefixes_security_exchange
    ON security_prefixes(security_id, exchange_id);
CREATE INDEX IF NOT EXISTS idx_security_prefixes_prefix
    ON security_prefixes(exchange_id, prefix, instrument_market);

COMMENT ON TABLE security_prefixes IS 'Тикеры на торговых площадках; акция и фьючерс различаются security_id и instrument_market';
COMMENT ON COLUMN security_prefixes.instrument_market IS 'Рынок: stock, futures, bonds, index — различает VTBR-акцию и VTBR-фьючерс';
COMMENT ON COLUMN security_prefixes.tbank_figi IS 'FIGI инструмента в T-Bank Invest API';

-- ============================================
-- Справочник: 34 акции ММВБ
-- ============================================
INSERT INTO securities (name, security_type_id)
SELECT v.name, st.id
FROM (VALUES
    ('Сбербанк (обыкновенные)', 'Stock'),
    ('Сбербанк (привилегированные)', 'PreferredStock'),
    ('Газпром', 'Stock'),
    ('ЛУКОЙЛ', 'Stock'),
    ('Роснефть', 'Stock'),
    ('НОВАТЭК', 'Stock'),
    ('Норникель', 'Stock'),
    ('Татнефть (обыкновенные)', 'Stock'),
    ('Татнефть (привилегированные)', 'PreferredStock'),
    ('Сургутнефтегаз (обыкновенные)', 'Stock'),
    ('Сургутнефтегаз (привилегированные)', 'PreferredStock'),
    ('Полюс', 'Stock'),
    ('Алроса', 'Stock'),
    ('Северсталь', 'Stock'),
    ('НЛМК', 'Stock'),
    ('ММК', 'Stock'),
    ('Мечел (обыкновенные)', 'Stock'),
    ('Мечел (привилегированные)', 'PreferredStock'),
    ('Магнит', 'Stock'),
    ('МТС', 'Stock'),
    ('ВТБ', 'Stock'),
    ('РУСАЛ', 'Stock'),
    ('РусГидро', 'Stock'),
    ('Интер РАО', 'Stock'),
    ('ФСК-Россети', 'Stock'),
    ('Транснефть (привилегированные)', 'PreferredStock'),
    ('Юнипро', 'Stock'),
    ('Московская биржа', 'Stock'),
    ('Ростелеком', 'Stock'),
    ('Яндекс', 'Stock'),
    ('Аэрофлот', 'Stock'),
    ('Совкомфлот', 'Stock'),
    ('ФосАгро', 'Stock'),
    ('АФК Система', 'Stock')
) AS v(name, type_name)
JOIN security_types st ON st.name = v.type_name
ON CONFLICT (name) DO NOTHING;

-- ============================================
-- Справочник: 20 фьючерсов ММВБ
-- ============================================
INSERT INTO securities (name, security_type_id)
SELECT v.name, st.id
FROM (VALUES
    ('USD/RUB (доллар/рубль)', 'Futures'),
    ('EUR/RUB (евро/рубль)', 'Futures'),
    ('CNY/RUB (юань/рубль)', 'Futures'),
    ('CNY/RUB вечный фьючерс', 'Futures'),
    ('USD/RUB вечный фьючерс', 'Futures'),
    ('Природный газ', 'Futures'),
    ('Нефть Brent', 'Futures'),
    ('Золото (USD)', 'Futures'),
    ('Серебро (USD)', 'Futures'),
    ('Золото (рублевый)', 'Futures'),
    ('Золото вечный фьючерс', 'Futures'),
    ('Сбербанк (фьючерс на акции)', 'Futures'),
    ('ВТБ (фьючерс на акции)', 'Futures'),
    ('Газпром (фьючерс на акции)', 'Futures'),
    ('ЛУКОЙЛ (фьючерс на акции)', 'Futures'),
    ('Индекс Мосбиржи (IMOEX)', 'Futures'),
    ('Индекс РТС', 'Futures'),
    ('Индекс Мосбиржи (дневной фьючерс)', 'Futures'),
    ('Серебро (квартальный)', 'Futures'),
    ('Золото (квартальный)', 'Futures')
) AS v(name, type_name)
JOIN security_types st ON st.name = v.type_name
ON CONFLICT (name) DO NOTHING;

-- ============================================
-- Префиксы ММВБ (exchange MOEX = id 1)
-- instrument_market отделяет акцию от фьючерса при одинаковом prefix
-- ============================================
INSERT INTO security_prefixes (security_id, exchange_id, prefix, instrument_market, tbank_figi, note)
SELECT s.id, e.id, v.prefix, v.instrument_market, v.tbank_figi, v.note
FROM exchanges e
CROSS JOIN (VALUES
    ('Сбербанк (обыкновенные)', 'SBER', 'stock', 'BBG004730N88', 'Акция MOEX TQBR'),
    ('Сбербанк (привилегированные)', 'SBERP', 'stock', 'BBG0047315Y7', NULL),
    ('Газпром', 'GAZP', 'stock', 'BBG004730RP0', NULL),
    ('ЛУКОЙЛ', 'LKOH', 'stock', 'BBG004731032', 'Акция; тикер LKOH'),
    ('Роснефть', 'ROSN', 'stock', 'BBG004731354', NULL),
    ('НОВАТЭК', 'NVTK', 'stock', 'BBG00475KKY8', NULL),
    ('Норникель', 'GMKN', 'stock', 'BBG004731489', NULL),
    ('Татнефть (обыкновенные)', 'TATN', 'stock', 'BBG004RVFFC0', NULL),
    ('Татнефть (привилегированные)', 'TATNP', 'stock', 'BBG004S681W1', NULL),
    ('Сургутнефтегаз (обыкновенные)', 'SNGS', 'stock', 'BBG0047315D0', NULL),
    ('Сургутнефтегаз (привилегированные)', 'SNGSP', 'stock', 'BBG004S681M2', NULL),
    ('Полюс', 'PLZL', 'stock', 'BBG000R607Y3', NULL),
    ('Алроса', 'ALRS', 'stock', 'BBG004S68B31', NULL),
    ('Северсталь', 'CHMF', 'stock', 'BBG00475KHX6', NULL),
    ('НЛМК', 'NLMK', 'stock', 'BBG004S681BH', NULL),
    ('ММК', 'MAGN', 'stock', 'BBG004S68507', NULL),
    ('Мечел (обыкновенные)', 'MTLR', 'stock', 'BBG004S68598', NULL),
    ('Мечел (привилегированные)', 'MTLRP', 'stock', 'BBG004S686N0', NULL),
    ('Магнит', 'MGNT', 'stock', 'BBG004RVFCY3', NULL),
    ('МТС', 'MTSS', 'stock', 'BBG004S681W1', NULL),
    ('ВТБ', 'VTBR', 'stock', 'BBG004730ZJ9', 'Акция; тикер VTBR'),
    ('РУСАЛ', 'RUAL', 'stock', 'BBG008F2T3T2', NULL),
    ('РусГидро', 'HYDR', 'stock', 'BBG00475K2X9', NULL),
    ('Интер РАО', 'IRAO', 'stock', 'BBG004S68473', NULL),
    ('ФСК-Россети', 'FEES', 'stock', 'BBG00475JZZ6', NULL),
    ('Транснефть (привилегированные)', 'TRNFP', 'stock', 'BBG00475KHX6', NULL),
    ('Юнипро', 'UPRO', 'stock', 'BBG004S686W0', NULL),
    ('Московская биржа', 'MOEX', 'stock', 'BBG004730JJ5', NULL),
    ('Ростелеком', 'RTKM', 'stock', 'BBG004S682Z6', NULL),
    ('Яндекс', 'YDEX', 'stock', NULL, NULL),
    ('Аэрофлот', 'AFLT', 'stock', 'BBG004S683W7', NULL),
    ('Совкомфлот', 'FLOT', 'stock', NULL, NULL),
    ('ФосАгро', 'PHOR', 'stock', 'BBG004S689R0', NULL),
    ('АФК Система', 'AFKS', 'stock', 'BBG004S68614', NULL),
    ('USD/RUB (доллар/рубль)', 'Si', 'futures', NULL, 'Базовый код MOEX FORTS'),
    ('EUR/RUB (евро/рубль)', 'Eu', 'futures', NULL, NULL),
    ('CNY/RUB (юань/рубль)', 'CR', 'futures', NULL, NULL),
    ('CNY/RUB вечный фьючерс', 'CNYRUBF', 'futures', NULL, 'Вечный фьючерс'),
    ('USD/RUB вечный фьючерс', 'USDRUBF', 'futures', NULL, 'Вечный фьючерс'),
    ('Природный газ', 'NG', 'futures', NULL, NULL),
    ('Нефть Brent', 'Br', 'futures', NULL, NULL),
    ('Золото (USD)', 'GD', 'futures', NULL, NULL),
    ('Серебро (USD)', 'SV', 'futures', NULL, NULL),
    ('Золото (рублевый)', 'GL', 'futures', NULL, NULL),
    ('Золото вечный фьючерс', 'GLDRUBF', 'futures', NULL, NULL),
    ('Сбербанк (фьючерс на акции)', 'SBRF', 'futures', NULL, 'Фьючерс MOEX FORTS'),
    ('ВТБ (фьючерс на акции)', 'VTBR', 'futures', NULL, 'Фьючерс; тот же prefix, другой security_id'),
    ('Газпром (фьючерс на акции)', 'GAZR', 'futures', NULL, NULL),
    ('ЛУКОЙЛ (фьючерс на акции)', 'LKOH', 'futures', NULL, 'Фьючерс; тот же prefix, другой security_id'),
    ('Индекс Мосбиржи (IMOEX)', 'MX', 'futures', NULL, NULL),
    ('Индекс РТС', 'RI', 'futures', NULL, NULL),
    ('Индекс Мосбиржи (дневной фьючерс)', 'IMOEXF', 'futures', NULL, NULL),
    ('Серебро (квартальный)', 'SILV', 'futures', NULL, NULL),
    ('Золото (квартальный)', 'GOLD', 'futures', NULL, NULL)
) AS v(security_name, prefix, instrument_market, tbank_figi, note)
JOIN securities s ON s.name = v.security_name
WHERE e.name = 'MOEX'
ON CONFLICT (security_id, exchange_id) DO UPDATE SET
    prefix = EXCLUDED.prefix,
    instrument_market = EXCLUDED.instrument_market,
    tbank_figi = COALESCE(EXCLUDED.tbank_figi, security_prefixes.tbank_figi),
    note = EXCLUDED.note;

-- ============================================
-- Таблица: timeframes (таймфреймы)
-- ============================================
CREATE TABLE IF NOT EXISTS timeframes (
    id SERIAL PRIMARY KEY,
    tf VARCHAR(20) NOT NULL UNIQUE,
    full_name VARCHAR(50) NOT NULL,
    sec INTEGER NOT NULL CHECK (sec > 0),
    is_active BOOLEAN NOT NULL DEFAULT TRUE
);

INSERT INTO timeframes (tf, full_name, sec, is_active) VALUES
    ('M1', '1 минута', 60, TRUE), ('M2', '2 минуты', 120, TRUE), ('M3', '3 минуты', 180, TRUE),
    ('M5', '5 минут', 300, TRUE), ('M10', '10 минут', 600, TRUE), ('M15', '15 минут', 900, TRUE),
    ('M20', '20 минут', 1200, TRUE), ('M30', '30 минут', 1800, TRUE),
    ('H1', '1 час', 3600, TRUE), ('H2', '2 часа', 7200, TRUE), ('H4', '4 часа', 14400, TRUE),
    ('H6', '6 часов', 21600, TRUE), ('H8', '8 часов', 28800, TRUE), ('H12', '12 часов', 43200, TRUE),
    ('D1', '1 день', 86400, TRUE), ('D2', '2 дня', 172800, TRUE), ('D3', '3 дня', 259200, TRUE),
    ('W1', '1 неделя', 604800, TRUE), ('W2', '2 недели', 1209600, TRUE), ('W3', '3 недели', 1814400, TRUE),
    ('MN1', '1 месяц', 2592000, TRUE), ('MN2', '2 месяца', 5184000, TRUE), ('MN3', '3 месяца', 7776000, TRUE),
    ('MN6', '6 месяцев', 15552000, TRUE), ('Y1', '1 год', 31536000, TRUE)
ON CONFLICT (tf) DO UPDATE SET
    full_name = EXCLUDED.full_name,
    sec = EXCLUDED.sec,
    is_active = EXCLUDED.is_active;

COMMENT ON TABLE timeframes IS 'Таблица таймфреймов';
COMMENT ON COLUMN timeframes.is_active IS 'Использовать при массовой загрузке load_all_timeframes*';

-- ============================================
-- Таблица: brokers (брокеры)
-- ============================================
CREATE TABLE IF NOT EXISTS brokers (
    id SERIAL PRIMARY KEY,
    code VARCHAR(50) NOT NULL UNIQUE,
    name VARCHAR(100) NOT NULL,
    api_url VARCHAR(255),
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO brokers (code, name, api_url) VALUES
    ('T-BANK', 'T-Bank (Т-Банк)', 'https://invest-public-api.tinkoff.ru/rest')
ON CONFLICT (code) DO NOTHING;

-- ============================================
-- Таблица: accounts (счета)
-- ============================================
CREATE TABLE IF NOT EXISTS accounts (
    id SERIAL PRIMARY KEY,
    broker_id INTEGER NOT NULL REFERENCES brokers(id) ON DELETE CASCADE,
    account_code VARCHAR(100) NOT NULL,
    name VARCHAR(100) NOT NULL,
    account_type VARCHAR(20) NOT NULL CHECK (account_type IN ('real', 'fake')),
    is_efficient BOOLEAN NOT NULL DEFAULT FALSE,
    token_encrypted TEXT,
    token_hash VARCHAR(64),
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_accounts_broker_account_code ON accounts(broker_id, account_code);

INSERT INTO accounts (broker_id, account_code, name, account_type, is_efficient, token_encrypted, token_hash)
SELECT b.id, 'FAKE-EFF-001', 'Демо-счет T-Bank (эффективный)', 'fake', TRUE, NULL, NULL
FROM brokers b WHERE b.code = 'T-BANK'
ON CONFLICT (broker_id, account_code) DO NOTHING;

-- ============================================
-- Таблица: prices (цены OHLCV)
-- ============================================
CREATE TABLE IF NOT EXISTS prices (
    id BIGSERIAL PRIMARY KEY,
    security_id INTEGER NOT NULL REFERENCES securities(id) ON DELETE CASCADE,
    timeframe_id INTEGER NOT NULL REFERENCES timeframes(id) ON DELETE CASCADE,
    dt TIMESTAMP NOT NULL,
    open_price NUMERIC(18, 6) NOT NULL,
    high_price NUMERIC(18, 6) NOT NULL,
    low_price NUMERIC(18, 6) NOT NULL,
    close_price NUMERIC(18, 6) NOT NULL,
    volume NUMERIC(20, 2),
    value NUMERIC(20, 2),
    trades INTEGER,
    contract_prefix VARCHAR(50),
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Существующие БД: CREATE TABLE IF NOT EXISTS не добавляет новые колонки
ALTER TABLE prices ADD COLUMN IF NOT EXISTS contract_prefix VARCHAR(50);

CREATE INDEX IF NOT EXISTS idx_prices_security_id ON prices(security_id);
CREATE INDEX IF NOT EXISTS idx_prices_timeframe_id ON prices(timeframe_id);
CREATE INDEX IF NOT EXISTS idx_prices_dt ON prices(dt);
CREATE INDEX IF NOT EXISTS idx_prices_security_timeframe ON prices(security_id, timeframe_id);
CREATE INDEX IF NOT EXISTS idx_prices_security_timeframe_dt ON prices(security_id, timeframe_id, dt);
CREATE UNIQUE INDEX IF NOT EXISTS idx_prices_unique_candle ON prices(security_id, timeframe_id, dt);
CREATE INDEX IF NOT EXISTS idx_prices_contract_prefix ON prices(contract_prefix)
    WHERE contract_prefix IS NOT NULL;

COMMENT ON TABLE prices IS 'Таблица цен (OHLCV)';
COMMENT ON COLUMN prices.contract_prefix IS 'Тикер конкретного контракта (Si-6.26); NULL для акций. Групповой префикс — в security_prefixes.prefix';

-- ============================================
-- Таблица: parameter_types (типы параметров)
-- ============================================
CREATE TABLE IF NOT EXISTS parameter_types (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL UNIQUE,
    short_name VARCHAR(20) NOT NULL UNIQUE,
    value_type VARCHAR(20) NOT NULL,
    is_control BOOLEAN NOT NULL DEFAULT FALSE,
    is_fake_only BOOLEAN NOT NULL DEFAULT FALSE,
    description TEXT,
    default_value TEXT,
    min_value NUMERIC(18, 6),
    max_value NUMERIC(18, 6),
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_parameter_types_short_name ON parameter_types(short_name);

INSERT INTO parameter_types (name, short_name, value_type, description, default_value, min_value, max_value) VALUES
    ('RSI период', 'RSI_PERIOD', 'integer', 'Период расчёта RSI', '14', 2, 100),
    ('SMA период', 'SMA_PERIOD', 'integer', 'Период расчёта SMA', '20', 2, 500),
    ('EMA период', 'EMA_PERIOD', 'integer', 'Период расчёта EMA', '20', 2, 500),
    ('BB период', 'BB_PERIOD', 'integer', 'Период полос Боллинджера', '20', 2, 500),
    ('ATR период', 'ATR_PERIOD', 'integer', 'Период ATR', '14', 2, 100),
    ('STOCH период K', 'STOCH_PERIOD', 'integer', 'Период %K стохастика', '14', 2, 100),
    ('T-Bank API токен', 'TBANK_API_TOKEN', 'secret', 'Глобальный токен Invest API T-Bank для загрузки цен (не привязан к счёту)', '', NULL, NULL),
    ('Техническое логирование', 'APP_TECH_LOGGING', 'boolean', 'Глобальный журнал app_tech_log: trade runner, сигналы, параметры логики', '0', NULL, NULL),
    ('Heartbeat UI trade runner', 'APP_TRADE_RUNNER_HB', 'text', 'Последний heartbeat Angular; без него run_trade_cycle пропускается', '', NULL, NULL)
ON CONFLICT (short_name) DO NOTHING;

-- ============================================
-- Таблица: parameter_sets (наборы параметров)
-- ============================================
CREATE TABLE IF NOT EXISTS parameter_sets (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    description TEXT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_parameter_sets_name ON parameter_sets(name);

INSERT INTO parameter_sets (name, description) VALUES
    ('Default', 'Базовый набор параметров по умолчанию')
ON CONFLICT (name) DO NOTHING;

-- ============================================
-- Таблица: parameter_values (значения параметров)
-- ============================================
CREATE TABLE IF NOT EXISTS parameter_values (
    id SERIAL PRIMARY KEY,
    parameter_set_id INTEGER NOT NULL REFERENCES parameter_sets(id) ON DELETE CASCADE,
    parameter_type_id INTEGER NOT NULL REFERENCES parameter_types(id) ON DELETE CASCADE,
    value TEXT NOT NULL,
    record_date TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_parameter_values_unique ON parameter_values(parameter_set_id, parameter_type_id);

INSERT INTO parameter_values (parameter_set_id, parameter_type_id, value)
SELECT ps.id, pt.id, pt.default_value
FROM parameter_sets ps
CROSS JOIN parameter_types pt
WHERE ps.name = 'Default'
ON CONFLICT (parameter_set_id, parameter_type_id) DO NOTHING;

INSERT INTO parameter_values (parameter_set_id, parameter_type_id, value)
SELECT ps.id, pt.id, ''
FROM parameter_sets ps
JOIN parameter_types pt ON pt.short_name = 'TBANK_API_TOKEN'
WHERE ps.name = 'Default'
ON CONFLICT (parameter_set_id, parameter_type_id) DO NOTHING;

-- ============================================
-- Таблица: indicators (справочник индикаторов)
-- ============================================
CREATE TABLE IF NOT EXISTS indicators (
    id SERIAL PRIMARY KEY,
    code VARCHAR(20) NOT NULL UNIQUE,
    name VARCHAR(100) NOT NULL,
    -- Шаблон вызова функции расчёта (EXECUTE в PostgreSQL / EXECUTE IMMEDIATE в Oracle).
    -- Плейсхолдеры :period, :fast_period, :series, :security_id, :timeframe_id, :dt, :indicator_id и др.
    -- :series — код серии из indicator_value_types (RSI, MACD, UPPER, …).
    script TEXT,
    -- Многочленная формула для массивного расчёта (sync / calc_poly_formula_array):
    -- pp, sma(pp), pp * (1;-2;1), @RSI, sma() * sma() * sma() и т.д.
    formula TEXT,
    is_custom BOOLEAN NOT NULL DEFAULT FALSE,
    -- Подробное описание: полное название, расчёт, сигналы, применение (многострочный TEXT).
    description TEXT,
    category VARCHAR(50),
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON COLUMN indicators.script IS
'Устаревший per-bar шаблон SELECT calc_ind_*(…). Для новых индикаторов — поле formula.';

COMMENT ON COLUMN indicators.formula IS
'Многочленная формула массивного расчёта: pp, sma, @SMA, pp * (1;-2;1). Код индикатора (SMA, RSI) = ссылка @CODE в других формулах.';

COMMENT ON COLUMN indicators.is_custom IS
'TRUE — пользовательская/составная формула (подсветка в списке индикаторов).';

COMMENT ON COLUMN indicators.description IS
'Справочное описание: полное наименование, расчёт, типичные сигналы и область применения.';

INSERT INTO indicators (code, name, description, category) VALUES
    ('SMA', 'Simple Moving Average', 'Простое скользящее среднее', 'trend'),
    ('EMA', 'Exponential Moving Average', 'Экспоненциальное скользящее среднее', 'trend'),
    ('WMA', 'Weighted Moving Average', 'Взвешенное скользящее среднее', 'trend'),
    ('RSI', 'Relative Strength Index', 'Индекс относительной силы (0-100)', 'momentum'),
    ('MACD', 'Moving Average Convergence Divergence', 'Схождение/расхождение скользящих средних', 'momentum'),
    ('STOCH', 'Stochastic Oscillator', 'Стохастический осциллятор (%K, %D)', 'momentum'),
    ('BB', 'Bollinger Bands', 'Полосы Боллинджера', 'volatility'),
    ('ATR', 'Average True Range', 'Средний истинный диапазон', 'volatility'),
    ('PACC', 'Price Acceleration', 'Ускорение цены', 'momentum'),
    ('ADX', 'Average Directional Index', 'Индекс среднего направления', 'trend'),
    ('OBV', 'On-Balance Volume', 'Накопленный объем', 'volume'),
    ('VWAP', 'Volume Weighted Average Price', 'Объемно-взвешенная средняя цена', 'volume'),
    ('MFI', 'Money Flow Index', 'Индекс денежного потока', 'momentum'),
    ('CCI', 'Commodity Channel Index', 'Индекс товарного канала', 'momentum'),
    ('WILLR', 'Williams %R', 'Процентный диапазон Вильямса', 'momentum'),
    ('PSAR', 'Parabolic SAR', 'Параболическая система SAR', 'trend'),
    ('ICHIMOKU', 'Ichimoku Cloud', 'Облако Ишимоку', 'trend'),
    ('KDJ', 'KDJ Indicator', 'Индикатор KDJ', 'momentum'),
    ('DMI', 'Directional Movement Index', 'Индекс направленного движения', 'trend'),
    ('KELTNER', 'Keltner Channels', 'Каналы Кельтнера', 'volatility'),
    ('DONCHIAN', 'Donchian Channels', 'Каналы Дончиана', 'volatility'),
    ('ROC', 'Rate of Change', 'Темп изменения', 'momentum'),
    ('TRIX', 'Triple Exponential Average', 'Тройное экспоненциальное среднее', 'momentum'),
    ('CMO', 'Chande Momentum Oscillator', 'Осциллятор моментума Чанде', 'momentum'),
    ('RVI', 'Relative Vigor Index', 'Индекс относительной бодрости', 'momentum'),
    ('TSI', 'True Strength Index', 'Индекс истинной силы', 'momentum'),
    ('UO', 'Ultimate Oscillator', 'Ультимативный осциллятор', 'momentum'),
    ('AROON', 'Aroon Indicator', 'Индикатор Арун', 'trend'),
    ('SAR', 'Stop And Reverse', 'Стоп и реверс', 'trend'),
    ('HMA', 'Hull Moving Average', 'Скользящее среднее Халла', 'trend'),
    ('ZLEMA', 'Zero Lag EMA', 'EMA с нулевым запаздыванием', 'trend'),
    ('SMAT3', 'SMA Triple', 'Тройное SMA (тройная свёртка)', 'trend')
ON CONFLICT (code) DO NOTHING;

-- Шаблоны расчёта (функция + параметры; :series подставляется для каждой линии индикатора)
UPDATE indicators SET script = 'SELECT calc_ind_rsi(:period, :series, :security_id, :timeframe_id, :dt, :indicator_id)' WHERE code = 'RSI';
UPDATE indicators SET script = 'SELECT calc_ind_sma(:period, :series, :security_id, :timeframe_id, :dt, :indicator_id)' WHERE code = 'SMA';
UPDATE indicators SET script = 'SELECT calc_ind_ema(:period, :series, :security_id, :timeframe_id, :dt, :indicator_id)' WHERE code = 'EMA';
UPDATE indicators SET script = 'SELECT calc_ind_macd(:fast_period, :slow_period, :signal_period, :series, :security_id, :timeframe_id, :dt, :indicator_id)' WHERE code = 'MACD';
UPDATE indicators SET script = 'SELECT calc_ind_bb(:period, :std_dev, :series, :security_id, :timeframe_id, :dt, :indicator_id)' WHERE code = 'BB';
UPDATE indicators SET script = 'SELECT calc_ind_atr(:period, :series, :security_id, :timeframe_id, :dt, :indicator_id)' WHERE code = 'ATR';
UPDATE indicators SET script = 'SELECT calc_ind_stoch(:k_period, :d_period, :smooth, :series, :security_id, :timeframe_id, :dt, :indicator_id)' WHERE code = 'STOCH';

ALTER TABLE indicators ADD COLUMN IF NOT EXISTS formula TEXT;
ALTER TABLE indicators ADD COLUMN IF NOT EXISTS is_custom BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE indicators ADD COLUMN IF NOT EXISTS sig_trend_def TEXT;
ALTER TABLE indicators ADD COLUMN IF NOT EXISTS sig_ct_def TEXT;

COMMENT ON COLUMN indicators.sig_trend_def IS
'Условие трендового сигнала по умолчанию (на сериях индикатора: VALUE, K, MIDDLE …)';

COMMENT ON COLUMN indicators.sig_ct_def IS
'Условие контртрендового сигнала по умолчанию';

-- Многочленные формулы (массивный расчёт — единый парсер, без SELECT)
UPDATE indicators SET formula = 'sma', is_custom = FALSE WHERE code = 'SMA';
UPDATE indicators SET formula = 'ema', is_custom = FALSE WHERE code = 'EMA';
UPDATE indicators SET formula = 'pp * (1; -2; 1)', is_custom = TRUE WHERE code = 'PACC';
UPDATE indicators SET formula = 'sma(period=20, series=VALUE) * sma(period=20, series=VALUE) * sma(period=20, series=VALUE)', is_custom = TRUE WHERE code = 'SMAT3';

-- Формулы сигналов по умолчанию (условие на серии; в логике: @CODE(params) + условие)
UPDATE indicators SET sig_trend_def = 'pp > VALUE', sig_ct_def = 'pp < VALUE'
WHERE category = 'trend'
  AND code NOT IN ('ADX', 'DMI', 'AROON', 'PSAR', 'SAR', 'ICHIMOKU');

UPDATE indicators SET sig_trend_def = 'VALUE > 50', sig_ct_def = 'VALUE < 30'
WHERE category = 'momentum'
  AND code NOT IN ('MACD', 'STOCH', 'PACC');

UPDATE indicators SET sig_trend_def = 'VALUE > 0', sig_ct_def = 'VALUE < 0' WHERE code IN ('MACD', 'PACC', 'ATR');
UPDATE indicators SET sig_trend_def = 'K > D', sig_ct_def = 'K < 20' WHERE code = 'STOCH';
UPDATE indicators SET sig_trend_def = 'pp > MIDDLE', sig_ct_def = 'pp < LOWER'
WHERE code IN ('BB', 'KELTNER', 'DONCHIAN');
UPDATE indicators SET sig_trend_def = 'VALUE > 0', sig_ct_def = 'VALUE < 0' WHERE category = 'volume';
UPDATE indicators SET sig_trend_def = 'VALUE > 25', sig_ct_def = 'VALUE < 20' WHERE code IN ('ADX', 'DMI');
UPDATE indicators SET sig_trend_def = 'UP > DOWN', sig_ct_def = 'DOWN > UP' WHERE code = 'AROON';
UPDATE indicators SET sig_trend_def = 'pp > VALUE', sig_ct_def = 'pp < VALUE'
WHERE code IN ('PSAR', 'SAR', 'ICHIMOKU', 'SMAT3');

UPDATE indicators SET
    sig_trend_def = COALESCE(sig_trend_def, 'VALUE > 50'),
    sig_ct_def = COALESCE(sig_ct_def, 'VALUE < 50')
WHERE sig_trend_def IS NULL OR sig_ct_def IS NULL;

-- Подробные описания индикаторов с функциями расчёта в PostgreSQL
UPDATE indicators SET description = $desc$
Relative Strength Index (RSI) — индекс относительной силы

Расчёт: за период N (по умолчанию 14) суммируются приросты и падения цены закрытия; RS = средний прирост / среднее падение; RSI = 100 − 100/(1+RS). Значения в диапазоне 0–100.

Сигналы: RSI выше 70 — зона перекупленности (риск коррекции вниз); ниже 30 — перепроданность (возможен отскок); пересечение уровня 50 — смена краткосрочного импульса; расхождение RSI и цены предупреждает о ослаблении тренда.

Применение: фильтр входов в тренд и контртренд, оценка силы движения, тайминг на боковом рынке, комбинация с MA и объёмом.
$desc$ WHERE code = 'RSI';

UPDATE indicators SET description = $desc$
Simple Moving Average (SMA) — простое скользящее среднее

Расчёт: среднее арифметическое цен закрытия за последние N свечей (по умолчанию 20). Каждая свеча в окне имеет одинаковый вес.

Сигналы: цена выше SMA — бычий фон, ниже — медвежий; пересечение цены и линии SMA — возможная смена краткосрочного тренда; наклон SMA показывает направление и силу тренда; несколько SMA разного периода дают «золотой/мёртвый крест».

Применение: определение тренда, динамические уровни поддержки и сопротивления, trailing stop, база для MACD, полос Боллинджера и других индикаторов.
$desc$ WHERE code = 'SMA';

UPDATE indicators SET description = $desc$
Exponential Moving Average (EMA) — экспоненциальное скользящее среднее

Расчёт: рекурсивное сглаживание цены закрытия; последним свечам присваивается больший вес (множитель 2/(N+1), по умолчанию N=20). Быстрее реагирует на изменения, чем SMA.

Сигналы: цена выше EMA — восходящий импульс, ниже — нисходящий; пересечение быстрой и медленной EMA — классический трендовый сигнал; резкий отрыв цены от EMA — перегрев движения.

Применение: трендовые системы, основа MACD, фильтр направления сделок, короткие и среднесрочные стратегии на ликвидных инструментах.
$desc$ WHERE code = 'EMA';

UPDATE indicators SET description = $desc$
Moving Average Convergence Divergence (MACD) — схождение/расхождение скользящих средних

Расчёт: линия MACD = EMA(12) − EMA(26); сигнальная линия = EMA(9) от MACD; гистограмма = MACD − Signal. Серии: MACD, SIGNAL, HISTOGRAM, ZERO.

Сигналы: пересечение MACD и Signal снизу вверх — бычий сигнал, сверху вниз — медвежий; гистограмма выше/ниже нуля подтверждает импульс; дивергенция MACD и цены — предупреждение о развороте; пересечение нулевой линии — смена доминирующего тренда.

Применение: определение момента входа в тренд, подтверждение пробоев, фильтр для swing- и позиционной торговли, сочетание с RSI и объёмом.
$desc$ WHERE code = 'MACD';

UPDATE indicators SET description = $desc$
Bollinger Bands (BB) — полосы Боллинджера

Расчёт: средняя полоса = SMA(N), по умолчанию N=20; верхняя и нижняя = SMA ± k·σ (k=2 стандартных отклонения); bandwidth — относительная ширина канала. Серии: UPPER, MIDDLE, LOWER, BANDWIDTH.

Сигналы: касание/пробой верхней полосы — перекупленность или сильный тренд; нижней — перепроданность или падение; сжатие полос (низкий bandwidth) — ожидание всплеска волатильности; «walking the bands» — устойчивый тренд вдоль границы.

Применение: оценка волатильности, mean-reversion на боковике, подтверждение пробоев при расширении полос, постановка стопов относительно полос.
$desc$ WHERE code = 'BB';

UPDATE indicators SET description = $desc$
Average True Range (ATR) — средний истинный диапазон

Расчёт: True Range = max(High−Low, |High−Close_prev|, |Low−Close_prev|); ATR — сглаженное среднее TR за N периодов (Wilder, по умолчанию 14). ATR_PCT — ATR в процентах от цены.

Сигналы: рост ATR — усиление волатильности и движения; падение ATR — затишье и сжатие; резкий скачок ATR после консолидации — начало импульса. Сам по себе не даёт направления buy/sell.

Применение: расчёт стоп-лоссов и тейк-профитов в пунктах цены, sizing позиции, фильтр «достаточной» волатильности для входа, сравнение активности инструментов.
$desc$ WHERE code = 'ATR';

UPDATE indicators SET description = $desc$
Stochastic Oscillator (STOCH) — стохастический осциллятор

Расчёт: %K = (Close − Low_N) / (High_N − Low_N) × 100 за период N (по умолчанию 14); %D — SMA(%K) за 3 периода. Значения 0–100. Серии: K, D, пороги 80/20.

Сигналы: %K и %D выше 80 — перекупленность; ниже 20 — перепроданность; пересечение %K и %D в зонах экстремумов — сигнал разворота; бычья/медвежья дивергенция с ценой — предупреждение о смене импульса.

Применение: тайминг входа на коррекциях в тренде, скальпинг и intraday, комбинация с уровнями и трендовыми фильтрами (MA, ADX).
$desc$ WHERE code = 'STOCH';

UPDATE indicators SET description = $desc$
Price Acceleration (PACC) — ускорение цены

Расчёт: вторая разность цены закрытия — дискретный аналог второй производной по времени.
Формула в терминах многочленов MultiLogic: pp * (1; -2; 1), где pp — ряд Close, оператор * — свёртка (см. MultiLogic PolynomialIndicators).
На баре k: a_k = p_k − 2·p_{k−1} + p_{k−2}. Показывает, ускоряется или замедляется движение цены.

Сигналы: смена знака ускорения — возможный разворот импульса; положительное ускорение на растущей цене — усиление тренда; отрицательное — замедление роста или усиление падения.

Применение: фильтр импульса, подтверждение пробоев, оценка «кривизны» траектории цены; линия строится на шкале цены (как SMA).
$desc$ WHERE code = 'PACC';

UPDATE indicators SET description = $desc$
SMA Triple (SMAT3) — тройная свёртка ряда SMA

Расчёт: sma(period=20, series=VALUE) * … (трижды). В () — параметры: позиционно (20, VALUE) или period=20, series=VALUE; без () — дефолты серии на бумаге.
S = sma(…), затем ((S * S) * S) с нормализацией при равной длине рядов.

Сигналы: усиленное сглаживание на шкале цены; отлично от одинарного SMA.

Применение: тройная свёртка многочленов; запись через * без скобок и без композиции.
$desc$ WHERE code = 'SMAT3';

-- SMAT3COMP удалён (композиция sma(sma(...)) не используется)

-- ============================================
-- Таблица: indicator_value_types (линии индикаторов)
-- ============================================
CREATE TABLE IF NOT EXISTS indicator_value_types (
    id SERIAL PRIMARY KEY,
    indicator_id INTEGER NOT NULL REFERENCES indicators(id) ON DELETE CASCADE,
    code VARCHAR(20) NOT NULL,
    name VARCHAR(50) NOT NULL,
    value_type VARCHAR(20) NOT NULL DEFAULT 'float',
    is_threshold BOOLEAN NOT NULL DEFAULT FALSE,
    threshold_value NUMERIC(18, 6),
    description TEXT,
    display_order INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_indicator_value_types_unique ON indicator_value_types(indicator_id, code);

-- Типы значений (привязка по коду индикатора, не по id)
INSERT INTO indicator_value_types (indicator_id, code, name, value_type, is_threshold, threshold_value, description, display_order)
SELECT i.id, v.code, v.name, v.value_type, v.is_threshold, v.threshold_value, v.description, v.display_order
FROM indicators i
JOIN (VALUES
    ('RSI', 'RSI', 'Значение RSI', 'float', FALSE, NULL, 'Основное значение RSI', 1),
    ('RSI', 'OVERBOUGHT', 'Перекупленность', 'float', TRUE, 70, 'Порог перекупленности', 2),
    ('RSI', 'OVERSOLD', 'Перепроданность', 'float', TRUE, 30, 'Порог перепроданности', 3),
    ('RSI', 'NEUTRAL', 'Нейтральная зона', 'float', TRUE, 50, 'Нейтральный уровень', 4),
    ('MACD', 'MACD', 'MACD линия', 'float', FALSE, NULL, 'Разница EMA', 1),
    ('MACD', 'SIGNAL', 'Сигнальная линия', 'float', FALSE, NULL, 'Signal line', 2),
    ('MACD', 'HISTOGRAM', 'Гистограмма', 'float', FALSE, NULL, 'MACD - Signal', 3),
    ('MACD', 'ZERO', 'Нулевая линия', 'float', TRUE, 0, 'Нулевой уровень', 4),
    ('STOCH', 'K', '%K линия', 'float', FALSE, NULL, 'Быстрая линия', 1),
    ('STOCH', 'D', '%D линия', 'float', FALSE, NULL, 'Медленная линия', 2),
    ('STOCH', 'OVERBOUGHT', 'Перекупленность', 'float', TRUE, 80, 'Порог 80', 3),
    ('STOCH', 'OVERSOLD', 'Перепроданность', 'float', TRUE, 20, 'Порог 20', 4),
    ('BB', 'UPPER', 'Верхняя полоса', 'float', FALSE, NULL, 'Upper band', 1),
    ('BB', 'MIDDLE', 'Средняя полоса', 'float', FALSE, NULL, 'Middle band', 2),
    ('BB', 'LOWER', 'Нижняя полоса', 'float', FALSE, NULL, 'Lower band', 3),
    ('BB', 'BANDWIDTH', 'Ширина полос', 'float', FALSE, NULL, 'Bandwidth', 4),
    ('ATR', 'ATR', 'Значение ATR', 'float', FALSE, NULL, 'ATR', 1),
    ('ATR', 'ATR_PCT', 'ATR в процентах', 'float', FALSE, NULL, 'ATR %', 2),
    ('PACC', 'VALUE', 'Ускорение цены', 'float', FALSE, NULL, 'pp * (1;-2;1)', 1),
    ('SMAT3', 'VALUE', 'SMA³ свёртка', 'float', FALSE, NULL, 'sma(period=20,series=VALUE)*3', 1),
    ('SMA', 'VALUE', 'Значение MA', 'float', FALSE, NULL, 'SMA value', 1),
    ('EMA', 'VALUE', 'Значение EMA', 'float', FALSE, NULL, 'EMA value', 1),
    ('WMA', 'VALUE', 'Значение WMA', 'float', FALSE, NULL, 'WMA value', 1)
) AS v(indicator_code, code, name, value_type, is_threshold, threshold_value, description, display_order)
    ON i.code = v.indicator_code
ON CONFLICT (indicator_id, code) DO NOTHING;

-- ============================================
-- Таблица: security_indicator_series (серии индикаторов на бумаге)
-- Одна строка = одна линия на графике (серия) с формулой вызова calc_ind_*_array
-- ============================================
CREATE TABLE IF NOT EXISTS security_indicator_series (
    id SERIAL PRIMARY KEY,
    security_id INTEGER NOT NULL REFERENCES securities(id) ON DELETE CASCADE,
    indicator_id INTEGER NOT NULL REFERENCES indicators(id) ON DELETE CASCADE,
    series_code VARCHAR(20) NOT NULL,
    invoke_formula TEXT NOT NULL,
    param_period INTEGER,
    param_fast_period INTEGER,
    param_slow_period INTEGER,
    param_signal_period INTEGER,
    param_std_dev NUMERIC(10, 4) DEFAULT 2.0,
    param_k_period INTEGER,
    param_d_period INTEGER,
    param_smooth INTEGER,
    point_count INTEGER NOT NULL DEFAULT 100,
    display_order INTEGER NOT NULL DEFAULT 0,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_security_indicator_series_unique
    ON security_indicator_series(security_id, indicator_id, series_code);
CREATE INDEX IF NOT EXISTS idx_security_indicator_series_security_id
    ON security_indicator_series(security_id);
CREATE INDEX IF NOT EXISTS idx_security_indicator_series_indicator_id
    ON security_indicator_series(indicator_id);

COMMENT ON TABLE security_indicator_series IS
'Привязка серий индикатора к бумаге: invoke_formula — calc_ind_*_array(…) или многочленная формула (pp * (1;-2;1), @SMA, …)';

-- Пример: SBER + STOCH, серии %K и %D с параметрами по умолчанию
INSERT INTO security_indicator_series (
    security_id, indicator_id, series_code, invoke_formula,
    param_k_period, param_d_period, param_smooth, point_count, display_order
)
SELECT s.id, i.id, v.series_code, v.formula, 14, 3, 3, 100, v.ord
FROM securities s
JOIN security_prefixes sp ON sp.security_id = s.id AND sp.prefix = 'SBER'
JOIN indicators i ON i.code = 'STOCH'
CROSS JOIN (
    VALUES
        ('K', 'calc_ind_stoch_array(:param_k_period, :param_d_period, :param_smooth, :series, :security_id, :timeframe_id, :point_count, :end_dt)', 1),
        ('D', 'calc_ind_stoch_array(:param_k_period, :param_d_period, :param_smooth, :series, :security_id, :timeframe_id, :point_count, :end_dt)', 2)
) AS v(series_code, formula, ord)
ON CONFLICT (security_id, indicator_id, series_code) DO NOTHING;

-- Пример: SBER + PACC (ускорение цены), многочленная формула по умолчанию
INSERT INTO security_indicator_series (
    security_id, indicator_id, series_code, invoke_formula,
    point_count, display_order
)
SELECT s.id, i.id, 'VALUE', 'pp * (1; -2; 1)', 100, 3
FROM securities s
JOIN security_prefixes sp ON sp.security_id = s.id AND sp.prefix = 'SBER'
JOIN indicators i ON i.code = 'PACC'
ON CONFLICT (security_id, indicator_id, series_code) DO NOTHING;

-- ============================================
-- Таблица: indicator_values (рассчитанные значения)
-- ============================================
CREATE TABLE IF NOT EXISTS indicator_values (
    id BIGSERIAL PRIMARY KEY,
    indicator_id INTEGER NOT NULL REFERENCES indicators(id) ON DELETE CASCADE,
    indicator_value_type_id INTEGER NOT NULL REFERENCES indicator_value_types(id) ON DELETE CASCADE,
    security_id INTEGER NOT NULL REFERENCES securities(id) ON DELETE CASCADE,
    timeframe_id INTEGER NOT NULL REFERENCES timeframes(id) ON DELETE CASCADE,
    dt TIMESTAMP NOT NULL,
    value NUMERIC(18, 6),
    is_signal BOOLEAN NOT NULL DEFAULT FALSE,
    signal_type VARCHAR(20),
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_indicator_values_indicator_id ON indicator_values(indicator_id);
CREATE INDEX IF NOT EXISTS idx_indicator_values_security_id ON indicator_values(security_id);
CREATE INDEX IF NOT EXISTS idx_indicator_values_timeframe_id ON indicator_values(timeframe_id);
CREATE INDEX IF NOT EXISTS idx_indicator_values_dt ON indicator_values(dt);
CREATE UNIQUE INDEX IF NOT EXISTS idx_indicator_values_unique
    ON indicator_values(indicator_id, indicator_value_type_id, security_id, timeframe_id, dt);

-- ============================================
-- Таблицы торговой логики (заготовка)
-- logics — основная сущность: одна строка = одна торговля (трейд)
-- ============================================
CREATE TABLE IF NOT EXISTS logics (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL UNIQUE,
    account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE RESTRICT,
    is_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    position_size_pct NUMERIC(8, 4) NOT NULL DEFAULT 10,
    max_open_positions INTEGER NOT NULL DEFAULT 5,
    initial_balance NUMERIC(18, 2),
    current_balance NUMERIC(18, 2)
);

-- Блок миграции: обновление существующей схемы v17 → v18 (для БД без новых колонок)
ALTER TABLE logics ADD COLUMN IF NOT EXISTS position_size_pct NUMERIC(8, 4) NOT NULL DEFAULT 10;
ALTER TABLE logics ADD COLUMN IF NOT EXISTS max_open_positions INTEGER NOT NULL DEFAULT 5;
ALTER TABLE logics ADD COLUMN IF NOT EXISTS initial_balance NUMERIC(18, 2);
ALTER TABLE logics ADD COLUMN IF NOT EXISTS current_balance NUMERIC(18, 2);

DO $$
BEGIN
    ALTER TABLE logics ADD CONSTRAINT chk_logics_position_size_pct
        CHECK (position_size_pct > 0 AND position_size_pct <= 100);
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
    ALTER TABLE logics ADD CONSTRAINT chk_logics_max_open_positions
        CHECK (max_open_positions > 0);
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

COMMENT ON COLUMN logics.position_size_pct IS '% депозита на одну сделку (от current_balance логики)';
COMMENT ON COLUMN logics.max_open_positions IS 'Макс. число одновременно открытых long-позиций по бумагам';
COMMENT ON COLUMN logics.initial_balance IS 'Начальный остаток (фейковый счёт / эталон депозита для расчёта лота)';
COMMENT ON COLUMN logics.current_balance IS 'Текущий остаток после сделок (обновляет trade runner)';

CREATE INDEX IF NOT EXISTS idx_logics_account_id ON logics(account_id);

COMMENT ON TABLE logics IS 'Торговые логики: одна строка — одна торговля (трейд); главная таблица, от которой смотрятся связанные данные';
COMMENT ON COLUMN logics.name IS 'Уникальное имя логики';
COMMENT ON COLUMN logics.account_id IS 'Счёт (accounts), на котором выполняется эта торговля';
COMMENT ON COLUMN logics.is_enabled IS 'Логика включена (активна) или выключена';

-- Пример: цена выше SMA — long, ниже SMA — short (фейковый счёт T-Bank)
INSERT INTO logics (
    name, account_id, is_enabled,
    position_size_pct, max_open_positions, initial_balance, current_balance
)
SELECT
    'SMA Price Cross Demo',
    a.id,
    FALSE,
    10,
    3,
    1000000,
    1000000
FROM accounts a
JOIN brokers b ON b.id = a.broker_id
WHERE b.code = 'T-BANK' AND a.account_code = 'FAKE-EFF-001'
ON CONFLICT (name) DO UPDATE SET
    position_size_pct = EXCLUDED.position_size_pct,
    max_open_positions = EXCLUDED.max_open_positions,
    initial_balance = EXCLUDED.initial_balance,
    current_balance = COALESCE(logics.current_balance, EXCLUDED.current_balance);

-- ============================================
-- Параметры торговой логики (EAV: logic_param_defs + logic_params)
-- ============================================
CREATE TABLE IF NOT EXISTS logic_param_defs (
    param_key VARCHAR(64) PRIMARY KEY,
    name_ru VARCHAR(200) NOT NULL,
    value_type VARCHAR(20) NOT NULL CHECK (value_type IN ('number', 'integer', 'money', 'boolean', 'text')),
    default_value TEXT NOT NULL DEFAULT '',
    description TEXT,
    display_order INTEGER NOT NULL DEFAULT 0
);

INSERT INTO logic_param_defs (param_key, name_ru, value_type, default_value, description, display_order) VALUES
    ('timeframe', 'Таймфрейм', 'text', 'M15',
     'Таймфрейм цен, индикаторов и цикла сделок (M15, H1, D1 …)', 0),
    ('position_size_pct', '% депозита на сделку', 'number', '10',
     'Доля текущего остатка на одну покупку (1–100)', 1),
    ('max_open_positions', 'Макс. открытых позиций', 'integer', '5',
     'Long/Short позиции по разным бумагам одновременно', 2),
    ('initial_balance', 'Начальный остаток', 'money', '',
     'Стартовый депозит бумажной торговли / эталон для расчёта лота', 3),
    ('current_balance', 'Текущий остаток', 'money', '',
     'Обновляется trade runner после симулированных сделок', 4),
    ('commission_pct', '% комиссии от депозита', 'number', '0.05',
     'Фейковый счёт: комиссия = текущий депозит × % / 100 (на каждую сделку)', 5),
    ('cost_method', 'Метод расчёта PnL', 'text', 'FIFO',
     'FIFO — по очереди покупок; AVERAGE — по средней цене остатка', 6),
    ('stop_loss_timeframe', 'Таймфрейм стоп-лосса', 'text', 'M5',
     'TF для проверки стоп-лоссов (по умолчанию M5)', 7),
    ('last_stop_bar_dt', 'Последняя свеча стоп-лосса', 'text', '',
     'Служебный: open time закрытой свечи TF стоп-лосса', 97),
    ('last_trade_check_at', 'Последняя проверка сигналов', 'text', '',
     'Служебный: время последнего run_trade_cycle (не редактировать)', 98),
    ('last_trade_bar_dt', 'Последняя обработанная свеча', 'text', '',
     'Служебный: open time закрытой свечи TF (не редактировать)', 99)
ON CONFLICT (param_key) DO UPDATE SET
    name_ru = EXCLUDED.name_ru,
    value_type = EXCLUDED.value_type,
    description = EXCLUDED.description,
    display_order = EXCLUDED.display_order;

CREATE TABLE IF NOT EXISTS logic_params (
    id SERIAL PRIMARY KEY,
    logic_id INTEGER NOT NULL REFERENCES logics(id) ON DELETE CASCADE,
    param_key VARCHAR(64) NOT NULL REFERENCES logic_param_defs(param_key) ON DELETE RESTRICT,
    param_value TEXT NOT NULL DEFAULT '',
    value_type VARCHAR(20) NOT NULL CHECK (value_type IN ('number', 'integer', 'money', 'boolean', 'text')),
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (logic_id, param_key)
);

CREATE INDEX IF NOT EXISTS idx_logic_params_logic_id ON logic_params(logic_id);

COMMENT ON TABLE logic_param_defs IS 'Справочник ключей параметров торговой логики';
COMMENT ON TABLE logic_params IS 'Значения параметров logics: одна строка = один параметр одной логики';
COMMENT ON COLUMN logic_params.param_key IS 'Имя параметра (ссылка на logic_param_defs)';
COMMENT ON COLUMN logic_params.param_value IS 'Значение в текстовом виде';
COMMENT ON COLUMN logic_params.value_type IS 'Тип значения: number | integer | money | boolean | text';

-- Миграция v18/v19 → v20: перенос из колонок logics в logic_params
INSERT INTO logic_params (logic_id, param_key, param_value, value_type)
SELECT l.id, 'position_size_pct', l.position_size_pct::text, 'number'
FROM logics l
WHERE l.position_size_pct IS NOT NULL
ON CONFLICT (logic_id, param_key) DO UPDATE SET
    param_value = EXCLUDED.param_value,
    updated_at = CURRENT_TIMESTAMP;

INSERT INTO logic_params (logic_id, param_key, param_value, value_type)
SELECT l.id, 'max_open_positions', l.max_open_positions::text, 'integer'
FROM logics l
WHERE l.max_open_positions IS NOT NULL
ON CONFLICT (logic_id, param_key) DO UPDATE SET
    param_value = EXCLUDED.param_value,
    updated_at = CURRENT_TIMESTAMP;

INSERT INTO logic_params (logic_id, param_key, param_value, value_type)
SELECT l.id, 'initial_balance', l.initial_balance::text, 'money'
FROM logics l
WHERE l.initial_balance IS NOT NULL
ON CONFLICT (logic_id, param_key) DO UPDATE SET
    param_value = EXCLUDED.param_value,
    updated_at = CURRENT_TIMESTAMP;

INSERT INTO logic_params (logic_id, param_key, param_value, value_type)
SELECT l.id, 'current_balance', l.current_balance::text, 'money'
FROM logics l
WHERE l.current_balance IS NOT NULL
ON CONFLICT (logic_id, param_key) DO UPDATE SET
    param_value = EXCLUDED.param_value,
    updated_at = CURRENT_TIMESTAMP;

-- Дефолты для всех логик без строк в logic_params
INSERT INTO logic_params (logic_id, param_key, param_value, value_type)
SELECT l.id, d.param_key, d.default_value, d.value_type
FROM logics l
CROSS JOIN logic_param_defs d
ON CONFLICT (logic_id, param_key) DO NOTHING;

-- Демо SMA: параметры в logic_params
INSERT INTO logic_params (logic_id, param_key, param_value, value_type)
SELECT l.id, v.param_key, v.param_value, v.value_type
FROM logics l
CROSS JOIN (VALUES
    ('timeframe', 'M15', 'text'),
    ('position_size_pct', '10', 'number'),
    ('max_open_positions', '3', 'integer'),
    ('initial_balance', '1000000', 'money'),
    ('current_balance', '1000000', 'money'),
    ('commission_pct', '0.05', 'number'),
    ('cost_method', 'FIFO', 'text'),
    ('stop_loss_timeframe', 'M5', 'text')
) AS v(param_key, param_value, value_type)
WHERE l.name = 'SMA Price Cross Demo'
ON CONFLICT (logic_id, param_key) DO UPDATE SET
    param_value = EXCLUDED.param_value,
    updated_at = CURRENT_TIMESTAMP;

CREATE TABLE IF NOT EXISTS sides (
    id SERIAL PRIMARY KEY,
    name VARCHAR(20) NOT NULL UNIQUE
);

INSERT INTO sides (name) VALUES ('Open'), ('Close') ON CONFLICT (name) DO NOTHING;

CREATE TABLE IF NOT EXISTS actions (
    id SERIAL PRIMARY KEY,
    name VARCHAR(20) NOT NULL UNIQUE
);

INSERT INTO actions (name) VALUES ('Long'), ('Short') ON CONFLICT (name) DO NOTHING;

CREATE TABLE IF NOT EXISTS logics_detail (
    id SERIAL PRIMARY KEY,
    logic_name VARCHAR(100) NOT NULL REFERENCES logics(name),
    formula TEXT NOT NULL,
    side_id INTEGER NOT NULL REFERENCES sides(id),
    action_id INTEGER NOT NULL REFERENCES actions(id)
);

-- Сигналы индикаторов, привязанные к торговой логике
CREATE TABLE IF NOT EXISTS logic_indicator_signals (
    id SERIAL PRIMARY KEY,
    logic_id INTEGER NOT NULL REFERENCES logics(id) ON DELETE CASCADE,
    indicator_id INTEGER NOT NULL REFERENCES indicators(id) ON DELETE RESTRICT,
    position_side VARCHAR(10) NOT NULL DEFAULT 'long' CHECK (position_side IN ('long', 'short')),
    signal_kind VARCHAR(10) NOT NULL CHECK (signal_kind IN ('trend', 'counter')),
    formula TEXT NOT NULL,
    display_order INTEGER NOT NULL DEFAULT 0,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (logic_id, indicator_id, position_side, signal_kind)
);

-- Миграция v18 → v19: position_side (long | short)
ALTER TABLE logic_indicator_signals ADD COLUMN IF NOT EXISTS position_side VARCHAR(10) NOT NULL DEFAULT 'long';

DO $$
BEGIN
    ALTER TABLE logic_indicator_signals ADD CONSTRAINT logic_indicator_signals_position_side_check
        CHECK (position_side IN ('long', 'short'));
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

UPDATE logic_indicator_signals SET position_side = 'long' WHERE position_side IS NULL OR position_side = '';

ALTER TABLE logic_indicator_signals DROP CONSTRAINT IF EXISTS logic_indicator_signals_logic_id_indicator_id_signal_kind_key;

DROP INDEX IF EXISTS logic_indicator_signals_logic_id_indicator_id_signal_kind_key;

CREATE UNIQUE INDEX IF NOT EXISTS idx_logic_indicator_signals_unique
    ON logic_indicator_signals (logic_id, indicator_id, position_side, signal_kind);

CREATE INDEX IF NOT EXISTS idx_logic_indicator_signals_logic_id
    ON logic_indicator_signals(logic_id);
CREATE INDEX IF NOT EXISTS idx_logic_indicator_signals_indicator_id
    ON logic_indicator_signals(indicator_id);

COMMENT ON TABLE logic_indicator_signals IS
'Сигналы индикаторов для logics: формула @CODE(params) + условие из indicators.sig_*_def';
COMMENT ON COLUMN logic_indicator_signals.position_side IS 'long | short — сторона позиции сигнала';
COMMENT ON COLUMN logic_indicator_signals.signal_kind IS 'trend | counter';
COMMENT ON COLUMN logic_indicator_signals.formula IS
'Редактируемая формула: @RSI(period=14,series=VALUE) VALUE > 50';

-- Стоп-лосс и тейк-профит по торговой логике
CREATE TABLE IF NOT EXISTS logic_stops (
    id SERIAL PRIMARY KEY,
    logic_id INTEGER NOT NULL REFERENCES logics(id) ON DELETE CASCADE,
    rule_kind VARCHAR(20) NOT NULL CHECK (rule_kind IN ('stop_loss', 'take_profit')),
    scope_type VARCHAR(20) NOT NULL CHECK (scope_type IN ('security', 'security_resume', 'portfolio')),
    value NUMERIC(18, 6) NOT NULL CHECK (value > 0),
    value_unit VARCHAR(10) NOT NULL CHECK (value_unit IN ('percent', 'atr')),
    display_order INTEGER NOT NULL DEFAULT 0,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_logic_stops_logic_id ON logic_stops(logic_id);
CREATE INDEX IF NOT EXISTS idx_logic_stops_rule_kind ON logic_stops(logic_id, rule_kind);

COMMENT ON TABLE logic_stops IS
'Стоп-лосс и тейк-профит для logics: security (по бумаге) или portfolio (портфель логики)';
COMMENT ON COLUMN logic_stops.rule_kind IS 'stop_loss | take_profit';
COMMENT ON COLUMN logic_stops.scope_type IS
'stop_loss: security | security_resume | portfolio; take_profit: security | portfolio';

UPDATE logic_stops
SET scope_type = 'security'
WHERE rule_kind = 'take_profit' AND scope_type = 'security_resume';

DO $$
BEGIN
    ALTER TABLE logic_stops DROP CONSTRAINT IF EXISTS logic_stops_tp_scope_check;
    ALTER TABLE logic_stops ADD CONSTRAINT logic_stops_tp_scope_check
        CHECK (rule_kind = 'stop_loss' OR scope_type IN ('security', 'portfolio'));
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;
COMMENT ON COLUMN logic_stops.value_unit IS 'percent | atr';

-- Ценные бумаги, привязанные к торговой логике (портфель логики)
CREATE TABLE IF NOT EXISTS logic_securities (
    id SERIAL PRIMARY KEY,
    logic_id INTEGER NOT NULL REFERENCES logics(id) ON DELETE CASCADE,
    security_id INTEGER NOT NULL REFERENCES securities(id) ON DELETE RESTRICT,
    display_order INTEGER NOT NULL DEFAULT 0,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    real_trading_paused BOOLEAN NOT NULL DEFAULT FALSE,
    stop_resume_equity NUMERIC(20, 6),
    stop_resume_baseline NUMERIC(20, 6),
    stop_resume_triggered_at TIMESTAMP,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (logic_id, security_id)
);

CREATE INDEX IF NOT EXISTS idx_logic_securities_logic_id ON logic_securities(logic_id);
CREATE INDEX IF NOT EXISTS idx_logic_securities_security_id ON logic_securities(security_id);

COMMENT ON TABLE logic_securities IS
'Портфель ценных бумаг торговой логики: одна строка — одна бумага в logics';
COMMENT ON COLUMN logic_securities.display_order IS 'Порядок отображения в UI';
COMMENT ON COLUMN logic_securities.real_trading_paused IS
'TRUE — реальная торговля по бумаге приостановлена (теневой режим после security_resume SL)';
COMMENT ON COLUMN logic_securities.stop_resume_equity IS
'Целевая стоимость трека бумаги для возобновления реальной торговли';
COMMENT ON COLUMN logic_securities.stop_resume_baseline IS
'Стоимость трека сразу после срабатывания SL (база для теневого восстановления)';

ALTER TABLE logic_securities ADD COLUMN IF NOT EXISTS real_trading_paused BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE logic_securities ADD COLUMN IF NOT EXISTS stop_resume_equity NUMERIC(20, 6);
ALTER TABLE logic_securities ADD COLUMN IF NOT EXISTS stop_resume_baseline NUMERIC(20, 6);
ALTER TABLE logic_securities ADD COLUMN IF NOT EXISTS stop_resume_triggered_at TIMESTAMP;

-- Демо-логика SMA Price Cross Demo: только long-trend и short-trend + SBER
DELETE FROM logic_indicator_signals lis
USING logics l
WHERE lis.logic_id = l.id
  AND l.name = 'SMA Price Cross Demo'
  AND lis.signal_kind = 'counter';

INSERT INTO logic_indicator_signals (logic_id, indicator_id, position_side, signal_kind, formula, display_order)
SELECT l.id, i.id, 'long', 'trend', '@SMA(period=20,series=VALUE) pp > VALUE', 0
FROM logics l
CROSS JOIN indicators i
WHERE l.name = 'SMA Price Cross Demo' AND i.code = 'SMA'
ON CONFLICT (logic_id, indicator_id, position_side, signal_kind) DO UPDATE SET
    formula = EXCLUDED.formula,
    is_active = TRUE;

INSERT INTO logic_indicator_signals (logic_id, indicator_id, position_side, signal_kind, formula, display_order)
SELECT l.id, i.id, 'short', 'trend', '@SMA(period=20,series=VALUE) pp < VALUE', 1
FROM logics l
CROSS JOIN indicators i
WHERE l.name = 'SMA Price Cross Demo' AND i.code = 'SMA'
ON CONFLICT (logic_id, indicator_id, position_side, signal_kind) DO UPDATE SET
    formula = EXCLUDED.formula,
    is_active = TRUE;

INSERT INTO logic_securities (logic_id, security_id, display_order)
SELECT l.id, s.id, 0
FROM logics l
JOIN securities s ON s.name = 'Сбербанк (обыкновенные)'
WHERE l.name = 'SMA Price Cross Demo'
ON CONFLICT (logic_id, security_id) DO UPDATE SET is_active = TRUE;

-- Сделки по торговой логике (исполнение по сигналам индикаторов)
CREATE TABLE IF NOT EXISTS logic_trades (
    id BIGSERIAL PRIMARY KEY,
    logic_id INTEGER NOT NULL REFERENCES logics(id) ON DELETE RESTRICT,
    account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE RESTRICT,
    security_id INTEGER NOT NULL REFERENCES securities(id) ON DELETE RESTRICT,
    timeframe_id INTEGER NOT NULL REFERENCES timeframes(id) ON DELETE RESTRICT,
    side_id INTEGER NOT NULL REFERENCES sides(id) ON DELETE RESTRICT,
    action_id INTEGER NOT NULL REFERENCES actions(id) ON DELETE RESTRICT,
    signal_kind VARCHAR(10) NOT NULL CHECK (signal_kind IN ('trend', 'counter')),
    signal_formula TEXT NOT NULL,
    quantity NUMERIC(20, 6) NOT NULL DEFAULT 1 CHECK (quantity > 0),
    price NUMERIC(18, 6) NOT NULL CHECK (price > 0),
    bar_dt TIMESTAMP NOT NULL,
    executed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    is_simulated BOOLEAN NOT NULL DEFAULT FALSE,
    is_fictitious BOOLEAN NOT NULL DEFAULT FALSE,
    is_shadow BOOLEAN NOT NULL DEFAULT FALSE,
    is_test BOOLEAN NOT NULL DEFAULT FALSE,
    broker_order_id VARCHAR(100),
    status VARCHAR(20) NOT NULL DEFAULT 'filled'
        CHECK (status IN ('pending', 'submitted', 'filled', 'rejected', 'cancelled')),
    commission NUMERIC(18, 6) NOT NULL DEFAULT 0,
    financial_result NUMERIC(20, 6),
    note TEXT,
    trade_reason TEXT,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_logic_trades_logic_id ON logic_trades(logic_id);
CREATE INDEX IF NOT EXISTS idx_logic_trades_executed_at ON logic_trades(executed_at DESC);
CREATE INDEX IF NOT EXISTS idx_logic_trades_security_id ON logic_trades(security_id);

ALTER TABLE logic_trades ADD COLUMN IF NOT EXISTS commission NUMERIC(18, 6) NOT NULL DEFAULT 0;
ALTER TABLE logic_trades ADD COLUMN IF NOT EXISTS financial_result NUMERIC(20, 6);
ALTER TABLE logic_trades ADD COLUMN IF NOT EXISTS is_shadow BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE logic_trades ADD COLUMN IF NOT EXISTS is_test BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE logic_trades ADD COLUMN IF NOT EXISTS trade_reason TEXT;

ALTER TABLE logic_trades DROP CONSTRAINT IF EXISTS logic_trades_logic_id_security_id_signal_kind_bar_dt_key;
DROP INDEX IF EXISTS logic_trades_logic_id_security_id_signal_kind_bar_dt_key;
CREATE UNIQUE INDEX IF NOT EXISTS idx_logic_trades_signal_bar_book
    ON logic_trades (logic_id, security_id, signal_kind, bar_dt, is_test, is_shadow);

CREATE INDEX IF NOT EXISTS idx_logic_trades_test ON logic_trades(logic_id) WHERE is_test;

COMMENT ON TABLE logic_trades IS
'Сделки logics: исполнение по logic_indicator_signals; is_simulated — фейковый счёт; is_fictitious — резерв';
COMMENT ON COLUMN logic_trades.is_simulated IS 'TRUE — сделка на фейковом счёте (бумажная торговля)';
COMMENT ON COLUMN logic_trades.is_fictitious IS 'Фиктивная сделка (резерв, заполнение позже)';
COMMENT ON COLUMN logic_trades.is_shadow IS
'Теневая сделка: не влияет на реальный депозит; режим возобновления после стоп-лосса по бумаге';
COMMENT ON COLUMN logic_trades.is_test IS
'TRUE — сделка исторического тестирования (отдельная книга, не смешивается с боевыми и live-теневыми)';
COMMENT ON COLUMN logic_trades.trade_reason IS
'Причина сделки: сигнал индикатора, stop_loss/take_profit (тип), market:close_all и т.п.';
COMMENT ON COLUMN logic_trades.bar_dt IS 'Свеча, на которой сработал сигнал';
COMMENT ON COLUMN logic_trades.commission IS 'Комиссия по сделке (фейк: % от депозита; реал: с биржи)';
COMMENT ON COLUMN logic_trades.financial_result IS 'Итог PnL закрывающей сделки (сумма пакетов); NULL для открытия';

CREATE TABLE IF NOT EXISTS logic_backtest_runs (
    id BIGSERIAL PRIMARY KEY,
    logic_id INTEGER NOT NULL REFERENCES logics(id) ON DELETE CASCADE,
    date_from DATE NOT NULL,
    date_to DATE NOT NULL,
    status VARCHAR(30) NOT NULL DEFAULT 'pending'
        CHECK (status IN (
            'pending', 'loading_prices', 'loading_indicators', 'running',
            'completed', 'cancelled', 'failed'
        )),
    progress_pct NUMERIC(5, 2) NOT NULL DEFAULT 0,
    phase_message TEXT,
    phase_detail TEXT,
    current_bar_dt TIMESTAMP,
    total_bars INTEGER NOT NULL DEFAULT 0,
    processed_bars INTEGER NOT NULL DEFAULT 0,
    trades_created INTEGER NOT NULL DEFAULT 0,
    test_balance NUMERIC(20, 6),
    financial_result NUMERIC(20, 6),
    cancel_requested BOOLEAN NOT NULL DEFAULT FALSE,
    error_message TEXT,
    started_at TIMESTAMP,
    finished_at TIMESTAMP,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_logic_backtest_runs_logic ON logic_backtest_runs(logic_id, created_at DESC);

COMMENT ON TABLE logic_backtest_runs IS
'Историческое тестирование: прогресс, период, итог (сделки is_test=TRUE)';

CREATE TABLE IF NOT EXISTS logic_backtest_security_state (
    run_id BIGINT NOT NULL REFERENCES logic_backtest_runs(id) ON DELETE CASCADE,
    security_id INTEGER NOT NULL REFERENCES securities(id) ON DELETE CASCADE,
    real_trading_paused BOOLEAN NOT NULL DEFAULT FALSE,
    stop_resume_equity NUMERIC(20, 6),
    stop_resume_baseline NUMERIC(20, 6),
    PRIMARY KEY (run_id, security_id)
);

COMMENT ON TABLE logic_backtest_security_state IS
'Пауза security_resume внутри backtest (не меняет live logic_securities)';

-- Пакеты закрытия (FIFO / средняя): связь продажи с покупками
CREATE TABLE IF NOT EXISTS logic_trade_lots (
    id BIGSERIAL PRIMARY KEY,
    logic_id INTEGER NOT NULL REFERENCES logics(id) ON DELETE CASCADE,
    close_trade_id BIGINT NOT NULL REFERENCES logic_trades(id) ON DELETE CASCADE,
    open_trade_id BIGINT REFERENCES logic_trades(id) ON DELETE SET NULL,
    action_id INTEGER NOT NULL REFERENCES actions(id) ON DELETE RESTRICT,
    cost_method VARCHAR(10) NOT NULL DEFAULT 'FIFO'
        CHECK (cost_method IN ('FIFO', 'AVERAGE')),
    quantity NUMERIC(20, 6) NOT NULL CHECK (quantity > 0),
    close_amount NUMERIC(20, 6) NOT NULL,
    open_amount NUMERIC(20, 6) NOT NULL,
    close_commission NUMERIC(18, 6) NOT NULL DEFAULT 0,
    open_commission NUMERIC(18, 6) NOT NULL DEFAULT 0,
    financial_result NUMERIC(20, 6) NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_logic_trade_lots_close ON logic_trade_lots(close_trade_id);
CREATE INDEX IF NOT EXISTS idx_logic_trade_lots_open ON logic_trade_lots(open_trade_id);
CREATE INDEX IF NOT EXISTS idx_logic_trade_lots_logic ON logic_trade_lots(logic_id);

COMMENT ON TABLE logic_trade_lots IS
'Пакеты по сделкам: закрытие → открытие; PnL = доход − расход − комиссии';
COMMENT ON COLUMN logic_trade_lots.open_trade_id IS 'NULL при методе AVERAGE (средняя цена)';

-- ============================================
-- Таблица: futures_expirations (контракты фьючерсов)
-- ============================================
CREATE TABLE IF NOT EXISTS futures_expirations (
    id SERIAL PRIMARY KEY,
    security_id INTEGER NOT NULL REFERENCES securities(id) ON DELETE CASCADE,
    prefix VARCHAR(50) NOT NULL,
    moex_secid VARCHAR(20),
    expiration_date DATE NOT NULL,
    tbank_figi VARCHAR(50),
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_futures_exp_security_id ON futures_expirations(security_id);
CREATE INDEX IF NOT EXISTS idx_futures_exp_prefix ON futures_expirations(prefix);
CREATE INDEX IF NOT EXISTS idx_futures_exp_date ON futures_expirations(expiration_date);
CREATE UNIQUE INDEX IF NOT EXISTS idx_futures_exp_security_prefix ON futures_expirations(security_id, prefix);

ALTER TABLE futures_expirations ADD COLUMN IF NOT EXISTS moex_secid VARCHAR(20);

COMMENT ON TABLE futures_expirations IS 'Контракты фьючерсов; prefix — SHORTNAME MOEX (CNY-9.26), moex_secid — SECID (CRU6) для T-Bank/MOEX. Sync из MOEX ISS.';

-- Ручной INSERT контрактов не нужен — sync_futures_expirations_from_moex подтягивает список с MOEX.
-- ============================================
-- Таблица: price_load_log (лог загрузки цен)
-- ============================================
CREATE TABLE IF NOT EXISTS price_load_log (
    id BIGSERIAL PRIMARY KEY,
    security_id INTEGER NOT NULL REFERENCES securities(id),
    timeframe_id INTEGER NOT NULL REFERENCES timeframes(id),
    date_from DATE NOT NULL,
    date_to DATE NOT NULL,
    source VARCHAR(20) NOT NULL,
    records_loaded INTEGER DEFAULT 0,
    contract_prefix VARCHAR(50),
    error_message TEXT,
    loaded_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

ALTER TABLE price_load_log ADD COLUMN IF NOT EXISTS contract_prefix VARCHAR(50);

CREATE INDEX IF NOT EXISTS idx_price_load_log_security ON price_load_log(security_id, timeframe_id);
CREATE INDEX IF NOT EXISTS idx_price_load_log_loaded_at ON price_load_log(loaded_at);

-- ============================================
-- Таблица: app_tech_log (технический журнал UI/API)
-- ============================================
CREATE TABLE IF NOT EXISTS app_tech_log (
    id BIGSERIAL PRIMARY KEY,
    trace_id UUID NOT NULL DEFAULT gen_random_uuid(),
    span_id VARCHAR(64) NOT NULL,
    parent_span_id VARCHAR(64),
    thread_key VARCHAR(128) NOT NULL,
    source VARCHAR(32) NOT NULL DEFAULT 'web',
    operation VARCHAR(128) NOT NULL,
    phase VARCHAR(16) NOT NULL CHECK (phase IN ('start', 'end', 'event')),
    started_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    finished_at TIMESTAMPTZ,
    duration_ms INTEGER,
    security_id INTEGER REFERENCES securities(id) ON DELETE SET NULL,
    timeframe_id INTEGER REFERENCES timeframes(id) ON DELETE SET NULL,
    logic_id INTEGER REFERENCES logics(id) ON DELETE SET NULL,
    sync_gen INTEGER,
    message TEXT,
    payload JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

ALTER TABLE app_tech_log ADD COLUMN IF NOT EXISTS logic_id INTEGER REFERENCES logics(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_app_tech_log_created_at ON app_tech_log(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_app_tech_log_trace_id ON app_tech_log(trace_id);
CREATE INDEX IF NOT EXISTS idx_app_tech_log_thread_key ON app_tech_log(thread_key);
CREATE INDEX IF NOT EXISTS idx_app_tech_log_security ON app_tech_log(security_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_app_tech_log_logic_id ON app_tech_log(logic_id, created_at DESC);

COMMENT ON TABLE app_tech_log IS
'Технический журнал проекта: sync графика, trade runner, сигналы, параметры логики (если APP_TECH_LOGGING=1)';
COMMENT ON COLUMN app_tech_log.trace_id IS 'Цепочка одного жеста пользователя (pan/zoom)';
COMMENT ON COLUMN app_tech_log.thread_key IS 'Поток: sec:29:gen:3, logic:1:trade, trade-runner и т.п.';
COMMENT ON COLUMN app_tech_log.logic_id IS 'Торговая логика (trade runner, параметры, enable/disable)';
COMMENT ON COLUMN app_tech_log.phase IS 'start | end | event';

-- ============================================
-- Дополнительные индексы
-- ============================================
CREATE INDEX IF NOT EXISTS idx_security_types_name ON security_types(name);
CREATE INDEX IF NOT EXISTS idx_exchanges_name ON exchanges(name);
CREATE INDEX IF NOT EXISTS idx_securities_type_id ON securities(security_type_id);
CREATE INDEX IF NOT EXISTS idx_security_prefixes_security_id ON security_prefixes(security_id);
CREATE INDEX IF NOT EXISTS idx_timeframes_tf ON timeframes(tf);
CREATE INDEX IF NOT EXISTS idx_brokers_code ON brokers(code);
CREATE INDEX IF NOT EXISTS idx_indicators_code ON indicators(code);

-- ============================================
-- Готово: шаг 1 завершён
-- ============================================
