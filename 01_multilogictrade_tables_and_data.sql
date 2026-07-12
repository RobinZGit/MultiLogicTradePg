-- ============================================
-- MultiLogicTrade — шаг 1: таблицы и справочники
-- Версия: v12 (идемпотентный запуск)
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
    ('АФК Система', 'AFKS', 'stock', 'BBG004S686B0', NULL),
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
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_prices_security_id ON prices(security_id);
CREATE INDEX IF NOT EXISTS idx_prices_timeframe_id ON prices(timeframe_id);
CREATE INDEX IF NOT EXISTS idx_prices_dt ON prices(dt);
CREATE INDEX IF NOT EXISTS idx_prices_security_timeframe ON prices(security_id, timeframe_id);
CREATE INDEX IF NOT EXISTS idx_prices_security_timeframe_dt ON prices(security_id, timeframe_id, dt);
CREATE UNIQUE INDEX IF NOT EXISTS idx_prices_unique_candle ON prices(security_id, timeframe_id, dt);

COMMENT ON TABLE prices IS 'Таблица цен (OHLCV)';

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
    ('STOCH период K', 'STOCH_PERIOD', 'integer', 'Период %K стохастика', '14', 2, 100)
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
    -- Подробное описание: полное название, расчёт, сигналы, применение (многострочный TEXT).
    description TEXT,
    category VARCHAR(50),
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON COLUMN indicators.script IS
'Шаблон SQL для динамического расчёта: SELECT calc_ind_*(…). Плейсхолдеры подставляются при EXECUTE.';

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
    ('ZLEMA', 'Zero Lag EMA', 'EMA с нулевым запаздыванием', 'trend')
ON CONFLICT (code) DO NOTHING;

-- Шаблоны расчёта (функция + параметры; :series подставляется для каждой линии индикатора)
UPDATE indicators SET script = 'SELECT calc_ind_rsi(:period, :series, :security_id, :timeframe_id, :dt, :indicator_id)' WHERE code = 'RSI';
UPDATE indicators SET script = 'SELECT calc_ind_sma(:period, :series, :security_id, :timeframe_id, :dt, :indicator_id)' WHERE code = 'SMA';
UPDATE indicators SET script = 'SELECT calc_ind_ema(:period, :series, :security_id, :timeframe_id, :dt, :indicator_id)' WHERE code = 'EMA';
UPDATE indicators SET script = 'SELECT calc_ind_macd(:fast_period, :slow_period, :signal_period, :series, :security_id, :timeframe_id, :dt, :indicator_id)' WHERE code = 'MACD';
UPDATE indicators SET script = 'SELECT calc_ind_bb(:period, :std_dev, :series, :security_id, :timeframe_id, :dt, :indicator_id)' WHERE code = 'BB';
UPDATE indicators SET script = 'SELECT calc_ind_atr(:period, :series, :security_id, :timeframe_id, :dt, :indicator_id)' WHERE code = 'ATR';
UPDATE indicators SET script = 'SELECT calc_ind_stoch(:k_period, :d_period, :smooth, :series, :security_id, :timeframe_id, :dt, :indicator_id)' WHERE code = 'STOCH';

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
    ('SMA', 'VALUE', 'Значение MA', 'float', FALSE, NULL, 'SMA value', 1),
    ('EMA', 'VALUE', 'Значение EMA', 'float', FALSE, NULL, 'EMA value', 1),
    ('WMA', 'VALUE', 'Значение WMA', 'float', FALSE, NULL, 'WMA value', 1)
) AS v(indicator_code, code, name, value_type, is_threshold, threshold_value, description, display_order)
    ON i.code = v.indicator_code
ON CONFLICT (indicator_id, code) DO NOTHING;

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
    is_enabled BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE INDEX IF NOT EXISTS idx_logics_account_id ON logics(account_id);

COMMENT ON TABLE logics IS 'Торговые логики: одна строка — одна торговля (трейд); главная таблица, от которой смотрятся связанные данные';
COMMENT ON COLUMN logics.name IS 'Уникальное имя логики';
COMMENT ON COLUMN logics.account_id IS 'Счёт (accounts), на котором выполняется эта торговля';
COMMENT ON COLUMN logics.is_enabled IS 'Логика включена (активна) или выключена';

-- Пример: одна демо-логика на фейковом счёте T-Bank
INSERT INTO logics (name, account_id)
SELECT 'Demo RSI SBER M5', a.id
FROM accounts a
JOIN brokers b ON b.id = a.broker_id
WHERE b.code = 'T-BANK' AND a.account_code = 'FAKE-EFF-001'
ON CONFLICT (name) DO NOTHING;

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

-- ============================================
-- Таблица: futures_expirations (контракты фьючерсов)
-- ============================================
CREATE TABLE IF NOT EXISTS futures_expirations (
    id SERIAL PRIMARY KEY,
    security_id INTEGER NOT NULL REFERENCES securities(id) ON DELETE CASCADE,
    prefix VARCHAR(50) NOT NULL,
    expiration_date DATE NOT NULL,
    tbank_figi VARCHAR(50),
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_futures_exp_security_id ON futures_expirations(security_id);
CREATE INDEX IF NOT EXISTS idx_futures_exp_prefix ON futures_expirations(prefix);
CREATE INDEX IF NOT EXISTS idx_futures_exp_date ON futures_expirations(expiration_date);
CREATE UNIQUE INDEX IF NOT EXISTS idx_futures_exp_security_prefix ON futures_expirations(security_id, prefix);

COMMENT ON TABLE futures_expirations IS 'Контракты фьючерсов; prefix — полный тикер MOEX (Si-3.26)';

-- Примеры контрактов (обновляйте даты экспирации по мере необходимости)
INSERT INTO futures_expirations (security_id, prefix, expiration_date, is_active)
SELECT s.id, v.prefix, v.expiration_date, TRUE
FROM (VALUES
    ('USD/RUB (доллар/рубль)', 'Si-3.26', DATE '2026-03-19'),
    ('USD/RUB (доллар/рубль)', 'Si-6.26', DATE '2026-06-18'),
    ('USD/RUB (доллар/рубль)', 'Si-9.26', DATE '2026-09-18'),
    ('EUR/RUB (евро/рубль)', 'Eu-3.26', DATE '2026-03-19'),
    ('Сбербанк (фьючерс на акции)', 'SBRF-3.26', DATE '2026-03-19'),
    ('ВТБ (фьючерс на акции)', 'VTBR-3.26', DATE '2026-03-19'),
    ('Газпром (фьючерс на акции)', 'GAZR-3.26', DATE '2026-03-19'),
    ('ЛУКОЙЛ (фьючерс на акции)', 'LKOH-3.26', DATE '2026-03-19'),
    ('Индекс Мосбиржи (IMOEX)', 'MX-3.26', DATE '2026-03-19'),
    ('Индекс РТС', 'RI-3.26', DATE '2026-03-19'),
    ('Нефть Brent', 'BR-4.26', DATE '2026-04-30'),
    ('Золото (USD)', 'GD-4.26', DATE '2026-04-30')
) AS v(security_name, prefix, expiration_date)
JOIN securities s ON s.name = v.security_name
ON CONFLICT (security_id, prefix) DO UPDATE SET
    expiration_date = EXCLUDED.expiration_date,
    is_active = EXCLUDED.is_active;

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
    error_message TEXT,
    loaded_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_price_load_log_security ON price_load_log(security_id, timeframe_id);
CREATE INDEX IF NOT EXISTS idx_price_load_log_loaded_at ON price_load_log(loaded_at);

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
