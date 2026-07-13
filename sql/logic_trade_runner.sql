-- ============================================
-- Trade runner: оценка сигналов и logic_trades (PostgreSQL)
-- Вставляется в 02 перед @optional-pgcron-block
-- ============================================

CREATE OR REPLACE FUNCTION get_logic_param_text(p_logic_id INTEGER, p_param_key TEXT)
RETURNS TEXT
LANGUAGE sql STABLE AS $$
    SELECT lp.param_value
    FROM logic_params lp
    WHERE lp.logic_id = p_logic_id AND lp.param_key = p_param_key
    LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION get_logic_param_numeric(p_logic_id INTEGER, p_param_key TEXT, p_default NUMERIC)
RETURNS NUMERIC
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_raw TEXT;
    v_num NUMERIC;
BEGIN
    v_raw := btrim(COALESCE(get_logic_param_text(p_logic_id, p_param_key), ''));
    IF v_raw = '' THEN
        RETURN p_default;
    END IF;
    v_num := replace(v_raw, ',', '.')::NUMERIC;
    IF v_num IS NULL THEN
        RETURN p_default;
    END IF;
    RETURN v_num;
END;
$$;

CREATE OR REPLACE FUNCTION logic_resolve_timeframe_id(p_logic_id INTEGER)
RETURNS INTEGER
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_tf TEXT;
    v_id INTEGER;
BEGIN
    v_tf := upper(btrim(COALESCE(get_logic_param_text(p_logic_id, 'timeframe'), 'M15')));
    SELECT t.id INTO v_id
    FROM timeframes t
    WHERE upper(t.tf) = v_tf AND COALESCE(t.is_active, TRUE)
    ORDER BY t.sec
    LIMIT 1;
    IF v_id IS NULL THEN
        SELECT t.id INTO v_id FROM timeframes t WHERE upper(t.tf) = 'M15' LIMIT 1;
    END IF;
    RETURN v_id;
END;
$$;

COMMENT ON FUNCTION logic_resolve_timeframe_id(INTEGER) IS
'timeframe_id из logic_params.timeframe (код TF, по умолчанию M15)';

CREATE OR REPLACE FUNCTION logic_last_closed_bar_dt(
    p_tf_sec INTEGER,
    p_at TIMESTAMP DEFAULT LOCALTIMESTAMP
)
RETURNS TIMESTAMP
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_tz TEXT := current_setting('TimeZone');
    v_epoch NUMERIC;
    v_current_bar_start NUMERIC;
BEGIN
    IF p_tf_sec IS NULL OR p_tf_sec <= 0 THEN
        RETURN NULL;
    END IF;
    v_epoch := EXTRACT(EPOCH FROM (COALESCE(p_at, LOCALTIMESTAMP) AT TIME ZONE v_tz));
    v_current_bar_start := floor(v_epoch / p_tf_sec) * p_tf_sec;
    RETURN (to_timestamp(v_current_bar_start - p_tf_sec) AT TIME ZONE v_tz)::timestamp;
END;
$$;

COMMENT ON FUNCTION logic_last_closed_bar_dt(INTEGER, TIMESTAMP) IS
'Начало последней закрытой свечи (open time) для TF с периодом p_tf_sec секунд';

CREATE OR REPLACE FUNCTION logic_bar_data_at(
    p_security_id INTEGER,
    p_timeframe_id INTEGER,
    p_indicator_id INTEGER,
    p_series TEXT,
    p_bar_dt TIMESTAMP
)
RETURNS TABLE (bar_dt TIMESTAMP, ind_value NUMERIC, close_price NUMERIC)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_tf_sec INTEGER;
    v_ind_dt TIMESTAMP;
    v_ind_val NUMERIC;
    v_pp NUMERIC;
BEGIN
    SELECT t.sec INTO v_tf_sec FROM timeframes t WHERE t.id = p_timeframe_id;

    SELECT iv.dt, iv.value
    INTO v_ind_dt, v_ind_val
    FROM indicator_values iv
    JOIN indicator_value_types ivt ON ivt.id = iv.indicator_value_type_id
    WHERE iv.security_id = p_security_id
      AND iv.timeframe_id = p_timeframe_id
      AND iv.indicator_id = p_indicator_id
      AND upper(ivt.code) = upper(COALESCE(p_series, 'VALUE'))
      AND iv.dt = p_bar_dt
    LIMIT 1;

    IF v_ind_dt IS NULL AND v_tf_sec IS NOT NULL THEN
        SELECT iv.dt, iv.value
        INTO v_ind_dt, v_ind_val
        FROM indicator_values iv
        JOIN indicator_value_types ivt ON ivt.id = iv.indicator_value_type_id
        WHERE iv.security_id = p_security_id
          AND iv.timeframe_id = p_timeframe_id
          AND iv.indicator_id = p_indicator_id
          AND upper(ivt.code) = upper(COALESCE(p_series, 'VALUE'))
          AND iv.dt > p_bar_dt - make_interval(secs => v_tf_sec)
          AND iv.dt <= p_bar_dt
        ORDER BY iv.dt DESC
        LIMIT 1;
    END IF;

    IF v_ind_dt IS NULL THEN
        RETURN;
    END IF;

    SELECT p.close_price
    INTO v_pp
    FROM prices p
    WHERE p.security_id = p_security_id
      AND p.timeframe_id = p_timeframe_id
      AND p.dt = v_ind_dt
    LIMIT 1;

    IF v_pp IS NULL THEN
        SELECT p.close_price
        INTO v_pp
        FROM prices p
        WHERE p.security_id = p_security_id
          AND p.timeframe_id = p_timeframe_id
          AND p.dt <= v_ind_dt
        ORDER BY p.dt DESC
        LIMIT 1;
    END IF;

    IF v_pp IS NULL OR v_pp <= 0 THEN
        RETURN;
    END IF;

    bar_dt := v_ind_dt;
    ind_value := v_ind_val;
    close_price := v_pp;
    RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION logic_bar_data_at(INTEGER, INTEGER, INTEGER, TEXT, TIMESTAMP) IS
