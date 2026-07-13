-- ============================================
-- Trade PnL: комиссия, FIFO / средняя, пакеты по сделкам
-- Вставляется в 02 перед process_logic_trades
-- ============================================

CREATE OR REPLACE FUNCTION logic_trade_calc_commission(
    p_logic_id INTEGER,
    p_balance NUMERIC
)
RETURNS NUMERIC
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_pct NUMERIC;
    v_base NUMERIC;
BEGIN
    v_pct := get_logic_param_numeric(p_logic_id, 'commission_pct', 0);
    IF v_pct IS NULL OR v_pct <= 0 THEN
        RETURN 0;
    END IF;
    v_base := COALESCE(
        NULLIF(p_balance, 0),
        get_logic_param_numeric(p_logic_id, 'initial_balance', 0),
        0
    );
    IF v_base <= 0 THEN
        RETURN 0;
    END IF;
    RETURN round(v_base * v_pct / 100.0, 6);
END;
$$;

COMMENT ON FUNCTION logic_trade_calc_commission(INTEGER, NUMERIC) IS
'Комиссия фейкового счёта: % от текущего депозита (commission_pct)';

CREATE OR REPLACE FUNCTION logic_trade_open_remaining_qty(p_open_trade_id BIGINT)
RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT GREATEST(
        lt.quantity - COALESCE((
            SELECT SUM(l.quantity)
            FROM logic_trade_lots l
            WHERE l.open_trade_id = lt.id
        ), 0),
        0
    )
    FROM logic_trades lt
    WHERE lt.id = p_open_trade_id;
$$;

COMMENT ON FUNCTION logic_trade_open_remaining_qty(BIGINT) IS
'Остаток лота открывающей сделки (qty минус уже закрыто пакетами)';

