-- ============================================
-- MultiLogicTrade — шаг 2: функции и процедуры
-- Версия: v12 (идемпотентный запуск)
-- ============================================
-- Подключение: база multilogictrade
-- Предварительно выполните: 00 → 01
-- Можно выполнять многократно (CREATE OR REPLACE).
--
-- ================================================================
-- СТРУКТУРА ФАЙЛА
-- ================================================================
--
-- Часть A (этот файл, начало → строка «HTTP-ЗАГРУЗКА»):
--   parse_tbank_quotation, insert_candle, calculate_indicator,
--   load_prices_from_tbank/moex (заглушки без HTTP) и др.
--   Расширения НЕ требуются.
--
-- Часть B (блок «HTTP-ЗАГРУЗКА» в конце файла):
--   CREATE EXTENSION http;
--   load_prices_from_tbank_http, load_prices_from_moex_http,
--   load_prices_http, load_prices_batch_http, load_all_timeframes_http
--   Требует предварительной установки pgsql-http НА СЕРВЕРЕ PostgreSQL.
--
-- Если pgsql-http ещё не установлен:
--   • выполните только часть A (остановитесь перед CREATE EXTENSION http), ИЛИ
--   • установите расширение (ниже) и запустите весь файл целиком.
--
-- ================================================================
-- УСТАНОВКА pgsql-http — WINDOWS (PostgreSQL 15, один раз на машине)
-- ================================================================
--
-- 1. Скачать готовые бинарники для PG 15 x64:
--      https://www.postgresonline.com/downloads/pg15http_w64.zip
--
-- 2. Распаковать в каталог проекта:
--      _tmp_http_ext\pg15http_w64\
--    (должны появиться lib\http.dll, share\extension\http*, bin\*.dll)
--
-- 3. Скопировать файлы в установку PostgreSQL (нужны права администратора):
--      scripts\install_pgsql_http.ps1
--    Запуск: PowerShell → правой кнопкой → «Запуск от имени администратора»
--
--    Скрипт install_pgsql_http.ps1 выполняет:
--      Copy-Item ...\lib\http.dll          → C:\Program Files\PostgreSQL\15\lib\
--      Copy-Item ...\share\extension\http* → C:\Program Files\PostgreSQL\15\share\extension\
--      Copy-Item ...\bin\*.dll             → C:\Program Files\PostgreSQL\15\bin\
--      Copy-Item ...\ssl\certs\*           → C:\Program Files\PostgreSQL\15\ssl\certs\
--      Restart-Service postgresql-x64-15
--
-- 4. Проверка на диске:
--      Test-Path "C:\Program Files\PostgreSQL\15\lib\http.dll"
--      Test-Path "C:\Program Files\PostgreSQL\15\share\extension\http.control"
--
-- 5. Включить расширение в базе (выполняется ниже в блоке HTTP, или вручную):
--      CREATE EXTENSION IF NOT EXISTS http;
--
-- 6. Проверка в multilogictrade:
--      SELECT extname, extversion FROM pg_extension WHERE extname = 'http';
--      SELECT status FROM http_get('https://httpbin.org/get');
--    При ошибке SSL-сертификата:
--      SELECT http_set_curlopt('CURLOPT_CAINFO',
--        'C:/Program Files/PostgreSQL/15/ssl/certs/curl-ca-bundle.crt');
--
-- 7. Повторно выполнить этот файл (02), если часть B не создалась с первого раза:
--      .\scripts\run_multilogictrade.ps1 -Steps 2
--
-- Linux / macOS: см. комментарии перед блоком «HTTP-ЗАГРУЗКА» (сборка из git).
-- ================================================================
-- ============================================

-- ============================================
-- Вспомогательная функция: parse_tbank_quotation
-- Разбор цены T-Bank: {units, nano} или число
-- ============================================
CREATE OR REPLACE FUNCTION parse_tbank_quotation(p_value JSONB)
RETURNS NUMERIC(18,6) AS $$
DECLARE
    v_units BIGINT;
    v_nano INTEGER;
