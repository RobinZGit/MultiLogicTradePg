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

    v_expr := regexp_replace(v_expr, '\mpp\b', p_pp::TEXT, 'gi');
    v_expr := regexp_replace(v_expr, '\mVALUE\b', p_value::TEXT, 'gi');
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
BEGIN
    SELECT l.id, l.account_id, a.account_type
    INTO v_logic
    FROM logics l
    JOIN accounts a ON a.id = l.account_id
    WHERE l.id = p_logic_id
      AND l.is_enabled = TRUE
      AND a.is_active = TRUE;

    IF NOT FOUND THEN
        RETURN 0;
    END IF;

    v_tf_id := logic_resolve_timeframe_id(p_logic_id);
    IF v_tf_id IS NULL THEN
        RETURN 0;
    END IF;

    SELECT t.sec INTO v_tf_sec FROM timeframes t WHERE t.id = v_tf_id;

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
        RETURN 0;
    END IF;

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

            SELECT iv.dt, iv.value
            INTO v_ind_dt, v_ind_value
            FROM indicator_values iv
            JOIN indicator_value_types ivt ON ivt.id = iv.indicator_value_type_id
            WHERE iv.security_id = v_sec.security_id
              AND iv.timeframe_id = v_tf_id
              AND iv.indicator_id = v_sig.indicator_id
              AND upper(ivt.code) = upper(v_series)
            ORDER BY iv.dt DESC
            LIMIT 1;

            IF v_ind_dt IS NULL OR v_ind_value IS NULL THEN
                CONTINUE;
            END IF;

            SELECT p.close_price
            INTO v_pp
            FROM prices p
            WHERE p.security_id = v_sec.security_id
              AND p.timeframe_id = v_tf_id
              AND p.dt <= v_ind_dt
            ORDER BY p.dt DESC
            LIMIT 1;

            IF v_pp IS NULL OR v_pp <= 0 THEN
                CONTINUE;
            END IF;

            IF NOT evaluate_signal_condition(v_parsed.condition, v_pp, v_ind_value) THEN
                CONTINUE;
            END IF;

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
            END IF;
        END LOOP;
    END LOOP;

    PERFORM logic_upsert_param(
        p_logic_id,
        'last_trade_check_at',
        to_char(CURRENT_TIMESTAMP, 'YYYY-MM-DD"T"HH24:MI:SS'),
        'text'
    );

    RETURN v_created;
END;
$$;

COMMENT ON FUNCTION process_logic_trades(INTEGER) IS
'Один проход по сигналам и бумагам логики: indicator_values + prices на timeframe из logic_params';

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
        RETURN jsonb_build_object('skipped', TRUE, 'reason', 'locked');
    END IF;

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
'Цикл торговли по всем включённым logics. Вызывается pg_cron или API (Node fallback).';