'Индикатор и close на конкретной закрытой свече (exact dt, затем fallback в пределах одного бара)';

CREATE OR REPLACE FUNCTION parse_signal_series(p_params TEXT)
RETURNS TEXT
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_part TEXT;
    v_key TEXT;
    v_val TEXT;
BEGIN
    IF p_params IS NULL OR btrim(p_params) = '' THEN
        RETURN 'VALUE';
    END IF;
    FOREACH v_part IN ARRAY string_to_array(p_params, ',')
    LOOP
        v_part := btrim(v_part);
        IF position('=' IN v_part) > 0 THEN
            v_key := lower(btrim(split_part(v_part, '=', 1)));
            v_val := btrim(split_part(v_part, '=', 2));
            IF v_key = 'series' AND v_val <> '' THEN
                RETURN upper(v_val);
            END IF;
        END IF;
    END LOOP;
    RETURN 'VALUE';
END;
$$;

CREATE OR REPLACE FUNCTION evaluate_signal_condition(
    p_condition TEXT,
    p_pp NUMERIC,
    p_value NUMERIC
)
RETURNS BOOLEAN
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_expr TEXT;
    v_left NUMERIC;
    v_right NUMERIC;
    v_op TEXT;
    v_m TEXT[];
BEGIN
    v_expr := btrim(COALESCE(p_condition, ''));
    IF v_expr = '' OR p_pp IS NULL OR p_value IS NULL THEN
        RETURN FALSE;
    END IF;
    IF p_pp IS NULL OR p_value IS NULL OR p_pp <= 0 THEN
        RETURN FALSE;
    END IF;

    v_expr := regexp_replace(v_expr, '\mpp\y', p_pp::TEXT, 'gi');
    v_expr := regexp_replace(v_expr, '\yVALUE\y', p_value::TEXT, 'gi');
    IF v_expr ~ '[A-Za-z_]' THEN
        RETURN FALSE;
    END IF;

    v_m := regexp_match(v_expr, '^\s*(-?\d+(?:\.\d+)?)\s*(>=|<=|<>|!=|=|>|<)\s*(-?\d+(?:\.\d+)?)\s*$');
    IF v_m IS NULL THEN
        RETURN FALSE;
    END IF;

    v_left := v_m[1]::NUMERIC;
    v_op := v_m[2];
    v_right := v_m[3]::NUMERIC;

    CASE v_op
        WHEN '>' THEN RETURN v_left > v_right;
        WHEN '<' THEN RETURN v_left < v_right;
        WHEN '>=' THEN RETURN v_left >= v_right;
        WHEN '<=' THEN RETURN v_left <= v_right;
        WHEN '=' THEN RETURN v_left = v_right;
        WHEN '!=' THEN RETURN v_left <> v_right;
        WHEN '<>' THEN RETURN v_left <> v_right;
        ELSE RETURN FALSE;
    END CASE;
END;
$$;

CREATE OR REPLACE FUNCTION parse_signal_formula(p_formula TEXT)
RETURNS TABLE (
    valid BOOLEAN,
    indicator_code TEXT,
    params TEXT,
    condition TEXT
)
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_m TEXT[];
BEGIN
    valid := FALSE;
    indicator_code := NULL;
    params := NULL;
    condition := NULL;

    v_m := regexp_match(btrim(COALESCE(p_formula, '')), '^@([A-Za-z0-9_]+)\(([^)]*)\)\s+(.+)$', 'i');
    IF v_m IS NULL THEN
        RETURN NEXT;
        RETURN;
    END IF;

    valid := TRUE;
    indicator_code := upper(v_m[1]);
    params := btrim(v_m[2]);
    condition := btrim(v_m[3]);
    RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION logic_long_position_qty(p_logic_id INTEGER, p_security_id INTEGER)
RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT GREATEST(COALESCE(SUM(
        CASE
            WHEN s.name = 'Open' AND a.name = 'Long' THEN lt.quantity
            WHEN s.name = 'Close' AND a.name = 'Long' THEN -lt.quantity
            ELSE 0
        END
    ), 0), 0)
    FROM logic_trades lt
    JOIN sides s ON s.id = lt.side_id
    JOIN actions a ON a.id = lt.action_id
    WHERE lt.logic_id = p_logic_id
      AND lt.security_id = p_security_id
      AND lt.status IN ('filled', 'submitted');
$$;

CREATE OR REPLACE FUNCTION logic_short_position_qty(p_logic_id INTEGER, p_security_id INTEGER)
RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT GREATEST(COALESCE(SUM(
        CASE
            WHEN s.name = 'Open' AND a.name = 'Short' THEN lt.quantity
            WHEN s.name = 'Close' AND a.name = 'Short' THEN -lt.quantity
            ELSE 0
        END
    ), 0), 0)
    FROM logic_trades lt
    JOIN sides s ON s.id = lt.side_id
    JOIN actions a ON a.id = lt.action_id
    WHERE lt.logic_id = p_logic_id
      AND lt.security_id = p_security_id
      AND lt.status IN ('filled', 'submitted');
$$;

CREATE OR REPLACE FUNCTION logic_count_open_positions(p_logic_id INTEGER)
RETURNS INTEGER
LANGUAGE sql STABLE AS $$
    SELECT COUNT(*)::INTEGER FROM (
        SELECT lt.security_id
        FROM logic_trades lt
        JOIN sides s ON s.id = lt.side_id
        JOIN actions a ON a.id = lt.action_id
        WHERE lt.logic_id = p_logic_id
          AND lt.status IN ('filled', 'submitted')
        GROUP BY lt.security_id
        HAVING COALESCE(SUM(
            CASE
                WHEN s.name = 'Open' AND a.name = 'Long' THEN lt.quantity
                WHEN s.name = 'Close' AND a.name = 'Long' THEN -lt.quantity
                WHEN s.name = 'Open' AND a.name = 'Short' THEN lt.quantity
                WHEN s.name = 'Close' AND a.name = 'Short' THEN -lt.quantity
                ELSE 0
            END
        ), 0) > 0
    ) q;
$$;

CREATE OR REPLACE FUNCTION logic_calc_open_quantity(
    p_balance NUMERIC,
    p_position_size_pct NUMERIC,
    p_price NUMERIC
)
RETURNS INTEGER
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_amount NUMERIC;
    v_qty INTEGER;
BEGIN
    IF p_balance IS NULL OR p_balance <= 0 THEN
        RETURN 0;
    END IF;
    IF p_price IS NULL OR p_price <= 0 THEN
        RETURN 0;
    END IF;
    IF p_position_size_pct IS NULL OR p_position_size_pct <= 0 THEN
        RETURN 0;
    END IF;
    v_amount := p_balance * (p_position_size_pct / 100.0);
    v_qty := floor(v_amount / p_price)::INTEGER;
    IF v_qty >= 1 THEN
        RETURN v_qty;
    END IF;
    RETURN 0;
END;
$$;

CREATE OR REPLACE FUNCTION logic_upsert_param(
    p_logic_id INTEGER,
    p_param_key TEXT,
    p_value TEXT,
    p_value_type TEXT DEFAULT 'text'
)
RETURNS VOID
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO logic_params (logic_id, param_key, param_value, value_type)
    VALUES (p_logic_id, p_param_key, COALESCE(p_value, ''), p_value_type)
    ON CONFLICT (logic_id, param_key) DO UPDATE SET
        param_value = EXCLUDED.param_value,
        value_type = EXCLUDED.value_type,
        updated_at = CURRENT_TIMESTAMP;
END;
$$;