BEGIN
    IF p_value IS NULL OR p_value = 'null'::JSONB THEN
        RETURN NULL;
    END IF;

    IF jsonb_typeof(p_value) = 'number' THEN
        RETURN p_value::TEXT::NUMERIC(18,6);
    END IF;

    IF jsonb_typeof(p_value) = 'string' THEN
        RETURN (p_value #>> '{}')::NUMERIC(18,6);
    END IF;

    v_units := COALESCE((p_value->>'units')::BIGINT, 0);
    v_nano := COALESCE((p_value->>'nano')::INTEGER, 0);
    RETURN v_units + (v_nano / 1000000000.0);
END;
$$ LANGUAGE plpgsql IMMUTABLE;

COMMENT ON FUNCTION parse_tbank_quotation(JSONB) IS
'Преобразует Quotation T-Bank API (units+nano) или число в NUMERIC';

-- ============================================
-- Вспомогательная функция: get_moex_candle_interval
-- Код интервала для MOEX ISS API
-- ============================================
CREATE OR REPLACE FUNCTION get_moex_candle_interval(p_tf VARCHAR)
RETURNS INTEGER AS $$
BEGIN
    RETURN CASE p_tf
        WHEN 'M1' THEN 1
        WHEN 'M2' THEN 2
        WHEN 'M3' THEN 3
        WHEN 'M5' THEN 5
        WHEN 'M10' THEN 10
        WHEN 'M15' THEN 15
        WHEN 'M20' THEN 20
        WHEN 'M30' THEN 30
        WHEN 'M60' THEN 60
        WHEN 'H1' THEN 60
        WHEN 'H2' THEN 120
        WHEN 'H4' THEN 240
        WHEN 'D1' THEN 24
        WHEN 'W1' THEN 7
        WHEN 'MN1' THEN 31
        ELSE 1
    END;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

COMMENT ON FUNCTION get_moex_candle_interval(VARCHAR) IS
'Возвращает параметр interval для MOEX ISS candles API';

-- ============================================
-- Вспомогательная функция: get_tbank_candle_interval
-- Интервал свечи для T-Bank Invest API
-- ============================================
CREATE OR REPLACE FUNCTION get_tbank_candle_interval(p_tf VARCHAR)
RETURNS TEXT AS $$
BEGIN
    RETURN CASE p_tf
        WHEN 'M1' THEN 'CANDLE_INTERVAL_1_MIN'
        WHEN 'M2' THEN 'CANDLE_INTERVAL_2_MIN'
        WHEN 'M3' THEN 'CANDLE_INTERVAL_3_MIN'
        WHEN 'M5' THEN 'CANDLE_INTERVAL_5_MIN'
        WHEN 'M10' THEN 'CANDLE_INTERVAL_10_MIN'
        WHEN 'M15' THEN 'CANDLE_INTERVAL_15_MIN'
        WHEN 'M30' THEN 'CANDLE_INTERVAL_30_MIN'
        WHEN 'H1' THEN 'CANDLE_INTERVAL_HOUR'
        WHEN 'H2' THEN 'CANDLE_INTERVAL_2_HOUR'
        WHEN 'H4' THEN 'CANDLE_INTERVAL_4_HOUR'
        WHEN 'D1' THEN 'CANDLE_INTERVAL_DAY'
        WHEN 'W1' THEN 'CANDLE_INTERVAL_WEEK'
        WHEN 'MN1' THEN 'CANDLE_INTERVAL_MONTH'
        ELSE 'CANDLE_INTERVAL_DAY'
    END;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

COMMENT ON FUNCTION get_tbank_candle_interval(VARCHAR) IS
'Возвращает CANDLE_INTERVAL_* для T-Bank GetCandles API';

-- ISO-8601 UTC для T-Bank GetCandles (обязателен символ T, иначе HTTP 400)
CREATE OR REPLACE FUNCTION tbank_iso_utc(p_date DATE, p_time TIME DEFAULT TIME '00:00:00')
RETURNS TEXT
LANGUAGE sql
IMMUTABLE AS $$
    SELECT to_char(p_date::timestamp + p_time, 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
$$;

COMMENT ON FUNCTION tbank_iso_utc(DATE, TIME) IS
'Дата/время в формате 2026-07-05T00:00:00Z для T-Bank Invest API';

-- Вечные фьючерсы MOEX (CNYRUBF, USDRUBF …) — без rollover по контрактам
CREATE OR REPLACE FUNCTION is_perpetual_future_group(
    p_group_prefix VARCHAR,
    p_note TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE sql IMMUTABLE AS $$
    SELECT btrim(p_group_prefix) IN ('CNYRUBF', 'USDRUBF', 'GLDRUBF', 'IMOEXF')
        OR coalesce(p_note, '') ILIKE '%вечн%';
$$;

-- Функция: get_active_future_prefix
-- Определяет активный фьючерс на заданную дату
-- ============================================
CREATE OR REPLACE FUNCTION get_active_future_prefix(
    p_security_id INTEGER,
    p_date DATE
)
RETURNS VARCHAR(50) AS $$
DECLARE
    v_group_prefix VARCHAR(50);
    v_note TEXT;
    v_prefix VARCHAR(50);
BEGIN
    SELECT sp.prefix, sp.note INTO v_group_prefix, v_note
    FROM security_prefixes sp
    WHERE sp.security_id = p_security_id AND sp.exchange_id = 1;

    IF is_perpetual_future_group(v_group_prefix, v_note) THEN
        RETURN v_group_prefix;
    END IF;

    SELECT fe.prefix INTO v_prefix
    FROM futures_expirations fe
    WHERE fe.security_id = p_security_id
      AND fe.expiration_date > p_date
      AND fe.is_active = TRUE
    ORDER BY fe.expiration_date ASC
    LIMIT 1;

    RETURN v_prefix;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION get_active_future_prefix(INTEGER, DATE) IS 
'Тикер активного фьючерса на дату; для вечных (CNYRUBF …) — групповой префикс из security_prefixes';

-- Контракт фьючерса на дату + дата начала торгов (день после экспирации предыдущего)
CREATE OR REPLACE FUNCTION get_future_contract_for_date(
    p_security_id INTEGER,
    p_date DATE
)
RETURNS TABLE (
    prefix VARCHAR(50),
    moex_secid VARCHAR(20),
    expiration_date DATE,
    tbank_figi VARCHAR(50),
    start_date DATE
)
LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY
    SELECT
        fe.prefix,
        fe.moex_secid,
        fe.expiration_date,
        fe.tbank_figi,
        COALESCE(
            (
                SELECT fe2.expiration_date + 1
                FROM futures_expirations fe2
                WHERE fe2.security_id = fe.security_id
                  AND fe2.expiration_date < fe.expiration_date
                  AND fe2.is_active = TRUE
                ORDER BY fe2.expiration_date DESC
                LIMIT 1
            ),
            DATE '2000-01-01'
        ) AS start_date
    FROM futures_expirations fe
    WHERE fe.security_id = p_security_id
      AND fe.expiration_date > p_date
      AND fe.is_active = TRUE
    ORDER BY fe.expiration_date ASC
    LIMIT 1;
END;
$$;

COMMENT ON FUNCTION get_future_contract_for_date(INTEGER, DATE) IS
'Контракт фьючерса на дату (ближайшая экспирация после даты) и start_date для загрузки истории';

-- ============================================
-- Функция: get_tbank_token
-- Получает зашифрованный токен T-Bank из счета
-- ============================================
CREATE OR REPLACE FUNCTION get_tbank_token(
    p_account_code VARCHAR(100) DEFAULT NULL
)
RETURNS TEXT AS $$
DECLARE
    v_token TEXT;
BEGIN
    IF p_account_code IS NOT NULL AND btrim(p_account_code) <> '' THEN
        SELECT btrim(a.token_encrypted) INTO v_token
        FROM accounts a
        JOIN brokers b ON a.broker_id = b.id
        WHERE b.code = 'T-BANK'
          AND a.account_code = p_account_code
          AND a.is_active = TRUE
          AND a.token_encrypted IS NOT NULL
          AND btrim(a.token_encrypted) <> '';
        IF v_token IS NOT NULL THEN
            RETURN v_token;
        END IF;
    END IF;

    SELECT btrim(a.token_encrypted) INTO v_token
    FROM accounts a
    JOIN brokers b ON a.broker_id = b.id
    WHERE b.code = 'T-BANK'
      AND a.is_active = TRUE
      AND a.token_encrypted IS NOT NULL
      AND btrim(a.token_encrypted) <> ''
    ORDER BY a.is_efficient DESC, a.id
    LIMIT 1;

    RETURN NULLIF(v_token, '');
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION get_tbank_token(VARCHAR) IS 
'Токен T-Bank: по account_code или первый активный счёт с токеном (is_efficient DESC)';

-- ============================================
-- Процедура: insert_candle
-- Вставляет/обновляет одну свечу (UPSERT)
-- ============================================
CREATE OR REPLACE PROCEDURE insert_candle(
    p_security_id INTEGER,
    p_timeframe_id INTEGER,
    p_dt TIMESTAMP,
    p_open NUMERIC(18,6),
    p_high NUMERIC(18,6),
    p_low NUMERIC(18,6),
    p_close NUMERIC(18,6),
    p_volume NUMERIC(20,2) DEFAULT NULL,
    p_value NUMERIC(20,2) DEFAULT NULL,
    p_trades INTEGER DEFAULT NULL,
    p_contract_prefix VARCHAR DEFAULT NULL
)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO prices (
        security_id, timeframe_id, dt,
        open_price, high_price, low_price, close_price,
        volume, value, trades, contract_prefix
    )
    VALUES (
        p_security_id, p_timeframe_id, p_dt,
        p_open, p_high, p_low, p_close,
        p_volume, p_value, p_trades, p_contract_prefix
    )
    ON CONFLICT (security_id, timeframe_id, dt)
    DO UPDATE SET
        open_price = EXCLUDED.open_price,
        high_price = EXCLUDED.high_price,
        low_price = EXCLUDED.low_price,
        close_price = EXCLUDED.close_price,
        volume = EXCLUDED.volume,
        value = EXCLUDED.value,
        trades = EXCLUDED.trades,
        contract_prefix = COALESCE(EXCLUDED.contract_prefix, prices.contract_prefix);
END;
$$;

COMMENT ON PROCEDURE insert_candle(INTEGER, INTEGER, TIMESTAMP, NUMERIC, NUMERIC, NUMERIC, NUMERIC, NUMERIC, NUMERIC, INTEGER, VARCHAR) IS 
'Вставляет/обновляет одну свечу. contract_prefix — тикер контракта (Si-6.26) для фьючерсов';

-- ============================================
-- Процедура: load_prices_from_tbank
-- Загружает цены через API T-Bank (TData)
-- ============================================
CREATE OR REPLACE PROCEDURE load_prices_from_tbank(
    p_security_id INTEGER,
    p_timeframe_id INTEGER,
    p_date_from DATE,
    p_date_to DATE
)
LANGUAGE plpgsql AS $$
DECLARE
    v_prefix VARCHAR(50);
    v_tf_sec INTEGER;
    v_tf_name VARCHAR(20);
    v_is_future BOOLEAN;
    v_token TEXT;
    v_start_ts TIMESTAMP;
    v_end_ts TIMESTAMP;
    v_records_loaded INTEGER := 0;
BEGIN
    -- Получаем префикс
    SELECT sp.prefix INTO v_prefix
    FROM security_prefixes sp
    WHERE sp.security_id = p_security_id AND sp.exchange_id = 1;

    IF v_prefix IS NULL THEN
        RAISE EXCEPTION 'Префикс не найден для security_id=%', p_security_id;
    END IF;

    SELECT sec, tf INTO v_tf_sec, v_tf_name
    FROM timeframes WHERE id = p_timeframe_id;

    -- Проверяем, это фьючерс или нет
    SELECT (st.name = 'Futures') INTO v_is_future
    FROM securities s
    JOIN security_types st ON s.security_type_id = st.id
    WHERE s.id = p_security_id;

    -- Для фьючерса определяем активный контракт
    IF v_is_future THEN
        v_prefix := get_active_future_prefix(p_security_id, p_date_from);
        IF v_prefix IS NULL THEN
            RAISE EXCEPTION 'Активный фьючерс не найден для security_id=% на дату %', p_security_id, p_date_from;
        END IF;
    END IF;

    -- Получаем токен
    v_token := get_tbank_token();
    IF v_token IS NULL THEN
        RAISE EXCEPTION 'T-Bank токен не найден. Заполните token_encrypted в accounts.';
    END IF;

    v_start_ts := p_date_from::TIMESTAMP;
    v_end_ts := (p_date_to + INTERVAL '1 day')::TIMESTAMP;

    RAISE NOTICE 'T-Bank API запрос: figi=%, interval=%, from=%, to=%', 
        v_prefix, v_tf_name, v_start_ts, v_end_ts;

    -- Логируем попытку
    INSERT INTO price_load_log (security_id, timeframe_id, date_from, date_to, source, records_loaded)
    VALUES (p_security_id, p_timeframe_id, p_date_from, p_date_to, 'T-BANK', 0);

EXCEPTION
    WHEN OTHERS THEN
        INSERT INTO price_load_log (security_id, timeframe_id, date_from, date_to, source, records_loaded, error_message)
        VALUES (p_security_id, p_timeframe_id, p_date_from, p_date_to, 'T-BANK', 0, SQLERRM);
        RAISE;
END;
$$;

COMMENT ON PROCEDURE load_prices_from_tbank(INTEGER, INTEGER, DATE, DATE) IS 
'Загружает цены через API T-Bank. Для фьючерсов автоматически выбирает активный контракт.';

-- ============================================
-- Процедура: load_prices_from_moex
-- Загружает цены через API MOEX (ISS)
-- ============================================
CREATE OR REPLACE PROCEDURE load_prices_from_moex(
    p_security_id INTEGER,
    p_timeframe_id INTEGER,
    p_date_from DATE,
    p_date_to DATE
)
LANGUAGE plpgsql AS $$
DECLARE
    v_prefix VARCHAR(50);
    v_tf_name VARCHAR(20);
    v_is_future BOOLEAN;
    v_engine VARCHAR(20) := 'stock';
    v_market VARCHAR(20) := 'shares';
    v_board VARCHAR(20) := 'TQBR';
    v_start_dt TIMESTAMP;
    v_end_dt TIMESTAMP;
    v_url TEXT;
    v_records_loaded INTEGER := 0;
BEGIN
    SELECT sp.prefix INTO v_prefix
    FROM security_prefixes sp
    WHERE sp.security_id = p_security_id AND sp.exchange_id = 1;

    IF v_prefix IS NULL THEN
        RAISE EXCEPTION 'Префикс не найден для security_id=%', p_security_id;
    END IF;

    SELECT tf INTO v_tf_name
    FROM timeframes WHERE id = p_timeframe_id;

    -- Определяем рынок
    SELECT 
        CASE st.name
            WHEN 'Stock' THEN 'stock'
            WHEN 'Futures' THEN 'futures'
            WHEN 'Bond' THEN 'bonds'
            WHEN 'Index' THEN 'stock'
            ELSE 'stock'
        END,
        CASE st.name
            WHEN 'Stock' THEN 'shares'
            WHEN 'Futures' THEN 'forts'
            WHEN 'Bond' THEN 'bonds'
            WHEN 'Index' THEN 'index'
            ELSE 'shares'
        END,
        CASE st.name
            WHEN 'Stock' THEN 'TQBR'
            WHEN 'Futures' THEN 'RFUD'
            ELSE 'TQBR'
        END
    INTO v_engine, v_market, v_board
    FROM securities s
    JOIN security_types st ON s.security_type_id = st.id
    WHERE s.id = p_security_id;

    -- Для фьючерсов определяем активный контракт
    IF v_engine = 'futures' THEN
        v_prefix := get_active_future_prefix(p_security_id, p_date_from);
        IF v_prefix IS NULL THEN
            RAISE EXCEPTION 'Активный фьючерс не найден для security_id=% на дату %', p_security_id, p_date_from;
        END IF;
    END IF;

    v_start_dt := p_date_from::TIMESTAMP;
    v_end_dt := (p_date_to + INTERVAL '1 day')::TIMESTAMP;

    -- Формируем URL MOEX ISS API
    v_url := format(
        'https://iss.moex.com/iss/engines/%s/markets/%s/boards/%s/securities/%s/candles.json?from=%s&till=%s&interval=%s',
        v_engine, v_market, v_board, v_prefix,
        to_char(v_start_dt, 'YYYY-MM-DD'),
        to_char(v_end_dt, 'YYYY-MM-DD'),
        get_moex_candle_interval(v_tf_name)::TEXT
    );

    RAISE NOTICE 'MOEX API URL: %', v_url;

    -- Логируем попытку
    INSERT INTO price_load_log (security_id, timeframe_id, date_from, date_to, source, records_loaded)
    VALUES (p_security_id, p_timeframe_id, p_date_from, p_date_to, 'MOEX', 0);

EXCEPTION
    WHEN OTHERS THEN
        INSERT INTO price_load_log (security_id, timeframe_id, date_from, date_to, source, records_loaded, error_message)
        VALUES (p_security_id, p_timeframe_id, p_date_from, p_date_to, 'MOEX', 0, SQLERRM);
        RAISE;
END;
$$;

COMMENT ON PROCEDURE load_prices_from_moex(INTEGER, INTEGER, DATE, DATE) IS 
'Загружает цены через открытое API MOEX ISS. Для фьючерсов выбирает активный контракт.';

-- ============================================
-- ГЛАВНАЯ ПРОЦЕДУРА: load_prices
-- Сначала T-Bank, если не сработало -- MOEX
-- ============================================
CREATE OR REPLACE PROCEDURE load_prices(
    p_security_id INTEGER,
    p_timeframe_id INTEGER,
    p_date_from DATE,
    p_date_to DATE
)
LANGUAGE plpgsql AS $$
DECLARE
    v_tbank_ok BOOLEAN := FALSE;
    v_error_msg TEXT;
BEGIN
    -- Попытка 1: T-Bank
    BEGIN
        CALL load_prices_from_tbank(p_security_id, p_timeframe_id, p_date_from, p_date_to);
        v_tbank_ok := TRUE;
        RAISE NOTICE 'Цены успешно загружены из T-Bank';
    EXCEPTION
        WHEN OTHERS THEN
            v_error_msg := SQLERRM;
            RAISE NOTICE 'T-Bank недоступен: %. Переключаемся на MOEX...', v_error_msg;
    END;

    -- Попытка 2: MOEX (если T-Bank не сработал)
    IF NOT v_tbank_ok THEN
        BEGIN
            CALL load_prices_from_moex(p_security_id, p_timeframe_id, p_date_from, p_date_to);
            RAISE NOTICE 'Цены успешно загружены из MOEX';
        EXCEPTION
            WHEN OTHERS THEN
                v_error_msg := SQLERRM;
                RAISE EXCEPTION 'Оба источника недоступны. T-Bank: %; MOEX: %', v_error_msg, SQLERRM;
        END;
    END IF;
END;
$$;

COMMENT ON PROCEDURE load_prices(INTEGER, INTEGER, DATE, DATE) IS 
'Главная процедура загрузки цен: сначала T-Bank, если не отвечает -- MOEX. Для фьючерсов автоматически выбирает активный контракт на дату периода.';

-- ============================================
-- Процедура: load_prices_batch
-- Загрузка цен для нескольких бумаг сразу
-- ============================================
CREATE OR REPLACE PROCEDURE load_prices_batch(
    p_security_ids INTEGER[],
    p_timeframe_id INTEGER,
    p_date_from DATE,
    p_date_to DATE
)
LANGUAGE plpgsql AS $$
DECLARE
    v_security_id INTEGER;
BEGIN
    FOREACH v_security_id IN ARRAY p_security_ids
    LOOP
        BEGIN
            CALL load_prices(v_security_id, p_timeframe_id, p_date_from, p_date_to);
            RAISE NOTICE 'Загружены цены для security_id=%', v_security_id;
        EXCEPTION
            WHEN OTHERS THEN
                RAISE NOTICE 'Ошибка загрузки для security_id=%: %', v_security_id, SQLERRM;
        END;
    END LOOP;
END;
$$;

COMMENT ON PROCEDURE load_prices_batch(INTEGER[], INTEGER, DATE, DATE) IS 
'Загружает цены для массива бумаг по одному таймфрейму и периоду.';

-- ============================================
-- Процедура: load_all_timeframes
-- Загрузка всех таймфреймов для одной бумаги
-- ============================================
CREATE OR REPLACE PROCEDURE load_all_timeframes(
    p_security_id INTEGER,
    p_date_from DATE,
    p_date_to DATE
)
LANGUAGE plpgsql AS $$
DECLARE
    v_tf RECORD;
BEGIN
    FOR v_tf IN SELECT id FROM timeframes WHERE COALESCE(is_active, TRUE) = TRUE ORDER BY sec
    LOOP
        BEGIN
            CALL load_prices(p_security_id, v_tf.id, p_date_from, p_date_to);
            RAISE NOTICE 'Загружен таймфрейм id=% для security_id=%', v_tf.id, p_security_id;
        EXCEPTION
            WHEN OTHERS THEN
                RAISE NOTICE 'Ошибка загрузки таймфрейма id=%: %', v_tf.id, SQLERRM;
        END;
    END LOOP;
END;
$$;

COMMENT ON PROCEDURE load_all_timeframes(INTEGER, DATE, DATE) IS 
'Загружает все таймфреймы для одной бумаги за указанный период.';

-- ============================================
-- Процедура: cleanup_old_prices
-- Очистка старых цен (архивирование)
-- ============================================
CREATE OR REPLACE PROCEDURE cleanup_old_prices(
    p_days_to_keep INTEGER DEFAULT 365
)
LANGUAGE plpgsql AS $$
DECLARE
    v_cutoff_date TIMESTAMP;
    v_deleted_count INTEGER;
BEGIN
    v_cutoff_date := CURRENT_TIMESTAMP - (p_days_to_keep || ' days')::INTERVAL;

    DELETE FROM prices
    WHERE dt < v_cutoff_date;

    GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
    RAISE NOTICE 'Удалено % старых свечей (старше % дней)', v_deleted_count, p_days_to_keep;
END;
$$;

COMMENT ON PROCEDURE cleanup_old_prices(INTEGER) IS 
'Удаляет цены старше указанного количества дней (по умолчанию 365).';

-- ============================================
-- Индикаторы: подстановка плейсхолдеров и функции calc_ind_*
-- (вставляется в 02_multilogictrade_functions_and_procedures.sql)
-- ============================================

CREATE OR REPLACE FUNCTION get_ind_series_threshold(
    p_indicator_id INTEGER,
    p_series VARCHAR
)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    SELECT threshold_value
    FROM indicator_value_types
    WHERE indicator_id = p_indicator_id
      AND code = p_series
      AND is_threshold = TRUE;
$$;

COMMENT ON FUNCTION get_ind_series_threshold(INTEGER, VARCHAR) IS
'Пороговое значение серии индикатора (OVERBOUGHT, ZERO и т.д.).';

-- Подстановка плейсхолдеров в indicators.script перед EXECUTE.
-- Длинные имена (:fast_period) заменяются раньше коротких (:period).
CREATE OR REPLACE FUNCTION substitute_indicator_script(
    p_template TEXT,
    p_period INTEGER DEFAULT NULL,
    p_fast_period INTEGER DEFAULT NULL,
    p_slow_period INTEGER DEFAULT NULL,
    p_signal_period INTEGER DEFAULT NULL,
    p_std_dev NUMERIC DEFAULT NULL,
    p_k_period INTEGER DEFAULT NULL,
    p_d_period INTEGER DEFAULT NULL,
    p_smooth INTEGER DEFAULT NULL,
    p_series VARCHAR DEFAULT NULL,
    p_security_id INTEGER DEFAULT NULL,
    p_timeframe_id INTEGER DEFAULT NULL,
    p_dt TIMESTAMP DEFAULT NULL,
    p_indicator_id INTEGER DEFAULT NULL
)
RETURNS TEXT
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_sql TEXT := p_template;
BEGIN
    IF v_sql IS NULL OR TRIM(v_sql) = '' THEN
        RETURN NULL;
    END IF;

    v_sql := REPLACE(v_sql, ':fast_period', COALESCE(p_fast_period::TEXT, 'NULL'));
    v_sql := REPLACE(v_sql, ':slow_period', COALESCE(p_slow_period::TEXT, 'NULL'));
    v_sql := REPLACE(v_sql, ':signal_period', COALESCE(p_signal_period::TEXT, 'NULL'));
    v_sql := REPLACE(v_sql, ':k_period', COALESCE(p_k_period::TEXT, 'NULL'));
    v_sql := REPLACE(v_sql, ':d_period', COALESCE(p_d_period::TEXT, 'NULL'));
    v_sql := REPLACE(v_sql, ':std_dev', COALESCE(p_std_dev::TEXT, 'NULL'));
    v_sql := REPLACE(v_sql, ':smooth', COALESCE(p_smooth::TEXT, 'NULL'));
    v_sql := REPLACE(v_sql, ':security_id', COALESCE(p_security_id::TEXT, 'NULL'));
    v_sql := REPLACE(v_sql, ':timeframe_id', COALESCE(p_timeframe_id::TEXT, 'NULL'));
    v_sql := REPLACE(v_sql, ':indicator_id', COALESCE(p_indicator_id::TEXT, 'NULL'));
    v_sql := REPLACE(v_sql, ':period', COALESCE(p_period::TEXT, 'NULL'));
    v_sql := REPLACE(v_sql, ':series', quote_literal(COALESCE(p_series, '')));
    v_sql := REPLACE(v_sql, ':dt', quote_literal(p_dt));

    RETURN v_sql;
END;
$$;

COMMENT ON FUNCTION substitute_indicator_script(TEXT, INTEGER, INTEGER, INTEGER, INTEGER, NUMERIC, INTEGER, INTEGER, INTEGER, VARCHAR, INTEGER, INTEGER, TIMESTAMP, INTEGER) IS
'Подставляет значения параметров и :series в шаблон indicators.script для EXECUTE.';

CREATE OR REPLACE FUNCTION exec_indicator_script(
    p_template TEXT,
    p_period INTEGER DEFAULT NULL,
    p_fast_period INTEGER DEFAULT NULL,
    p_slow_period INTEGER DEFAULT NULL,
    p_signal_period INTEGER DEFAULT NULL,
    p_std_dev NUMERIC DEFAULT NULL,
    p_k_period INTEGER DEFAULT NULL,
    p_d_period INTEGER DEFAULT NULL,
    p_smooth INTEGER DEFAULT NULL,
    p_series VARCHAR DEFAULT NULL,
    p_security_id INTEGER DEFAULT NULL,
    p_timeframe_id INTEGER DEFAULT NULL,
    p_dt TIMESTAMP DEFAULT NULL,
    p_indicator_id INTEGER DEFAULT NULL
)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_sql TEXT;
    v_result NUMERIC;
BEGIN
    v_sql := substitute_indicator_script(
        p_template, p_period, p_fast_period, p_slow_period, p_signal_period,
        p_std_dev, p_k_period, p_d_period, p_smooth, p_series,
        p_security_id, p_timeframe_id, p_dt, p_indicator_id
    );
    IF v_sql IS NULL THEN
        RETURN NULL;
    END IF;
    EXECUTE v_sql INTO v_result;
    RETURN v_result;
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'exec_indicator_script [%]: %', p_series, SQLERRM;
        RETURN NULL;
END;
$$;

COMMENT ON FUNCTION exec_indicator_script(TEXT, INTEGER, INTEGER, INTEGER, INTEGER, NUMERIC, INTEGER, INTEGER, INTEGER, VARCHAR, INTEGER, INTEGER, TIMESTAMP, INTEGER) IS
'Выполняет indicators.script (аналог EXECUTE IMMEDIATE) и возвращает NUMERIC.';

-- RSI
CREATE OR REPLACE FUNCTION calc_ind_rsi(
    p_period INTEGER,
    p_series VARCHAR,
    p_security_id INTEGER,
    p_timeframe_id INTEGER,
    p_dt TIMESTAMP,
    p_indicator_id INTEGER DEFAULT NULL
)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_closes NUMERIC[];
    v_idx INTEGER;
    v_gain NUMERIC := 0;
    v_loss NUMERIC := 0;
    v_avg_gain NUMERIC;
    v_avg_loss NUMERIC;
    v_rs NUMERIC;
    v_thr NUMERIC;
    j INTEGER;
BEGIN
    IF p_series IS NOT NULL AND p_series <> 'RSI' AND p_indicator_id IS NOT NULL THEN
        v_thr := get_ind_series_threshold(p_indicator_id, p_series);
        IF v_thr IS NOT NULL THEN
            RETURN v_thr;
        END IF;
        RETURN NULL;
    END IF;

    SELECT array_agg(close_price ORDER BY dt), COUNT(*)
    INTO v_closes, v_idx
    FROM prices
    WHERE security_id = p_security_id
      AND timeframe_id = p_timeframe_id
      AND dt <= p_dt;

    IF v_idx IS NULL OR v_idx < p_period + 1 THEN
        RETURN NULL;
    END IF;

    FOR j IN v_idx - p_period + 1 .. v_idx LOOP
        IF v_closes[j] > v_closes[j - 1] THEN
            v_gain := v_gain + (v_closes[j] - v_closes[j - 1]);
        ELSE
            v_loss := v_loss + (v_closes[j - 1] - v_closes[j]);
        END IF;
    END LOOP;

    v_avg_gain := v_gain / p_period;
    v_avg_loss := v_loss / p_period;
    IF v_avg_loss = 0 THEN
        RETURN 100;
    END IF;
    v_rs := v_avg_gain / v_avg_loss;
    RETURN 100 - (100 / (1 + v_rs));
END;
$$;

-- SMA
CREATE OR REPLACE FUNCTION calc_ind_sma(
    p_period INTEGER,
    p_series VARCHAR,
    p_security_id INTEGER,
    p_timeframe_id INTEGER,
    p_dt TIMESTAMP,
    p_indicator_id INTEGER DEFAULT NULL
)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_thr NUMERIC;
BEGIN
    IF p_series IS NOT NULL AND p_series <> 'VALUE' AND p_indicator_id IS NOT NULL THEN
        v_thr := get_ind_series_threshold(p_indicator_id, p_series);
        IF v_thr IS NOT NULL THEN RETURN v_thr; END IF;
        RETURN NULL;
    END IF;

    RETURN (
        SELECT AVG(close_price)
        FROM (
            SELECT close_price
            FROM prices
            WHERE security_id = p_security_id
              AND timeframe_id = p_timeframe_id
              AND dt <= p_dt
            ORDER BY dt DESC
            LIMIT p_period
        ) s
    );
END;
$$;

-- EMA (значение на свече p_dt)
CREATE OR REPLACE FUNCTION calc_ind_ema(
    p_period INTEGER,
    p_series VARCHAR,
    p_security_id INTEGER,
    p_timeframe_id INTEGER,
    p_dt TIMESTAMP,
    p_indicator_id INTEGER DEFAULT NULL
)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_thr NUMERIC;
    v_ema NUMERIC;
    v_mult NUMERIC;
    r RECORD;
BEGIN
    IF p_series IS NOT NULL AND p_series <> 'VALUE' AND p_indicator_id IS NOT NULL THEN
        v_thr := get_ind_series_threshold(p_indicator_id, p_series);
        IF v_thr IS NOT NULL THEN RETURN v_thr; END IF;
        RETURN NULL;
    END IF;

    v_mult := 2.0 / (p_period + 1);
    v_ema := NULL;
    FOR r IN
        SELECT close_price
        FROM prices
        WHERE security_id = p_security_id
          AND timeframe_id = p_timeframe_id
          AND dt <= p_dt
        ORDER BY dt
    LOOP
        IF v_ema IS NULL THEN
            v_ema := r.close_price;
        ELSE
            v_ema := (r.close_price - v_ema) * v_mult + v_ema;
        END IF;
    END LOOP;
    RETURN v_ema;
END;
$$;

-- MACD
CREATE OR REPLACE FUNCTION calc_ind_macd(
    p_fast_period INTEGER,
    p_slow_period INTEGER,
    p_signal_period INTEGER,
    p_series VARCHAR,
    p_security_id INTEGER,
    p_timeframe_id INTEGER,
    p_dt TIMESTAMP,
    p_indicator_id INTEGER DEFAULT NULL
)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_closes NUMERIC[];
    v_idx INTEGER;
    v_mult_fast NUMERIC;
    v_mult_slow NUMERIC;
    v_mult_signal NUMERIC;
    v_ema_fast NUMERIC;
    v_ema_slow NUMERIC;
    v_macd NUMERIC;
    v_macd_signal NUMERIC;
    v_macd_line NUMERIC[];
    i INTEGER;
    v_thr NUMERIC;
BEGIN
    IF p_indicator_id IS NOT NULL AND p_series IN ('ZERO', 'OVERBOUGHT', 'OVERSOLD') THEN
        v_thr := get_ind_series_threshold(p_indicator_id, p_series);
        IF v_thr IS NOT NULL THEN RETURN v_thr; END IF;
    END IF;

    SELECT array_agg(close_price ORDER BY dt), COUNT(*)
    INTO v_closes, v_idx
    FROM prices
    WHERE security_id = p_security_id
      AND timeframe_id = p_timeframe_id
      AND dt <= p_dt;

    IF v_idx IS NULL OR v_idx < p_slow_period THEN
        RETURN NULL;
    END IF;

    v_mult_fast := 2.0 / (p_fast_period + 1);
    v_mult_slow := 2.0 / (p_slow_period + 1);
    v_mult_signal := 2.0 / (p_signal_period + 1);
    v_ema_fast := v_closes[1];
    v_ema_slow := v_closes[1];
    v_macd_line := ARRAY[]::NUMERIC[];

    FOR i IN 2 .. v_idx LOOP
        v_ema_fast := (v_closes[i] - v_ema_fast) * v_mult_fast + v_ema_fast;
        v_ema_slow := (v_closes[i] - v_ema_slow) * v_mult_slow + v_ema_slow;
        v_macd := v_ema_fast - v_ema_slow;
        v_macd_line := array_append(v_macd_line, v_macd);
    END LOOP;

    IF array_length(v_macd_line, 1) IS NULL THEN
        RETURN NULL;
    END IF;

    v_macd_signal := v_macd_line[1];
    FOR i IN 2 .. array_length(v_macd_line, 1) LOOP
        v_macd_signal := (v_macd_line[i] - v_macd_signal) * v_mult_signal + v_macd_signal;
    END LOOP;

    v_macd := v_macd_line[array_length(v_macd_line, 1)];

    RETURN CASE p_series
        WHEN 'MACD' THEN v_macd
        WHEN 'SIGNAL' THEN v_macd_signal
        WHEN 'HISTOGRAM' THEN v_macd - v_macd_signal
        WHEN 'ZERO' THEN 0
        ELSE NULL
    END;
END;
$$;

-- Bollinger Bands
CREATE OR REPLACE FUNCTION calc_ind_bb(
    p_period INTEGER,
    p_std_dev NUMERIC,
    p_series VARCHAR,
    p_security_id INTEGER,
    p_timeframe_id INTEGER,
    p_dt TIMESTAMP,
    p_indicator_id INTEGER DEFAULT NULL
)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_middle NUMERIC;
    v_std NUMERIC;
    v_thr NUMERIC;
BEGIN
    IF p_indicator_id IS NOT NULL AND p_series NOT IN ('UPPER', 'MIDDLE', 'LOWER', 'BANDWIDTH') THEN
        v_thr := get_ind_series_threshold(p_indicator_id, p_series);
        IF v_thr IS NOT NULL THEN RETURN v_thr; END IF;
        RETURN NULL;
    END IF;

    SELECT AVG(close_price), STDDEV_SAMP(close_price)
    INTO v_middle, v_std
    FROM (
        SELECT close_price
        FROM prices
        WHERE security_id = p_security_id
          AND timeframe_id = p_timeframe_id
          AND dt <= p_dt
        ORDER BY dt DESC
        LIMIT p_period
    ) s;

    IF v_middle IS NULL THEN
        RETURN NULL;
    END IF;
    v_std := COALESCE(v_std, 0);

    RETURN CASE p_series
        WHEN 'MIDDLE' THEN v_middle
        WHEN 'UPPER' THEN v_middle + p_std_dev * v_std
        WHEN 'LOWER' THEN v_middle - p_std_dev * v_std
        WHEN 'BANDWIDTH' THEN
            CASE WHEN v_middle = 0 THEN NULL
                 ELSE (2 * p_std_dev * v_std) / v_middle * 100
            END
        ELSE NULL
    END;
END;
$$;

-- ATR
CREATE OR REPLACE FUNCTION calc_ind_atr(
    p_period INTEGER,
    p_series VARCHAR,
    p_security_id INTEGER,
    p_timeframe_id INTEGER,
    p_dt TIMESTAMP,
    p_indicator_id INTEGER DEFAULT NULL
)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_highs NUMERIC[];
    v_lows NUMERIC[];
    v_closes NUMERIC[];
    v_idx INTEGER;
    v_atr NUMERIC;
    v_tr NUMERIC;
    v_tr_high NUMERIC;
    v_tr_low NUMERIC;
    v_tr_close NUMERIC;
    i INTEGER;
    v_thr NUMERIC;
BEGIN
    IF p_series = 'ATR_PCT' THEN
        v_atr := calc_ind_atr(p_period, 'ATR', p_security_id, p_timeframe_id, p_dt, p_indicator_id);
        SELECT close_price INTO v_tr_close
        FROM prices
        WHERE security_id = p_security_id AND timeframe_id = p_timeframe_id AND dt = p_dt;
        IF v_atr IS NULL OR v_tr_close IS NULL OR v_tr_close = 0 THEN
            RETURN NULL;
        END IF;
        RETURN v_atr / v_tr_close * 100;
    END IF;

    IF p_series IS NOT NULL AND p_series <> 'ATR' AND p_indicator_id IS NOT NULL THEN
        v_thr := get_ind_series_threshold(p_indicator_id, p_series);
        IF v_thr IS NOT NULL THEN RETURN v_thr; END IF;
        RETURN NULL;
    END IF;

    SELECT
        array_agg(sub.high_price ORDER BY sub.dt),
        array_agg(sub.low_price ORDER BY sub.dt),
        array_agg(sub.close_price ORDER BY sub.dt),
        COUNT(*)
    INTO v_highs, v_lows, v_closes, v_idx
    FROM (
        SELECT high_price, low_price, close_price, dt
        FROM prices
        WHERE security_id = p_security_id
          AND timeframe_id = p_timeframe_id
          AND dt <= p_dt
        ORDER BY dt DESC
        LIMIT LEAST(5000, GREATEST(p_period * 30, 200))
    ) sub;

    IF v_idx IS NULL OR v_idx < p_period + 1 THEN
        RETURN NULL;
    END IF;

    v_atr := 0;
    FOR i IN 2 .. v_idx LOOP
        v_tr_high := v_highs[i] - v_lows[i];
        v_tr_low := ABS(v_highs[i] - v_closes[i - 1]);
        v_tr_close := ABS(v_lows[i] - v_closes[i - 1]);
        v_tr := GREATEST(v_tr_high, v_tr_low, v_tr_close);
        IF i <= p_period THEN
            v_atr := v_atr + v_tr;
            IF i = p_period THEN
                v_atr := v_atr / p_period;
            END IF;
        ELSE
            v_atr := (v_atr * (p_period - 1) + v_tr) / p_period;
        END IF;
    END LOOP;

    RETURN v_atr;
END;
$$;

-- Stochastic
CREATE OR REPLACE FUNCTION calc_ind_stoch(
    p_k_period INTEGER,
    p_d_period INTEGER,
    p_smooth INTEGER,
    p_series VARCHAR,
    p_security_id INTEGER,
    p_timeframe_id INTEGER,
    p_dt TIMESTAMP,
    p_indicator_id INTEGER DEFAULT NULL
)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_highs NUMERIC[];
    v_lows NUMERIC[];
    v_closes NUMERIC[];
    v_idx INTEGER;
    v_k_values NUMERIC[] := ARRAY[]::NUMERIC[];
    v_stoch_k NUMERIC;
    v_stoch_d NUMERIC;
    i INTEGER;
    j INTEGER;
    v_lowest NUMERIC;
    v_highest NUMERIC;
    v_sum NUMERIC;
    v_thr NUMERIC;
BEGIN
    IF p_indicator_id IS NOT NULL AND p_series IN ('OVERBOUGHT', 'OVERSOLD') THEN
        v_thr := get_ind_series_threshold(p_indicator_id, p_series);
        IF v_thr IS NOT NULL THEN RETURN v_thr; END IF;
    END IF;

    SELECT
        array_agg(high_price ORDER BY dt),
        array_agg(low_price ORDER BY dt),
        array_agg(close_price ORDER BY dt),
        COUNT(*)
    INTO v_highs, v_lows, v_closes, v_idx
    FROM prices
    WHERE security_id = p_security_id
      AND timeframe_id = p_timeframe_id
      AND dt <= p_dt;

    IF v_idx IS NULL OR v_idx < p_k_period THEN
        RETURN NULL;
    END IF;

    FOR i IN p_k_period .. v_idx LOOP
        v_lowest := v_lows[i];
        v_highest := v_highs[i];
        FOR j IN i - p_k_period + 1 .. i LOOP
            IF v_lows[j] < v_lowest THEN v_lowest := v_lows[j]; END IF;
            IF v_highs[j] > v_highest THEN v_highest := v_highs[j]; END IF;
        END LOOP;
        IF v_highest = v_lowest THEN
            v_stoch_k := 50;
        ELSE
            v_stoch_k := (v_closes[i] - v_lowest) / (v_highest - v_lowest) * 100;
        END IF;
        v_k_values := array_append(v_k_values, v_stoch_k);
    END LOOP;

    IF array_length(v_k_values, 1) IS NULL THEN
        RETURN NULL;
    END IF;

    v_stoch_k := v_k_values[array_length(v_k_values, 1)];

    IF p_series = 'K' THEN
        RETURN v_stoch_k;
    END IF;

    IF p_series = 'D' THEN
        v_sum := 0;
        FOR i IN GREATEST(1, array_length(v_k_values, 1) - p_d_period + 1) .. array_length(v_k_values, 1) LOOP
            v_sum := v_sum + v_k_values[i];
        END LOOP;
        RETURN v_sum / LEAST(p_d_period, array_length(v_k_values, 1));
    END IF;

    RETURN NULL;
END;
$$;

-- ============================================
-- Массивные функции индикаторов (один проход по ценам)
-- Сигнатура: (параметры индикатора…, series, security_id, timeframe_id, point_count, end_dt)
-- Возвращает TABLE(dt, value) — последние point_count точек до end_dt
-- ============================================

CREATE OR REPLACE FUNCTION ind_resolve_end_dt(
    p_security_id INTEGER,
    p_timeframe_id INTEGER,
    p_end_dt TIMESTAMP
)
RETURNS TIMESTAMP
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        p_end_dt,
        (SELECT MAX(dt) FROM prices
         WHERE security_id = p_security_id AND timeframe_id = p_timeframe_id)
    );
$$;

CREATE OR REPLACE FUNCTION ind_warmup_bars(p_period INTEGER, p_point_count INTEGER)
RETURNS INTEGER
LANGUAGE sql IMMUTABLE AS $$
    SELECT GREATEST(COALESCE(p_period, 14) * 4, COALESCE(p_point_count, 100) + COALESCE(p_period, 14) + 20);
$$;

-- RSI array
CREATE OR REPLACE FUNCTION calc_ind_rsi_array(
    p_period INTEGER,
    p_series VARCHAR,
    p_security_id INTEGER,
    p_timeframe_id INTEGER,
    p_point_count INTEGER DEFAULT 100,
    p_end_dt TIMESTAMP DEFAULT NULL
)
RETURNS TABLE (dt TIMESTAMP, value NUMERIC)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_end TIMESTAMP;
    v_bars INTEGER;
    v_dts TIMESTAMP[];
    v_closes NUMERIC[];
    v_n INTEGER;
    v_gain NUMERIC;
    v_loss NUMERIC;
    v_avg_gain NUMERIC;
    v_avg_loss NUMERIC;
    v_rs NUMERIC;
    v_rsi NUMERIC;
    i INTEGER;
    j INTEGER;
    v_start INTEGER;
BEGIN
    IF p_series IS NOT NULL AND p_series <> 'RSI' THEN
        RETURN;
    END IF;

    v_end := ind_resolve_end_dt(p_security_id, p_timeframe_id, p_end_dt);
    IF v_end IS NULL THEN RETURN; END IF;
    v_bars := ind_warmup_bars(p_period, p_point_count);

    SELECT array_agg(x.dt ORDER BY x.dt),
           array_agg(x.close_price ORDER BY x.dt),
           COUNT(*)::INTEGER
    INTO v_dts, v_closes, v_n
    FROM (
        SELECT p.dt, p.close_price
        FROM prices p
        WHERE p.security_id = p_security_id
          AND p.timeframe_id = p_timeframe_id
          AND p.dt <= v_end
        ORDER BY p.dt DESC
        LIMIT v_bars
    ) x;

    IF v_n IS NULL OR v_n < p_period + 1 THEN RETURN; END IF;

    v_start := GREATEST(p_period + 1, v_n - p_point_count + 1);
    FOR i IN v_start .. v_n LOOP
        v_gain := 0;
        v_loss := 0;
        FOR j IN i - p_period + 1 .. i LOOP
            IF v_closes[j] > v_closes[j - 1] THEN
                v_gain := v_gain + (v_closes[j] - v_closes[j - 1]);
            ELSE
                v_loss := v_loss + (v_closes[j - 1] - v_closes[j]);
            END IF;
        END LOOP;
        v_avg_gain := v_gain / p_period;
        v_avg_loss := v_loss / p_period;
        IF v_avg_loss = 0 THEN
            v_rsi := 100;
        ELSE
            v_rs := v_avg_gain / v_avg_loss;
            v_rsi := 100 - (100 / (1 + v_rs));
        END IF;
        dt := v_dts[i];
        value := v_rsi;
        RETURN NEXT;
    END LOOP;
END;
$$;

-- SMA array
CREATE OR REPLACE FUNCTION calc_ind_sma_array(
    p_period INTEGER,
    p_series VARCHAR,
    p_security_id INTEGER,
    p_timeframe_id INTEGER,
    p_point_count INTEGER DEFAULT 100,
    p_end_dt TIMESTAMP DEFAULT NULL
)
RETURNS TABLE (dt TIMESTAMP, value NUMERIC)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_end TIMESTAMP;
    v_bars INTEGER;
    v_dts TIMESTAMP[];
    v_closes NUMERIC[];
    v_n INTEGER;
    v_sum NUMERIC;
    i INTEGER;
    v_start INTEGER;
BEGIN
    IF p_series IS NOT NULL AND p_series <> 'VALUE' THEN RETURN; END IF;

    v_end := ind_resolve_end_dt(p_security_id, p_timeframe_id, p_end_dt);
    IF v_end IS NULL THEN RETURN; END IF;
    v_bars := ind_warmup_bars(p_period, p_point_count);

    SELECT array_agg(x.dt ORDER BY x.dt),
           array_agg(x.close_price ORDER BY x.dt),
           COUNT(*)::INTEGER
    INTO v_dts, v_closes, v_n
    FROM (
        SELECT p.dt, p.close_price FROM prices p
        WHERE p.security_id = p_security_id AND p.timeframe_id = p_timeframe_id AND p.dt <= v_end
        ORDER BY p.dt DESC LIMIT v_bars
    ) x;

    IF v_n IS NULL OR v_n < p_period THEN RETURN; END IF;

    v_start := GREATEST(p_period, v_n - p_point_count + 1);
    FOR i IN v_start .. v_n LOOP
        v_sum := 0;
        FOR j IN i - p_period + 1 .. i LOOP
            v_sum := v_sum + v_closes[j];
        END LOOP;
        dt := v_dts[i];
        value := v_sum / p_period;
        RETURN NEXT;
    END LOOP;
END;
$$;

-- EMA array
CREATE OR REPLACE FUNCTION calc_ind_ema_array(
    p_period INTEGER,
    p_series VARCHAR,
    p_security_id INTEGER,
    p_timeframe_id INTEGER,
    p_point_count INTEGER DEFAULT 100,
    p_end_dt TIMESTAMP DEFAULT NULL
)
RETURNS TABLE (dt TIMESTAMP, value NUMERIC)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_end TIMESTAMP;
    v_bars INTEGER;
    v_dts TIMESTAMP[];
    v_closes NUMERIC[];
    v_n INTEGER;
    v_mult NUMERIC;
    v_ema NUMERIC;
    i INTEGER;
    v_start INTEGER;
BEGIN
    IF p_series IS NOT NULL AND p_series <> 'VALUE' THEN RETURN; END IF;

    v_end := ind_resolve_end_dt(p_security_id, p_timeframe_id, p_end_dt);
    IF v_end IS NULL THEN RETURN; END IF;
    v_bars := ind_warmup_bars(p_period, p_point_count);
    v_mult := 2.0 / (p_period + 1);

    SELECT array_agg(x.dt ORDER BY x.dt),
           array_agg(x.close_price ORDER BY x.dt),
           COUNT(*)::INTEGER
    INTO v_dts, v_closes, v_n
    FROM (
        SELECT p.dt, p.close_price FROM prices p
        WHERE p.security_id = p_security_id AND p.timeframe_id = p_timeframe_id AND p.dt <= v_end
        ORDER BY p.dt DESC LIMIT v_bars
    ) x;

    IF v_n IS NULL OR v_n < 1 THEN RETURN; END IF;

    v_ema := v_closes[1];
    v_start := GREATEST(2, v_n - p_point_count + 1);
    FOR i IN 2 .. v_n LOOP
        v_ema := (v_closes[i] - v_ema) * v_mult + v_ema;
        IF i >= GREATEST(p_period, v_start) THEN
            dt := v_dts[i];
            value := v_ema;
            RETURN NEXT;
        END IF;
    END LOOP;
END;
$$;

-- MACD array (один проход → MACD / SIGNAL / HISTOGRAM)
CREATE OR REPLACE FUNCTION calc_ind_macd_array(
    p_fast_period INTEGER,
    p_slow_period INTEGER,
    p_signal_period INTEGER,
    p_series VARCHAR,
    p_security_id INTEGER,
    p_timeframe_id INTEGER,
    p_point_count INTEGER DEFAULT 100,
    p_end_dt TIMESTAMP DEFAULT NULL
)
RETURNS TABLE (dt TIMESTAMP, value NUMERIC)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_end TIMESTAMP;
    v_bars INTEGER;
    v_dts TIMESTAMP[];
    v_closes NUMERIC[];
    v_n INTEGER;
    v_mult_fast NUMERIC;
    v_mult_slow NUMERIC;
    v_mult_signal NUMERIC;
    v_ema_fast NUMERIC;
    v_ema_slow NUMERIC;
    v_macd NUMERIC;
    v_macd_signal NUMERIC;
    v_macd_line NUMERIC[];
    v_signal_line NUMERIC[];
    i INTEGER;
    v_start INTEGER;
BEGIN
    IF p_series NOT IN ('MACD', 'SIGNAL', 'HISTOGRAM') THEN RETURN; END IF;

    v_end := ind_resolve_end_dt(p_security_id, p_timeframe_id, p_end_dt);
    IF v_end IS NULL THEN RETURN; END IF;
    v_bars := ind_warmup_bars(p_slow_period + p_signal_period, p_point_count);

    SELECT array_agg(x.dt ORDER BY x.dt),
           array_agg(x.close_price ORDER BY x.dt),
           COUNT(*)::INTEGER
    INTO v_dts, v_closes, v_n
    FROM (
        SELECT p.dt, p.close_price FROM prices p
        WHERE p.security_id = p_security_id AND p.timeframe_id = p_timeframe_id AND p.dt <= v_end
        ORDER BY p.dt DESC LIMIT v_bars
    ) x;

    IF v_n IS NULL OR v_n < p_slow_period THEN RETURN; END IF;

    v_mult_fast := 2.0 / (p_fast_period + 1);
    v_mult_slow := 2.0 / (p_slow_period + 1);
    v_mult_signal := 2.0 / (p_signal_period + 1);
    v_ema_fast := v_closes[1];
    v_ema_slow := v_closes[1];
    v_macd_line := ARRAY[]::NUMERIC[];
    v_signal_line := ARRAY[]::NUMERIC[];

    FOR i IN 2 .. v_n LOOP
        v_ema_fast := (v_closes[i] - v_ema_fast) * v_mult_fast + v_ema_fast;
        v_ema_slow := (v_closes[i] - v_ema_slow) * v_mult_slow + v_ema_slow;
        v_macd := v_ema_fast - v_ema_slow;
        v_macd_line := array_append(v_macd_line, v_macd);
        IF array_length(v_macd_line, 1) = 1 THEN
            v_macd_signal := v_macd;
        ELSE
            v_macd_signal := (v_macd - v_macd_signal) * v_mult_signal + v_macd_signal;
        END IF;
        v_signal_line := array_append(v_signal_line, v_macd_signal);
    END LOOP;

    v_start := GREATEST(1, array_length(v_macd_line, 1) - p_point_count + 1);
    FOR i IN v_start .. array_length(v_macd_line, 1) LOOP
        dt := v_dts[i + 1];
        v_macd := v_macd_line[i];
        v_macd_signal := v_signal_line[i];
        value := CASE p_series
            WHEN 'MACD' THEN v_macd
            WHEN 'SIGNAL' THEN v_macd_signal
            WHEN 'HISTOGRAM' THEN v_macd - v_macd_signal
        END;
        RETURN NEXT;
    END LOOP;
END;
$$;

-- BB array
CREATE OR REPLACE FUNCTION calc_ind_bb_array(
    p_period INTEGER,
    p_std_dev NUMERIC,
    p_series VARCHAR,
    p_security_id INTEGER,
    p_timeframe_id INTEGER,
    p_point_count INTEGER DEFAULT 100,
    p_end_dt TIMESTAMP DEFAULT NULL
)
RETURNS TABLE (dt TIMESTAMP, value NUMERIC)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_end TIMESTAMP;
    v_bars INTEGER;
    v_dts TIMESTAMP[];
    v_closes NUMERIC[];
    v_n INTEGER;
    v_middle NUMERIC;
    v_std NUMERIC;
    v_sum NUMERIC;
    v_sum_sq NUMERIC;
    i INTEGER;
    j INTEGER;
    v_start INTEGER;
BEGIN
    IF p_series NOT IN ('UPPER', 'MIDDLE', 'LOWER', 'BANDWIDTH') THEN RETURN; END IF;

    v_end := ind_resolve_end_dt(p_security_id, p_timeframe_id, p_end_dt);
    IF v_end IS NULL THEN RETURN; END IF;
    v_bars := ind_warmup_bars(p_period, p_point_count);

    SELECT array_agg(x.dt ORDER BY x.dt),
           array_agg(x.close_price ORDER BY x.dt),
           COUNT(*)::INTEGER
    INTO v_dts, v_closes, v_n
    FROM (
        SELECT p.dt, p.close_price FROM prices p
        WHERE p.security_id = p_security_id AND p.timeframe_id = p_timeframe_id AND p.dt <= v_end
        ORDER BY p.dt DESC LIMIT v_bars
    ) x;

    IF v_n IS NULL OR v_n < p_period THEN RETURN; END IF;

    v_start := GREATEST(p_period, v_n - p_point_count + 1);
    FOR i IN v_start .. v_n LOOP
        v_sum := 0;
        v_sum_sq := 0;
        FOR j IN i - p_period + 1 .. i LOOP
            v_sum := v_sum + v_closes[j];
            v_sum_sq := v_sum_sq + v_closes[j] * v_closes[j];
        END LOOP;
        v_middle := v_sum / p_period;
        v_std := sqrt(GREATEST(v_sum_sq / p_period - v_middle * v_middle, 0));
        dt := v_dts[i];
        value := CASE p_series
            WHEN 'MIDDLE' THEN v_middle
            WHEN 'UPPER' THEN v_middle + p_std_dev * v_std
            WHEN 'LOWER' THEN v_middle - p_std_dev * v_std
            WHEN 'BANDWIDTH' THEN CASE WHEN v_middle = 0 THEN NULL ELSE (2 * p_std_dev * v_std) / v_middle * 100 END
        END;
        RETURN NEXT;
    END LOOP;
END;
$$;

-- ATR array
CREATE OR REPLACE FUNCTION calc_ind_atr_array(
    p_period INTEGER,
    p_series VARCHAR,
    p_security_id INTEGER,
    p_timeframe_id INTEGER,
    p_point_count INTEGER DEFAULT 100,
    p_end_dt TIMESTAMP DEFAULT NULL
)
RETURNS TABLE (dt TIMESTAMP, value NUMERIC)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_end TIMESTAMP;
    v_bars INTEGER;
    v_dts TIMESTAMP[];
    v_highs NUMERIC[];
    v_lows NUMERIC[];
    v_closes NUMERIC[];
    v_n INTEGER;
    v_atr NUMERIC;
    v_tr NUMERIC;
    v_tr_high NUMERIC;
    v_tr_low NUMERIC;
    v_tr_close NUMERIC;
    i INTEGER;
    v_start INTEGER;
BEGIN
    IF p_series NOT IN ('ATR', 'ATR_PCT') THEN RETURN; END IF;

    v_end := ind_resolve_end_dt(p_security_id, p_timeframe_id, p_end_dt);
    IF v_end IS NULL THEN RETURN; END IF;
    v_bars := ind_warmup_bars(p_period, p_point_count);

    SELECT array_agg(x.dt ORDER BY x.dt),
           array_agg(x.high_price ORDER BY x.dt),
           array_agg(x.low_price ORDER BY x.dt),
           array_agg(x.close_price ORDER BY x.dt),
           COUNT(*)::INTEGER
    INTO v_dts, v_highs, v_lows, v_closes, v_n
    FROM (
        SELECT p.dt, p.high_price, p.low_price, p.close_price FROM prices p
        WHERE p.security_id = p_security_id AND p.timeframe_id = p_timeframe_id AND p.dt <= v_end
        ORDER BY p.dt DESC LIMIT v_bars
    ) x;

    IF v_n IS NULL OR v_n < p_period + 1 THEN RETURN; END IF;

    v_atr := 0;
    v_start := GREATEST(p_period, v_n - p_point_count + 1);
    FOR i IN 2 .. v_n LOOP
        v_tr_high := v_highs[i] - v_lows[i];
        v_tr_low := ABS(v_highs[i] - v_closes[i - 1]);
        v_tr_close := ABS(v_lows[i] - v_closes[i - 1]);
        v_tr := GREATEST(v_tr_high, v_tr_low, v_tr_close);
        IF i <= p_period THEN
            v_atr := v_atr + v_tr;
            IF i = p_period THEN v_atr := v_atr / p_period; END IF;
        ELSE
            v_atr := (v_atr * (p_period - 1) + v_tr) / p_period;
        END IF;
        IF i >= v_start AND i >= p_period THEN
            dt := v_dts[i];
            value := CASE p_series
                WHEN 'ATR' THEN v_atr
                WHEN 'ATR_PCT' THEN CASE WHEN v_closes[i] = 0 THEN NULL ELSE v_atr / v_closes[i] * 100 END
            END;
            RETURN NEXT;
        END IF;
    END LOOP;
END;
$$;

-- Stochastic array
CREATE OR REPLACE FUNCTION calc_ind_stoch_array(
    p_k_period INTEGER,
    p_d_period INTEGER,
    p_smooth INTEGER,
    p_series VARCHAR,
    p_security_id INTEGER,
    p_timeframe_id INTEGER,
    p_point_count INTEGER DEFAULT 100,
    p_end_dt TIMESTAMP DEFAULT NULL
)
RETURNS TABLE (dt TIMESTAMP, value NUMERIC)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_end TIMESTAMP;
    v_bars INTEGER;
    v_dts TIMESTAMP[];
    v_highs NUMERIC[];
    v_lows NUMERIC[];
    v_closes NUMERIC[];
    v_n INTEGER;
    v_k_values NUMERIC[];
    v_stoch_k NUMERIC;
    v_stoch_d NUMERIC;
    i INTEGER;
    j INTEGER;
    v_lowest NUMERIC;
    v_highest NUMERIC;
    v_sum NUMERIC;
    v_start INTEGER;
BEGIN
    IF p_series NOT IN ('K', 'D') THEN RETURN; END IF;

    v_end := ind_resolve_end_dt(p_security_id, p_timeframe_id, p_end_dt);
    IF v_end IS NULL THEN RETURN; END IF;
    v_bars := ind_warmup_bars(p_k_period + p_d_period, p_point_count);

    SELECT array_agg(x.dt ORDER BY x.dt),
           array_agg(x.high_price ORDER BY x.dt),
           array_agg(x.low_price ORDER BY x.dt),
           array_agg(x.close_price ORDER BY x.dt),
           COUNT(*)::INTEGER
    INTO v_dts, v_highs, v_lows, v_closes, v_n
    FROM (
        SELECT p.dt, p.high_price, p.low_price, p.close_price FROM prices p
        WHERE p.security_id = p_security_id AND p.timeframe_id = p_timeframe_id AND p.dt <= v_end
        ORDER BY p.dt DESC LIMIT v_bars
    ) x;

    IF v_n IS NULL OR v_n < p_k_period THEN RETURN; END IF;

    v_k_values := ARRAY[]::NUMERIC[];
    FOR i IN p_k_period .. v_n LOOP
        v_lowest := v_lows[i];
        v_highest := v_highs[i];
        FOR j IN i - p_k_period + 1 .. i LOOP
            IF v_lows[j] < v_lowest THEN v_lowest := v_lows[j]; END IF;
            IF v_highs[j] > v_highest THEN v_highest := v_highs[j]; END IF;
        END LOOP;
        IF v_highest = v_lowest THEN v_stoch_k := 50;
        ELSE v_stoch_k := (v_closes[i] - v_lowest) / (v_highest - v_lowest) * 100;
        END IF;
        v_k_values := array_append(v_k_values, v_stoch_k);
    END LOOP;

    v_start := GREATEST(1, array_length(v_k_values, 1) - p_point_count + 1);
    FOR i IN v_start .. array_length(v_k_values, 1) LOOP
        dt := v_dts[p_k_period + i - 1];
        IF p_series = 'K' THEN
            value := v_k_values[i];
            RETURN NEXT;
        ELSE
            v_sum := 0;
            FOR j IN GREATEST(1, i - p_d_period + 1) .. i LOOP
                v_sum := v_sum + v_k_values[j];
            END LOOP;
            value := v_sum / LEAST(p_d_period, i);
            RETURN NEXT;
        END IF;
    END LOOP;
END;
$$;

-- ============================================
-- Многочленные индикаторы: парсинг и вычисление
-- Синтаксис по MultiLogic PolynomialIndicators:
--   pp oo hh ll vv — OHLCV; (a; b; c) — ядро; * — свёртка; # /# — покомпонентно; @CODE — индикатор
-- ============================================

CREATE OR REPLACE FUNCTION poly_is_formula(p_formula TEXT)
RETURNS BOOLEAN
LANGUAGE sql IMMUTABLE AS $$
    SELECT COALESCE(btrim(p_formula), '') <> ''
       AND btrim(p_formula) !~* '^calc_';
$$;

CREATE OR REPLACE FUNCTION poly_len(p_arr NUMERIC[])
RETURNS INTEGER
LANGUAGE sql IMMUTABLE AS $$
    SELECT COALESCE(array_length(p_arr, 1), 0);
$$;

CREATE OR REPLACE FUNCTION poly_extend(p_arr NUMERIC[], p_len INTEGER)
RETURNS NUMERIC[]
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_n INTEGER := poly_len(p_arr);
    v_out NUMERIC[];
    i INTEGER;
BEGIN
    IF p_len <= 0 THEN RETURN ARRAY[]::NUMERIC[]; END IF;
    IF v_n = 0 THEN RETURN array_fill(0::NUMERIC, ARRAY[p_len]); END IF;
    IF v_n = 1 THEN RETURN array_fill(p_arr[1], ARRAY[p_len]); END IF;
    IF v_n >= p_len THEN RETURN p_arr[1:p_len]; END IF;
    v_out := p_arr;
    FOR i IN v_n + 1 .. p_len LOOP
        v_out := array_append(v_out, 0::NUMERIC);
    END LOOP;
    RETURN v_out;
END;
$$;

CREATE OR REPLACE FUNCTION poly_align2(
    p_a NUMERIC[],
    p_b NUMERIC[]
)
RETURNS TABLE (a NUMERIC[], b NUMERIC[])
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_len INTEGER;
BEGIN
    v_len := GREATEST(poly_len(p_a), poly_len(p_b));
    a := poly_extend(p_a, v_len);
    b := poly_extend(p_b, v_len);
    RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION poly_add(p_a NUMERIC[], p_b NUMERIC[])
RETURNS NUMERIC[]
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_row RECORD;
    v_i INTEGER;
    v_out NUMERIC[];
BEGIN
    SELECT * INTO v_row FROM poly_align2(p_a, p_b);
    v_out := ARRAY[]::NUMERIC[];
    FOR v_i IN 1 .. poly_len(v_row.a) LOOP
        v_out := array_append(v_out, COALESCE(v_row.a[v_i], 0) + COALESCE(v_row.b[v_i], 0));
    END LOOP;
    RETURN v_out;
END;
$$;

CREATE OR REPLACE FUNCTION poly_sub(p_a NUMERIC[], p_b NUMERIC[])
RETURNS NUMERIC[]
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_row RECORD;
    v_i INTEGER;
    v_out NUMERIC[];
BEGIN
    SELECT * INTO v_row FROM poly_align2(p_a, p_b);
    v_out := ARRAY[]::NUMERIC[];
    FOR v_i IN 1 .. poly_len(v_row.a) LOOP
        v_out := array_append(v_out, COALESCE(v_row.a[v_i], 0) - COALESCE(v_row.b[v_i], 0));
    END LOOP;
    RETURN v_out;
END;
$$;

CREATE OR REPLACE FUNCTION poly_neg(p_a NUMERIC[])
RETURNS NUMERIC[]
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_i INTEGER;
    v_out NUMERIC[] := ARRAY[]::NUMERIC[];
BEGIN
    FOR v_i IN 1 .. poly_len(p_a) LOOP
        v_out := array_append(v_out, -p_a[v_i]);
    END LOOP;
    RETURN v_out;
END;
$$;

CREATE OR REPLACE FUNCTION poly_comp_mul(p_a NUMERIC[], p_b NUMERIC[])
RETURNS NUMERIC[]
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_row RECORD;
    v_i INTEGER;
    v_out NUMERIC[];
BEGIN
    SELECT * INTO v_row FROM poly_align2(p_a, p_b);
    v_out := ARRAY[]::NUMERIC[];
    FOR v_i IN 1 .. poly_len(v_row.a) LOOP
        v_out := array_append(v_out, COALESCE(v_row.a[v_i], 0) * COALESCE(v_row.b[v_i], 0));
    END LOOP;
    RETURN v_out;
END;
$$;

CREATE OR REPLACE FUNCTION poly_comp_div(p_a NUMERIC[], p_b NUMERIC[])
RETURNS NUMERIC[]
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_row RECORD;
    v_i INTEGER;
    v_out NUMERIC[];
    v_den NUMERIC;
BEGIN
    SELECT * INTO v_row FROM poly_align2(p_a, p_b);
    v_out := ARRAY[]::NUMERIC[];
    FOR v_i IN 1 .. poly_len(v_row.a) LOOP
        v_den := COALESCE(v_row.b[v_i], 0);
        IF v_den = 0 THEN
            v_out := array_append(v_out, NULL);
        ELSE
            v_out := array_append(v_out, COALESCE(v_row.a[v_i], 0) / v_den);
        END IF;
    END LOOP;
    RETURN v_out;
END;
$$;

CREATE OR REPLACE FUNCTION poly_convolve(p_a NUMERIC[], p_b NUMERIC[])
RETURNS NUMERIC[]
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_na INTEGER := poly_len(p_a);
    v_nb INTEGER := poly_len(p_b);
    v_out NUMERIC[];
    i INTEGER;
    j INTEGER;
    v_sum NUMERIC;
BEGIN
    IF v_na = 0 OR v_nb = 0 THEN RETURN ARRAY[]::NUMERIC[]; END IF;
    v_out := array_fill(0::NUMERIC, ARRAY[v_na]);
    FOR i IN 1 .. v_na LOOP
        v_sum := 0;
        FOR j IN 1 .. v_nb LOOP
            IF i - j + 1 >= 1 AND i - j + 1 <= v_na THEN
                v_sum := v_sum + p_a[i - j + 1] * p_b[j];
            END IF;
        END LOOP;
        v_out[i] := v_sum;
    END LOOP;
    RETURN v_out;
END;
$$;

CREATE OR REPLACE FUNCTION poly_delta_kernel(p_k INTEGER)
RETURNS NUMERIC[]
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_out NUMERIC[];
    i INTEGER;
BEGIN
    IF p_k < 0 THEN
        RAISE EXCEPTION 'poly_delta_kernel: k must be >= 0, got %', p_k;
    END IF;
    v_out := array_fill(0::NUMERIC, ARRAY[p_k + 1]);
    v_out[p_k + 1] := 1;
    RETURN v_out;
END;
$$;

CREATE OR REPLACE FUNCTION poly_ctx_period(p_ctx JSONB)
RETURNS INTEGER
LANGUAGE sql IMMUTABLE AS $$
    SELECT GREATEST(COALESCE(NULLIF(p_ctx ->> 'param_period', '')::INTEGER, 20), 2);
$$;

CREATE OR REPLACE FUNCTION poly_pp_from_ctx(p_ctx JSONB)
RETURNS NUMERIC[]
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_ctx ? 'm_pp' THEN
        RETURN ARRAY(SELECT jsonb_array_elements_text(p_ctx -> 'm_pp')::NUMERIC);
    END IF;
    RAISE EXCEPTION 'poly_eval: pp not loaded in context';
END;
$$;

CREATE OR REPLACE FUNCTION poly_build_sma_kernel(p_period INTEGER)
RETURNS NUMERIC[]
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_n INTEGER := GREATEST(COALESCE(p_period, 20), 1);
    v_out NUMERIC[] := ARRAY[]::NUMERIC[];
    i INTEGER;
BEGIN
    FOR i IN 1 .. v_n LOOP
        v_out := array_append(v_out, 1.0 / v_n);
    END LOOP;
    RETURN v_out;
END;
$$;

CREATE OR REPLACE FUNCTION poly_build_ema_kernel(p_period INTEGER)
RETURNS NUMERIC[]
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_n INTEGER := GREATEST(COALESCE(p_period, 20), 2);
    v_alpha NUMERIC := 2.0 / (v_n + 1);
    v_len INTEGER := GREATEST(v_n * 4, 24);
    v_out NUMERIC[] := ARRAY[]::NUMERIC[];
    i INTEGER;
BEGIN
    FOR i IN 0 .. v_len - 1 LOOP
        v_out := array_append(v_out, v_alpha * power(1 - v_alpha, i));
    END LOOP;
    RETURN v_out;
END;
$$;

CREATE OR REPLACE FUNCTION poly_tokenize(p_formula TEXT)
RETURNS TEXT[]
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_src TEXT := COALESCE(p_formula, '');
    v_len INTEGER := length(v_src);
    v_i INTEGER := 1;
    v_c TEXT;
    v_tokens TEXT[] := ARRAY[]::TEXT[];
    v_buf TEXT;
    v_num TEXT;
    v_peek TEXT;
    v_j INTEGER;
BEGIN
    WHILE v_i <= v_len LOOP
        v_c := substr(v_src, v_i, 1);
        IF v_c ~ '\s' THEN
            v_i := v_i + 1;
            CONTINUE;
        END IF;

        IF v_c = '(' THEN
            v_j := v_i + 1;
            WHILE v_j <= v_len AND substr(v_src, v_j, 1) ~ '\s' LOOP v_j := v_j + 1; END LOOP;
            IF v_j <= v_len AND substr(v_src, v_j, 1) ~ '[0-9.\-+]' THEN
                v_buf := '';
                v_j := v_i + 1;
                WHILE v_j <= v_len LOOP
                    v_peek := substr(v_src, v_j, 1);
                    IF v_peek ~ '[0-9.\-+eE,; ]' THEN
                        IF v_peek !~ '\s' THEN v_buf := v_buf || v_peek; END IF;
                        v_j := v_j + 1;
                    ELSE
                        EXIT;
                    END IF;
                END LOOP;
                IF v_j <= v_len AND substr(v_src, v_j, 1) = ')'
                   AND (position(';' IN v_buf) > 0 OR position(',' IN v_buf) > 0) THEN
                    v_buf := replace(replace(v_buf, ';', ','), ' ', '');
                    v_tokens := array_append(v_tokens, 'VEC:' || v_buf);
                    v_i := v_j + 1;
                    CONTINUE;
                END IF;
            END IF;
            v_tokens := array_append(v_tokens, 'LP');
            v_i := v_i + 1;
            CONTINUE;
        END IF;

        IF v_c = ')' THEN
            v_tokens := array_append(v_tokens, 'RP');
            v_i := v_i + 1;
            CONTINUE;
        END IF;

        IF v_c = '@' THEN
            v_buf := '';
            v_i := v_i + 1;
            WHILE v_i <= v_len LOOP
                v_peek := substr(v_src, v_i, 1);
                EXIT WHEN v_peek !~ '[A-Za-z0-9_]';
                v_buf := v_buf || v_peek;
                v_i := v_i + 1;
            END LOOP;
            IF v_buf = '' THEN
                RAISE EXCEPTION 'poly_tokenize: empty indicator reference at position %', v_i;
            END IF;
            IF v_i <= v_len AND substr(v_src, v_i, 1) = ':' THEN
                v_i := v_i + 1;
                v_num := '';
                WHILE v_i <= v_len LOOP
                    v_peek := substr(v_src, v_i, 1);
                    EXIT WHEN v_peek !~ '[A-Za-z0-9_]';
                    v_num := v_num || v_peek;
                    v_i := v_i + 1;
                END LOOP;
                v_tokens := array_append(v_tokens, 'IND:' || upper(v_buf) || ':' || upper(v_num));
            ELSE
                v_tokens := array_append(v_tokens, 'IND:' || upper(v_buf));
            END IF;
            CONTINUE;
        END IF;

        IF v_c ~ '[A-Za-z]' THEN
            v_buf := v_c;
            v_i := v_i + 1;
            WHILE v_i <= v_len LOOP
                v_peek := substr(v_src, v_i, 1);
                EXIT WHEN v_peek !~ '[A-Za-z0-9_]';
                v_buf := v_buf || v_peek;
                v_i := v_i + 1;
            END LOOP;
            IF lower(v_buf) IN ('dd', 'delta') THEN
                WHILE v_i <= v_len AND substr(v_src, v_i, 1) ~ '\s' LOOP v_i := v_i + 1; END LOOP;
                IF v_i > v_len OR substr(v_src, v_i, 1) <> '(' THEN
                    RAISE EXCEPTION 'poly_tokenize: expected ( after %', v_buf;
                END IF;
                v_i := v_i + 1;
                v_num := '';
                WHILE v_i <= v_len LOOP
                    v_peek := substr(v_src, v_i, 1);
                    IF v_peek ~ '[0-9]' THEN
                        v_num := v_num || v_peek;
                        v_i := v_i + 1;
                    ELSIF v_peek ~ '\s' THEN
                        v_i := v_i + 1;
                    ELSE
                        EXIT;
                    END IF;
                END LOOP;
                IF v_i > v_len OR substr(v_src, v_i, 1) <> ')' OR v_num = '' THEN
                    RAISE EXCEPTION 'poly_tokenize: invalid dd(k) at position %', v_i;
                END IF;
                v_tokens := array_append(v_tokens, 'DD:' || v_num);
                v_i := v_i + 1;
                CONTINUE;
            END IF;
            v_tokens := array_append(v_tokens, 'ID:' || lower(v_buf));
            CONTINUE;
        END IF;

        IF v_c ~ '[0-9.]' OR (v_c = '-' AND v_i < v_len AND substr(v_src, v_i + 1, 1) ~ '[0-9.]') THEN
            v_num := v_c;
            v_i := v_i + 1;
            WHILE v_i <= v_len AND substr(v_src, v_i, 1) ~ '[0-9.eE+-]' LOOP
                v_num := v_num || substr(v_src, v_i, 1);
                v_i := v_i + 1;
            END LOOP;
            v_tokens := array_append(v_tokens, 'NUM:' || v_num);
            CONTINUE;
        END IF;

        IF v_c = '/' AND v_i < v_len AND substr(v_src, v_i + 1, 1) = '#' THEN
            v_tokens := array_append(v_tokens, 'OP:/#');
            v_i := v_i + 2;
            CONTINUE;
        END IF;

        IF v_c IN ('+', '-', '*', '#') THEN
            v_tokens := array_append(v_tokens, 'OP:' || v_c);
            v_i := v_i + 1;
            CONTINUE;
        END IF;

        RAISE EXCEPTION 'poly_tokenize: unexpected character % at position %', v_c, v_i;
    END LOOP;
    RETURN v_tokens;
END;
$$;

CREATE OR REPLACE FUNCTION poly_peek_token(p_tokens TEXT[], p_pos INTEGER)
RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN p_pos >= 1 AND p_pos <= COALESCE(array_length(p_tokens, 1), 0)
                THEN p_tokens[p_pos] ELSE NULL END;
$$;

CREATE OR REPLACE FUNCTION poly_parse_atom(
    p_tokens TEXT[],
    p_pos INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_t TEXT;
    v_parts TEXT[];
    v_vec NUMERIC[];
    v_inner JSONB;
    i INTEGER;
    v_pos INTEGER := p_pos;
BEGIN
    v_t := poly_peek_token(p_tokens, v_pos);
    IF v_t IS NULL THEN
        RAISE EXCEPTION 'poly_parse: unexpected end of formula';
    END IF;

    IF v_t = 'LP' THEN
        v_pos := v_pos + 1;
        v_inner := poly_parse_add(p_tokens, v_pos);
        v_pos := (v_inner ->> 'p')::INTEGER;
        IF poly_peek_token(p_tokens, v_pos) <> 'RP' THEN
            RAISE EXCEPTION 'poly_parse: expected )';
        END IF;
        RETURN jsonb_build_object('n', v_inner -> 'n', 'p', v_pos + 1);
    END IF;

    IF v_t LIKE 'ID:%' AND lower(substr(v_t, 4)) IN ('sma', 'ema', 'ww') THEN
        v_pos := v_pos + 1;
        IF poly_peek_token(p_tokens, v_pos) <> 'LP' THEN
            RAISE EXCEPTION 'poly_parse: expected ( after %', substr(v_t, 4);
        END IF;
        v_pos := v_pos + 1;
        IF poly_peek_token(p_tokens, v_pos) = 'RP' THEN
            RETURN jsonb_build_object(
                'n', jsonb_build_object('fn', lower(substr(v_t, 4)), 'has_arg', FALSE),
                'p', v_pos + 1
            );
        END IF;
        v_inner := poly_parse_add(p_tokens, v_pos);
        v_pos := (v_inner ->> 'p')::INTEGER;
        IF poly_peek_token(p_tokens, v_pos) <> 'RP' THEN
            RAISE EXCEPTION 'poly_parse: expected ) after %()', substr(v_t, 4);
        END IF;
        RETURN jsonb_build_object(
            'n', jsonb_build_object('fn', lower(substr(v_t, 4)), 'has_arg', TRUE, 'arg', v_inner -> 'n'),
            'p', v_pos + 1
        );
    END IF;

    IF v_t LIKE 'ID:%' THEN
        RETURN jsonb_build_object('n', jsonb_build_object('var', substr(v_t, 4)), 'p', v_pos + 1);
    END IF;

    IF v_t LIKE 'NUM:%' THEN
        RETURN jsonb_build_object('n', jsonb_build_object('num', substr(v_t, 5)::NUMERIC), 'p', v_pos + 1);
    END IF;

    IF v_t LIKE 'VEC:%' THEN
        v_parts := string_to_array(substr(v_t, 5), ',');
        v_vec := ARRAY[]::NUMERIC[];
        FOR i IN 1 .. COALESCE(array_length(v_parts, 1), 0) LOOP
            v_vec := array_append(v_vec, btrim(v_parts[i])::NUMERIC);
        END LOOP;
        RETURN jsonb_build_object('n', jsonb_build_object('vec', to_jsonb(v_vec)), 'p', v_pos + 1);
    END IF;

    IF v_t LIKE 'DD:%' THEN
        RETURN jsonb_build_object('n', jsonb_build_object('dd', (substr(v_t, 4))::INTEGER), 'p', v_pos + 1);
    END IF;

    IF v_t LIKE 'IND:%' THEN
        v_parts := string_to_array(substr(v_t, 5), ':');
        IF array_length(v_parts, 1) = 1 THEN
            RETURN jsonb_build_object(
                'n', jsonb_build_object('ind', jsonb_build_object('code', v_parts[1], 'series', NULL)),
                'p', v_pos + 1
            );
        END IF;
        RETURN jsonb_build_object(
            'n', jsonb_build_object('ind', jsonb_build_object('code', v_parts[1], 'series', v_parts[2])),
            'p', v_pos + 1
        );
    END IF;

    RAISE EXCEPTION 'poly_parse: unexpected token %', v_t;
END;
$$;

CREATE OR REPLACE FUNCTION poly_parse_unary(
    p_tokens TEXT[],
    p_pos INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_inner JSONB;
BEGIN
    IF poly_peek_token(p_tokens, p_pos) = 'OP:-' THEN
        v_inner := poly_parse_unary(p_tokens, p_pos + 1);
        RETURN jsonb_build_object(
            'n', jsonb_build_object('op', 'neg', 'arg', v_inner -> 'n'),
            'p', (v_inner ->> 'p')::INTEGER
        );
    END IF;
    RETURN poly_parse_atom(p_tokens, p_pos);
END;
$$;

CREATE OR REPLACE FUNCTION poly_parse_comp(
    p_tokens TEXT[],
    p_pos INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_left JSONB;
    v_right JSONB;
    v_op TEXT;
    v_pos INTEGER;
BEGIN
    v_left := poly_parse_unary(p_tokens, p_pos);
    v_pos := (v_left ->> 'p')::INTEGER;
    v_left := v_left -> 'n';

    WHILE poly_peek_token(p_tokens, v_pos) IN ('OP:#', 'OP:/#') LOOP
        v_op := substr(poly_peek_token(p_tokens, v_pos), 4);
        v_pos := v_pos + 1;
        v_right := poly_parse_unary(p_tokens, v_pos);
        v_pos := (v_right ->> 'p')::INTEGER;
        IF v_op = '#' THEN
            v_left := jsonb_build_object('op', 'cmul', 'left', v_left, 'right', v_right -> 'n');
        ELSE
            v_left := jsonb_build_object('op', 'cdiv', 'left', v_left, 'right', v_right -> 'n');
        END IF;
    END LOOP;

    RETURN jsonb_build_object('n', v_left, 'p', v_pos);
END;
$$;

CREATE OR REPLACE FUNCTION poly_parse_conv(
    p_tokens TEXT[],
    p_pos INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_left JSONB;
    v_right JSONB;
    v_pos INTEGER;
BEGIN
    v_left := poly_parse_comp(p_tokens, p_pos);
    v_pos := (v_left ->> 'p')::INTEGER;
    v_left := v_left -> 'n';

    WHILE poly_peek_token(p_tokens, v_pos) = 'OP:*' LOOP
        v_pos := v_pos + 1;
        v_right := poly_parse_comp(p_tokens, v_pos);
        v_pos := (v_right ->> 'p')::INTEGER;
        v_left := jsonb_build_object('op', 'conv', 'left', v_left, 'right', v_right -> 'n');
    END LOOP;

    RETURN jsonb_build_object('n', v_left, 'p', v_pos);
END;
$$;

CREATE OR REPLACE FUNCTION poly_parse_add(
    p_tokens TEXT[],
    p_pos INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_left JSONB;
    v_right JSONB;
    v_op TEXT;
    v_pos INTEGER;
BEGIN
    v_left := poly_parse_conv(p_tokens, p_pos);
    v_pos := (v_left ->> 'p')::INTEGER;
    v_left := v_left -> 'n';

    WHILE poly_peek_token(p_tokens, v_pos) IN ('OP:+', 'OP:-') LOOP
        v_op := substr(poly_peek_token(p_tokens, v_pos), 4);
        v_pos := v_pos + 1;
        v_right := poly_parse_conv(p_tokens, v_pos);
        v_pos := (v_right ->> 'p')::INTEGER;
        IF v_op = '+' THEN
            v_left := jsonb_build_object('op', 'add', 'left', v_left, 'right', v_right -> 'n');
        ELSE
            v_left := jsonb_build_object('op', 'sub', 'left', v_left, 'right', v_right -> 'n');
        END IF;
    END LOOP;

    RETURN jsonb_build_object('n', v_left, 'p', v_pos);
END;
$$;

CREATE OR REPLACE FUNCTION poly_parse(p_formula TEXT)
RETURNS JSONB
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_tokens TEXT[];
    v_pos INTEGER := 1;
    v_step JSONB;
BEGIN
    v_tokens := poly_tokenize(p_formula);
    IF COALESCE(array_length(v_tokens, 1), 0) = 0 THEN
        RAISE EXCEPTION 'poly_parse: empty formula';
    END IF;
    v_step := poly_parse_add(v_tokens, v_pos);
    v_pos := (v_step ->> 'p')::INTEGER;
    IF v_pos <= COALESCE(array_length(v_tokens, 1), 0) THEN
        RAISE EXCEPTION 'poly_parse: trailing tokens at position % (%)', v_pos, v_tokens[v_pos];
    END IF;
    RETURN v_step -> 'n';
END;
$$;

CREATE OR REPLACE FUNCTION poly_load_market_array(
    p_field TEXT,
    p_security_id INTEGER,
    p_timeframe_id INTEGER,
    p_end_dt TIMESTAMP,
    p_bars INTEGER
)
RETURNS NUMERIC[]
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_arr NUMERIC[];
    v_field TEXT := lower(btrim(p_field));
BEGIN
    SELECT array_agg(x.v ORDER BY x.dt)
    INTO v_arr
    FROM (
        SELECT p.dt,
               CASE v_field
                   WHEN 'pp' THEN p.close_price
                   WHEN 'oo' THEN p.open_price
                   WHEN 'hh' THEN p.high_price
                   WHEN 'll' THEN p.low_price
                   WHEN 'vv' THEN p.volume::NUMERIC
                   ELSE NULL
               END AS v
        FROM prices p
        WHERE p.security_id = p_security_id
          AND p.timeframe_id = p_timeframe_id
          AND p.dt <= p_end_dt
        ORDER BY p.dt DESC
        LIMIT p_bars
    ) x;
    RETURN COALESCE(v_arr, ARRAY[]::NUMERIC[]);
END;
$$;

CREATE OR REPLACE FUNCTION poly_load_market_dts(
    p_security_id INTEGER,
    p_timeframe_id INTEGER,
    p_end_dt TIMESTAMP,
    p_bars INTEGER
)
RETURNS TIMESTAMP[]
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(array_agg(x.dt ORDER BY x.dt), ARRAY[]::TIMESTAMP[])
    FROM (
        SELECT p.dt
        FROM prices p
        WHERE p.security_id = p_security_id
          AND p.timeframe_id = p_timeframe_id
          AND p.dt <= p_end_dt
        ORDER BY p.dt DESC
        LIMIT p_bars
    ) x;
$$;

CREATE OR REPLACE FUNCTION poly_load_indicator_array(
    p_indicator_code TEXT,
    p_series TEXT,
    p_security_id INTEGER,
    p_timeframe_id INTEGER,
    p_end_dt TIMESTAMP,
    p_bars INTEGER,
    p_period INTEGER DEFAULT NULL,
    p_fast_period INTEGER DEFAULT NULL,
    p_slow_period INTEGER DEFAULT NULL,
    p_signal_period INTEGER DEFAULT NULL,
    p_std_dev NUMERIC DEFAULT NULL,
    p_k_period INTEGER DEFAULT NULL,
    p_d_period INTEGER DEFAULT NULL,
    p_smooth INTEGER DEFAULT NULL,
    p_target_dts TIMESTAMP[] DEFAULT NULL
)
RETURNS NUMERIC[]
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_series TEXT := COALESCE(NULLIF(btrim(p_series), ''), 'VALUE');
    v_map JSONB := '{}'::JSONB;
    v_arr NUMERIC[] := ARRAY[]::NUMERIC[];
    v_dt TIMESTAMP;
    v_val NUMERIC;
    i INTEGER;
BEGIN
    FOR v_dt, v_val IN
        SELECT t.dt, t.value
        FROM calc_indicator_series_array(
            p_indicator_code, v_series,
            p_security_id, p_timeframe_id, p_bars, p_end_dt,
            p_period, p_fast_period, p_slow_period, p_signal_period,
            p_std_dev, p_k_period, p_d_period, p_smooth
        ) t
    LOOP
        v_map := v_map || jsonb_build_object(to_char(v_dt, 'YYYY-MM-DD HH24:MI:SS'), to_jsonb(v_val));
    END LOOP;

    IF p_target_dts IS NULL THEN
        SELECT COALESCE(array_agg((v_map ->> to_char(d, 'YYYY-MM-DD HH24:MI:SS'))::NUMERIC ORDER BY ord), ARRAY[]::NUMERIC[])
        INTO v_arr
        FROM unnest(
            (SELECT poly_load_market_dts(p_security_id, p_timeframe_id, p_end_dt, p_bars))
        ) WITH ORDINALITY AS t(d, ord);
        RETURN v_arr;
    END IF;

    FOR i IN 1 .. COALESCE(array_length(p_target_dts, 1), 0) LOOP
        v_dt := p_target_dts[i];
        v_val := (v_map ->> to_char(v_dt, 'YYYY-MM-DD HH24:MI:SS'))::NUMERIC;
        v_arr := array_append(v_arr, v_val);
    END LOOP;
    RETURN v_arr;
END;
$$;

CREATE OR REPLACE FUNCTION poly_eval_node(
    p_node JSONB,
    p_ctx JSONB
)
RETURNS NUMERIC[]
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_op TEXT;
    v_var TEXT;
    v_num NUMERIC;
    v_vec NUMERIC[];
    v_left NUMERIC[];
    v_right NUMERIC[];
    v_ind JSONB;
    v_code TEXT;
    v_series TEXT;
    v_fn TEXT;
    v_period INTEGER;
    v_arg NUMERIC[];
    i INTEGER;
BEGIN
    IF p_node ? 'num' THEN
        RETURN ARRAY[(p_node ->> 'num')::NUMERIC];
    END IF;

    IF p_node ? 'vec' THEN
        v_vec := ARRAY[]::NUMERIC[];
        FOR i IN 0 .. jsonb_array_length(p_node -> 'vec') - 1 LOOP
            v_vec := array_append(v_vec, ((p_node -> 'vec' ->> i)::NUMERIC));
        END LOOP;
        RETURN v_vec;
    END IF;

    IF p_node ? 'dd' THEN
        RETURN poly_delta_kernel((p_node ->> 'dd')::INTEGER);
    END IF;

    IF p_node ? 'fn' THEN
        v_fn := lower(p_node ->> 'fn');
        v_period := poly_ctx_period(p_ctx);
        IF COALESCE((p_node ->> 'has_arg')::BOOLEAN, FALSE) THEN
            v_arg := poly_eval_node(p_node -> 'arg', p_ctx);
        ELSE
            v_arg := NULL;
        END IF;
        CASE v_fn
            WHEN 'ww' THEN
                RETURN poly_build_sma_kernel(v_period);
            WHEN 'sma' THEN
                RETURN poly_convolve(
                    COALESCE(v_arg, poly_pp_from_ctx(p_ctx)),
                    poly_build_sma_kernel(v_period)
                );
            WHEN 'ema' THEN
                RETURN poly_convolve(
                    COALESCE(v_arg, poly_pp_from_ctx(p_ctx)),
                    poly_build_ema_kernel(v_period)
                );
            ELSE
                RAISE EXCEPTION 'poly_eval: unknown function %', v_fn;
        END CASE;
    END IF;

    IF p_node ? 'var' THEN
        v_var := p_node ->> 'var';
        IF p_ctx ? ('m_' || v_var) THEN
            v_vec := ARRAY(SELECT jsonb_array_elements_text(p_ctx -> ('m_' || v_var))::NUMERIC);
            RETURN v_vec;
        END IF;
        RAISE EXCEPTION 'poly_eval: unknown market variable %', v_var;
    END IF;

    IF p_node ? 'ind' THEN
        v_ind := p_node -> 'ind';
        v_code := v_ind ->> 'code';
        v_series := v_ind ->> 'series';
        RETURN poly_load_indicator_array(
            v_code, v_series,
            (p_ctx ->> 'security_id')::INTEGER,
            (p_ctx ->> 'timeframe_id')::INTEGER,
            (p_ctx ->> 'end_dt')::TIMESTAMP,
            (p_ctx ->> 'bars')::INTEGER,
            NULLIF(p_ctx ->> 'param_period', '')::INTEGER,
            NULLIF(p_ctx ->> 'param_fast_period', '')::INTEGER,
            NULLIF(p_ctx ->> 'param_slow_period', '')::INTEGER,
            NULLIF(p_ctx ->> 'param_signal_period', '')::INTEGER,
            NULLIF(p_ctx ->> 'param_std_dev', '')::NUMERIC,
            NULLIF(p_ctx ->> 'param_k_period', '')::INTEGER,
            NULLIF(p_ctx ->> 'param_d_period', '')::INTEGER,
            NULLIF(p_ctx ->> 'param_smooth', '')::INTEGER,
            ARRAY(SELECT jsonb_array_elements_text(p_ctx -> 'dts')::TIMESTAMP)
        );
    END IF;

    IF p_node ? 'op' THEN
        v_op := p_node ->> 'op';
        IF v_op = 'neg' THEN
            RETURN poly_neg(poly_eval_node(p_node -> 'arg', p_ctx));
        END IF;
        v_left := poly_eval_node(p_node -> 'left', p_ctx);
        v_right := poly_eval_node(p_node -> 'right', p_ctx);
        CASE v_op
            WHEN 'add' THEN RETURN poly_add(v_left, v_right);
            WHEN 'sub' THEN RETURN poly_sub(v_left, v_right);
            WHEN 'conv' THEN RETURN poly_convolve(v_left, v_right);
            WHEN 'cmul' THEN RETURN poly_comp_mul(v_left, v_right);
            WHEN 'cdiv' THEN RETURN poly_comp_div(v_left, v_right);
            ELSE RAISE EXCEPTION 'poly_eval: unknown op %', v_op;
        END CASE;
    END IF;

    RAISE EXCEPTION 'poly_eval: invalid node %', p_node;
END;
$$;

CREATE OR REPLACE FUNCTION calc_poly_formula_array(
    p_formula TEXT,
    p_series VARCHAR,
    p_security_id INTEGER,
    p_timeframe_id INTEGER,
    p_point_count INTEGER DEFAULT 100,
    p_end_dt TIMESTAMP DEFAULT NULL,
    p_period INTEGER DEFAULT NULL,
    p_fast_period INTEGER DEFAULT NULL,
    p_slow_period INTEGER DEFAULT NULL,
    p_signal_period INTEGER DEFAULT NULL,
    p_std_dev NUMERIC DEFAULT NULL,
    p_k_period INTEGER DEFAULT NULL,
    p_d_period INTEGER DEFAULT NULL,
    p_smooth INTEGER DEFAULT NULL
)
RETURNS TABLE (dt TIMESTAMP, value NUMERIC)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_end TIMESTAMP;
    v_bars INTEGER;
    v_dts TIMESTAMP[];
    v_ast JSONB;
    v_ctx JSONB;
    v_values NUMERIC[];
    v_n INTEGER;
    v_start INTEGER;
    i INTEGER;
BEGIN
    IF p_series IS NOT NULL AND btrim(p_series) = '' THEN
        RETURN;
    END IF;

    v_end := ind_resolve_end_dt(p_security_id, p_timeframe_id, p_end_dt);
    IF v_end IS NULL THEN RETURN; END IF;

    v_bars := GREATEST(COALESCE(p_point_count, 100) + 30, ind_warmup_bars(COALESCE(p_period, 14), p_point_count));

    v_dts := poly_load_market_dts(p_security_id, p_timeframe_id, v_end, v_bars);
    v_n := COALESCE(array_length(v_dts, 1), 0);
    IF v_n = 0 THEN RETURN; END IF;

    v_ctx := jsonb_build_object(
        'security_id', p_security_id,
        'timeframe_id', p_timeframe_id,
        'end_dt', to_char(v_end, 'YYYY-MM-DD HH24:MI:SS'),
        'bars', v_bars,
        'param_period', p_period,
        'param_fast_period', p_fast_period,
        'param_slow_period', p_slow_period,
        'param_signal_period', p_signal_period,
        'param_std_dev', p_std_dev,
        'param_k_period', p_k_period,
        'param_d_period', p_d_period,
        'param_smooth', p_smooth,
        'dts', to_jsonb(v_dts)
    );

    IF position('pp' IN lower(btrim(p_formula))) > 0 THEN
        v_ctx := v_ctx || jsonb_build_object(
            'm_pp', to_jsonb(poly_load_market_array('pp', p_security_id, p_timeframe_id, v_end, v_bars))
        );
    END IF;
    IF position('oo' IN lower(btrim(p_formula))) > 0 THEN
        v_ctx := v_ctx || jsonb_build_object(
            'm_oo', to_jsonb(poly_load_market_array('oo', p_security_id, p_timeframe_id, v_end, v_bars))
        );
    END IF;
    IF position('hh' IN lower(btrim(p_formula))) > 0 THEN
        v_ctx := v_ctx || jsonb_build_object(
            'm_hh', to_jsonb(poly_load_market_array('hh', p_security_id, p_timeframe_id, v_end, v_bars))
        );
    END IF;
    IF position('ll' IN lower(btrim(p_formula))) > 0 THEN
        v_ctx := v_ctx || jsonb_build_object(
            'm_ll', to_jsonb(poly_load_market_array('ll', p_security_id, p_timeframe_id, v_end, v_bars))
        );
    END IF;
    IF position('vv' IN lower(btrim(p_formula))) > 0 THEN
        v_ctx := v_ctx || jsonb_build_object(
            'm_vv', to_jsonb(poly_load_market_array('vv', p_security_id, p_timeframe_id, v_end, v_bars))
        );
    END IF;

    v_ast := poly_parse(p_formula);
    v_values := poly_eval_node(v_ast, v_ctx);
    v_n := LEAST(COALESCE(array_length(v_values, 1), 0), COALESCE(array_length(v_dts, 1), 0));
    IF v_n = 0 THEN RETURN; END IF;

    v_start := GREATEST(1, v_n - COALESCE(p_point_count, 100) + 1);
    FOR i IN v_start .. v_n LOOP
        dt := v_dts[i];
        value := v_values[i];
        RETURN NEXT;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION calc_poly_formula_array IS
'Вычисляет многочленную формулу индикатора (pp * (1;-2;1), @SMA # pp, …) и возвращает последние point_count точек.';

-- Диспетчер массивного расчёта по коду индикатора
CREATE OR REPLACE FUNCTION calc_indicator_series_array(
    p_indicator_code VARCHAR,
    p_series VARCHAR,
    p_security_id INTEGER,
    p_timeframe_id INTEGER,
    p_point_count INTEGER DEFAULT 100,
    p_end_dt TIMESTAMP DEFAULT NULL,
    p_period INTEGER DEFAULT NULL,
    p_fast_period INTEGER DEFAULT NULL,
    p_slow_period INTEGER DEFAULT NULL,
    p_signal_period INTEGER DEFAULT NULL,
    p_std_dev NUMERIC DEFAULT NULL,
    p_k_period INTEGER DEFAULT NULL,
    p_d_period INTEGER DEFAULT NULL,
    p_smooth INTEGER DEFAULT NULL
)
RETURNS TABLE (dt TIMESTAMP, value NUMERIC)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_formula TEXT;
BEGIN
    SELECT NULLIF(btrim(formula), '') INTO v_formula
    FROM indicators WHERE code = upper(btrim(p_indicator_code));

    IF poly_is_formula(v_formula) THEN
        RETURN QUERY SELECT * FROM calc_poly_formula_array(
            v_formula, p_series, p_security_id, p_timeframe_id, p_point_count, p_end_dt,
            p_period, p_fast_period, p_slow_period, p_signal_period,
            p_std_dev, p_k_period, p_d_period, p_smooth);
        RETURN;
    END IF;

    CASE upper(btrim(p_indicator_code))
        WHEN 'RSI' THEN
            RETURN QUERY SELECT * FROM calc_ind_rsi_array(
                COALESCE(p_period, 14), p_series, p_security_id, p_timeframe_id, p_point_count, p_end_dt);
        WHEN 'SMA' THEN
            RETURN QUERY SELECT * FROM calc_ind_sma_array(
                COALESCE(p_period, 20), p_series, p_security_id, p_timeframe_id, p_point_count, p_end_dt);
        WHEN 'EMA' THEN
            RETURN QUERY SELECT * FROM calc_ind_ema_array(
                COALESCE(p_period, 20), p_series, p_security_id, p_timeframe_id, p_point_count, p_end_dt);
        WHEN 'MACD' THEN
            RETURN QUERY SELECT * FROM calc_ind_macd_array(
                COALESCE(p_fast_period, 12), COALESCE(p_slow_period, 26), COALESCE(p_signal_period, 9),
                p_series, p_security_id, p_timeframe_id, p_point_count, p_end_dt);
        WHEN 'BB' THEN
            RETURN QUERY SELECT * FROM calc_ind_bb_array(
                COALESCE(p_period, 20), COALESCE(p_std_dev, 2.0), p_series, p_security_id, p_timeframe_id, p_point_count, p_end_dt);
        WHEN 'ATR' THEN
            RETURN QUERY SELECT * FROM calc_ind_atr_array(
                COALESCE(p_period, 14), p_series, p_security_id, p_timeframe_id, p_point_count, p_end_dt);
        WHEN 'STOCH' THEN
            RETURN QUERY SELECT * FROM calc_ind_stoch_array(
                COALESCE(p_k_period, 14), COALESCE(p_d_period, 3), COALESCE(p_smooth, 3),
                p_series, p_security_id, p_timeframe_id, p_point_count, p_end_dt);
        ELSE
            RETURN;
    END CASE;
END;
$$;

-- Дефолтные параметры из parameter_values / indicator code
CREATE OR REPLACE FUNCTION resolve_indicator_params(
    p_indicator_code VARCHAR,
    OUT param_period INTEGER,
    OUT param_fast_period INTEGER,
    OUT param_slow_period INTEGER,
    OUT param_signal_period INTEGER,
    OUT param_std_dev NUMERIC,
    OUT param_k_period INTEGER,
    OUT param_d_period INTEGER,
    OUT param_smooth INTEGER
)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    param_period := CASE upper(p_indicator_code)
        WHEN 'RSI' THEN 14 WHEN 'SMA' THEN 20 WHEN 'EMA' THEN 20 WHEN 'BB' THEN 20
        WHEN 'ATR' THEN 14 WHEN 'STOCH' THEN 14 WHEN 'SMAT3' THEN 20 WHEN 'SMAT3COMP' THEN 20 ELSE 14 END;
    BEGIN
        SELECT pv.value::INTEGER INTO param_period
        FROM parameter_values pv
        JOIN parameter_types pt ON pt.id = pv.parameter_type_id
        JOIN parameter_sets ps ON ps.id = pv.parameter_set_id
        WHERE ps.name = 'Default' AND pt.short_name = upper(p_indicator_code) || '_PERIOD'
        LIMIT 1;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    param_fast_period := 12;
    param_slow_period := 26;
    param_signal_period := 9;
    param_std_dev := 2.0;
    param_k_period := COALESCE(param_period, 14);
    param_d_period := 3;
    param_smooth := 3;
END;
$$;

CREATE OR REPLACE FUNCTION default_invoke_formula(p_indicator_code VARCHAR)
RETURNS TEXT
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        NULLIF(btrim(i.formula), ''),
        'calc_indicator_series_array(:indicator_code, :series, :security_id, :timeframe_id, :point_count, :end_dt)'
    )
    FROM indicators i
    WHERE i.code = upper(btrim(p_indicator_code));
$$;

-- Создать все серии индикатора на бумаге (при drop)
CREATE OR REPLACE PROCEDURE ensure_security_indicator_series(
    p_security_id INTEGER,
    p_indicator_id INTEGER
)
LANGUAGE plpgsql AS $$
DECLARE
    v_code VARCHAR(20);
    v_params RECORD;
    v_vt RECORD;
    v_ord INTEGER := 0;
BEGIN
    SELECT code INTO v_code FROM indicators WHERE id = p_indicator_id;
    IF v_code IS NULL THEN
        RAISE EXCEPTION 'indicator_id=% not found', p_indicator_id;
    END IF;

    SELECT * INTO v_params FROM resolve_indicator_params(v_code);

    FOR v_vt IN
        SELECT id, code, display_order
        FROM indicator_value_types
        WHERE indicator_id = p_indicator_id AND is_threshold = FALSE
        ORDER BY display_order, id
    LOOP
        v_ord := v_ord + 1;
        INSERT INTO security_indicator_series (
            security_id, indicator_id, series_code, invoke_formula,
            param_period, param_fast_period, param_slow_period, param_signal_period,
            param_std_dev, param_k_period, param_d_period, param_smooth,
            point_count, display_order
        )
        VALUES (
            p_security_id, p_indicator_id, v_vt.code, default_invoke_formula(v_code),
            v_params.param_period, v_params.param_fast_period, v_params.param_slow_period,
            v_params.param_signal_period, v_params.param_std_dev,
            v_params.param_k_period, v_params.param_d_period, v_params.param_smooth,
            100, v_ord
        )
        ON CONFLICT (security_id, indicator_id, series_code) DO UPDATE SET
            is_active = TRUE,
            invoke_formula = EXCLUDED.invoke_formula;
    END LOOP;
END;
$$;

-- Синхронизация одной серии → indicator_values (инкрементально)
CREATE OR REPLACE PROCEDURE sync_security_indicator_series(
    p_series_id INTEGER,
    p_timeframe_id INTEGER,
    p_end_dt TIMESTAMP DEFAULT NULL,
    p_point_count INTEGER DEFAULT NULL,
    p_incremental BOOLEAN DEFAULT TRUE
)
LANGUAGE plpgsql AS $$
DECLARE
    v_row security_indicator_series%ROWTYPE;
    v_code VARCHAR(20);
    v_vt_id INTEGER;
    v_count INTEGER;
    v_pt RECORD;
BEGIN
    SELECT * INTO v_row FROM security_indicator_series WHERE id = p_series_id AND is_active = TRUE;
    IF NOT FOUND THEN RETURN; END IF;

    SELECT code INTO v_code FROM indicators WHERE id = v_row.indicator_id;
    SELECT id INTO v_vt_id FROM indicator_value_types
    WHERE indicator_id = v_row.indicator_id AND code = v_row.series_code;

    v_count := COALESCE(p_point_count, v_row.point_count, 100);

    IF NOT EXISTS (
        SELECT 1 FROM prices
        WHERE security_id = v_row.security_id
          AND timeframe_id = p_timeframe_id
          AND (p_end_dt IS NULL OR dt <= p_end_dt)
        LIMIT 1
    ) THEN
        RETURN;
    END IF;

    IF poly_is_formula(v_row.invoke_formula) THEN
        FOR v_pt IN
            SELECT * FROM calc_poly_formula_array(
                v_row.invoke_formula, v_row.series_code,
                v_row.security_id, p_timeframe_id, v_count, p_end_dt,
                v_row.param_period, v_row.param_fast_period, v_row.param_slow_period,
                v_row.param_signal_period, v_row.param_std_dev,
                v_row.param_k_period, v_row.param_d_period, v_row.param_smooth
            )
        LOOP
            PERFORM insert_indicator_value(
                v_row.indicator_id, v_vt_id, v_row.security_id, p_timeframe_id,
                v_pt.dt, v_pt.value, FALSE, NULL, NOT p_incremental
            );
        END LOOP;
    ELSE
        FOR v_pt IN
            SELECT * FROM calc_indicator_series_array(
                v_code, v_row.series_code,
                v_row.security_id, p_timeframe_id, v_count, p_end_dt,
                v_row.param_period, v_row.param_fast_period, v_row.param_slow_period,
                v_row.param_signal_period, v_row.param_std_dev,
                v_row.param_k_period, v_row.param_d_period, v_row.param_smooth
            )
        LOOP
            PERFORM insert_indicator_value(
                v_row.indicator_id, v_vt_id, v_row.security_id, p_timeframe_id,
                v_pt.dt, v_pt.value, FALSE, NULL, NOT p_incremental
            );
        END LOOP;
    END IF;
END;
$$;

-- Синхронизация всех серий одного индикатора на бумаге
CREATE OR REPLACE PROCEDURE sync_security_indicator_series_for_indicator(
    p_security_id INTEGER,
    p_indicator_id INTEGER,
    p_timeframe_id INTEGER,
    p_end_dt TIMESTAMP DEFAULT NULL,
    p_point_count INTEGER DEFAULT NULL,
    p_incremental BOOLEAN DEFAULT TRUE
)
LANGUAGE plpgsql AS $$
DECLARE
    v_id INTEGER;
BEGIN
    FOR v_id IN
        SELECT id FROM security_indicator_series
        WHERE security_id = p_security_id
          AND indicator_id = p_indicator_id
          AND is_active = TRUE
        ORDER BY display_order, id
    LOOP
        CALL sync_security_indicator_series(
            v_id, p_timeframe_id, p_end_dt, p_point_count, p_incremental
        );
    END LOOP;
END;
$$;

COMMENT ON PROCEDURE sync_security_indicator_series_for_indicator IS
'Пересчёт только серий указанного индикатора на бумаге (фоновый sync после drag-and-drop).';

-- Синхронизация всех серий бумаги
CREATE OR REPLACE PROCEDURE sync_security_indicator_series_all(
    p_security_id INTEGER,
    p_timeframe_id INTEGER,
    p_end_dt TIMESTAMP DEFAULT NULL,
    p_point_count INTEGER DEFAULT NULL,
    p_incremental BOOLEAN DEFAULT TRUE
)
LANGUAGE plpgsql AS $$
DECLARE
    v_id INTEGER;
BEGIN
    FOR v_id IN
        SELECT id FROM security_indicator_series
        WHERE security_id = p_security_id AND is_active = TRUE
        ORDER BY display_order, id
    LOOP
        CALL sync_security_indicator_series(v_id, p_timeframe_id, p_end_dt, p_point_count, p_incremental);
    END LOOP;
END;
$$;

-- ============================================
-- Процедура: refresh_indicator_values
-- Пересчет индикаторов для свежих цен
-- ============================================
CREATE OR REPLACE PROCEDURE refresh_indicator_values(
    p_security_id INTEGER,
    p_timeframe_id INTEGER,
    p_indicator_id INTEGER
)
LANGUAGE plpgsql AS $$
DECLARE
    v_script TEXT;
    v_indicator_code VARCHAR(20);
    v_date_from DATE;
    v_date_to DATE;
BEGIN
    SELECT code, script INTO v_indicator_code, v_script
    FROM indicators WHERE id = p_indicator_id;

    IF NOT FOUND THEN
        RAISE NOTICE 'Индикатор id=% не найден', p_indicator_id;
        RETURN;
    END IF;

    IF v_script IS NULL OR TRIM(v_script) = '' THEN
        RAISE NOTICE 'Скрипт для индикатора % не заполнен', v_indicator_code;
        RETURN;
    END IF;

    v_date_to := CURRENT_DATE;
    v_date_from := (CURRENT_DATE - INTERVAL '30 days')::DATE;

    RAISE NOTICE 'Пересчёт индикатора % по script за % — %', v_indicator_code, v_date_from, v_date_to;

    CALL calculate_indicator(
        p_security_id,
        p_timeframe_id,
        p_indicator_id,
        v_date_from,
        v_date_to,
        TRUE
    );

EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'Ошибка пересчёта индикатора %: %', v_indicator_code, SQLERRM;
END;
$$;

COMMENT ON PROCEDURE refresh_indicator_values(INTEGER, INTEGER, INTEGER) IS 
'Пересчитывает значения индикатора для свежих цен через indicators.script и calculate_indicator.';


-- ============================================
-- Процедура: calculate_indicator
-- Расчет значений индикатора и запись в таблицу indicator_values
-- ============================================
-- ============================================
-- Процедура: calculate_indicator
-- Расчет значений технического индикатора и запись в таблицу indicator_values
-- ============================================
--
-- ПАРАМЕТРЫ:
--   p_security_id   INTEGER  - ID ценной бумаги из таблицы securities
--                              (например: 1 = SBER, 3 = GAZP, 35 = Si фьючерс)
--   p_timeframe_id   INTEGER  - ID таймфрейма из таблицы timeframes
--                              (например: 4 = M5, 15 = D1, 22 = MN1)
--   p_indicator_id   INTEGER  - ID индикатора из таблицы indicators
--                              (например: 4 = RSI, 5 = MACD, 7 = BB)
--   p_date_from      DATE     - Начальная дата периода расчета (включительно)
--   p_date_to        DATE     - Конечная дата периода расчета (включительно)
--   p_overwrite      BOOLEAN  - Флаг перезаписи существующих записей:
--                              TRUE  = удалить старые значения и записать новые
--                              FALSE = пропустить свечи, где значения уже есть
--
-- ПОДДЕРЖИВАЕМЫЕ ИНДИКАТОРЫ:
--   RSI      - Индекс относительной силы (0-100), период по умолчанию 14
--   SMA      - Простое скользящее среднее, период по умолчанию 20
--   EMA      - Экспоненциальное скользящее среднее, период по умолчанию 20
--   MACD     - Схождение/расхождение MA (fast=12, slow=26, signal=9)
--   BB       - Полосы Боллинджера (период=20, std_dev=2.0)
--   ATR      - Средний истинный диапазон, период по умолчанию 14
--   STOCH    - Стохастик (%K период=14, %D период=3, сглаживание=3)
--
-- ПРИМЕР ВЫЗОВА:
--   CALL calculate_indicator(1, 4, 4, '2026-06-17', '2026-06-24', TRUE);
--   -- Расчет RSI для SBER (id=1) на M5 (id=4) за неделю с перезаписью
-- ============================================
CREATE OR REPLACE PROCEDURE calculate_indicator(
    p_security_id INTEGER,           -- ID бумаги (ссылка на securities.id)
    p_timeframe_id INTEGER,          -- ID таймфрейма (ссылка на timeframes.id)
    p_indicator_id INTEGER,          -- ID индикатора (ссылка на indicators.id)
    p_date_from DATE,                -- Начало периода расчета (YYYY-MM-DD)
    p_date_to DATE,                  -- Конец периода расчета (YYYY-MM-DD)
    p_overwrite BOOLEAN DEFAULT FALSE -- Перезаписывать существующие записи?
)
LANGUAGE plpgsql AS $$
DECLARE
    -- ============================================================
    -- ПЕРЕМЕННЫЕ ИНФОРМАЦИИ ОБ ИНДИКАТОРЕ
    -- ============================================================
    v_indicator_code VARCHAR(20);    -- Код индикатора (RSI, MACD, BB и т.д.)
    v_indicator_name VARCHAR(100);   -- Полное имя индикатора
    v_indicator_category VARCHAR(50);-- Категория: trend, momentum, volatility, volume
    v_script TEXT;                   -- Шаблон indicators.script → EXECUTE (calc_ind_* + :series)

    -- ============================================================
    -- ПАРАМЕТРЫ ИНДИКАТОРА (загружаются из parameter_values или берутся по умолчанию)
    -- ============================================================
    v_period INTEGER := 14;          -- Основной период (для RSI, SMA, EMA, ATR, STOCH)
    v_fast_period INTEGER := 12;     -- Период быстрой линии (только для MACD)
    v_slow_period INTEGER := 26;     -- Период медленной линии (только для MACD)
    v_signal_period INTEGER := 9;    -- Период сигнальной линии (MACD, STOCH)
    v_std_dev NUMERIC := 2.0;        -- Количество стандартных отклонений (только для BB)
    v_k_period INTEGER := 14;        -- Период %K линии (только для Stochastic)
    v_d_period INTEGER := 3;         -- Период %D линии (только для Stochastic)
    v_smooth INTEGER := 3;           -- Период сглаживания (только для Stochastic)

    -- ============================================================
    -- ПЕРЕМЕННЫЕ ДЛЯ РАСЧЕТА RSI
    -- ============================================================
    v_gain NUMERIC(18,6) := 0;       -- Сумма положительных изменений цены
    v_loss NUMERIC(18,6) := 0;       -- Сумма отрицательных изменений цены
    v_avg_gain NUMERIC(18,6) := 0;   -- Средний прирост за период
    v_avg_loss NUMERIC(18,6) := 0;   -- Средняя потеря за период
    v_rsi NUMERIC(18,6);             -- Итоговое значение RSI (0-100)
    v_rs NUMERIC(18,6);              -- Отношение avg_gain / avg_loss

    -- ============================================================
    -- ПЕРЕМЕННЫЕ ДЛЯ РАСЧЕТА SMA / EMA
    -- ============================================================
    v_sma NUMERIC(18,6);             -- Значение простого скользящего среднего
    v_ema NUMERIC(18,6);             -- Значение экспоненциального скользящего среднего
    v_ema_prev NUMERIC(18,6);        -- Предыдущее значение EMA (для рекурсии)
    v_multiplier NUMERIC(18,6);    -- Множитель сглаживания EMA = 2/(period+1)
    v_sum NUMERIC(18,6) := 0;        -- Аккумулятор суммы (для SMA)
    v_count INTEGER := 0;            -- Счетчик итераций

    -- ============================================================
    -- ПЕРЕМЕННЫЕ ДЛЯ РАСЧЕТА BOLLINGER BANDS
    -- ============================================================
    v_bb_middle NUMERIC(18,6);       -- Средняя полоса (SMA)
    v_bb_upper NUMERIC(18,6);        -- Верхняя полоса (SMA + k*σ)
    v_bb_lower NUMERIC(18,6);        -- Нижняя полоса (SMA - k*σ)
    v_bb_stddev NUMERIC(18,6);       -- Стандартное отклонение
    v_bb_sum_sq NUMERIC(18,6) := 0;  -- Сумма квадратов отклонений (для σ)

    -- ============================================================
    -- ПЕРЕМЕННЫЕ ДЛЯ РАСЧЕТА MACD
    -- ============================================================
    v_ema_fast NUMERIC(18,6);        -- Быстрая EMA (период 12)
    v_ema_slow NUMERIC(18,6);        -- Медленная EMA (период 26)
    v_macd NUMERIC(18,6);            -- Линия MACD = EMA_fast - EMA_slow
    v_macd_signal NUMERIC(18,6);     -- Сигнальная линия (EMA от MACD, период 9)
    v_macd_histogram NUMERIC(18,6);  -- Гистограмма = MACD - Signal
    v_mult_fast NUMERIC(18,6);       -- Множитель быстрой EMA = 2/(12+1)
    v_mult_slow NUMERIC(18,6);       -- Множитель медленной EMA = 2/(26+1)
    v_mult_signal NUMERIC(18,6);     -- Множитель сигнальной EMA = 2/(9+1)

    -- ============================================================
    -- ПЕРЕМЕННЫЕ ДЛЯ РАСЧЕТА STOCHASTIC
    -- ============================================================
    v_stoch_k NUMERIC(18,6);         -- %K линия = (Close - Low) / (High - Low) * 100
    v_stoch_d NUMERIC(18,6);         -- %D линия = SMA(%K, 3)
    v_stoch_j NUMERIC(18,6);         -- J линия = 3K - 2D (не используется)
    v_lowest_low NUMERIC(18,6);      -- Минимум low за период %K
    v_highest_high NUMERIC(18,6);    -- Максимум high за период %K
    v_k_sum NUMERIC(18,6) := 0;      -- Аккумулятор для SMA %K
    v_k_count INTEGER := 0;          -- Счетчик для SMA %K

    -- ============================================================
    -- ПЕРЕМЕННЫЕ ДЛЯ РАСЧЕТА ATR
    -- ============================================================
    v_atr NUMERIC(18,6);             -- Текущее значение ATR
    v_atr_prev NUMERIC(18,6);        -- Предыдущее значение ATR (для Wilder's smoothing)
    v_tr NUMERIC(18,6);              -- True Range = max(High-Low, |High-Close_prev|, |Low-Close_prev|)
    v_tr_high NUMERIC(18,6);         -- High - Low (компонент TR)
    v_tr_low NUMERIC(18,6);          -- |High - Close_prev| (компонент TR)
    v_tr_close NUMERIC(18,6);        -- |Low - Close_prev| (компонент TR)

    -- ============================================================
    -- ПОРОГОВЫЕ ЗНАЧЕНИЯ (загружаются из indicator_value_types.threshold_value)
    -- ============================================================
    v_overbought NUMERIC(18,6) := 70;-- Порог перекупленности (RSI=70, STOCH=80)
    v_oversold NUMERIC(18,6) := 30;  -- Порог перепроданности (RSI=30, STOCH=20)
    v_neutral NUMERIC(18,6) := 50;  -- Нейтральный уровень

    -- ============================================================
    -- СЧЕТЧИКИ РЕЗУЛЬТАТОВ ОПЕРАЦИЙ
    -- ============================================================
    v_records_inserted INTEGER := 0; -- Количество вставленных новых записей
    v_records_updated INTEGER := 0;  -- Количество обновленных записей (при overwrite=TRUE)
    v_records_skipped INTEGER := 0;  -- Количество пропущенных записей (при overwrite=FALSE)
    v_dt TIMESTAMP;                  -- Текущая дата/время свечи

    -- ============================================================
    -- КУРСОР ДЛЯ ЗАГРУЗКИ ЦЕНОВЫХ ДАННЫХ
    -- ============================================================
    -- Загружаем OHLCV из таблицы prices для указанной бумаги, таймфрейма и периода
    cur_prices CURSOR(p_sec INTEGER, p_tf INTEGER, p_from TIMESTAMP, p_to TIMESTAMP) FOR
        SELECT dt, open_price, high_price, low_price, close_price, volume
        FROM prices
        WHERE security_id = p_sec AND timeframe_id = p_tf
          AND dt >= p_from AND dt <= p_to
        ORDER BY dt;

    -- ============================================================
    -- МАССИВЫ ДЛЯ ХРАНЕНИЯ ЦЕНОВЫХ ДАННЫХ В ПАМЯТИ
    -- ============================================================
    -- Загружаем все цены в массивы для быстрого доступа по индексу
    -- Это быстрее, чем многократные обращения к курсору
    v_closes NUMERIC(18,6)[];      -- Массив цен закрытия
    v_highs NUMERIC(18,6)[];       -- Массив максимальных цен
    v_lows NUMERIC(18,6)[];        -- Массив минимальных цен
    v_dts TIMESTAMP[];             -- Массив дат/времени свечей
    v_idx INTEGER := 0;            -- Текущий индекс в массивах (количество свечей)

    -- ============================================================
    -- ПЕРЕМЕННЫЕ ДЛЯ РАБОТЫ С ТИПАМИ ЗНАЧЕНИЙ ИНДИКАТОРА
    -- ============================================================
    v_value_type_id INTEGER;       -- ID типа значения из indicator_value_types.id
    v_value_type_code VARCHAR(20);   -- Код типа значения (RSI, K, D, UPPER и т.д.)

    -- ============================================================
    -- ПЕРЕМЕННАЯ ДЛЯ ПРОВЕРКИ СУЩЕСТВОВАНИЯ ЗАПИСИ
    -- ============================================================
    v_existing_count INTEGER;        -- Количество существующих записей (0 или 1)
    v_price RECORD;                  -- Строка курсора цен
    v_load_from TIMESTAMP;           -- Начало загрузки цен (прогрев до date_from)
BEGIN
    -- ============================================================
    -- БЛОК 1: ЗАГРУЗКА ИНФОРМАЦИИ ОБ ИНДИКАТОРЕ
    -- ============================================================
    -- Получаем код, имя, категорию и SQL-скрипт индикатора из таблицы indicators
    -- Если индикатор не найден -- выбрасываем исключение
    SELECT code, name, category, script
    INTO v_indicator_code, v_indicator_name, v_indicator_category, v_script
    FROM indicators
    WHERE id = p_indicator_id;

    IF v_indicator_code IS NULL THEN
        RAISE EXCEPTION 'Индикатор с id=% не найден в таблице indicators', p_indicator_id;
    END IF;

    RAISE NOTICE '=== РАСЧЕТ ИНДИКАТОРА % ===', v_indicator_code;
    RAISE NOTICE 'Бумага: %, Таймфрейм: %, Период: % - %', 
        p_security_id, p_timeframe_id, p_date_from, p_date_to;

    -- ============================================================
    -- БЛОК 2: ЗАГРУЗКА ПАРАМЕТРОВ ИНДИКАТОРА
    -- ============================================================
    -- Пытаемся загрузить период из таблицы parameter_values
    -- Если параметр не найден -- используем значение по умолчанию
    BEGIN
        SELECT value::INTEGER INTO v_period
        FROM parameter_values pv
        JOIN parameter_types pt ON pv.parameter_type_id = pt.id
        WHERE pt.short_name = v_indicator_code || '_PERIOD'
        LIMIT 1;
    EXCEPTION WHEN OTHERS THEN
        -- Параметр не найден -- используем дефолтные значения по типу индикатора
        v_period := CASE v_indicator_code
            WHEN 'RSI' THEN 14
            WHEN 'SMA' THEN 20
            WHEN 'EMA' THEN 20
            WHEN 'BB' THEN 20
            WHEN 'ATR' THEN 14
            WHEN 'STOCH' THEN 14
            ELSE 14
        END;
    END;

    -- ============================================================
    -- БЛОК 3: УСТАНОВКА СПЕЦИФИЧНЫХ ПАРАМЕТРОВ ПО ТИПУ ИНДИКАТОРА
    -- ============================================================
    IF v_indicator_code = 'MACD' THEN
        -- MACD: fast=12, slow=26, signal=9 (стандартные параметры)
        v_fast_period := 12;
        v_slow_period := 26;
        v_signal_period := 9;
    ELSIF v_indicator_code = 'BB' THEN
        -- Bollinger Bands: std_dev = 2 (2 стандартных отклонения)
        v_std_dev := 2.0;
    ELSIF v_indicator_code = 'STOCH' THEN
        -- Stochastic: %K=14, %D=3, сглаживание=3
        v_k_period := 14;
        v_d_period := 3;
        v_smooth := 3;
    END IF;

    -- ============================================================
    -- БЛОК 4: ЗАГРУЗКА ЦЕНОВЫХ ДАННЫХ В МАССИВЫ (с прогревом до date_from)
    -- ============================================================
    SELECT COALESCE(
        (
            SELECT MIN(w.dt)
            FROM (
                SELECT dt
                FROM prices
                WHERE security_id = p_security_id
                  AND timeframe_id = p_timeframe_id
                  AND dt < p_date_from::TIMESTAMP
                ORDER BY dt DESC
                LIMIT GREATEST(v_period, v_k_period, 14) + 10
            ) w
        ),
        p_date_from::TIMESTAMP
    ) INTO v_load_from;

    FOR v_price IN
        SELECT dt, open_price, high_price, low_price, close_price, volume
        FROM prices
        WHERE security_id = p_security_id
          AND timeframe_id = p_timeframe_id
          AND dt >= v_load_from
          AND dt < (p_date_to + INTERVAL '1 day')::TIMESTAMP
        ORDER BY dt
    LOOP
        v_idx := v_idx + 1;
        v_closes[v_idx] := v_price.close_price;   -- Цена закрытия
        v_highs[v_idx] := v_price.high_price;     -- Максимальная цена
        v_lows[v_idx] := v_price.low_price;       -- Минимальная цена
        v_dts[v_idx] := v_price.dt;               -- Дата/время свечи
    END LOOP;

    -- ============================================================
    -- БЛОК 5: ПРОВЕРКА ДОСТАТОЧНОСТИ ДАННЫХ
    -- ============================================================
    -- Если свечей меньше, чем период индикатора -- расчет невозможен
    IF v_idx < v_period THEN
        RAISE NOTICE 'Недостаточно данных: загружено % свечей, нужно минимум % для периода %', 
            v_idx, v_period, v_indicator_code;
        RETURN;  -- Выходим из процедуры
    END IF;

    RAISE NOTICE 'Загружено % свечей для расчета индикатора %', v_idx, v_indicator_code;

    -- ============================================================
    -- БЛОК 5.1: РАСЧЁТ ПО ШАБЛОНУ indicators.script (EXECUTE)
    -- ============================================================
    -- Для RSI/SMA/EMA/MACD/BB/ATR/STOCH — inline O(n); via_script вызывает calc_ind_*
    -- на каждую свечу и сканирует всю историю → зависание на длинных рядах.
    IF COALESCE(TRIM(v_script), '') <> ''
       AND v_indicator_code NOT IN ('RSI', 'SMA', 'EMA', 'MACD', 'BB', 'ATR', 'STOCH') THEN
        EXECUTE 'CALL calculate_indicator_via_script($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17)'
        USING p_security_id, p_timeframe_id, p_indicator_id,
              p_date_from, p_date_to, p_overwrite, v_script,
              v_period, v_fast_period, v_slow_period, v_signal_period,
              v_std_dev, v_k_period, v_d_period, v_smooth;
        RETURN;
    END IF;

    -- ============================================================
    -- БЛОК 6: РАСЧЕТ ИНДИКАТОРА (ветвление по типу, legacy)
    -- ============================================================

    -- ==========================================
    -- 6.1 РАСЧЕТ RSI (Relative Strength Index)
    -- ==========================================
    -- Формула: RSI = 100 - (100 / (1 + RS))
    -- Где RS = средний прирост / средняя потеря за период
    -- Значение от 0 до 100. >70 = перекупленность, <30 = перепроданность
    IF v_indicator_code = 'RSI' THEN

        -- Загружаем пороговые значения из indicator_value_types
        -- OVERBOUGHT (по умолчанию 70), OVERSOLD (по умолчанию 30), NEUTRAL (50)
        FOREACH v_value_type_code IN ARRAY ARRAY['RSI', 'OVERBOUGHT', 'OVERSOLD', 'NEUTRAL']::VARCHAR(20)[]
        LOOP
            SELECT id INTO v_value_type_id
            FROM indicator_value_types
            WHERE indicator_id = p_indicator_id AND code = v_value_type_code;

            IF v_value_type_id IS NULL THEN
                RAISE NOTICE 'Тип значения % не найден для индикатора RSI', v_value_type_code;
                CONTINUE;
            END IF;

            -- Сохраняем пороговые значения для последующей проверки сигналов
            IF v_value_type_code = 'OVERBOUGHT' THEN
                v_overbought := COALESCE((SELECT threshold_value FROM indicator_value_types WHERE id = v_value_type_id), 70);
            ELSIF v_value_type_code = 'OVERSOLD' THEN
                v_oversold := COALESCE((SELECT threshold_value FROM indicator_value_types WHERE id = v_value_type_id), 30);
            ELSIF v_value_type_code = 'NEUTRAL' THEN
                v_neutral := COALESCE((SELECT threshold_value FROM indicator_value_types WHERE id = v_value_type_id), 50);
            END IF;
        END LOOP;

        -- Основной цикл расчета RSI для каждой свечи, начиная с (period+1)
        FOR i IN v_period + 1 .. v_idx
        LOOP
            -- Сброс аккумуляторов прироста и потерь
            v_gain := 0;
            v_loss := 0;

            -- Суммируем приросты и потери за период
            FOR j IN i - v_period + 1 .. i
            LOOP
                IF v_closes[j] > v_closes[j - 1] THEN
                    -- Цена выросла -- добавляем прирост
                    v_gain := v_gain + (v_closes[j] - v_closes[j - 1]);
                ELSE
                    -- Цена упала -- добавляем потерю
                    v_loss := v_loss + (v_closes[j - 1] - v_closes[j]);
                END IF;
            END LOOP;

            -- Средние прирост и потеря
            v_avg_gain := v_gain / v_period;
            v_avg_loss := v_loss / v_period;

            -- Расчет RS и RSI
            IF v_avg_loss = 0 THEN
                v_rsi := 100;  -- Если потерь нет -- RSI = 100 (максимум)
            ELSE
                v_rs := v_avg_gain / v_avg_loss;
                v_rsi := 100 - (100 / (1 + v_rs));
            END IF;

            v_dt := v_dts[i];

            -- ============================================================
            -- БЛОК 6.1.1: ЗАПИСЬ ЗНАЧЕНИЯ RSI В БАЗУ
            -- ============================================================
            SELECT id INTO v_value_type_id
            FROM indicator_value_types
            WHERE indicator_id = p_indicator_id AND code = 'RSI';

            IF v_value_type_id IS NOT NULL THEN
                -- Проверяем, есть ли уже запись для этой свечи
                SELECT COUNT(*) INTO v_existing_count
                FROM indicator_values
                WHERE indicator_id = p_indicator_id
                  AND indicator_value_type_id = v_value_type_id
                  AND security_id = p_security_id
                  AND timeframe_id = p_timeframe_id
                  AND dt = v_dt;

                -- Если запись есть и overwrite=FALSE -- пропускаем
                IF v_existing_count > 0 AND NOT p_overwrite THEN
                    v_records_skipped := v_records_skipped + 1;
                ELSE
                    -- Удаляем старую запись, если overwrite=TRUE
                    IF v_existing_count > 0 THEN
                        DELETE FROM indicator_values
                        WHERE indicator_id = p_indicator_id
                          AND indicator_value_type_id = v_value_type_id
                          AND security_id = p_security_id
                          AND timeframe_id = p_timeframe_id
                          AND dt = v_dt;
                        v_records_updated := v_records_updated + 1;
                    ELSE
                        v_records_inserted := v_records_inserted + 1;
                    END IF;

                    -- Вставляем новое значение RSI
                    INSERT INTO indicator_values (indicator_id, indicator_value_type_id, security_id, timeframe_id, dt, value, is_signal, signal_type)
                    VALUES (p_indicator_id, v_value_type_id, p_security_id, p_timeframe_id, v_dt, v_rsi, FALSE, NULL);
                END IF;
            END IF;

            -- ============================================================
            -- БЛОК 6.1.2: ПРОВЕРКА ПОРОГОВЫХ ЗНАЧЕНИЙ И СИГНАЛОВ
            -- ============================================================
            -- Если RSI >= overbought -- создаем сигнал перекупленности
            IF v_rsi >= v_overbought THEN
                SELECT id INTO v_value_type_id FROM indicator_value_types WHERE indicator_id = p_indicator_id AND code = 'OVERBOUGHT';
                IF v_value_type_id IS NOT NULL THEN
                    PERFORM insert_indicator_value(p_indicator_id, v_value_type_id, p_security_id, p_timeframe_id, v_dt, v_overbought, TRUE, 'overbought', p_overwrite);
                END IF;
            -- Если RSI <= oversold -- создаем сигнал перепроданности
            ELSIF v_rsi <= v_oversold THEN
                SELECT id INTO v_value_type_id FROM indicator_value_types WHERE indicator_id = p_indicator_id AND code = 'OVERSOLD';
                IF v_value_type_id IS NOT NULL THEN
                    PERFORM insert_indicator_value(p_indicator_id, v_value_type_id, p_security_id, p_timeframe_id, v_dt, v_oversold, TRUE, 'oversold', p_overwrite);
                END IF;
            END IF;
        END LOOP;

    -- ==========================================
    -- 6.2 РАСЧЕТ SMA (Simple Moving Average)
    -- ==========================================
    -- Формула: SMA = сумма(close, period) / period
    -- Простое среднее арифметическое цен закрытия за период
    ELSIF v_indicator_code = 'SMA' THEN
        -- Цикл по всем свечам, начиная с периода
        FOR i IN v_period .. v_idx
        LOOP
            -- Суммируем цены закрытия за период
            v_sum := 0;
            FOR j IN i - v_period + 1 .. i
            LOOP
                v_sum := v_sum + v_closes[j];
            END LOOP;
            v_sma := v_sum / v_period;  -- Делим на количество свечей
            v_dt := v_dts[i];

            -- Записываем значение SMA
            SELECT id INTO v_value_type_id FROM indicator_value_types WHERE indicator_id = p_indicator_id AND code = 'VALUE';
            IF v_value_type_id IS NOT NULL THEN
                PERFORM insert_indicator_value(p_indicator_id, v_value_type_id, p_security_id, p_timeframe_id, v_dt, v_sma, FALSE, NULL, p_overwrite);
                v_records_inserted := v_records_inserted + 1;
            END IF;
        END LOOP;

    -- ==========================================
    -- 6.3 РАСЧЕТ EMA (Exponential Moving Average)
    -- ==========================================
    -- Формула: EMA(today) = (Close(today) - EMA(yesterday)) * multiplier + EMA(yesterday)
    -- Где multiplier = 2 / (period + 1)
    -- Первое EMA = SMA за период
    ELSIF v_indicator_code = 'EMA' THEN
        -- Множитель сглаживания: 2/(N+1)
        v_multiplier := 2.0 / (v_period + 1);

        -- Расчет начального SMA (первое EMA = SMA)
        v_sum := 0;
        FOR j IN 1 .. v_period
        LOOP
            v_sum := v_sum + v_closes[j];
        END LOOP;
        v_ema := v_sum / v_period;

        -- Основной цикл расчета EMA
        FOR i IN v_period .. v_idx
        LOOP
            -- Если не первая точка -- применяем формулу EMA
            IF i > v_period THEN
                v_ema := (v_closes[i] - v_ema) * v_multiplier + v_ema;
            END IF;
            v_dt := v_dts[i];

            -- Записываем значение EMA
            SELECT id INTO v_value_type_id FROM indicator_value_types WHERE indicator_id = p_indicator_id AND code = 'VALUE';
            IF v_value_type_id IS NOT NULL THEN
                PERFORM insert_indicator_value(p_indicator_id, v_value_type_id, p_security_id, p_timeframe_id, v_dt, v_ema, FALSE, NULL, p_overwrite);
                v_records_inserted := v_records_inserted + 1;
            END IF;
        END LOOP;

    -- ==========================================
    -- 6.4 РАСЧЕТ MACD
    -- ==========================================
    -- MACD Line = EMA(12) - EMA(26)
    -- Signal Line = EMA(9) от MACD Line
    -- Histogram = MACD Line - Signal Line
    ELSIF v_indicator_code = 'MACD' THEN
        -- Множители для EMA
        v_mult_fast := 2.0 / (v_fast_period + 1);
        v_mult_slow := 2.0 / (v_slow_period + 1);
        v_mult_signal := 2.0 / (v_signal_period + 1);

        -- Начальные EMA (первые значения = SMA)
        v_sum := 0;
        FOR j IN 1 .. v_fast_period LOOP v_sum := v_sum + v_closes[j]; END LOOP;
        v_ema_fast := v_sum / v_fast_period;

        v_sum := 0;
        FOR j IN 1 .. v_slow_period LOOP v_sum := v_sum + v_closes[j]; END LOOP;
        v_ema_slow := v_sum / v_slow_period;

        v_macd_signal := 0;

        -- Основной цикл расчета MACD
        FOR i IN GREATEST(v_fast_period, v_slow_period) .. v_idx
        LOOP
            -- Обновляем быструю EMA (период 12)
            IF i > v_fast_period THEN
                v_ema_fast := (v_closes[i] - v_ema_fast) * v_mult_fast + v_ema_fast;
            END IF;
            -- Обновляем медленную EMA (период 26)
            IF i > v_slow_period THEN
                v_ema_slow := (v_closes[i] - v_ema_slow) * v_mult_slow + v_ema_slow;
            END IF;

            -- Линия MACD = разница EMA
            v_macd := v_ema_fast - v_ema_slow;

            -- Сигнальная линия = EMA(9) от MACD
            IF i = GREATEST(v_fast_period, v_slow_period) THEN
                v_macd_signal := v_macd;  -- Первое значение = MACD
            ELSE
                v_macd_signal := (v_macd - v_macd_signal) * v_mult_signal + v_macd_signal;
            END IF;

            -- Гистограмма = MACD - Signal
            v_macd_histogram := v_macd - v_macd_signal;
            v_dt := v_dts[i];

            -- Записываем MACD line
            SELECT id INTO v_value_type_id FROM indicator_value_types WHERE indicator_id = p_indicator_id AND code = 'MACD';
            IF v_value_type_id IS NOT NULL THEN
                PERFORM insert_indicator_value(p_indicator_id, v_value_type_id, p_security_id, p_timeframe_id, v_dt, v_macd, FALSE, NULL, p_overwrite);
            END IF;

            -- Записываем Signal line
            SELECT id INTO v_value_type_id FROM indicator_value_types WHERE indicator_id = p_indicator_id AND code = 'SIGNAL';
            IF v_value_type_id IS NOT NULL THEN
                PERFORM insert_indicator_value(p_indicator_id, v_value_type_id, p_security_id, p_timeframe_id, v_dt, v_macd_signal, FALSE, NULL, p_overwrite);
            END IF;

            -- Записываем Histogram
            SELECT id INTO v_value_type_id FROM indicator_value_types WHERE indicator_id = p_indicator_id AND code = 'HISTOGRAM';
            IF v_value_type_id IS NOT NULL THEN
                PERFORM insert_indicator_value(p_indicator_id, v_value_type_id, p_security_id, p_timeframe_id, v_dt, v_macd_histogram, FALSE, NULL, p_overwrite);
            END IF;

            -- Записываем нулевую линию (порог)
            SELECT id INTO v_value_type_id FROM indicator_value_types WHERE indicator_id = p_indicator_id AND code = 'ZERO';
            IF v_value_type_id IS NOT NULL THEN
                PERFORM insert_indicator_value(p_indicator_id, v_value_type_id, p_security_id, p_timeframe_id, v_dt, 0, FALSE, NULL, p_overwrite);
            END IF;

            v_records_inserted := v_records_inserted + 3;
        END LOOP;

    -- ==========================================
    -- 6.5 РАСЧЕТ BOLLINGER BANDS
    -- ==========================================
    -- Middle Band = SMA(period)
    -- Upper Band = SMA + (std_dev * σ)
    -- Lower Band = SMA - (std_dev * σ)
    -- Bandwidth = (Upper - Lower) / Middle
    ELSIF v_indicator_code = 'BB' THEN
        FOR i IN v_period .. v_idx
        LOOP
            -- Средняя полоса = SMA
            v_sum := 0;
            FOR j IN i - v_period + 1 .. i
            LOOP
                v_sum := v_sum + v_closes[j];
            END LOOP;
            v_bb_middle := v_sum / v_period;

            -- Стандартное отклонение
            v_bb_sum_sq := 0;
            FOR j IN i - v_period + 1 .. i
            LOOP
                v_bb_sum_sq := v_bb_sum_sq + POWER(v_closes[j] - v_bb_middle, 2);
            END LOOP;
            v_bb_stddev := SQRT(v_bb_sum_sq / v_period);

            -- Верхняя и нижняя полосы
            v_bb_upper := v_bb_middle + (v_std_dev * v_bb_stddev);
            v_bb_lower := v_bb_middle - (v_std_dev * v_bb_stddev);
            v_dt := v_dts[i];

            -- Записываем Upper band
            SELECT id INTO v_value_type_id FROM indicator_value_types WHERE indicator_id = p_indicator_id AND code = 'UPPER';
            IF v_value_type_id IS NOT NULL THEN
                PERFORM insert_indicator_value(p_indicator_id, v_value_type_id, p_security_id, p_timeframe_id, v_dt, v_bb_upper, FALSE, NULL, p_overwrite);
            END IF;

            -- Записываем Middle band
            SELECT id INTO v_value_type_id FROM indicator_value_types WHERE indicator_id = p_indicator_id AND code = 'MIDDLE';
            IF v_value_type_id IS NOT NULL THEN
                PERFORM insert_indicator_value(p_indicator_id, v_value_type_id, p_security_id, p_timeframe_id, v_dt, v_bb_middle, FALSE, NULL, p_overwrite);
            END IF;

            -- Записываем Lower band
            SELECT id INTO v_value_type_id FROM indicator_value_types WHERE indicator_id = p_indicator_id AND code = 'LOWER';
            IF v_value_type_id IS NOT NULL THEN
                PERFORM insert_indicator_value(p_indicator_id, v_value_type_id, p_security_id, p_timeframe_id, v_dt, v_bb_lower, FALSE, NULL, p_overwrite);
            END IF;

            -- Записываем Bandwidth
            SELECT id INTO v_value_type_id FROM indicator_value_types WHERE indicator_id = p_indicator_id AND code = 'BANDWIDTH';
            IF v_value_type_id IS NOT NULL THEN
                PERFORM insert_indicator_value(p_indicator_id, v_value_type_id, p_security_id, p_timeframe_id, v_dt, 
                    (v_bb_upper - v_bb_lower) / v_bb_middle, FALSE, NULL, p_overwrite);
            END IF;

            v_records_inserted := v_records_inserted + 4;
        END LOOP;

    -- ==========================================
    -- 6.6 РАСЧЕТ ATR (Average True Range)
    -- ==========================================
    -- TR = max(High - Low, |High - Close_prev|, |Low - Close_prev|)
    -- ATR = SMA(TR, period) или EMA(TR, period) -- здесь используется Wilder's smoothing
    ELSIF v_indicator_code = 'ATR' THEN
        v_atr := 0;

        FOR i IN 2 .. v_idx
        LOOP
            -- Вычисляем True Range
            v_tr_high := v_highs[i] - v_lows[i];                          -- High - Low
            v_tr_low := ABS(v_highs[i] - v_closes[i-1]);                  -- |High - Close_prev|
            v_tr_close := ABS(v_lows[i] - v_closes[i-1]);                 -- |Low - Close_prev|
            v_tr := GREATEST(v_tr_high, v_tr_low, v_tr_close);            -- Максимум из трех

            -- Wilder's smoothing: ATR = (ATR_prev * (N-1) + TR) / N
            IF i <= v_period THEN
                -- Накопление для первого ATR (простое среднее)
                v_atr := v_atr + v_tr;
                IF i = v_period THEN
                    v_atr := v_atr / v_period;  -- Первое значение = SMA
                END IF;
            ELSE
                -- Последующие значения -- Wilder's smoothing
                v_atr := (v_atr * (v_period - 1) + v_tr) / v_period;
            END IF;

            v_dt := v_dts[i];

            -- Записываем ATR (начиная с периода, только в запрошенном диапазоне)
            IF i >= v_period
               AND v_dts[i] >= p_date_from::TIMESTAMP
               AND v_dts[i] < (p_date_to + INTERVAL '1 day')::TIMESTAMP THEN
                SELECT id INTO v_value_type_id FROM indicator_value_types WHERE indicator_id = p_indicator_id AND code = 'ATR';
                IF v_value_type_id IS NOT NULL THEN
                    PERFORM insert_indicator_value(p_indicator_id, v_value_type_id, p_security_id, p_timeframe_id, v_dt, v_atr, FALSE, NULL, p_overwrite);
                END IF;

                -- Записываем ATR в процентах от цены
                SELECT id INTO v_value_type_id FROM indicator_value_types WHERE indicator_id = p_indicator_id AND code = 'ATR_PCT';
                IF v_value_type_id IS NOT NULL THEN
                    PERFORM insert_indicator_value(p_indicator_id, v_value_type_id, p_security_id, p_timeframe_id, v_dt, 
                        (v_atr / v_closes[i]) * 100, FALSE, NULL, p_overwrite);
                END IF;

                v_records_inserted := v_records_inserted + 2;
            END IF;
        END LOOP;

    -- ==========================================
    -- 6.7 РАСЧЕТ STOCHASTIC OSCILLATOR
    -- ==========================================
    -- %K = (Close - LowestLow) / (HighestHigh - LowestLow) * 100
    -- %D = SMA(%K, 3)
    -- J = 3K - 2D (не используется здесь)
    ELSIF v_indicator_code = 'STOCH' THEN
        FOR i IN v_k_period .. v_idx
        LOOP
            -- Находим минимум low и максимум high за период %K
            v_lowest_low := v_lows[i];
            v_highest_high := v_highs[i];

            FOR j IN i - v_k_period + 1 .. i
            LOOP
                IF v_lows[j] < v_lowest_low THEN v_lowest_low := v_lows[j]; END IF;
                IF v_highs[j] > v_highest_high THEN v_highest_high := v_highs[j]; END IF;
            END LOOP;

            -- Расчет %K
            IF v_highest_high - v_lowest_low = 0 THEN
                v_stoch_k := 50;  -- Если диапазон 0 -- нейтральное значение
            ELSE
                v_stoch_k := ((v_closes[i] - v_lowest_low) / (v_highest_high - v_lowest_low)) * 100;
            END IF;

            v_dt := v_dts[i];

            -- Записываем %K линию
            SELECT id INTO v_value_type_id FROM indicator_value_types WHERE indicator_id = p_indicator_id AND code = 'K';
            IF v_value_type_id IS NOT NULL THEN
                PERFORM insert_indicator_value(p_indicator_id, v_value_type_id, p_security_id, p_timeframe_id, v_dt, v_stoch_k, FALSE, NULL, p_overwrite);
            END IF;

            -- Расчет %D (SMA от %K, период 3)
            IF i >= v_k_period + v_d_period - 1 THEN
                v_k_sum := 0;
                FOR j IN i - v_d_period + 1 .. i
                LOOP
                    -- Пересчитываем %K для каждой точки окна %D
                    v_lowest_low := v_lows[j];
                    v_highest_high := v_highs[j];
                    FOR m IN j - v_k_period + 1 .. j
                    LOOP
                        IF v_lows[m] < v_lowest_low THEN v_lowest_low := v_lows[m]; END IF;
                        IF v_highs[m] > v_highest_high THEN v_highest_high := v_highs[m]; END IF;
                    END LOOP;

                    IF v_highest_high - v_lowest_low = 0 THEN
                        v_k_sum := v_k_sum + 50;
                    ELSE
                        v_k_sum := v_k_sum + ((v_closes[j] - v_lowest_low) / (v_highest_high - v_lowest_low)) * 100;
                    END IF;
                END LOOP;
                v_stoch_d := v_k_sum / v_d_period;

                -- Записываем %D линию
                SELECT id INTO v_value_type_id FROM indicator_value_types WHERE indicator_id = p_indicator_id AND code = 'D';
                IF v_value_type_id IS NOT NULL THEN
                    PERFORM insert_indicator_value(p_indicator_id, v_value_type_id, p_security_id, p_timeframe_id, v_dt, v_stoch_d, FALSE, NULL, p_overwrite);
                END IF;

                -- ============================================================
                -- БЛОК 6.7.1: ПРОВЕРКА ПОРОГОВЫХ СИГНАЛОВ СТОХАСТИКА
                -- ============================================================
                IF v_stoch_k >= 80 THEN
                    -- Перекупленность: %K >= 80
                    SELECT id INTO v_value_type_id FROM indicator_value_types WHERE indicator_id = p_indicator_id AND code = 'OVERBOUGHT';
                    IF v_value_type_id IS NOT NULL THEN
                        PERFORM insert_indicator_value(p_indicator_id, v_value_type_id, p_security_id, p_timeframe_id, v_dt, 80, TRUE, 'overbought', p_overwrite);
                    END IF;
                ELSIF v_stoch_k <= 20 THEN
                    -- Перепроданность: %K <= 20
                    SELECT id INTO v_value_type_id FROM indicator_value_types WHERE indicator_id = p_indicator_id AND code = 'OVERSOLD';
                    IF v_value_type_id IS NOT NULL THEN
                        PERFORM insert_indicator_value(p_indicator_id, v_value_type_id, p_security_id, p_timeframe_id, v_dt, 20, TRUE, 'oversold', p_overwrite);
                    END IF;
                END IF;

                v_records_inserted := v_records_inserted + 3;
            ELSE
                v_records_inserted := v_records_inserted + 1;
            END IF;
        END LOOP;

    -- ==========================================
    -- 6.8 НЕПОДДЕРЖИВАЕМЫЙ ИНДИКАТОР
    -- ==========================================
    ELSE
        RAISE NOTICE 'Расчет для индикатора % пока не реализован в данной процедуре', v_indicator_code;
    END IF;

    -- ============================================================
    -- БЛОК 7: ИТОГОВАЯ СТАТИСТИКА
    -- ============================================================
    RAISE NOTICE '=== РАСЧЕТ ЗАВЕРШЕН ===';
    RAISE NOTICE 'Индикатор: %, Бумага: %, Таймфрейм: %', v_indicator_code, p_security_id, p_timeframe_id;
    RAISE NOTICE 'Вставлено новых записей: %', v_records_inserted;
    RAISE NOTICE 'Обновлено существующих записей: %', v_records_updated;
    RAISE NOTICE 'Пропущено (уже существуют): %', v_records_skipped;

EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION 'Ошибка расчета индикатора % (id=%): %', v_indicator_code, p_indicator_id, SQLERRM;
END;
$$;

-- ============================================
-- КОММЕНТАРИЙ К ПРОЦЕДУРЕ calculate_indicator
-- ============================================
COMMENT ON PROCEDURE calculate_indicator(INTEGER, INTEGER, INTEGER, DATE, DATE, BOOLEAN) IS 
'Рассчитывает значения технического индикатора для указанной бумаги, таймфрейма и периода.

ПАРАМЕТРЫ:
  p_security_id  - ID ценной бумаги (securities.id)
  p_timeframe_id - ID таймфрейма (timeframes.id)
  p_indicator_id - ID индикатора (indicators.id)
  p_date_from    - Начальная дата периода (YYYY-MM-DD)
  p_date_to      - Конечная дата периода (YYYY-MM-DD)
  p_overwrite    - TRUE = перезаписать существующие, FALSE = пропустить

ПОДДЕРЖИВАЕМЫЕ ИНДИКАТОРЫ:
  RSI   - Индекс относительной силы (период 14, пороги 70/30)
  SMA   - Простое скользящее среднее (период 20)
  EMA   - Экспоненциальное скользящее среднее (период 20)
  MACD  - Схождение/расхождение (fast=12, slow=26, signal=9)
  BB    - Полосы Боллинджера (период 20, std_dev=2.0)
  ATR   - Средний истинный диапазон (период 14)
  STOCH - Стохастик (%K=14, %D=3)

ПРИМЕРЫ ВЫЗОВА:
  CALL calculate_indicator(1, 4, 4, ''2026-06-17'', ''2026-06-24'', TRUE);
  -- RSI для SBER (id=1) на M5 (id=4) за неделю с перезаписью

  CALL calculate_indicator(3, 15, 5, ''2026-06-01'', ''2026-06-24'', FALSE);
  -- MACD для GAZP (id=3) на D1 (id=15), пропустить если есть
';

-- ============================================
-- Вспомогательная функция: insert_indicator_value
-- ============================================
-- Параметры:
--   p_indicator_id      - ID индикатора (indicators.id)
--   p_value_type_id     - ID типа значения (indicator_value_types.id)
--   p_security_id       - ID бумаги (securities.id)
--   p_timeframe_id      - ID таймфрейма (timeframes.id)
--   p_dt                - Дата/время свечи
--   p_value             - Значение индикатора
--   p_is_signal         - Это сигнальное значение? (TRUE/FALSE)
--   p_signal_type       - Тип сигнала: buy, sell, overbought, oversold
--   p_overwrite         - Перезаписать существующую запись?
-- ============================================
CREATE OR REPLACE FUNCTION insert_indicator_value(
    p_indicator_id INTEGER,
    p_value_type_id INTEGER,
    p_security_id INTEGER,
    p_timeframe_id INTEGER,
    p_dt TIMESTAMP,
    p_value NUMERIC(18,6),
    p_is_signal BOOLEAN,
    p_signal_type VARCHAR(20),
    p_overwrite BOOLEAN
)
RETURNS VOID AS $$
BEGIN
    IF p_overwrite THEN
        INSERT INTO indicator_values (
            indicator_id, indicator_value_type_id, security_id, timeframe_id,
            dt, value, is_signal, signal_type
        ) VALUES (
            p_indicator_id, p_value_type_id, p_security_id, p_timeframe_id,
            p_dt, p_value, p_is_signal, p_signal_type
        )
        ON CONFLICT (indicator_id, indicator_value_type_id, security_id, timeframe_id, dt)
        DO UPDATE SET
            value = EXCLUDED.value,
            is_signal = EXCLUDED.is_signal,
            signal_type = EXCLUDED.signal_type;
    ELSE
        INSERT INTO indicator_values (
            indicator_id, indicator_value_type_id, security_id, timeframe_id,
            dt, value, is_signal, signal_type
        ) VALUES (
            p_indicator_id, p_value_type_id, p_security_id, p_timeframe_id,
            p_dt, p_value, p_is_signal, p_signal_type
        )
        ON CONFLICT (indicator_id, indicator_value_type_id, security_id, timeframe_id, dt)
        DO NOTHING;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Расчёт через indicators.script (EXECUTE)
CREATE OR REPLACE PROCEDURE calculate_indicator_via_script(
    p_security_id INTEGER,
    p_timeframe_id INTEGER,
    p_indicator_id INTEGER,
    p_date_from DATE,
    p_date_to DATE,
    p_overwrite BOOLEAN,
    p_script TEXT,
    p_period INTEGER,
    p_fast_period INTEGER,
    p_slow_period INTEGER,
    p_signal_period INTEGER,
    p_std_dev NUMERIC,
    p_k_period INTEGER,
    p_d_period INTEGER,
    p_smooth INTEGER
)
LANGUAGE plpgsql AS $$
DECLARE
    v_value_type RECORD;
    v_dt TIMESTAMP;
    v_value NUMERIC;
    v_records_inserted INTEGER := 0;
    v_records_skipped INTEGER := 0;
BEGIN
    FOR v_dt IN
        SELECT dt
        FROM prices
        WHERE security_id = p_security_id
          AND timeframe_id = p_timeframe_id
          AND dt >= p_date_from::TIMESTAMP
          AND dt < (p_date_to + INTERVAL '1 day')::TIMESTAMP
        ORDER BY dt
    LOOP
        FOR v_value_type IN
            SELECT id, code, is_threshold
            FROM indicator_value_types
            WHERE indicator_id = p_indicator_id
              AND is_threshold = FALSE
            ORDER BY display_order, id
        LOOP
            v_value := exec_indicator_script(
                p_script, p_period, p_fast_period, p_slow_period, p_signal_period,
                p_std_dev, p_k_period, p_d_period, p_smooth, v_value_type.code,
                p_security_id, p_timeframe_id, v_dt, p_indicator_id
            );

            IF v_value IS NULL THEN
                CONTINUE;
            END IF;

            PERFORM insert_indicator_value(
                p_indicator_id,
                v_value_type.id,
                p_security_id,
                p_timeframe_id,
                v_dt,
                v_value,
                v_value_type.is_threshold,
                CASE WHEN v_value_type.is_threshold THEN lower(v_value_type.code) ELSE NULL END,
                p_overwrite
            );
            v_records_inserted := v_records_inserted + 1;
        END LOOP;
    END LOOP;

    RAISE NOTICE 'calculate_indicator_via_script: записано % значений', v_records_inserted;
END;
$$;

COMMENT ON PROCEDURE calculate_indicator_via_script IS
'Расчёт индикатора по шаблону indicators.script (динамический EXECUTE, :series — код линии).';


-- ============================================
-- КОММЕНТАРИЙ К ФУНКЦИИ insert_indicator_value
-- ============================================
COMMENT ON FUNCTION insert_indicator_value(INTEGER, INTEGER, INTEGER, INTEGER, TIMESTAMP, NUMERIC, BOOLEAN, VARCHAR, BOOLEAN) IS 
'Вспомогательная функция для вставки/обновления одного значения индикатора.

Проверяет существование записи по уникальному индексу:
(indicator_id, indicator_value_type_id, security_id, timeframe_id, dt)

Если запись существует и p_overwrite=FALSE -- пропускает.
Если запись существует и p_overwrite=TRUE -- удаляет старую и вставляет новую.
Если записи нет -- просто вставляет новую.

Используется внутри calculate_indicator для записи каждого значения.';

-- ============================================
-- Процедура: calculate_all_indicators
-- ============================================
-- Параметры:
--   p_security_id  - ID ценной бумаги
--   p_timeframe_id - ID таймфрейма
--   p_date_from    - Начальная дата периода
--   p_date_to      - Конечная дата периода
--   p_overwrite    - Перезаписывать существующие записи?
-- ============================================
-- Рассчитывает ВСЕ активные индикаторы из таблицы indicators
-- для указанной бумаги, таймфрейма и периода.
-- Ошибки в расчете отдельных индикаторов не прерывают общий процесс.
-- ============================================
CREATE OR REPLACE PROCEDURE calculate_all_indicators(
    p_security_id INTEGER,
    p_timeframe_id INTEGER,
    p_date_from DATE,
    p_date_to DATE,
    p_overwrite BOOLEAN DEFAULT FALSE
)
LANGUAGE plpgsql AS $$
DECLARE
    v_indicator RECORD;  -- Курсор по активным индикаторам
BEGIN
    -- ============================================================
    -- БЛОК: ПЕРЕБОР ВСЕХ АКТИВНЫХ ИНДИКАТОРОВ
    -- ============================================================
    -- Выбираем все индикаторы где is_active = TRUE
    -- и по очереди вызываем для каждого calculate_indicator
    FOR v_indicator IN 
        SELECT id, code, name 
        FROM indicators 
        WHERE is_active = TRUE 
        ORDER BY id
    LOOP
        BEGIN
            -- Вызываем расчет для текущего индикатора
            CALL calculate_indicator(
                p_security_id,    -- Бумага
                p_timeframe_id,   -- Таймфрейм
                v_indicator.id,   -- ID индикатора
                p_date_from,      -- Начало периода
                p_date_to,        -- Конец периода
                p_overwrite       -- Флаг перезаписи
            );
            RAISE NOTICE 'Успешно рассчитан индикатор: % (%)', v_indicator.code, v_indicator.name;

        EXCEPTION
            WHEN OTHERS THEN
                -- Ошибка в одном индикаторе не прерывает расчет остальных
                RAISE NOTICE 'ОШИБКА расчета индикатора % (%): %', 
                    v_indicator.code, v_indicator.name, SQLERRM;
        END;
    END LOOP;

    RAISE NOTICE '=== Расчет всех индикаторов завершен ===';
END;
$$;

-- ============================================
-- КОММЕНТАРИЙ К ПРОЦЕДУРЕ calculate_all_indicators
-- ============================================
COMMENT ON PROCEDURE calculate_all_indicators(INTEGER, INTEGER, DATE, DATE, BOOLEAN) IS 
'Рассчитывает все активные индикаторы (indicators.is_active = TRUE) 
для указанной бумаги, таймфрейма и периода.

Перебирает все записи из таблицы indicators где is_active=TRUE
и вызывает для каждого calculate_indicator.

Ошибка в расчете одного индикатора НЕ прерывает расчет остальных.

ПРИМЕР:
  CALL calculate_all_indicators(1, 4, ''2026-06-17'', ''2026-06-24'', TRUE);
  -- Расчет ВСЕХ индикаторов для SBER на M5 за неделю';

-- ============================================
-- Процедура: calculate_indicators_batch
-- ============================================
-- Параметры:
--   p_security_ids - Массив ID бумаг (INTEGER[])
--   p_timeframe_id - ID таймфрейма
--   p_date_from    - Начальная дата периода
--   p_date_to      - Конечная дата периода
--   p_overwrite    - Перезаписывать существующие записи?
-- ============================================
-- Рассчитывает все индикаторы для массива бумаг.
-- Удобно для массового пересчета по портфелю.
-- ============================================
CREATE OR REPLACE PROCEDURE calculate_indicators_batch(
    p_security_ids INTEGER[],
    p_timeframe_id INTEGER,
    p_date_from DATE,
    p_date_to DATE,
    p_overwrite BOOLEAN DEFAULT FALSE
)
LANGUAGE plpgsql AS $$
DECLARE
    v_security_id INTEGER;  -- Текущая бумага из массива
BEGIN
    -- ============================================================
    -- БЛОК: ПЕРЕБОР ВСЕХ БУМАГ В МАССИВЕ
    -- ============================================================
    FOREACH v_security_id IN ARRAY p_security_ids
    LOOP
        BEGIN
            -- Вызываем расчет всех индикаторов для текущей бумаги
            CALL calculate_all_indicators(
                v_security_id,    -- Текущая бумага
                p_timeframe_id,   -- Таймфрейм
                p_date_from,      -- Начало периода
                p_date_to,        -- Конец периода
                p_overwrite       -- Флаг перезаписи
            );
            RAISE NOTICE 'Рассчитаны индикаторы для security_id=%', v_security_id;

        EXCEPTION
            WHEN OTHERS THEN
                -- Ошибка по одной бумаге не прерывает расчет остальных
                RAISE NOTICE 'ОШИБКА расчета для security_id=%: %', v_security_id, SQLERRM;
        END;
    END LOOP;

    RAISE NOTICE '=== Массовый расчет индикаторов завершен ===';
END;
$$;

-- ============================================
-- КОММЕНТАРИЙ К ПРОЦЕДУРЕ calculate_indicators_batch
-- ============================================
COMMENT ON PROCEDURE calculate_indicators_batch(INTEGER[], INTEGER, DATE, DATE, BOOLEAN) IS 
'Рассчитывает все активные индикаторы для массива бумаг.

Параметр p_security_ids -- массив ID из таблицы securities.

ПРИМЕР:
  CALL calculate_indicators_batch(ARRAY[1, 3, 4, 5], 4, ''2026-06-17'', ''2026-06-24'', FALSE);
  -- Расчет всех индикаторов для SBER, GAZP, LKOH, ROSN на M5';



-- ============================================
-- ЧАСТЬ B: HTTP-ЗАГРУЗКА (pgsql-http)
-- ============================================
--
-- СТОП. Перед выполнением команд ниже (CREATE EXTENSION и процедуры *_http)
-- расширение pgsql-http должно быть установлено на сервере PostgreSQL.
-- Краткая инструкция — в заголовке этого файла (шаг 2, раздел WINDOWS).
--
-- ================================================================
-- WINDOWS — установка pgsql-http (PostgreSQL 15, один раз)
-- ================================================================
--
--   1) Скачать:  https://www.postgresonline.com/downloads/pg15http_w64.zip
--   2) Распаковать в:  <репозиторий>\_tmp_http_ext\pg15http_w64\
--   3) От администратора выполнить:
--        .\scripts\install_pgsql_http.ps1
--      (копирует http.dll, http--*.sql, зависимости libcurl, перезапускает службу)
--   4) Проверить файлы:
--        C:\Program Files\PostgreSQL\15\lib\http.dll
--        C:\Program Files\PostgreSQL\15\share\extension\http.control
--   5) Далее — команды CREATE EXTENSION и процедуры в этом блоке.
--
-- ================================================================
-- LINUX / macOS — установка pgsql-http (сборка из исходников)
-- ================================================================
--
-- ШАГ 1: системные зависимости
--   Debian/Ubuntu:
--     sudo apt-get update
--     sudo apt-get install -y libcurl4-openssl-dev postgresql-server-dev-15
--   CentOS/RHEL/Fedora:
--     sudo yum install libcurl-devel postgresql-devel
--   macOS (Homebrew):
--     brew install curl postgresql
--
-- ШАГ 2: сборка
--   cd /tmp
--   git clone https://github.com/pramsey/pgsql-http.git
--   cd pgsql-http
--   make PG_CONFIG=/usr/lib/postgresql/15/bin/pg_config
--   sudo make install PG_CONFIG=/usr/lib/postgresql/15/bin/pg_config
--
-- ШАГ 3: проверка на диске
--   ls -la $(pg_config --sharedir)/extension/http*
--
-- ШАГ 4–5: CREATE EXTENSION и тест — см. команды ниже в этом блоке.
--
-- ================================================================
-- ПРОВЕРКА ПОСЛЕ CREATE EXTENSION http
-- ================================================================
--   SELECT extname, extversion FROM pg_extension WHERE extname = 'http';
--   SELECT status FROM http_get('https://httpbin.org/get');
--
-- ================================================================
-- БЕЗОПАСНОСТЬ (опционально)
-- ================================================================
--   ALTER SYSTEM SET http.whitelist = 'invest-public-api.tinkoff.ru,iss.moex.com';
--   SELECT pg_reload_conf();
--
-- ================================================================
-- ПЕРЕУСТАНОВКА
-- ================================================================
--   DROP EXTENSION http CASCADE;
--   Windows: удалить http.dll и http* из lib/ и share/extension/, перезапустить службу
--   Linux:   sudo rm $(pg_config --sharedir)/extension/http* $(pg_config --libdir)/http.so
--
-- ================================================================
-- Ниже: CREATE EXTENSION + процедуры load_*_http (часть B скрипта 02).
-- Если расширение не установлено — выполнение остановится на CREATE EXTENSION.
-- Закомментируйте блок до метки «КОНЕЦ ОПЦИОНАЛЬНОГО БЛОКА HTTP» или установите pgsql-http.
-- ================================================================

-- @optional-http-block
-- Ниже: CREATE EXTENSION + процедуры load_*_http (часть B скрипта 02).
-- ============================================
CREATE EXTENSION IF NOT EXISTS http;

-- Настройка CA для libcurl (pgsql-http). Без этого на Windows часто:
-- "SSL certificate problem: unable to get local issuer certificate"
CREATE OR REPLACE FUNCTION configure_http_ssl()
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    v_path TEXT;
    v_candidates TEXT[] := ARRAY[
        'C:/Program Files/PostgreSQL/15/ssl/certs/curl-ca-bundle.crt',
        'C:/Program Files/PostgreSQL/15/ssl/certs/cacert.pem',
        '/etc/ssl/certs/ca-certificates.crt',
        '/etc/pki/tls/certs/ca-bundle.crt'
    ];
BEGIN
    FOREACH v_path IN ARRAY v_candidates
    LOOP
        BEGIN
            PERFORM http_set_curlopt('CURLOPT_CAINFO', v_path);
            PERFORM http_set_curlopt('CURLOPT_SSL_VERIFYPEER', '1');
            RETURN;
        EXCEPTION
            WHEN OTHERS THEN
                CONTINUE;
        END;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION configure_http_ssl() IS
'Указывает libcurl путь к CA-bundle для HTTPS (pgsql-http). См. scripts/fix_pgsql_http_ssl.ps1';

-- instrumentId для GetCandles: ShareBy по тикеру (исправляет устаревший tbank_figi)
CREATE OR REPLACE FUNCTION resolve_tbank_instrument_id(
    p_security_id INTEGER,
    p_prefix VARCHAR,
    p_tbank_figi VARCHAR DEFAULT NULL,
    p_is_future BOOLEAN DEFAULT FALSE,
    p_class_code VARCHAR DEFAULT 'TQBR',
    p_moex_secid VARCHAR DEFAULT NULL
)
RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    v_token TEXT;
    v_headers http_header[];
    v_response http_response;
    v_instrument JSONB;
    v_id TEXT;
    v_try TEXT;
BEGIN
    v_token := get_tbank_token();

    IF p_is_future THEN
        IF v_token IS NULL OR btrim(v_token) = '' THEN
            RETURN COALESCE(p_tbank_figi, p_moex_secid, p_prefix);
        END IF;
        PERFORM configure_http_ssl();
        v_headers := ARRAY[
            http_header('Authorization', 'Bearer ' || v_token),
            http_header('Accept', 'application/json')
        ];
        FOREACH v_try IN ARRAY ARRAY[
            NULLIF(btrim(p_moex_secid), ''),
            NULLIF(btrim(p_prefix), '')
        ]
        LOOP
            CONTINUE WHEN v_try IS NULL;
            SELECT * INTO v_response FROM http((
                'POST',
                COALESCE(
                    (SELECT rtrim(b.api_url, '/') FROM brokers b WHERE b.code = 'T-BANK' LIMIT 1),
                    'https://invest-public-api.tinkoff.ru/rest'
                )
                    || '/tinkoff.public.invest.api.contract.v1.InstrumentsService/FutureBy',
                v_headers,
                'application/json',
                jsonb_build_object(
                    'id_type', 'INSTRUMENT_ID_TYPE_TICKER',
                    'classCode', 'SPBFUT',
                    'id', v_try
                )::TEXT
            )::http_request);
            IF v_response.status = 200 THEN
                v_instrument := v_response.content::JSONB->'instrument';
                v_id := COALESCE(v_instrument->>'uid', v_instrument->>'figi');
                IF p_security_id IS NOT NULL AND p_prefix IS NOT NULL AND v_instrument ? 'figi' THEN
                    UPDATE futures_expirations
                    SET tbank_figi = v_instrument->>'figi'
                    WHERE security_id = p_security_id
                      AND prefix = p_prefix
                      AND tbank_figi IS DISTINCT FROM v_instrument->>'figi';
                END IF;
                RETURN v_id;
            END IF;
        END LOOP;
        RETURN COALESCE(p_tbank_figi, p_moex_secid, p_prefix);
    END IF;

    IF v_token IS NULL OR btrim(v_token) = '' THEN
        RETURN COALESCE(p_tbank_figi, p_prefix);
    END IF;

    PERFORM configure_http_ssl();

    v_headers := ARRAY[
        http_header('Authorization', 'Bearer ' || v_token),
        http_header('Accept', 'application/json')
    ];

    SELECT * INTO v_response FROM http((
        'POST',
        COALESCE(
            (SELECT rtrim(b.api_url, '/') FROM brokers b WHERE b.code = 'T-BANK' LIMIT 1),
            'https://invest-public-api.tinkoff.ru/rest'
        )
            || '/tinkoff.public.invest.api.contract.v1.InstrumentsService/ShareBy',
        v_headers,
        'application/json',
        jsonb_build_object(
            'id_type', 'INSTRUMENT_ID_TYPE_TICKER',
            'classCode', p_class_code,
            'id', p_prefix
        )::TEXT
    )::http_request);

    IF v_response.status != 200 THEN
        RETURN COALESCE(p_tbank_figi, p_prefix);
    END IF;

    v_instrument := v_response.content::JSONB->'instrument';
    v_id := COALESCE(v_instrument->>'uid', v_instrument->>'figi', p_tbank_figi, p_prefix);

    IF p_security_id IS NOT NULL AND v_instrument ? 'figi' THEN
        UPDATE security_prefixes
        SET tbank_figi = v_instrument->>'figi'
        WHERE security_id = p_security_id
          AND exchange_id = 1
          AND tbank_figi IS DISTINCT FROM v_instrument->>'figi';
    END IF;

    RETURN v_id;
END;
$$;

COMMENT ON FUNCTION resolve_tbank_instrument_id(INTEGER, VARCHAR, VARCHAR, BOOLEAN, VARCHAR, VARCHAR) IS
'FutureBy: сначала moex_secid (CRU6), затем prefix (CNY-9.26); ShareBy для акций';

-- Миграция колонок (существующие БД без пересоздания)
ALTER TABLE futures_expirations ADD COLUMN IF NOT EXISTS moex_secid VARCHAR(20);
ALTER TABLE prices ADD COLUMN IF NOT EXISTS contract_prefix VARCHAR(50);
ALTER TABLE price_load_log ADD COLUMN IF NOT EXISTS contract_prefix VARCHAR(50);

-- Старые 4-арг. перегрузки конфликтуют с новыми (DEFAULT → «не уникальна» при CALL)
DROP PROCEDURE IF EXISTS load_prices_from_tbank_http(INTEGER, INTEGER, DATE, DATE);
DROP PROCEDURE IF EXISTS load_prices_from_moex_http(INTEGER, INTEGER, DATE, DATE);

-- Процедура: load_prices_from_tbank_http
-- Загрузка цен через T-Bank API с использованием pgsql-http
-- ============================================
CREATE OR REPLACE PROCEDURE load_prices_from_tbank_http(
    p_security_id INTEGER,
    p_timeframe_id INTEGER,
    p_date_from DATE,
    p_date_to DATE,
    p_contract_prefix VARCHAR DEFAULT NULL,
    p_contract_figi VARCHAR DEFAULT NULL
)
LANGUAGE plpgsql AS $$
DECLARE
    v_prefix VARCHAR(50);
    v_tbank_figi VARCHAR(50);
    v_tf_name VARCHAR(20);
    v_is_future BOOLEAN;
    v_token TEXT;
    v_api_url TEXT;
    v_payload TEXT;
    v_headers http_header[];
    v_response http_response;
    v_status INTEGER;
    v_content JSONB;
    v_candles JSONB;
    v_candle JSONB;
    v_candle_time TIMESTAMP;
    v_candle_open NUMERIC(18,6);
    v_candle_high NUMERIC(18,6);
    v_candle_low NUMERIC(18,6);
    v_candle_close NUMERIC(18,6);
    v_candle_volume NUMERIC(20,2);
    v_records_loaded INTEGER := 0;
    v_i INTEGER;
    v_instrument_id VARCHAR(100);
    v_store_contract VARCHAR(50);
    v_moex_secid VARCHAR(20);
    v_note TEXT;
BEGIN
    PERFORM configure_http_ssl();

    SELECT tf INTO v_tf_name FROM timeframes WHERE id = p_timeframe_id;

    IF p_contract_prefix IS NOT NULL THEN
        v_prefix := p_contract_prefix;
        v_tbank_figi := p_contract_figi;
        v_is_future := TRUE;
        v_store_contract := p_contract_prefix;
        SELECT fe.moex_secid INTO v_moex_secid
        FROM futures_expirations fe
        WHERE fe.security_id = p_security_id
          AND fe.prefix = p_contract_prefix
        LIMIT 1;
    ELSE
        SELECT sp.prefix, sp.tbank_figi, sp.note
        INTO v_prefix, v_tbank_figi, v_note
        FROM security_prefixes sp
        WHERE sp.security_id = p_security_id AND sp.exchange_id = 1;

        IF v_prefix IS NULL THEN
            RAISE EXCEPTION 'Префикс не найден для security_id=%', p_security_id;
        END IF;

        SELECT (st.name = 'Futures') INTO v_is_future
        FROM securities s
        JOIN security_types st ON s.security_type_id = st.id
        WHERE s.id = p_security_id;

        v_store_contract := NULL;

        IF v_is_future THEN
            IF is_perpetual_future_group(v_prefix, v_note) THEN
                v_store_contract := v_prefix;
            ELSE
                SELECT fe.prefix, fe.tbank_figi INTO v_prefix, v_tbank_figi
                FROM futures_expirations fe
                WHERE fe.security_id = p_security_id
                  AND fe.expiration_date > p_date_to
                  AND fe.is_active = TRUE
                ORDER BY fe.expiration_date ASC
                LIMIT 1;
                IF v_prefix IS NULL THEN
                    RAISE EXCEPTION 'Активный фьючерс не найден для security_id=% на дату %',
                        p_security_id, p_date_to;
                END IF;
                v_store_contract := v_prefix;
                SELECT fe.moex_secid INTO v_moex_secid
                FROM futures_expirations fe
                WHERE fe.security_id = p_security_id
                  AND fe.prefix = v_prefix
                LIMIT 1;
            END IF;
        END IF;
    END IF;
    v_token := get_tbank_token();
    IF v_token IS NULL THEN
        RAISE EXCEPTION 'T-Bank токен не найден. Заполните token_encrypted в accounts.';
    END IF;

    -- ============================================================
    -- БЛОК 5: ФОРМИРОВАНИЕ HTTP-ЗАПРОСА
    -- ============================================================
    v_instrument_id := resolve_tbank_instrument_id(
        p_security_id, v_prefix, v_tbank_figi, v_is_future, 'TQBR', v_moex_secid
    );

    v_api_url := 'https://invest-public-api.tinkoff.ru/rest/tinkoff.public.invest.api.contract.v1.MarketDataService/GetCandles';

    v_payload := jsonb_build_object(
        'instrumentId', v_instrument_id,
        'from', tbank_iso_utc(p_date_from),
        'to', tbank_iso_utc(p_date_to + 1),
        'interval', get_tbank_candle_interval(v_tf_name)
    )::TEXT;

    -- Заголовки (Content-Type задаётся в http_request, не в массиве headers)
    v_headers := ARRAY[
        http_header('Authorization', 'Bearer ' || v_token),
        http_header('Accept', 'application/json')
    ];

    -- ============================================================
    -- БЛОК 6: ВЫПОЛНЕНИЕ HTTP POST-ЗАПРОСА ЧЕРЕЗ pgsql-http
    -- ============================================================
    -- Функция http() из расширения pgsql-http выполняет запрос через libcurl
    -- Возвращает тип http_response со статусом, заголовками и телом ответа
    SELECT * INTO v_response FROM http((
        'POST',
        v_api_url,
        v_headers,
        'application/json',
        v_payload
    )::http_request);

    -- Проверяем HTTP-статус
    v_status := v_response.status;

    IF v_status != 200 THEN
        RAISE EXCEPTION 'T-Bank API вернул статус %: %', v_status, v_response.content;
    END IF;

    -- ============================================================
    -- БЛОК 7: РАЗБОР JSON-ОТВЕТА
    -- ============================================================
    -- Преобразуем текст ответа в JSONB
    v_content := v_response.content::JSONB;

    -- Извлекаем массив свечей
    v_candles := v_content->'candles';

    IF v_candles IS NULL OR jsonb_array_length(v_candles) = 0 THEN
        INSERT INTO price_load_log (
            security_id, timeframe_id, date_from, date_to,
            source, records_loaded, contract_prefix, error_message
        )
        VALUES (
            p_security_id, p_timeframe_id, p_date_from, p_date_to,
            'T-BANK', 0, v_store_contract, 'T-Bank вернул пустой массив свечей'
        );
        RAISE NOTICE 'T-Bank вернул пустой массив свечей';
        RETURN;
    END IF;

    -- ============================================================
    -- БЛОК 8: ЗАПИСЬ СВЕЧЕЙ В БАЗУ ДАННЫХ
    -- ============================================================
    FOR v_i IN 0 .. jsonb_array_length(v_candles) - 1
    LOOP
        v_candle := v_candles->v_i;

        -- Извлекаем поля свечи из JSON
        v_candle_time := (v_candle->>'time')::TIMESTAMP;
        v_candle_open := parse_tbank_quotation(v_candle->'open');
        v_candle_high := parse_tbank_quotation(v_candle->'high');
        v_candle_low := parse_tbank_quotation(v_candle->'low');
        v_candle_close := parse_tbank_quotation(v_candle->'close');
        v_candle_volume := COALESCE(parse_tbank_quotation(v_candle->'volume'), (v_candle->>'volume')::NUMERIC);

        -- Вставляем свечу через процедуру insert_candle (UPSERT)
        CALL insert_candle(
            p_security_id,
            p_timeframe_id,
            v_candle_time,
            v_candle_open,
            v_candle_high,
            v_candle_low,
            v_candle_close,
            v_candle_volume,
            NULL,
            NULL,
            v_store_contract
        );

        v_records_loaded := v_records_loaded + 1;
    END LOOP;

    -- ============================================================
    -- БЛОК 9: ЛОГИРОВАНИЕ РЕЗУЛЬТАТА
    -- ============================================================
    INSERT INTO price_load_log (
        security_id, timeframe_id, date_from, date_to,
        source, records_loaded, contract_prefix
    )
    VALUES (
        p_security_id, p_timeframe_id, p_date_from, p_date_to,
        'T-BANK', v_records_loaded, v_store_contract
    );

    RAISE NOTICE 'Загружено % свечей из T-Bank (контракт %)', v_records_loaded, v_store_contract;

EXCEPTION
    WHEN OTHERS THEN
        INSERT INTO price_load_log (
            security_id, timeframe_id, date_from, date_to,
            source, records_loaded, contract_prefix, error_message
        )
        VALUES (
            p_security_id, p_timeframe_id, p_date_from, p_date_to,
            'T-BANK', 0, v_store_contract, SQLERRM
        );
        RAISE;
END;
$$;

COMMENT ON PROCEDURE load_prices_from_tbank_http(INTEGER, INTEGER, DATE, DATE, VARCHAR, VARCHAR) IS 
'Загрузка свечей T-Bank. p_contract_prefix — тикер контракта (Si-6.26) для фьючерсов.';

-- ============================================
-- Процедура: load_prices_from_moex_http
-- Загрузка цен через MOEX ISS API с использованием pgsql-http
-- ============================================
CREATE OR REPLACE PROCEDURE load_prices_from_moex_http(
    p_security_id INTEGER,
    p_timeframe_id INTEGER,
    p_date_from DATE,
    p_date_to DATE,
    p_contract_prefix VARCHAR DEFAULT NULL
)
LANGUAGE plpgsql AS $$
DECLARE
    v_prefix VARCHAR(50);
    v_tf_name VARCHAR(20);
    v_sec_type VARCHAR(50);
    v_engine VARCHAR(20);
    v_market VARCHAR(20);
    v_board VARCHAR(20);
    v_api_url TEXT;
    v_response http_response;
    v_status INTEGER;
    v_content JSONB;
    v_candles_data JSONB;
    v_columns JSONB;
    v_col_map JSONB;
    v_row JSONB;
    v_row_idx INTEGER;
    v_col_idx INTEGER;
    v_dt TIMESTAMP;
    v_open NUMERIC(18,6);
    v_high NUMERIC(18,6);
    v_low NUMERIC(18,6);
    v_close NUMERIC(18,6);
    v_volume NUMERIC(20,2);
    v_value NUMERIC(20,2);
    v_records_loaded INTEGER := 0;
    v_store_contract VARCHAR(50);
    v_moex_ticker VARCHAR(50);
BEGIN
    PERFORM configure_http_ssl();

    SELECT tf INTO v_tf_name FROM timeframes WHERE id = p_timeframe_id;

    IF p_contract_prefix IS NOT NULL THEN
        v_prefix := p_contract_prefix;
        v_store_contract := p_contract_prefix;
        v_engine := 'futures';
        v_market := 'forts';
        v_board := 'RFUD';
        SELECT fe.moex_secid INTO v_moex_ticker
        FROM futures_expirations fe
        WHERE fe.security_id = p_security_id
          AND fe.prefix = p_contract_prefix
        LIMIT 1;
        v_moex_ticker := COALESCE(NULLIF(btrim(v_moex_ticker), ''), v_prefix);
    ELSE
        SELECT sp.prefix, st.name INTO v_prefix, v_sec_type
        FROM securities s
        JOIN security_types st ON s.security_type_id = st.id
        JOIN security_prefixes sp ON s.id = sp.security_id
        WHERE s.id = p_security_id AND sp.exchange_id = 1;

        IF v_prefix IS NULL THEN
            RAISE EXCEPTION 'Префикс не найден для security_id=%', p_security_id;
        END IF;

        v_store_contract := NULL;
        v_engine := CASE v_sec_type
            WHEN 'Stock' THEN 'stock'
            WHEN 'Futures' THEN 'futures'
            WHEN 'Bond' THEN 'bonds'
            WHEN 'Index' THEN 'stock'
            ELSE 'stock'
        END;
        v_market := CASE v_sec_type
            WHEN 'Stock' THEN 'shares'
            WHEN 'Futures' THEN 'forts'
            WHEN 'Bond' THEN 'bonds'
            WHEN 'Index' THEN 'index'
            ELSE 'shares'
        END;
        v_board := CASE v_sec_type
            WHEN 'Stock' THEN 'TQBR'
            WHEN 'Futures' THEN 'RFUD'
            WHEN 'Bond' THEN 'TQOB'
            ELSE 'TQBR'
        END;

        IF v_engine = 'futures' THEN
            v_prefix := get_active_future_prefix(p_security_id, p_date_to);
            IF v_prefix IS NULL THEN
                RAISE EXCEPTION 'Активный фьючерс не найден для security_id=% на дату %',
                    p_security_id, p_date_to;
            END IF;
            v_store_contract := v_prefix;
        END IF;
    END IF;

    IF p_contract_prefix IS NOT NULL THEN
        v_prefix := v_moex_ticker;
    END IF;

    v_api_url := format(
        'https://iss.moex.com/iss/engines/%s/markets/%s/boards/%s/securities/%s/candles.json?from=%s&till=%s&interval=%s',
        v_engine, v_market, v_board, v_prefix,
        p_date_from::TEXT,
        p_date_to::TEXT,
        get_moex_candle_interval(v_tf_name)::TEXT
    );

    RAISE NOTICE 'MOEX API URL: %', v_api_url;

    -- Выполняем GET-запрос через pgsql-http
    SELECT * INTO v_response FROM http_get(v_api_url);

    v_status := v_response.status;
    IF v_status != 200 THEN
        RAISE EXCEPTION 'MOEX API вернул статус %: %', v_status, v_response.content;
    END IF;

    -- ============================================================
    -- БЛОК 4: РАЗБОР JSON-ОТВЕТА MOEX
    -- ============================================================
    v_content := v_response.content::JSONB;

    -- MOEX возвращает данные в формате: {"candles": {"columns": [...], "data": [...]}}
    v_candles_data := v_content->'candles'->'data';
    v_columns := v_content->'candles'->'columns';

    IF v_candles_data IS NULL OR jsonb_array_length(v_candles_data) = 0 THEN
        INSERT INTO price_load_log (security_id, timeframe_id, date_from, date_to, source, records_loaded, error_message)
        VALUES (p_security_id, p_timeframe_id, p_date_from, p_date_to, 'MOEX', 0,
            'MOEX ISS: нет свечей M15 за период (ISS часто не хранит минутную историю; URL: '
            || left(v_api_url, 180) || ')');
        RAISE NOTICE 'MOEX вернул пустой массив свечей';
        RETURN;
    END IF;

    -- Создаем маппинг колонок: название -> индекс
    v_col_map := '{}'::JSONB;
    FOR v_col_idx IN 0 .. jsonb_array_length(v_columns) - 1
    LOOP
        v_col_map := jsonb_set(v_col_map, ARRAY[v_columns->>v_col_idx], to_jsonb(v_col_idx));
    END LOOP;

    -- ============================================================
    -- БЛОК 5: ЗАПИСЬ СВЕЧЕЙ В БАЗУ
    -- ============================================================
    FOR v_row_idx IN 0 .. jsonb_array_length(v_candles_data) - 1
    LOOP
        v_row := v_candles_data->v_row_idx;

        -- Извлекаем данные по индексам колонок
        v_dt := (v_row->>(v_col_map->>'begin')::INTEGER)::TIMESTAMP;
        v_open := (v_row->>(v_col_map->>'open')::INTEGER)::NUMERIC;
        v_high := (v_row->>(v_col_map->>'high')::INTEGER)::NUMERIC;
        v_low := (v_row->>(v_col_map->>'low')::INTEGER)::NUMERIC;
        v_close := (v_row->>(v_col_map->>'close')::INTEGER)::NUMERIC;
        v_volume := (v_row->>(v_col_map->>'volume')::INTEGER)::NUMERIC;
        v_value := (v_row->>(v_col_map->>'value')::INTEGER)::NUMERIC;

        -- Вставляем свечу
        CALL insert_candle(
            p_security_id, p_timeframe_id, v_dt,
            v_open, v_high, v_low, v_close,
            v_volume, v_value, NULL, v_store_contract
        );

        v_records_loaded := v_records_loaded + 1;
    END LOOP;

    -- ============================================================
    -- БЛОК 6: ЛОГИРОВАНИЕ
    -- ============================================================
    INSERT INTO price_load_log (
        security_id, timeframe_id, date_from, date_to,
        source, records_loaded, contract_prefix
    )
    VALUES (
        p_security_id, p_timeframe_id, p_date_from, p_date_to,
        'MOEX', v_records_loaded, v_store_contract
    );

    RAISE NOTICE 'Загружено % свечей из MOEX (контракт %)', v_records_loaded, v_store_contract;

EXCEPTION
    WHEN OTHERS THEN
        INSERT INTO price_load_log (
            security_id, timeframe_id, date_from, date_to,
            source, records_loaded, contract_prefix, error_message
        )
        VALUES (
            p_security_id, p_timeframe_id, p_date_from, p_date_to,
            'MOEX', 0, v_store_contract, SQLERRM
        );
        RAISE;
END;
$$;

COMMENT ON PROCEDURE load_prices_from_moex_http(INTEGER, INTEGER, DATE, DATE, VARCHAR) IS 
'Загрузка MOEX ISS. p_contract_prefix — тикер контракта для фьючерсов.';

-- MOEX ASSETCODE для группового префикса (CR → CNY, Br → BR)
CREATE OR REPLACE FUNCTION moex_future_asset_code(p_group_prefix VARCHAR)
RETURNS VARCHAR
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE upper(btrim(p_group_prefix))
        WHEN 'CR' THEN 'CNY'
        WHEN 'BR' THEN 'BR'
        ELSE btrim(p_group_prefix)
    END;
$$;

COMMENT ON FUNCTION moex_future_asset_code(VARCHAR) IS
'Код базового актива MOEX FORTS для группового префикса (CR → CNY)';

-- Синхронизация контрактов фьючерса из MOEX ISS → futures_expirations
CREATE OR REPLACE PROCEDURE sync_futures_expirations_from_moex(
    p_security_id INTEGER,
    p_date_from DATE,
    p_date_to DATE DEFAULT NULL
)
LANGUAGE plpgsql AS $$
DECLARE
    v_group_prefix VARCHAR(50);
    v_note TEXT;
    v_asset_code VARCHAR(50);
    v_url TEXT;
    v_response http_response;
    v_content JSONB;
    v_data JSONB;
    v_columns JSONB;
    v_col_map JSONB;
    v_row JSONB;
    v_row_idx INTEGER;
    v_col_idx INTEGER;
    v_secid TEXT;
    v_shortname TEXT;
    v_asset TEXT;
    v_lastdel DATE;
    v_cutoff DATE;
    v_synced INTEGER := 0;
BEGIN
    PERFORM configure_http_ssl();

    SELECT sp.prefix, sp.note INTO v_group_prefix, v_note
    FROM security_prefixes sp
    WHERE sp.security_id = p_security_id AND sp.exchange_id = 1;

    IF v_group_prefix IS NULL THEN
        RAISE EXCEPTION 'Префикс группы не найден для security_id=%', p_security_id;
    END IF;

    IF is_perpetual_future_group(v_group_prefix, v_note) THEN
        INSERT INTO futures_expirations (security_id, prefix, expiration_date, is_active)
        VALUES (p_security_id, v_group_prefix, DATE '2100-01-01', TRUE)
        ON CONFLICT (security_id, prefix) DO UPDATE SET
            expiration_date = EXCLUDED.expiration_date,
            is_active = TRUE;
        RETURN;
    END IF;

    v_asset_code := moex_future_asset_code(v_group_prefix);
    v_cutoff := LEAST(p_date_from, COALESCE(p_date_to, p_date_from)) - INTERVAL '400 days';

    v_url := 'https://iss.moex.com/iss/engines/futures/markets/forts/securities.json'
        || '?iss.meta=off&iss.only=securities'
        || '&securities.columns=SECID,SHORTNAME,ASSETCODE,LASTTRADEDATE,LASTDELDATE';

    SELECT * INTO v_response FROM http_get(v_url);
    IF v_response.status != 200 THEN
        RAISE EXCEPTION 'MOEX securities list: status %', v_response.status;
    END IF;

    v_content := v_response.content::JSONB;
    v_data := v_content->'securities'->'data';
    v_columns := v_content->'securities'->'columns';

    IF v_data IS NULL OR jsonb_array_length(v_data) = 0 THEN
        RAISE EXCEPTION 'MOEX securities list: пустой ответ';
    END IF;

    v_col_map := '{}'::JSONB;
    FOR v_col_idx IN 0 .. jsonb_array_length(v_columns) - 1
    LOOP
        v_col_map := jsonb_set(v_col_map, ARRAY[v_columns->>v_col_idx], to_jsonb(v_col_idx));
    END LOOP;

    FOR v_row_idx IN 0 .. jsonb_array_length(v_data) - 1
    LOOP
        v_row := v_data->v_row_idx;
        v_secid := v_row->>(v_col_map->>'SECID')::INTEGER;
        v_shortname := v_row->>(v_col_map->>'SHORTNAME')::INTEGER;
        v_asset := v_row->>(v_col_map->>'ASSETCODE')::INTEGER;
        v_lastdel := NULLIF(v_row->>(v_col_map->>'LASTDELDATE')::INTEGER, '')::DATE;

        IF v_shortname IS NULL OR v_lastdel IS NULL THEN
            CONTINUE;
        END IF;

        IF upper(v_asset) = upper(v_asset_code)
           OR upper(v_secid) LIKE upper(v_group_prefix) || '%'
        THEN
            IF v_lastdel >= v_cutoff THEN
                INSERT INTO futures_expirations (security_id, prefix, moex_secid, expiration_date, is_active)
                VALUES (p_security_id, v_shortname, v_secid, v_lastdel, TRUE)
                ON CONFLICT (security_id, prefix) DO UPDATE SET
                    moex_secid = EXCLUDED.moex_secid,
                    expiration_date = EXCLUDED.expiration_date,
                    is_active = TRUE;
                v_synced := v_synced + 1;
            END IF;
        END IF;
    END LOOP;

    RAISE NOTICE 'sync_futures_expirations_from_moex: security_id=% synced % (group=%, asset=%)',
        p_security_id, v_synced, v_group_prefix, v_asset_code;
END;
$$;

COMMENT ON PROCEDURE sync_futures_expirations_from_moex(INTEGER, DATE, DATE) IS
'Подтягивает контракты MOEX FORTS в futures_expirations по групповому префиксу (Si, CR→CNY …)';

-- Загрузка фьючерса: обход контрактов от date_to назад (rollover)
CREATE OR REPLACE PROCEDURE load_prices_futures_http(
    p_security_id INTEGER,
    p_timeframe_id INTEGER,
    p_date_from DATE,
    p_date_to DATE
)
LANGUAGE plpgsql AS $$
DECLARE
    v_seg_to DATE := p_date_to;
    v_seg_from DATE;
    v_contract RECORD;
    v_tbank_total INTEGER := 0;
    v_seg_records INTEGER;
    v_moex_total INTEGER := 0;
    v_logged_no_contract BOOLEAN := FALSE;
BEGIN
    PERFORM configure_http_ssl();

    CALL sync_futures_expirations_from_moex(p_security_id, p_date_from, p_date_to);

    LOOP
        SELECT * INTO v_contract
        FROM get_future_contract_for_date(p_security_id, v_seg_to);

        IF NOT FOUND THEN
            CALL sync_futures_expirations_from_moex(p_security_id, p_date_from, v_seg_to);
            SELECT * INTO v_contract
            FROM get_future_contract_for_date(p_security_id, v_seg_to);
            IF NOT FOUND THEN
                IF NOT v_logged_no_contract AND v_tbank_total = 0 THEN
                    INSERT INTO price_load_log (
                        security_id, timeframe_id, date_from, date_to,
                        source, records_loaded, error_message
                    )
                    VALUES (
                        p_security_id, p_timeframe_id, p_date_from, p_date_to,
                        'T-BANK', 0,
                        format('Контракт не найден на дату %s после sync MOEX', v_seg_to)
                    );
                    v_logged_no_contract := TRUE;
                END IF;
                EXIT;
            END IF;
        END IF;

        v_seg_from := GREATEST(p_date_from, v_contract.start_date);

        BEGIN
            CALL load_prices_from_tbank_http(
                p_security_id, p_timeframe_id, v_seg_from, v_seg_to,
                v_contract.prefix, v_contract.tbank_figi
            );
            SELECT records_loaded INTO v_seg_records
            FROM price_load_log
            WHERE security_id = p_security_id
              AND timeframe_id = p_timeframe_id
              AND date_from = v_seg_from
              AND date_to = v_seg_to
              AND source = 'T-BANK'
            ORDER BY id DESC
            LIMIT 1;
            v_tbank_total := v_tbank_total + COALESCE(v_seg_records, 0);
        EXCEPTION
            WHEN OTHERS THEN
                INSERT INTO price_load_log (
                    security_id, timeframe_id, date_from, date_to,
                    source, records_loaded, contract_prefix, error_message
                )
                VALUES (
                    p_security_id, p_timeframe_id, v_seg_from, v_seg_to,
                    'T-BANK', 0, v_contract.prefix, SQLERRM
                );
        END;

        IF v_seg_from <= p_date_from THEN
            EXIT;
        END IF;
        v_seg_to := v_seg_from - 1;
    END LOOP;

    IF v_tbank_total > 0 THEN
        RETURN;
    END IF;

    v_seg_to := p_date_to;
    LOOP
        SELECT * INTO v_contract
        FROM get_future_contract_for_date(p_security_id, v_seg_to);
        IF NOT FOUND THEN
            EXIT;
        END IF;
        v_seg_from := GREATEST(p_date_from, v_contract.start_date);

        BEGIN
            CALL load_prices_from_moex_http(
                p_security_id, p_timeframe_id, v_seg_from, v_seg_to,
                v_contract.prefix
            );
            SELECT records_loaded INTO v_seg_records
            FROM price_load_log
            WHERE security_id = p_security_id
              AND timeframe_id = p_timeframe_id
              AND date_from = v_seg_from
              AND date_to = v_seg_to
              AND source = 'MOEX'
            ORDER BY id DESC
            LIMIT 1;
            v_moex_total := v_moex_total + COALESCE(v_seg_records, 0);
        EXCEPTION
            WHEN OTHERS THEN
                NULL;
        END;

        IF v_seg_from <= p_date_from THEN
            EXIT;
        END IF;
        v_seg_to := v_seg_from - 1;
    END LOOP;
END;
$$;

COMMENT ON PROCEDURE load_prices_futures_http(INTEGER, INTEGER, DATE, DATE) IS
'Фьючерс-группа: загрузка по контрактам от date_to назад (Si-6.26 → Si-3.26 …), T-Bank → MOEX';

-- ============================================
-- ГЛАВНАЯ ПРОЦЕДУРА: load_prices_http
-- Сначала T-Bank, если не сработало -- MOEX
-- ============================================
CREATE OR REPLACE PROCEDURE load_prices_http(
    p_security_id INTEGER,
    p_timeframe_id INTEGER,
    p_date_from DATE,
    p_date_to DATE
)
LANGUAGE plpgsql AS $$
DECLARE
    v_tbank_ok BOOLEAN := FALSE;
    v_tbank_records INTEGER := 0;
    v_tbank_error TEXT;
    v_moex_records INTEGER := 0;
    v_is_future BOOLEAN := FALSE;
    v_group_prefix VARCHAR(50);
    v_note TEXT;
BEGIN
    PERFORM set_config('lock_timeout', '15000', true);
    PERFORM set_config('statement_timeout', '180000', true);
    PERFORM configure_http_ssl();

    SELECT (st.name = 'Futures') INTO v_is_future
    FROM securities s
    JOIN security_types st ON s.security_type_id = st.id
    WHERE s.id = p_security_id;

    SELECT sp.prefix, sp.note INTO v_group_prefix, v_note
    FROM security_prefixes sp
    WHERE sp.security_id = p_security_id AND sp.exchange_id = 1;

    IF v_is_future AND is_perpetual_future_group(v_group_prefix, v_note) THEN
        BEGIN
            CALL load_prices_from_tbank_http(p_security_id, p_timeframe_id, p_date_from, p_date_to);
            SELECT records_loaded INTO v_tbank_records
            FROM price_load_log
            WHERE security_id = p_security_id
              AND timeframe_id = p_timeframe_id
              AND date_from = p_date_from
              AND date_to = p_date_to
              AND source = 'T-BANK'
            ORDER BY id DESC
            LIMIT 1;
            v_tbank_ok := COALESCE(v_tbank_records, 0) > 0;
        EXCEPTION
            WHEN OTHERS THEN
                v_tbank_error := SQLERRM;
                INSERT INTO price_load_log (
                    security_id, timeframe_id, date_from, date_to,
                    source, records_loaded, error_message
                )
                VALUES (
                    p_security_id, p_timeframe_id, p_date_from, p_date_to,
                    'T-BANK', 0, v_tbank_error
                );
        END;
        IF NOT v_tbank_ok THEN
            BEGIN
                CALL load_prices_from_moex_http(p_security_id, p_timeframe_id, p_date_from, p_date_to);
            EXCEPTION
                WHEN OTHERS THEN
                    IF v_tbank_error IS NOT NULL THEN
                        RAISE EXCEPTION 'Оба источника недоступны. T-Bank: %; MOEX: %', v_tbank_error, SQLERRM;
                    ELSE
                        RAISE;
                    END IF;
            END;
        END IF;
        RETURN;
    END IF;

    IF v_is_future THEN
        CALL load_prices_futures_http(p_security_id, p_timeframe_id, p_date_from, p_date_to);
        SELECT COALESCE(SUM(records_loaded), 0) INTO v_tbank_records
        FROM price_load_log
        WHERE security_id = p_security_id
          AND timeframe_id = p_timeframe_id
          AND date_from >= p_date_from
          AND date_to <= p_date_to
          AND source = 'T-BANK'
          AND loaded_at >= (CURRENT_TIMESTAMP - INTERVAL '5 minutes');
        IF COALESCE(v_tbank_records, 0) = 0 THEN
            SELECT COALESCE(SUM(records_loaded), 0) INTO v_moex_records
            FROM price_load_log
            WHERE security_id = p_security_id
              AND timeframe_id = p_timeframe_id
              AND date_from >= p_date_from
              AND date_to <= p_date_to
              AND source = 'MOEX'
              AND loaded_at >= (CURRENT_TIMESTAMP - INTERVAL '5 minutes');
        END IF;
        RETURN;
    END IF;

    -- Акции и прочее: T-Bank → MOEX
    BEGIN
        CALL load_prices_from_tbank_http(p_security_id, p_timeframe_id, p_date_from, p_date_to);
        SELECT records_loaded INTO v_tbank_records
        FROM price_load_log
        WHERE security_id = p_security_id
          AND timeframe_id = p_timeframe_id
          AND date_from = p_date_from
          AND date_to = p_date_to
          AND source = 'T-BANK'
        ORDER BY id DESC
        LIMIT 1;
        v_tbank_ok := COALESCE(v_tbank_records, 0) > 0;
        IF v_tbank_ok THEN
            RAISE NOTICE 'Цены успешно загружены из T-Bank: % свечей', v_tbank_records;
        ELSE
            RAISE NOTICE 'T-Bank: 0 свечей, пробуем MOEX...';
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            v_tbank_error := SQLERRM;
            INSERT INTO price_load_log (
                security_id, timeframe_id, date_from, date_to,
                source, records_loaded, error_message
            )
            VALUES (
                p_security_id, p_timeframe_id, p_date_from, p_date_to,
                'T-BANK', 0, v_tbank_error
            );
            RAISE NOTICE 'T-Bank недоступен: %. Переключаемся на MOEX...', v_tbank_error;
    END;

    -- ============================================================
    -- БЛОК 2: MOEX — если T-Bank не дал данных
    -- ============================================================
    IF NOT v_tbank_ok THEN
        BEGIN
            CALL load_prices_from_moex_http(p_security_id, p_timeframe_id, p_date_from, p_date_to);
            SELECT records_loaded INTO v_moex_records
            FROM price_load_log
            WHERE security_id = p_security_id
              AND timeframe_id = p_timeframe_id
              AND date_from = p_date_from
              AND date_to = p_date_to
              AND source = 'MOEX'
            ORDER BY id DESC
            LIMIT 1;
            IF COALESCE(v_moex_records, 0) > 0 THEN
                RAISE NOTICE 'Цены успешно загружены из MOEX: % свечей', v_moex_records;
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                IF v_tbank_error IS NOT NULL THEN
                    RAISE EXCEPTION 'Оба источника недоступны. T-Bank: %; MOEX: %', v_tbank_error, SQLERRM;
                ELSE
                    RAISE EXCEPTION 'MOEX: %', SQLERRM;
                END IF;
        END;
    END IF;
END;
$$;

COMMENT ON PROCEDURE load_prices_http(INTEGER, INTEGER, DATE, DATE) IS 
'Загрузка цен: T-Bank (приоритет), MOEX — только если T-Bank дал 0 свечей или ошибку.';

-- ============================================
-- Процедура: load_prices_batch_http
-- Загрузка цен для нескольких бумаг сразу
-- ============================================
CREATE OR REPLACE PROCEDURE load_prices_batch_http(
    p_security_ids INTEGER[],
    p_timeframe_id INTEGER,
    p_date_from DATE,
    p_date_to DATE
)
LANGUAGE plpgsql AS $$
DECLARE
    v_security_id INTEGER;
BEGIN
    FOREACH v_security_id IN ARRAY p_security_ids
    LOOP
        BEGIN
            CALL load_prices_http(v_security_id, p_timeframe_id, p_date_from, p_date_to);
            RAISE NOTICE 'Загружены цены для security_id=%', v_security_id;
        EXCEPTION
            WHEN OTHERS THEN
                RAISE NOTICE 'Ошибка загрузки для security_id=%: %', v_security_id, SQLERRM;
        END;
    END LOOP;
END;
$$;

COMMENT ON PROCEDURE load_prices_batch_http(INTEGER[], INTEGER, DATE, DATE) IS 
'Загружает цены для массива бумаг по одному таймфрейму и периоду через pgsql-http.
Требует установки расширения: CREATE EXTENSION http;';

-- ============================================
-- Процедура: load_all_timeframes_http
-- Загрузка всех таймфреймов для одной бумаги
-- ============================================
CREATE OR REPLACE PROCEDURE load_all_timeframes_http(
    p_security_id INTEGER,
    p_date_from DATE,
    p_date_to DATE
)
LANGUAGE plpgsql AS $$
DECLARE
    v_tf RECORD;
BEGIN
    FOR v_tf IN SELECT id FROM timeframes WHERE COALESCE(is_active, TRUE) = TRUE ORDER BY sec
    LOOP
        BEGIN
            CALL load_prices_http(p_security_id, v_tf.id, p_date_from, p_date_to);
            RAISE NOTICE 'Загружен таймфрейм id=% для security_id=%', v_tf.id, p_security_id;
        EXCEPTION
            WHEN OTHERS THEN
                RAISE NOTICE 'Ошибка загрузки таймфрейма id=%: %', v_tf.id, SQLERRM;
        END;
    END LOOP;
END;
$$;

COMMENT ON PROCEDURE load_all_timeframes_http(INTEGER, DATE, DATE) IS 
'Загружает все таймфреймы для одной бумаги через pgsql-http.
Требует установки расширения: CREATE EXTENSION http;';

-- ============================================
-- T-BANK API через pgsql-http (счета, портфель, сделки)
-- Все HTTP-вызовы к брокеру/бирже — только из PostgreSQL.
-- ============================================

CREATE OR REPLACE FUNCTION get_tbank_api_url(p_broker_id INTEGER DEFAULT NULL)
RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    v_url TEXT;
BEGIN
    IF p_broker_id IS NOT NULL THEN
        SELECT api_url INTO v_url FROM brokers WHERE id = p_broker_id;
        IF v_url IS NOT NULL THEN
            RETURN rtrim(v_url, '/');
        END IF;
    END IF;
    SELECT api_url INTO v_url FROM brokers WHERE code = 'T-BANK' LIMIT 1;
    RETURN rtrim(COALESCE(v_url, 'https://invest-public-api.tinkoff.ru/rest'), '/');
END;
$$;

COMMENT ON FUNCTION get_tbank_api_url(INTEGER) IS
'Базовый REST URL T-Bank из brokers.api_url';

CREATE OR REPLACE FUNCTION tbank_http_post(
    p_api_url TEXT,
    p_rpc_path TEXT,
    p_token TEXT,
    p_body JSONB DEFAULT '{}'::jsonb
)
RETURNS JSONB
LANGUAGE plpgsql AS $$
DECLARE
    v_url TEXT;
    v_headers http_header[];
    v_response http_response;
    v_content JSONB;
BEGIN
    PERFORM configure_http_ssl();

    v_url := rtrim(COALESCE(p_api_url, get_tbank_api_url()), '/')
        || '/' || ltrim(p_rpc_path, '/');

    v_headers := ARRAY[
        http_header('Authorization', 'Bearer ' || p_token),
        http_header('Accept', 'application/json')
    ];

    SELECT * INTO v_response FROM http((
        'POST',
        v_url,
        v_headers,
        'application/json',
        COALESCE(p_body, '{}'::jsonb)::TEXT
    )::http_request);

    IF v_response.status != 200 THEN
        RAISE EXCEPTION 'T-Bank API HTTP %: %', v_response.status, v_response.content;
    END IF;

    v_content := v_response.content::JSONB;
    IF v_content ? 'code' AND (v_content->>'code') NOT IN ('', '0') THEN
        RAISE EXCEPTION 'T-Bank API: %', COALESCE(v_content->>'message', v_response.content);
    END IF;

    RETURN v_content;
END;
$$;

COMMENT ON FUNCTION tbank_http_post(TEXT, TEXT, TEXT, JSONB) IS
'Универсальный POST к T-Bank Invest API через pgsql-http';

CREATE OR REPLACE FUNCTION format_money_ru(
    p_amount NUMERIC,
    p_currency VARCHAR DEFAULT 'RUB'
)
RETURNS TEXT
LANGUAGE plpgsql AS $$
BEGIN
    IF p_amount IS NULL THEN
        RETURN NULL;
    END IF;
    RETURN to_char(p_amount, 'FM999G999G999G990D00') || ' '
        || CASE upper(COALESCE(p_currency, 'RUB'))
            WHEN 'RUB' THEN '₽'
            WHEN 'USD' THEN '$'
            WHEN 'EUR' THEN '€'
            ELSE upper(p_currency)
        END;
END;
$$;

COMMENT ON FUNCTION format_money_ru(NUMERIC, VARCHAR) IS
'Форматирование суммы для UI (остаток на счёте)';

CREATE OR REPLACE FUNCTION fetch_tbank_accounts(
    p_api_url TEXT,
    p_token TEXT
)
RETURNS JSONB
LANGUAGE sql AS $$
    SELECT COALESCE(
        tbank_http_post(
            p_api_url,
            'tinkoff.public.invest.api.contract.v1.UsersService/GetAccounts',
            p_token,
            '{}'::jsonb
        )->'accounts',
        '[]'::jsonb
    );
$$;

COMMENT ON FUNCTION fetch_tbank_accounts(TEXT, TEXT) IS
'Список счетов T-Bank (GetAccounts)';

CREATE OR REPLACE FUNCTION resolve_tbank_account(
    p_api_url TEXT,
    p_token TEXT,
    p_preferred_account_id VARCHAR DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql AS $$
DECLARE
    v_accounts JSONB;
    v_acc JSONB;
    v_picked JSONB;
    v_i INTEGER;
    v_mapped JSONB := '[]'::jsonb;
BEGIN
    v_accounts := fetch_tbank_accounts(p_api_url, p_token);
    IF jsonb_array_length(v_accounts) = 0 THEN
        RAISE EXCEPTION 'По токену не найдено ни одного счёта в T-Bank';
    END IF;

    IF p_preferred_account_id IS NOT NULL AND btrim(p_preferred_account_id) <> '' THEN
        FOR v_i IN 0 .. jsonb_array_length(v_accounts) - 1
        LOOP
            v_acc := v_accounts->v_i;
            IF v_acc->>'id' = p_preferred_account_id THEN
                v_picked := v_acc;
                EXIT;
            END IF;
        END LOOP;
    END IF;

    IF v_picked IS NULL THEN
        FOR v_i IN 0 .. jsonb_array_length(v_accounts) - 1
        LOOP
            v_acc := v_accounts->v_i;
            IF v_acc->>'status' = 'ACCOUNT_STATUS_OPEN' THEN
                v_picked := v_acc;
                EXIT;
            END IF;
        END LOOP;
    END IF;

    IF v_picked IS NULL THEN
        v_picked := v_accounts->0;
    END IF;

    FOR v_i IN 0 .. jsonb_array_length(v_accounts) - 1
    LOOP
        v_acc := v_accounts->v_i;
        v_mapped := v_mapped || jsonb_build_array(jsonb_build_object(
            'id', v_acc->>'id',
            'name', COALESCE(v_acc->>'name', ''),
            'type', COALESCE(v_acc->>'type', ''),
            'status', COALESCE(v_acc->>'status', '')
        ));
    END LOOP;

    RETURN jsonb_build_object(
        'accounts', v_mapped,
        'account_id', v_picked->>'id',
        'account_name', COALESCE(v_picked->>'name', '')
    );
END;
$$;

COMMENT ON FUNCTION resolve_tbank_account(TEXT, TEXT, VARCHAR) IS
'Выбор счёта T-Bank по токену (GetAccounts + preferred id)';

CREATE OR REPLACE FUNCTION fetch_tbank_portfolio_balance(
    p_api_url TEXT,
    p_token TEXT,
    p_account_id VARCHAR
)
RETURNS JSONB
LANGUAGE plpgsql AS $$
DECLARE
    v_data JSONB;
    v_total JSONB;
    v_amount NUMERIC;
    v_currency VARCHAR;
BEGIN
    v_data := tbank_http_post(
        p_api_url,
        'tinkoff.public.invest.api.contract.v1.OperationsService/GetPortfolio',
        p_token,
        jsonb_build_object('accountId', p_account_id)
    );

    v_total := COALESCE(v_data->'totalAmountPortfolio', v_data->'totalAmountShares');
    v_amount := parse_tbank_quotation(v_total);
    v_currency := COALESCE(v_total->>'currency', 'RUB');

    RETURN jsonb_build_object(
        'amount', v_amount,
        'currency', v_currency,
        'display', format_money_ru(v_amount, v_currency)
    );
END;
$$;

COMMENT ON FUNCTION fetch_tbank_portfolio_balance(TEXT, TEXT, VARCHAR) IS
'Остаток портфеля T-Bank (GetPortfolio)';

CREATE OR REPLACE FUNCTION fetch_tbank_account_balance(p_account_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql AS $$
DECLARE
    v_token TEXT;
    v_api_url TEXT;
    v_account_code VARCHAR;
    v_account_type VARCHAR;
    v_broker_code VARCHAR;
    v_resolved JSONB;
BEGIN
    SELECT btrim(a.token_encrypted), b.api_url, a.account_code, a.account_type, b.code
    INTO v_token, v_api_url, v_account_code, v_account_type, v_broker_code
    FROM accounts a
    JOIN brokers b ON b.id = a.broker_id
    WHERE a.id = p_account_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Счёт id=% не найден', p_account_id;
    END IF;

    IF v_account_type = 'fake' THEN
        RETURN jsonb_build_object('display', 'демо');
    END IF;

    IF v_broker_code <> 'T-BANK' THEN
        RETURN jsonb_build_object('display', 'н/д');
    END IF;

    IF v_token IS NULL OR v_token = '' THEN
        RETURN jsonb_build_object('display', '—');
    END IF;

    v_resolved := resolve_tbank_account(v_api_url, v_token, v_account_code);
    RETURN fetch_tbank_portfolio_balance(
        v_api_url,
        v_token,
        v_resolved->>'account_id'
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'error', SQLERRM,
            'display', 'ошибка'
        );
END;
$$;

COMMENT ON FUNCTION fetch_tbank_account_balance(INTEGER) IS
'Остаток по записи accounts.id (для API/UI)';

-- --- Сделки (заготовки для торговли через PostgreSQL) ---

CREATE OR REPLACE FUNCTION tbank_post_order(
    p_account_id INTEGER,
    p_figi VARCHAR,
    p_quantity NUMERIC,
    p_price NUMERIC,
    p_direction VARCHAR
)
RETURNS JSONB
LANGUAGE plpgsql AS $$
DECLARE
    v_token TEXT;
    v_api_url TEXT;
    v_account_code VARCHAR;
    v_resolved JSONB;
    v_dir VARCHAR;
BEGIN
    SELECT btrim(a.token_encrypted), b.api_url, a.account_code
    INTO v_token, v_api_url, v_account_code
    FROM accounts a
    JOIN brokers b ON b.id = a.broker_id
    WHERE a.id = p_account_id AND b.code = 'T-BANK';

    IF v_token IS NULL OR v_token = '' THEN
        RAISE EXCEPTION 'T-Bank токен не найден для account_id=%', p_account_id;
    END IF;

    v_resolved := resolve_tbank_account(v_api_url, v_token, v_account_code);
    v_dir := upper(btrim(p_direction));
    IF v_dir NOT IN ('BUY', 'SELL', 'ORDER_DIRECTION_BUY', 'ORDER_DIRECTION_SELL') THEN
        RAISE EXCEPTION 'direction: BUY или SELL';
    END IF;
    IF v_dir = 'BUY' THEN
        v_dir := 'ORDER_DIRECTION_BUY';
    ELSIF v_dir = 'SELL' THEN
        v_dir := 'ORDER_DIRECTION_SELL';
    END IF;

    RETURN tbank_http_post(
        v_api_url,
        'tinkoff.public.invest.api.contract.v1.OrdersService/PostOrder',
        v_token,
        jsonb_build_object(
            'accountId', v_resolved->>'account_id',
            'figi', p_figi,
            'quantity', p_quantity,
            'price', jsonb_build_object(
                'units', trunc(p_price)::bigint,
                'nano', round((p_price - trunc(p_price)) * 1000000000)::integer
            ),
            'direction', v_dir,
            'orderType', 'ORDER_TYPE_LIMIT',
            'orderId', gen_random_uuid()::text
        )
    );
END;
$$;

COMMENT ON FUNCTION tbank_post_order(INTEGER, VARCHAR, NUMERIC, NUMERIC, VARCHAR) IS
'Лимитная заявка T-Bank (PostOrder). Для будущей торговли из PostgreSQL.';

CREATE OR REPLACE FUNCTION tbank_cancel_order(
    p_account_id INTEGER,
    p_order_id VARCHAR
)
RETURNS JSONB
LANGUAGE plpgsql AS $$
DECLARE
    v_token TEXT;
    v_api_url TEXT;
    v_account_code VARCHAR;
    v_resolved JSONB;
BEGIN
    SELECT btrim(a.token_encrypted), b.api_url, a.account_code
    INTO v_token, v_api_url, v_account_code
    FROM accounts a
    JOIN brokers b ON b.id = a.broker_id
    WHERE a.id = p_account_id AND b.code = 'T-BANK';

    IF v_token IS NULL OR v_token = '' THEN
        RAISE EXCEPTION 'T-Bank токен не найден для account_id=%', p_account_id;
    END IF;

    v_resolved := resolve_tbank_account(v_api_url, v_token, v_account_code);

    RETURN tbank_http_post(
        v_api_url,
        'tinkoff.public.invest.api.contract.v1.OrdersService/CancelOrder',
        v_token,
        jsonb_build_object(
            'accountId', v_resolved->>'account_id',
            'orderId', p_order_id
        )
    );
END;
$$;

COMMENT ON FUNCTION tbank_cancel_order(INTEGER, VARCHAR) IS
'Отмена заявки T-Bank (CancelOrder)';

CREATE OR REPLACE FUNCTION tbank_get_orders(
    p_account_id INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql AS $$
DECLARE
    v_token TEXT;
    v_api_url TEXT;
    v_account_code VARCHAR;
    v_resolved JSONB;
BEGIN
    SELECT btrim(a.token_encrypted), b.api_url, a.account_code
    INTO v_token, v_api_url, v_account_code
    FROM accounts a
    JOIN brokers b ON b.id = a.broker_id
    WHERE a.id = p_account_id AND b.code = 'T-BANK';

    IF v_token IS NULL OR v_token = '' THEN
        RAISE EXCEPTION 'T-Bank токен не найден для account_id=%', p_account_id;
    END IF;

    v_resolved := resolve_tbank_account(v_api_url, v_token, v_account_code);

    RETURN tbank_http_post(
        v_api_url,
        'tinkoff.public.invest.api.contract.v1.OrdersService/GetOrders',
        v_token,
        jsonb_build_object('accountId', v_resolved->>'account_id')
    );
END;
$$;

COMMENT ON FUNCTION tbank_get_orders(INTEGER) IS
'Список заявок T-Bank (GetOrders)';

-- Главная load_prices → HTTP (переопределение заглушек части A)
CREATE OR REPLACE PROCEDURE load_prices(
    p_security_id INTEGER,
    p_timeframe_id INTEGER,
    p_date_from DATE,
    p_date_to DATE
)
LANGUAGE plpgsql AS $$
BEGIN
    CALL load_prices_http(p_security_id, p_timeframe_id, p_date_from, p_date_to);
END;
$$;

COMMENT ON PROCEDURE load_prices(INTEGER, INTEGER, DATE, DATE) IS
'Загрузка цен через PostgreSQL (pgsql-http): T-Bank → MOEX. Требует CREATE EXTENSION http;';


-- ============================================
-- ================================================================
-- ================================================================
-- ================================================================
--                    НЕОБЯЗАТЕЛЬНАЯ ЧАСТЬ
-- ================================================================
-- ================================================================
-- ================================================================
--
-- ВСЕ ЧТО НИЖЕ -- НЕ НУЖНО ДЛЯ СОЗДАНИЯ СТРУКТУРЫ БАЗЫ ДАННЫХ
-- ЭТО ПРИМЕРЫ ЗАПРОСОВ, ДОКУМЕНТАЦИЯ И СПРАВОЧНАЯ ИНФОРМАЦИЯ
-- МОЖНО НЕ ВЫПОЛНЯТЬ ЭТУ ЧАСТЬ ПРИ РАЗВЕРТЫВАНИИ БД
--
-- ================================================================
-- ================================================================
-- ================================================================


-- ============================================

-- ===== КОНЕЦ ОПЦИОНАЛЬНОГО БЛОКА HTTP (часть B скрипта 02) =====
-- Дальше — необязательная справочная часть; при развёртывании можно не выполнять.