CREATE OR REPLACE FUNCTION logic_trade_build_lots(p_close_trade_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    v_close RECORD;
    v_method TEXT;
    v_remaining NUMERIC;
    v_open RECORD;
    v_alloc NUMERIC;
    v_open_rem NUMERIC;
    v_close_comm_part NUMERIC;
    v_open_comm_part NUMERIC;
    v_close_amt NUMERIC;
    v_open_amt NUMERIC;
    v_pnl NUMERIC;
    v_total_pnl NUMERIC := 0;
    v_avg_price NUMERIC;
    v_total_open_qty NUMERIC;
    v_total_open_cost NUMERIC;
    v_total_open_comm NUMERIC;
BEGIN
    SELECT lt.*, sd.name AS side_name, ac.name AS action_name
    INTO v_close
    FROM logic_trades lt
    JOIN sides sd ON sd.id = lt.side_id
    JOIN actions ac ON ac.id = lt.action_id
    WHERE lt.id = p_close_trade_id;

    IF NOT FOUND OR v_close.side_name <> 'Close' THEN
        RETURN;
    END IF;
    IF v_close.status NOT IN ('filled', 'submitted') THEN
        RETURN;
    END IF;

    DELETE FROM logic_trade_lots WHERE close_trade_id = p_close_trade_id;

    v_method := upper(btrim(COALESCE(get_logic_param_text(v_close.logic_id, 'cost_method'), 'FIFO')));
    IF v_method NOT IN ('FIFO', 'AVERAGE') THEN
        v_method := 'FIFO';
    END IF;

    v_remaining := v_close.quantity;

    IF v_method = 'AVERAGE' THEN
        SELECT
            COALESCE(SUM(logic_trade_open_remaining_qty(lt.id)), 0),
            COALESCE(SUM(logic_trade_open_remaining_qty(lt.id) * lt.price), 0),
            COALESCE(SUM(
                CASE WHEN lt.quantity > 0
                    THEN COALESCE(lt.commission, 0) * logic_trade_open_remaining_qty(lt.id) / lt.quantity
                    ELSE 0
                END
            ), 0)
        INTO v_total_open_qty, v_total_open_cost, v_total_open_comm
        FROM logic_trades lt
        JOIN sides sd ON sd.id = lt.side_id
        JOIN actions ac ON ac.id = lt.action_id
        WHERE lt.logic_id = v_close.logic_id
          AND lt.security_id = v_close.security_id
          AND sd.name = 'Open'
          AND ac.name = v_close.action_name
          AND lt.status IN ('filled', 'submitted')
          AND lt.executed_at <= v_close.executed_at
          AND logic_trade_open_remaining_qty(lt.id) > 0;

        IF v_total_open_qty <= 0 THEN
            RETURN;
        END IF;

        v_avg_price := v_total_open_cost / v_total_open_qty;

        FOR v_open IN
            SELECT lt.id, lt.quantity, lt.commission
            FROM logic_trades lt
            JOIN sides sd ON sd.id = lt.side_id
            JOIN actions ac ON ac.id = lt.action_id
            WHERE lt.logic_id = v_close.logic_id
              AND lt.security_id = v_close.security_id
              AND sd.name = 'Open'
              AND ac.name = v_close.action_name
              AND lt.status IN ('filled', 'submitted')
              AND lt.executed_at <= v_close.executed_at
            ORDER BY lt.executed_at ASC, lt.id ASC
        LOOP
            EXIT WHEN v_remaining <= 0;
            v_open_rem := logic_trade_open_remaining_qty(v_open.id);
            IF v_open_rem <= 0 THEN
                CONTINUE;
            END IF;
            v_alloc := LEAST(v_remaining, v_open_rem);
            v_close_amt := v_alloc * v_close.price;
            v_open_amt := v_alloc * v_avg_price;
            v_close_comm_part := CASE WHEN v_close.quantity > 0
                THEN COALESCE(v_close.commission, 0) * v_alloc / v_close.quantity ELSE 0 END;
            v_open_comm_part := CASE WHEN v_total_open_qty > 0
                THEN v_total_open_comm * v_alloc / v_total_open_qty ELSE 0 END;

            IF v_close.action_name = 'Long' THEN
                v_pnl := v_close_amt - v_open_amt - v_close_comm_part - v_open_comm_part;
            ELSE
                v_pnl := v_open_amt - v_close_amt - v_close_comm_part - v_open_comm_part;
            END IF;

            INSERT INTO logic_trade_lots (
                logic_id, close_trade_id, open_trade_id,
                quantity, close_amount, open_amount,
                close_commission, open_commission, financial_result,
                action_id, cost_method
            )
            VALUES (
                v_close.logic_id, p_close_trade_id, v_open.id,
                v_alloc, v_close_amt, v_open_amt,
                v_close_comm_part, v_open_comm_part, v_pnl,
                v_close.action_id, 'AVERAGE'
            );
            v_total_pnl := v_total_pnl + v_pnl;
            v_remaining := v_remaining - v_alloc;
        END LOOP;
    ELSE
        FOR v_open IN
            SELECT lt.id, lt.quantity, lt.price, lt.commission, lt.executed_at
            FROM logic_trades lt
            JOIN sides sd ON sd.id = lt.side_id
            JOIN actions ac ON ac.id = lt.action_id
            WHERE lt.logic_id = v_close.logic_id
              AND lt.security_id = v_close.security_id
              AND sd.name = 'Open'
              AND ac.name = v_close.action_name
              AND lt.status IN ('filled', 'submitted')
              AND lt.executed_at <= v_close.executed_at
            ORDER BY lt.executed_at ASC, lt.id ASC
        LOOP
            EXIT WHEN v_remaining <= 0;
            v_open_rem := logic_trade_open_remaining_qty(v_open.id);
            IF v_open_rem <= 0 THEN
                CONTINUE;
            END IF;
            v_alloc := LEAST(v_remaining, v_open_rem);
            v_close_amt := v_alloc * v_close.price;
            v_open_amt := v_alloc * v_open.price;
            v_close_comm_part := CASE WHEN v_close.quantity > 0
                THEN COALESCE(v_close.commission, 0) * v_alloc / v_close.quantity ELSE 0 END;
            v_open_comm_part := CASE WHEN v_open.quantity > 0
                THEN COALESCE(v_open.commission, 0) * v_alloc / v_open.quantity ELSE 0 END;

            IF v_close.action_name = 'Long' THEN
                v_pnl := v_close_amt - v_open_amt - v_close_comm_part - v_open_comm_part;
            ELSE
                v_pnl := v_open_amt - v_close_amt - v_close_comm_part - v_open_comm_part;
            END IF;

            INSERT INTO logic_trade_lots (
                logic_id, close_trade_id, open_trade_id,
                quantity, close_amount, open_amount,
                close_commission, open_commission, financial_result,
                action_id, cost_method
            )
            VALUES (
                v_close.logic_id, p_close_trade_id, v_open.id,
                v_alloc, v_close_amt, v_open_amt,
                v_close_comm_part, v_open_comm_part, v_pnl,
                v_close.action_id, 'FIFO'
            );
            v_total_pnl := v_total_pnl + v_pnl;
            v_remaining := v_remaining - v_alloc;
        END LOOP;
    END IF;

    UPDATE logic_trades
    SET financial_result = CASE WHEN v_total_pnl <> 0 THEN v_total_pnl ELSE NULL END
    WHERE id = p_close_trade_id;
END;
$$;

COMMENT ON FUNCTION logic_trade_build_lots(BIGINT) IS
'Пакеты закрытия: FIFO или средняя; financial_result только на закрывающей сделке';

CREATE OR REPLACE FUNCTION logic_trade_finalize(p_trade_id BIGINT, p_balance NUMERIC)
RETURNS NUMERIC
LANGUAGE plpgsql AS $$
DECLARE
    v_trade RECORD;
    v_comm NUMERIC := 0;
    v_new_balance NUMERIC := p_balance;
    v_side_name TEXT;
BEGIN
    SELECT lt.*, sd.name AS side_name
    INTO v_trade
    FROM logic_trades lt
    JOIN sides sd ON sd.id = lt.side_id
    WHERE lt.id = p_trade_id;

    IF NOT FOUND THEN
        RETURN p_balance;
    END IF;

    v_side_name := v_trade.side_name;

    IF v_trade.is_simulated THEN
        v_comm := logic_trade_calc_commission(v_trade.logic_id, p_balance);
    ELSE
        v_comm := COALESCE(v_trade.commission, 0);
    END IF;

    UPDATE logic_trades SET commission = COALESCE(v_comm, 0) WHERE id = p_trade_id;

    IF v_side_name = 'Close' AND v_trade.status IN ('filled', 'submitted') THEN
        PERFORM logic_trade_build_lots(p_trade_id);
    END IF;

    IF v_trade.is_simulated AND v_new_balance IS NOT NULL AND v_comm > 0 THEN
        v_new_balance := v_new_balance - v_comm;
    END IF;

    RETURN v_new_balance;
END;
$$;

COMMENT ON FUNCTION logic_trade_finalize(BIGINT, NUMERIC) IS
'Комиссия на сделке; пакеты и PnL при закрытии; возвращает баланс после комиссии';

CREATE OR REPLACE FUNCTION logic_trade_rebuild_pnl(p_logic_id INTEGER DEFAULT NULL)
RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    v_logic RECORD;
    v_trade RECORD;
    v_balance NUMERIC;
    v_notional NUMERIC;
    v_count INTEGER := 0;
BEGIN
    FOR v_logic IN
        SELECT l.id
        FROM logics l
        WHERE p_logic_id IS NULL OR l.id = p_logic_id
        ORDER BY l.id
    LOOP
        v_balance := logic_ensure_balance(v_logic.id);

        FOR v_trade IN
            SELECT
                lt.id,
                lt.quantity,
                lt.price,
                lt.is_simulated,
                lt.status,
                sd.name AS side_name,
                ac.name AS action_name
            FROM logic_trades lt
            JOIN sides sd ON sd.id = lt.side_id
            JOIN actions ac ON ac.id = lt.action_id
            WHERE lt.logic_id = v_logic.id
              AND lt.status IN ('filled', 'submitted')
            ORDER BY lt.executed_at ASC, lt.id ASC
        LOOP
            IF v_trade.is_simulated THEN
                v_balance := logic_trade_finalize(v_trade.id, v_balance);
                v_notional := v_trade.quantity * v_trade.price;
                IF v_trade.action_name = 'Long' THEN
                    IF v_trade.side_name = 'Open' THEN
                        v_balance := v_balance - v_notional;
                    ELSE
                        v_balance := v_balance + v_notional;
                    END IF;
                ELSIF v_trade.action_name = 'Short' THEN
                    IF v_trade.side_name = 'Open' THEN
                        v_balance := v_balance + v_notional;
                    ELSE
                        v_balance := v_balance - v_notional;
                    END IF;
                END IF;
            ELSE
                PERFORM logic_trade_finalize(v_trade.id, NULL);
            END IF;
            v_count := v_count + 1;
        END LOOP;

        PERFORM logic_upsert_param(v_logic.id, 'current_balance', v_balance::TEXT, 'money');
    END LOOP;

    RETURN v_count;
END;
$$;

COMMENT ON FUNCTION logic_trade_rebuild_pnl(INTEGER) IS
'Пересчёт комиссии, пакетов и PnL по истории сделок логики (NULL = все логики)';