CREATE OR REPLACE FUNCTION logic_ensure_balance(p_logic_id INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql AS $$
DECLARE
    v_current NUMERIC;
    v_initial NUMERIC;
BEGIN
    v_current := get_logic_param_numeric(p_logic_id, 'current_balance', NULL);
    IF v_current IS NOT NULL THEN
        RETURN v_current;
    END IF;
    v_initial := get_logic_param_numeric(p_logic_id, 'initial_balance', NULL);
    IF v_initial IS NULL THEN
        RETURN NULL;
    END IF;
    PERFORM logic_upsert_param(p_logic_id, 'current_balance', v_initial::TEXT, 'money');
    RETURN v_initial;
END;
$$;

CREATE OR REPLACE FUNCTION logic_trade_load_date_from(
    p_tf_sec INTEGER,
    p_point_count INTEGER,
    p_closed_bar_dt TIMESTAMP
)
RETURNS DATE
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_date_to DATE;
    v_need_days INTEGER;
    v_max_days INTEGER;
    v_span INTEGER;
BEGIN
    v_date_to := GREATEST(p_closed_bar_dt::date, CURRENT_DATE);
    v_need_days := GREATEST(1, CEIL(GREATEST(COALESCE(p_point_count, 100), 30) * COALESCE(NULLIF(p_tf_sec, 0), 900) / 86400.0)::INTEGER);

    v_max_days := CASE
        WHEN COALESCE(p_tf_sec, 0) <= 120 THEN 0
        WHEN p_tf_sec <= 600 THEN 3
        WHEN p_tf_sec <= 1800 THEN 7
        WHEN p_tf_sec <= 3600 THEN 14
        ELSE 30
    END;

    IF v_max_days = 0 THEN
        RETURN v_date_to;
    END IF;

    v_span := LEAST(GREATEST(v_need_days, 1), v_max_days);
    RETURN v_date_to - v_span;
END;
$$;

COMMENT ON FUNCTION logic_trade_load_date_from(INTEGER, INTEGER, TIMESTAMP) IS
'date_from для load_prices с учётом лимитов T-Bank по TF (M1/M2 — только текущий день)';

CREATE OR REPLACE FUNCTION logic_trade_sync_point_count(p_tf_sec INTEGER)
RETURNS INTEGER
LANGUAGE sql
IMMUTABLE AS $$
    SELECT CASE
        WHEN COALESCE(p_tf_sec, 0) <= 60 THEN 400
        WHEN p_tf_sec <= 120 THEN 300
        WHEN p_tf_sec <= 300 THEN 200
        ELSE 150
    END;
$$;

COMMENT ON FUNCTION logic_trade_sync_point_count(INTEGER) IS
'Число свечей для sync индикаторов в runner: больше на M1/M2/M5';

CREATE OR REPLACE PROCEDURE logic_refresh_market_data(
    p_logic_id INTEGER,
    p_timeframe_id INTEGER,
    p_closed_bar_dt TIMESTAMP
)
LANGUAGE plpgsql AS $$
DECLARE
    v_sec RECORD;
    v_sig RECORD;
    v_date_from DATE;
    v_date_to DATE;
    v_point_count INTEGER;
    v_tf_sec INTEGER;
    v_err TEXT;
BEGIN
    SELECT t.sec INTO v_tf_sec FROM timeframes t WHERE t.id = p_timeframe_id;

    v_point_count := logic_trade_sync_point_count(v_tf_sec);
    v_date_to := GREATEST(p_closed_bar_dt::date, CURRENT_DATE);
    v_date_from := logic_trade_load_date_from(v_tf_sec, v_point_count, p_closed_bar_dt);

    FOR v_sec IN
        SELECT ls.security_id
        FROM logic_securities ls
        WHERE ls.logic_id = p_logic_id AND ls.is_active = TRUE
    LOOP
        BEGIN
            CALL load_prices(v_sec.security_id, p_timeframe_id, v_date_from, v_date_to);
            PERFORM logic_trade_log(
                p_logic_id,
                'trade.prices.loaded',
                format('Цены подгружены sec=%s (%s .. %s)', v_sec.security_id, v_date_from, v_date_to),
                jsonb_build_object(
                    'security_id', v_sec.security_id,
                    'date_from', v_date_from,
                    'date_to', v_date_to,
                    'timeframe_id', p_timeframe_id
                ),
                v_sec.security_id,
                p_timeframe_id
            );
        EXCEPTION
            WHEN undefined_function THEN
                PERFORM logic_trade_log(
                    p_logic_id,
                    'trade.prices.error',
                    'load_prices недоступен (нет HTTP-расширения)',
                    jsonb_build_object('security_id', v_sec.security_id),
                    v_sec.security_id,
                    p_timeframe_id
                );
            WHEN OTHERS THEN
                v_err := SQLERRM;
                PERFORM logic_trade_log(
                    p_logic_id,
                    'trade.prices.error',
                    format('Ошибка загрузки цен sec=%s: %s', v_sec.security_id, v_err),
                    jsonb_build_object('security_id', v_sec.security_id, 'error', v_err),
                    v_sec.security_id,
                    p_timeframe_id
                );
        END;

        FOR v_sig IN
            SELECT DISTINCT lis.indicator_id
            FROM logic_indicator_signals lis
            WHERE lis.logic_id = p_logic_id AND lis.is_active = TRUE
        LOOP
            BEGIN
                CALL ensure_security_indicator_series(v_sec.security_id, v_sig.indicator_id);
                CALL sync_security_indicator_series_for_indicator(
                    v_sec.security_id,
                    v_sig.indicator_id,
                    p_timeframe_id,
                    p_closed_bar_dt,
                    v_point_count,
                    TRUE
                );
                PERFORM logic_trade_log(
                    p_logic_id,
                    'trade.indicator.synced',
                    format('Индикатор id=%s пересчитан sec=%s', v_sig.indicator_id, v_sec.security_id),
                    jsonb_build_object(
                        'security_id', v_sec.security_id,
                        'indicator_id', v_sig.indicator_id,
                        'closed_bar', p_closed_bar_dt,
                        'point_count', v_point_count
                    ),
                    v_sec.security_id,
                    p_timeframe_id
                );
            EXCEPTION
                WHEN OTHERS THEN
                    v_err := SQLERRM;
                    PERFORM logic_trade_log(
                        p_logic_id,
                        'trade.indicator.error',
                        format('Ошибка расчёта индикатора id=%s sec=%s: %s', v_sig.indicator_id, v_sec.security_id, v_err),
                        jsonb_build_object(
                            'security_id', v_sec.security_id,
                            'indicator_id', v_sig.indicator_id,
                            'error', v_err
                        ),
                        v_sec.security_id,
                        p_timeframe_id
                    );
            END;
        END LOOP;
    END LOOP;
END;
$$;

COMMENT ON PROCEDURE logic_refresh_market_data(INTEGER, INTEGER, TIMESTAMP) IS
'Перед проверкой сигналов: load_prices + ensure/sync индикаторов логики на TF (live trading)';

CREATE OR REPLACE FUNCTION process_logic_trades(p_logic_id INTEGER)
RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    v_logic RECORD;
    v_tf_id INTEGER;
    v_tf_sec INTEGER;
    v_position_size_pct NUMERIC;
    v_max_positions INTEGER;
    v_balance NUMERIC;
    v_open_positions INTEGER;
    v_created INTEGER := 0;
    v_side_open_id INTEGER;
    v_side_close_id INTEGER;
    v_action_long_id INTEGER;
    v_action_short_id INTEGER;
    v_sig RECORD;
    v_sec RECORD;
    v_parsed RECORD;
    v_series TEXT;
    v_ind_value NUMERIC;
    v_ind_dt TIMESTAMP;
    v_pp NUMERIC;
    v_held_long NUMERIC;
    v_held_short NUMERIC;
    v_is_trend BOOLEAN;
    v_quantity INTEGER;
    v_side_id INTEGER;
    v_action_id INTEGER;
    v_direction TEXT;
    v_is_simulated BOOLEAN;
    v_broker_order_id TEXT;
    v_status TEXT;
    v_note TEXT;
    v_trade_id BIGINT;
    v_figi TEXT;
    v_order JSONB;
    v_notional NUMERIC;
    v_is_open BOOLEAN;
    v_closed_bar_dt TIMESTAMP;
    v_last_bar_raw TEXT;
    v_last_bar_dt TIMESTAMP;
    v_all_securities_ready BOOLEAN := TRUE;
    v_bar_row RECORD;
BEGIN
    SELECT l.id, l.account_id, a.account_type
    INTO v_logic
    FROM logics l
    JOIN accounts a ON a.id = l.account_id
    WHERE l.id = p_logic_id
      AND l.is_enabled = TRUE
      AND a.is_active = TRUE;

    IF NOT FOUND THEN
        PERFORM logic_trade_log(p_logic_id, 'logic.skip', 'Логика выключена или счёт неактивен');
        RETURN 0;
    END IF;

    v_tf_id := logic_resolve_timeframe_id(p_logic_id);
    IF v_tf_id IS NULL THEN
        PERFORM logic_trade_log(p_logic_id, 'logic.skip', 'Не задан timeframe в logic_params');
        RETURN 0;
    END IF;

    SELECT t.sec INTO v_tf_sec FROM timeframes t WHERE t.id = v_tf_id;

    v_closed_bar_dt := logic_last_closed_bar_dt(v_tf_sec);
    IF v_closed_bar_dt IS NULL THEN
        PERFORM logic_trade_log(p_logic_id, 'logic.skip', 'Не удалось вычислить закрытую свечу TF', NULL, NULL, v_tf_id);
        RETURN 0;
    END IF;

    v_last_bar_raw := btrim(COALESCE(get_logic_param_text(p_logic_id, 'last_trade_bar_dt'), ''));
    IF v_last_bar_raw <> '' THEN
        BEGIN
            v_last_bar_dt := v_last_bar_raw::TIMESTAMP;
            IF v_closed_bar_dt <= v_last_bar_dt THEN
                PERFORM logic_trade_log(
                    p_logic_id,
                    'trade.bar_skip',
                    format('Свеча %s уже обработана (last=%s)', v_closed_bar_dt, v_last_bar_dt),
                    jsonb_build_object('closed_bar', v_closed_bar_dt, 'last_bar', v_last_bar_dt),
                    NULL,
                    v_tf_id
                );
                RETURN 0;
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                NULL;
        END;
    END IF;

    SELECT id INTO v_side_open_id FROM sides WHERE name = 'Open' LIMIT 1;
    SELECT id INTO v_side_close_id FROM sides WHERE name = 'Close' LIMIT 1;
    SELECT id INTO v_action_long_id FROM actions WHERE name = 'Long' LIMIT 1;
    SELECT id INTO v_action_short_id FROM actions WHERE name = 'Short' LIMIT 1;

    IF v_side_open_id IS NULL OR v_side_close_id IS NULL
       OR v_action_long_id IS NULL OR v_action_short_id IS NULL THEN
        RETURN 0;
    END IF;

    v_position_size_pct := get_logic_param_numeric(p_logic_id, 'position_size_pct', 10);
    v_max_positions := GREATEST(1, get_logic_param_numeric(p_logic_id, 'max_open_positions', 5)::INTEGER);
    v_balance := logic_ensure_balance(p_logic_id);
    v_open_positions := logic_count_open_positions(p_logic_id);

    IF NOT EXISTS (
        SELECT 1 FROM logic_indicator_signals lis
        WHERE lis.logic_id = p_logic_id AND lis.is_active = TRUE
    ) OR NOT EXISTS (
        SELECT 1 FROM logic_securities ls
        WHERE ls.logic_id = p_logic_id AND ls.is_active = TRUE
    ) THEN
        PERFORM logic_trade_log(p_logic_id, 'logic.skip', 'Нет активных сигналов или бумаг');
        RETURN 0;
    END IF;

    CALL logic_refresh_market_data(p_logic_id, v_tf_id, v_closed_bar_dt);

    -- Все бумаги и все сигналы должны иметь данные на закрытой свече
    FOR v_sec IN
        SELECT ls.security_id
        FROM logic_securities ls
        WHERE ls.logic_id = p_logic_id AND ls.is_active = TRUE
    LOOP
        FOR v_sig IN
            SELECT lis.indicator_id, lis.formula
            FROM logic_indicator_signals lis
            WHERE lis.logic_id = p_logic_id AND lis.is_active = TRUE
        LOOP
            SELECT * INTO v_parsed FROM parse_signal_formula(v_sig.formula);
            IF NOT COALESCE(v_parsed.valid, FALSE) THEN
                CONTINUE;
            END IF;
            v_series := parse_signal_series(v_parsed.params);
            SELECT * INTO v_bar_row
            FROM logic_bar_data_at(
                v_sec.security_id, v_tf_id, v_sig.indicator_id, v_series, v_closed_bar_dt
            );
            IF NOT FOUND THEN
                v_all_securities_ready := FALSE;
                PERFORM logic_trade_log(
                    p_logic_id,
                    'trade.not_ready',
                    format('Нет данных на свече %s для security=%s signal=%s', v_closed_bar_dt, v_sec.security_id, v_sig.formula),
                    jsonb_build_object('closed_bar', v_closed_bar_dt, 'security_id', v_sec.security_id, 'formula', v_sig.formula),
                    v_sec.security_id,
                    v_tf_id
                );
                EXIT;
            END IF;
        END LOOP;
        IF NOT v_all_securities_ready THEN
            EXIT;
        END IF;
    END LOOP;

    IF NOT v_all_securities_ready THEN
        RETURN 0;
    END IF;

    PERFORM logic_trade_log(
        p_logic_id,
        'trade.bar_check',
        format('Проверка сигналов на закрытой свече %s', v_closed_bar_dt),
        jsonb_build_object('closed_bar', v_closed_bar_dt, 'timeframe_id', v_tf_id),
        NULL,
        v_tf_id
    );

    FOR v_sec IN
        SELECT ls.security_id
        FROM logic_securities ls
        WHERE ls.logic_id = p_logic_id AND ls.is_active = TRUE
    LOOP
        FOR v_sig IN
            SELECT lis.id, lis.position_side, lis.signal_kind, lis.formula, lis.indicator_id
            FROM logic_indicator_signals lis
            WHERE lis.logic_id = p_logic_id AND lis.is_active = TRUE
            ORDER BY lis.display_order, lis.id
        LOOP
            SELECT * INTO v_parsed FROM parse_signal_formula(v_sig.formula);
            IF NOT COALESCE(v_parsed.valid, FALSE) THEN
                CONTINUE;
            END IF;

            v_series := parse_signal_series(v_parsed.params);

            SELECT * INTO v_bar_row
            FROM logic_bar_data_at(
                v_sec.security_id, v_tf_id, v_sig.indicator_id, v_series, v_closed_bar_dt
            );
            IF NOT FOUND THEN
                CONTINUE;
            END IF;

            v_ind_dt := v_bar_row.bar_dt;
            v_ind_value := v_bar_row.ind_value;
            v_pp := v_bar_row.close_price;

            IF NOT evaluate_signal_condition(v_parsed.condition, v_pp, v_ind_value) THEN
                PERFORM logic_trade_log(
                    p_logic_id,
                    'trade.signal_skip',
                    format('Условие не выполнено: %s (pp=%s, value=%s)', v_parsed.condition, v_pp, v_ind_value),
                    jsonb_build_object(
                        'formula', v_sig.formula,
                        'signal_kind', v_sig.signal_kind,
                        'position_side', v_sig.position_side,
                        'pp', v_pp,
                        'ind_value', v_ind_value,
                        'bar_dt', v_ind_dt
                    ),
                    v_sec.security_id,
                    v_tf_id
                );
                CONTINUE;
            END IF;

            PERFORM logic_trade_log(
                p_logic_id,
                'trade.signal_hit',
                format('Сигнал %s/%s: %s', v_sig.position_side, v_sig.signal_kind, v_sig.formula),
                jsonb_build_object(
                    'formula', v_sig.formula,
                    'pp', v_pp,
                    'ind_value', v_ind_value,
                    'bar_dt', v_ind_dt
                ),
                v_sec.security_id,
                v_tf_id
            );

            v_held_long := CASE WHEN v_sig.position_side = 'long' THEN logic_long_position_qty(p_logic_id, v_sec.security_id) ELSE 0 END;
            v_held_short := CASE WHEN v_sig.position_side = 'short' THEN logic_short_position_qty(p_logic_id, v_sec.security_id) ELSE 0 END;
            v_is_trend := v_sig.signal_kind = 'trend';

            IF v_sig.position_side = 'long' THEN
                IF v_is_trend THEN
                    IF v_held_long > 0 OR v_open_positions >= v_max_positions THEN
                        CONTINUE;
                    END IF;
                    v_quantity := logic_calc_open_quantity(v_balance, v_position_size_pct, v_pp);
                    IF v_quantity < 1 THEN
                        IF v_logic.account_type = 'fake' THEN
                            CONTINUE;
                        END IF;
                        v_quantity := 1;
                    END IF;
                    v_side_id := v_side_open_id;
                    v_action_id := v_action_long_id;
                    v_direction := 'BUY';
                ELSE
                    IF v_held_long <= 0 THEN
                        CONTINUE;
                    END IF;
                    v_quantity := v_held_long::INTEGER;
                    v_side_id := v_side_close_id;
                    v_action_id := v_action_long_id;
                    v_direction := 'SELL';
                END IF;
            ELSIF v_is_trend THEN
                IF v_held_short > 0 OR v_open_positions >= v_max_positions THEN
                    CONTINUE;
                END IF;
                v_quantity := logic_calc_open_quantity(v_balance, v_position_size_pct, v_pp);
                IF v_quantity < 1 THEN
                    IF v_logic.account_type = 'fake' THEN
                        CONTINUE;
                    END IF;
                    v_quantity := 1;
                END IF;
                v_side_id := v_side_open_id;
                v_action_id := v_action_short_id;
                v_direction := 'SELL';
            ELSE
                IF v_held_short <= 0 THEN
                    CONTINUE;
                END IF;
                v_quantity := v_held_short::INTEGER;
                v_side_id := v_side_close_id;
                v_action_id := v_action_short_id;
                v_direction := 'BUY';
            END IF;

            v_is_simulated := v_logic.account_type = 'fake';
            v_broker_order_id := NULL;
            v_status := 'filled';
            v_note := NULL;

            IF v_logic.account_type <> 'fake' THEN
                v_is_simulated := FALSE;
                BEGIN
                    SELECT sp.tbank_figi INTO v_figi
                    FROM security_prefixes sp
                    WHERE sp.security_id = v_sec.security_id
                      AND sp.tbank_figi IS NOT NULL
                    ORDER BY sp.exchange_id
                    LIMIT 1;

                    IF v_figi IS NULL THEN
                        v_status := 'rejected';
                        v_note := 'Нет tbank_figi для бумаги';
                    ELSE
                        v_order := tbank_post_order(
                            v_logic.account_id, v_figi, v_quantity, v_pp, v_direction
                        );
                        v_broker_order_id := COALESCE(
                            v_order->>'orderId',
                            v_order->>'order_id',
                            v_order->'orderState'->>'orderId'
                        );
                        IF v_broker_order_id IS NOT NULL THEN
                            v_status := 'submitted';
                        ELSE
                            v_status := 'rejected';
                            v_note := v_order::TEXT;
                        END IF;
                    END IF;
                EXCEPTION
                    WHEN undefined_function THEN
                        v_status := 'rejected';
                        v_note := 'tbank_post_order недоступен (нет HTTP-расширения)';
                    WHEN OTHERS THEN
                        v_status := 'rejected';
                        v_note := SQLERRM;
                END;
            END IF;

            INSERT INTO logic_trades (
                logic_id, account_id, security_id, timeframe_id,
                side_id, action_id, signal_kind, signal_formula,
                quantity, price, bar_dt, is_simulated, is_fictitious,
                broker_order_id, status, note
            )
            VALUES (
                p_logic_id, v_logic.account_id, v_sec.security_id, v_tf_id,
                v_side_id, v_action_id, v_sig.signal_kind, v_sig.formula,
                v_quantity, v_pp, v_ind_dt, v_is_simulated, FALSE,
                v_broker_order_id, v_status, v_note
            )
            ON CONFLICT (logic_id, security_id, signal_kind, bar_dt) DO NOTHING
            RETURNING id INTO v_trade_id;

            IF v_trade_id IS NULL THEN
                CONTINUE;
            END IF;

            v_created := v_created + 1;

            IF v_logic.account_type = 'fake' AND v_balance IS NOT NULL AND v_status <> 'rejected' THEN
                v_balance := logic_trade_finalize(v_trade_id, v_balance);
                v_notional := v_quantity * v_pp;
                v_is_open := (v_sig.position_side = 'long' AND v_is_trend)
                           OR (v_sig.position_side = 'short' AND v_is_trend);
                IF v_sig.position_side = 'long' THEN
                    v_balance := v_balance + CASE WHEN v_is_open THEN -v_notional ELSE v_notional END;
                ELSE
                    v_balance := v_balance + CASE WHEN v_is_open THEN v_notional ELSE -v_notional END;
                END IF;
                IF v_is_open THEN
                    v_open_positions := v_open_positions + 1;
                ELSE
                    v_open_positions := GREATEST(0, v_open_positions - 1);
                END IF;
                PERFORM logic_upsert_param(p_logic_id, 'current_balance', v_balance::TEXT, 'money');
            ELSE
                PERFORM logic_trade_finalize(v_trade_id, v_balance);
            END IF;

            PERFORM logic_trade_log(
                p_logic_id,
                'trade.created',
                format('Сделка #%s qty=%s price=%s status=%s', v_trade_id, v_quantity, v_pp, v_status),
                jsonb_build_object(
                    'trade_id', v_trade_id,
                    'quantity', v_quantity,
                    'price', v_pp,
                    'status', v_status,
                    'signal_kind', v_sig.signal_kind,
                    'formula', v_sig.formula,
                    'bar_dt', v_ind_dt
                ),
                v_sec.security_id,
                v_tf_id
            );
        END LOOP;
    END LOOP;

    PERFORM logic_upsert_param(
        p_logic_id,
        'last_trade_check_at',
        to_char(CURRENT_TIMESTAMP, 'YYYY-MM-DD"T"HH24:MI:SS'),
        'text'
    );
    PERFORM logic_upsert_param(
        p_logic_id,
        'last_trade_bar_dt',
        to_char(v_closed_bar_dt, 'YYYY-MM-DD"T"HH24:MI:SS'),
        'text'
    );

    IF v_created = 0 THEN
        PERFORM logic_trade_log(
            p_logic_id,
            'trade.bar_done',
            format('Свеча %s проверена, сделок не создано', v_closed_bar_dt),
            jsonb_build_object('closed_bar', v_closed_bar_dt),
            NULL,
            v_tf_id
        );
    END IF;

    RETURN v_created;
END;
$$;

COMMENT ON FUNCTION process_logic_trades(INTEGER) IS
'Сигналы только на последней закрытой свече TF логики; last_trade_bar_dt — идемпотентность по бару';

CREATE OR REPLACE FUNCTION run_trade_cycle()
RETURNS JSONB
LANGUAGE plpgsql AS $$
DECLARE
    v_logic RECORD;
    v_total_created INTEGER := 0;
    v_processed INTEGER := 0;
    v_got_lock BOOLEAN;
BEGIN
    v_got_lock := pg_try_advisory_lock(hashtext('multilogictrade_run_trade_cycle'));
    IF NOT v_got_lock THEN
        PERFORM app_tech_log_event('trade-runner', 'cycle.skip', 'Пропуск: другой цикл уже выполняется', 'postgresql');
        RETURN jsonb_build_object('skipped', TRUE, 'reason', 'locked');
    END IF;

    IF NOT trade_runner_ui_is_active() THEN
        PERFORM pg_advisory_unlock(hashtext('multilogictrade_run_trade_cycle'));
        PERFORM app_tech_log_event(
            'trade-runner',
            'cycle.skip',
            'Пропуск: UI не активен (закройте Angular — робот не торгует)',
            'postgresql'
        );
        RETURN jsonb_build_object('skipped', TRUE, 'reason', 'ui_inactive');
    END IF;

    PERFORM app_tech_log_event('trade-runner', 'cycle.start', 'run_trade_cycle начат', 'postgresql');

    FOR v_logic IN
        SELECT l.id
        FROM logics l
        JOIN accounts a ON a.id = l.account_id
        WHERE l.is_enabled = TRUE AND a.is_active = TRUE
        ORDER BY l.id
    LOOP
        v_processed := v_processed + 1;
        v_total_created := v_total_created + process_logic_trades(v_logic.id);
    END LOOP;

    PERFORM pg_advisory_unlock(hashtext('multilogictrade_run_trade_cycle'));

    PERFORM app_tech_log_event(
        'trade-runner',
        'cycle.end',
        format('processed=%s created=%s', v_processed, v_total_created),
        'postgresql',
        'event',
        NULL,
        NULL,
        NULL,
        jsonb_build_object('processed', v_processed, 'created', v_total_created)
    );

    RETURN jsonb_build_object(
        'processed', v_processed,
        'created', v_total_created,
        'at', CURRENT_TIMESTAMP
    );
EXCEPTION
    WHEN OTHERS THEN
        PERFORM pg_advisory_unlock(hashtext('multilogictrade_run_trade_cycle'));
        RAISE;
END;
$$;

COMMENT ON FUNCTION run_trade_cycle() IS
'Цикл торговли по включённым logics. Только при активном UI (heartbeat Angular); pg_cron или Node fallback.';
