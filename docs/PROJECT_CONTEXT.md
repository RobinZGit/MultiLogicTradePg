# MultiLogicTradePg — контекст проекта

> Живой файл контекста для продолжения работы с разных устройств и в Cursor.
> **Обновлять в конце каждой значимой сессии** (см. `.cursor/rules/project-context.mdc`).

**Репозиторий:** https://github.com/RobinZGit/MultiLogicTradePg  
**Последнее обновление:** 2026-07-12

---

## Цель проекта

Перенос торговой системы **MultiLogic Trade** с Angular (логика в приложении) на **PostgreSQL-first**:

- расчёт индикаторов, загрузка цен, торговые правила — в БД;
- **Angular** — только визуальные формы и вызовы API/SQL.

Биржа: **MOEX** (акции + фьючерсы), источники цен: **T-Bank API** и **MOEX ISS** (через расширение `pgsql-http`).

---

## Структура SQL-скриптов (порядок запуска)

| Файл | Назначение |
|------|------------|
| `00_create_database.sql` | **DROP + CREATE** базы `multilogictrade` (полное пересоздание) |
| `01_multilogictrade_tables_and_data.sql` | Таблицы, индексы, справочники (идемпотентно) |
| `02_multilogictrade_functions_and_procedures.sql` | Функции и процедуры (идемпотентно) |
| `03_multilogictrade_examples.sql` | Примеры SELECT (необязательно) |

Устаревший монолит: `multilogictrade_full_database.sql` (v11) — только для истории.

**Полный цикл «с нуля»:** выполнить 00 → 01 → 02 (блок HTTP в 02 — опционально).

---

## Ключевые решения схемы (v12)

### Префиксы акций и фьючерсов

Один тикер MOEX (`VTBR`, `LKOH`) может быть у **акции** и **фьючерса**:

- уникальность: `(security_id, exchange_id)`, не глобально по `prefix`;
- поле `instrument_market`: `stock` | `futures` | `bonds` | `index`;
- `tbank_figi` — FIGI для T-Bank API (акции);
- активный контракт фьючерса — таблица `futures_expirations` (prefix вида `Si-3.26`).

### Индикаторы

- справочник `indicators` (30 шт.), реализован расчёт **7**: RSI, SMA, EMA, MACD, BB, ATR, STOCH;
- `calculate_indicator`, `calculate_all_indicators`, `calculate_indicators_batch`;
- параметры: `parameter_types` / `parameter_sets` / `parameter_values`.

### Торговая логика (заготовка)

- `logics`, `logics_detail` (формула + Open/Close + Long/Short) — **движок формул ещё не реализован**.

---

## Что сделано в сессии 2026-07-12

1. Разобран монолит v11, найдены ошибки (UNIQUE prefix, `v_price`, `is_active`, FIGI T-Bank и др.).
2. Созданы идемпотентные скрипты `00`–`03`, исправления в v12.
3. `00_create_database.sql`: добавлены **DROP DATABASE IF EXISTS** и завершение сессий перед созданием.
4. Добавлены `README.md`, этот файл контекста, правило Cursor для обновления контекста.

---

## Открытые задачи / следующие шаги

- [ ] Заполнить/актуализировать `futures_expirations` и `tbank_figi` под реальные контракты.
- [ ] Установить `pgsql-http` и протестировать `load_prices_http`.
- [ ] Влить реструктуризацию параметров индикаторов (черновик в `Indicators_parameters_todo`, v12+).
- [ ] Реализовать движок `logics_detail.formula`.
- [ ] Angular UI поверх БД.

---

## Заметки для агента

- Коммиты — **только по запросу** пользователя; контекст и код — **пушить** после изменений, если пользователь просит «выложить в репозиторий».
- Пользователь (Sergey) продолжает тему с **2–3 устройств** — читать этот файл и `git log` в начале сессии.
- Язык общения: русский (без English note, если пользователь пишет по-русски).

---

## История сессий (кратко)

| Дата | Суть |
|------|------|
| 2026-07-12 | Обзор репо, split SQL v12, fix ошибок, контекст + DROP в 00 |
