# MultiLogicTradePg — контекст проекта

> Живой файл контекста для продолжения работы с разных устройств и в Cursor.  
> **Обновлять при каждой выкладке и в конце значимой сессии** (см. `.cursor/rules/project-context.mdc`).  
> Включать **запросы пользователя текстом** (секция «Запросы пользователя»).

**Репозиторий:** https://github.com/RobinZGit/MultiLogicTradePg  
**Последнее обновление:** 2026-07-12 (app_tech_log, fix pan-left SMAT3 sync, checkbox «Логирование»)

---

## Цель проекта

Перенос торговой системы **MultiLogic Trade** с Angular (логика в приложении) на **PostgreSQL-first**:

- расчёт индикаторов, загрузка цен, торговые правила — в БД;
- **Angular** — визуальные формы и вызовы API/SQL.

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

**Полный цикл «с нуля»:** `00` → `01` → `02`. Для проверки скриптов без сброса данных — `npm run verify:sql`.

---

## Ключевые решения схемы (v12+)

### Префиксы акций и фьючерсов

- уникальность: `(security_id, exchange_id)`, не глобально по `prefix`;
- `instrument_market`: `stock` | `futures` | `bonds` | `index`;
- **Групповые фьючерсы** (Si, CR→CNY): префикс группы в `security_prefixes` (`CR`, `Si`);
- **Вечные фьючерсы** (`CNYRUBF`, `USDRUBF`, …): префикс = тикер группы, **без** rollover по контрактам;
- **`futures_expirations`** — **runtime-кэш** контрактов (пустая после `00`/TRUNCATE; заполняется `sync_futures_expirations_from_moex` при загрузке);
- поля контракта: `prefix` (SHORTNAME, напр. `CNY-9.26`), **`moex_secid`** (SECID, напр. `CRU6`), `expiration_date`, `tbank_figi`;
- **`prices.contract_prefix`** — какой контракт дал свечу при rollover.

### Загрузка цен (фьючерсы)

- `load_prices_futures_http` — обход контрактов от `date_to` назад (rollover);
- `sync_futures_expirations_from_moex` — список FORTS с MOEX ISS → UPSERT в `futures_expirations`;
- T-Bank **FutureBy** — сначала `moex_secid` (`CRU6`), затем `prefix` (`CNY-9.26`);
- MOEX candles URL — по **SECID**, не SHORTNAME;
- `load_prices_http` — вечные → T-Bank/MOEX по `CNYRUBF` из `security_prefixes` (не из `futures_expirations`);
- таймауты: `lock_timeout` / `statement_timeout` в API и SQL (защита от зависаний).

### Проверка SQL перед сборкой

- `scripts/verify-sql.mjs`, `npm run verify:sql` в `web/` (`prebuild`);
- CI: `--core-only` (без HTTP-блока); маркер `-- @optional-http-block` в `02`.

### UI

- Angular `web/` + Express `api/`;
- прокручиваемые списки — правило `.cursor/rules/scrollable-lists.mdc`;
- панель цен: `contract_prefix`, `group_prefix`, остановка после пустых периодов по `records_loaded`.

### Индикаторы и logics

- справочник `indicators` (32 шт.: + **SMAT3**), классические + **PACC** + пользовательские через `formula`;
- **`indicators.sig_trend_def`**, **`indicators.sig_ct_def`** — условия тренда/контртренда по умолчанию (на сериях: `VALUE > 50`, `pp > VALUE`, …);
- **`logic_indicator_signals`** — сигналы индикаторов на логике (`logic_id`, `indicator_id`, `signal_kind` trend|counter, `formula`);
- **`indicators.formula`** — многочлен для `calc_poly_formula_array`; **`is_custom`** — подсветка в списке;
- **`sma`**, **`ema`**, **`ww()`** — от close; **`sma(period=20)`**, **`sma(period=20, series=VALUE)`** — параметры в ();
- **`@CODE`**, `*`, `#`, ядра `(1;-2;1)` — единый парсер `poly_*` в `02`;
- `invoke_formula` / `default_invoke_formula`: если не `calc_*` — многочлен;
- UI: **«+»** у «Индикаторы» → форма (код, название, описание, формула); **«И.»** — справка по синтаксису;
- API: `GET/POST /api/indicators`, `PUT /api/indicators/:id` (formula для `is_custom`);
- `logics` + `logics_detail` — движок формул **ещё не реализован**;
- UI **Операции** (`/operations`): разворот строки логики → **«Сигналы индикаторов»** (+ тренд / + контртренд, мультивыбор, inline-формула `@RSI(…) VALUE > 50`);
- API: `GET/POST/PUT/DELETE /api/logic-indicator-signals`; парсер-заготовка `web/src/app/shared/signal-formula.ts`;

### Правило схемы БД

- изменения — в `00`–`02`; для существующих БД — `ALTER … ADD COLUMN IF NOT EXISTS` после `CREATE TABLE`;
- после правок — `npm run verify:sql`; правило: `.cursor/rules/database-scripts.mdc`.

---

## Что сделано (актуально на 2026-07-12)

### Бумаги ↔ индикаторы

12. Вкладки: **2 — Бумаги и индикаторы**, **3 — Справочники**.
13. Таблица **`security_indicator_series`** — одна строка = серия индикатора на бумаге (`series_code`, `invoke_formula`, параметры, `point_count`).
14. Функции **`calc_ind_*_array`** — один проход по ценам, возвращают `TABLE(dt, value)`; процедуры `ensure_security_indicator_series`, `sync_security_indicator_series(_all)`.
15. API: `GET/POST/DELETE /api/security-indicator-series`, `POST /api/security-indicator-series/sync`, `GET /api/indicator-values`.
16. UI: drag → создание всех серий индикатора + sync; список серий с удалением; график через sync (инкрементально при прокрутке).
17. **График цен:** панель (↻ пересчёт, ± zoom, ◀▶, ⛶ полный экран); колёсико/pinch; инкрементальный sync по видимому окну; fullscreen подписи **×1.55**; **линия y=0** на шкале цены (PACC) и в панели OSC (MACD и др.).
18. **Fix hang при добавлении индикатора:** POST `/api/security-indicator-series` без полного sync; расчёт — отдельно через `/sync`; прогресс «Добавление…» / «Расчёт…»; `insert_indicator_value` через UPSERT.
19. **Единый парсер формул:** `sma()`/`ema()`/`ww()`, поле `formula`, SMAT3; `calc_indicator_series_array` → `calc_poly_formula_array` при наличии formula.
20. **Создание индикатора в UI:** «+» в списке; POST `/api/indicators` + серия VALUE; форма с подсказкой и «И.»; синяя подсветка `is_custom`.
21. **Фоновый пересчёт после drag:** POST assign → список сразу; async sync в PostgreSQL; спиннер «Пересчёт …».
22. **T-Bank токен:** `parameter_types.TBANK_API_TOKEN` → `parameter_values`; `get_tbank_token` / `set_tbank_token`; диалог при «Загрузить цены»; API `GET/PUT /api/settings/tbank-token`.
23. **SMAT3 / график:** локальная свёртка по `period`; sync без зависания при scroll/fullscreen/expand (`verify-chart-sync.mjs`, `userInitiated`, suppress до готовности).
24. **Logics — сигналы индикаторов:** таблица `logic_indicator_signals`, дефолты `sig_*_def`, UI с inline-редактированием формулы.
25. **Технический журнал `app_tech_log`:** checkbox **«Логирование»** в шапке «Бумаги» (выкл. по умолчанию); start/end/event по `thread_key` (sec:N:gen:M); API `POST/GET /api/tech-log`.
26. **Fix pan влево (SMAT3):** proactive `loadOlder`, `incremental=false` при сдвиге `end_dt` влево, защита poll от stale gen, debounce по `lastVisibleRange`.

### Автотесты

- `scripts/verify-indicators.mjs` — smoke SQL (sync без цен, calc_ind_*_array, seed STOCH, sig_*_def).
- `scripts/verify-chart-sync.mjs` — регрессия зависания индикаторов на графике.
- `scripts/verify-async-sync.mjs` — async assign/sync.
- `npm run test:unit` — Karma/ChromeHeadless (разворот бумаги, fullscreen, recalc).
- `prebuild`: verify:sql → test:unit → generate:schema; CI: unit-тесты + verify-indicators.

### База и инфраструктура

1. Идемпотентные скрипты `00`–`03`, split монолита v11 → v12.
2. Локально: PostgreSQL 15, pgsql-http, база `multilogictrade`.
3. `verify:sql` + `verify:indicators` + `test:unit`, CI в `.github/workflows/pages.yml`.
4. `docs/LOCAL_SETUP.md`, `scripts/run_multilogictrade.ps1`, `web/MultiLogic_Trade_Progress_Start.bat`.

### Фьючерсы и загрузка цен

5. Rollover по контрактам, `prices.contract_prefix`, `load_prices_futures_http`.
6. Авто-sync контрактов MOEX → `futures_expirations` (без ручного INSERT в `01`).
7. `moex_secid` для T-Bank/MOEX (CNY, Si).
8. TRUNCATE + тест загрузки с пустой `futures_expirations` — OK (CNY id=52, Si id=54).
9. **Вечный CNYRUBF (id=51):** `get_active_future_prefix` и `load_prices_from_tbank_http` — префикс из `security_prefixes`, не из кэша контрактов; загрузка 305 свечей проверена.

### UI и API

10. Scrollable lists (securities, indicators, references, logics).
11. API: таймауты клиента, `GET /api/prices` с `contract_prefix` / `group_prefix`.
12. `price-chart`: canvas, overlay индикаторов, полноэкранный режим с крупными подписями.
13. `securities-panel`: drag-drop серий, загрузка цен, fix зависания при развороте без цен.

---

## Открытые задачи / следующие шаги

- [ ] Заполнить `tbank_figi` где возможно (частично через `resolve_tbank_instrument_id`).
- [ ] Влить реструктуризацию параметров индикаторов (черновик `Indicators_parameters_todo`).
- [ ] Реализовать движок `logics_detail.formula`.
- [ ] Прогнать полный UI-тест загрузки для вечных (`USDRUBF` и др.).
- [ ] Параметры индикаторов per-security (редактирование колонок `param_*` в UI).

---

## Заметки для агента

- Коммиты и push — **по запросу** пользователя (2026-07-12: push после PACC + zero line).
- При **выкладке** — обязательно обновить этот файл (правило `.cursor/rules/project-context.mdc`).
- Sergey — **2–3 устройства**; в начале сессии читать этот файл + `git log`.
- Язык: русский (English note — только если пользователь пишет по-английски).
- Пароль локального postgres часто: `111`.

---

## История сессий (кратко)

| Дата | Суть |
|------|------|
| 2026-07-12 | app_tech_log + UI «Логирование»; fix pan-left SMAT3 sync |
| 2026-07-12 | SMAT3 локальная свёртка; chart sync без зависания; verify-chart-sync |
| 2026-07-12 | logics: logic_indicator_signals, sig_*_def, UI сигналов, signal-formula |
| 2026-07-12 | pgsql-http, локальная БД 00–02 |
| 2026-07-12 | Фьючерсы: sync MOEX, moex_secid, rollover, verify:sql, scroll lists |
| 2026-07-12 | TRUNCATE + load test; fix вечный CNYRUBF; правило контекста при выкладке |
| 2026-07-12 | security_indicator_series, calc_ind_*_array, sync инкрементальный |
| 2026-07-12 | verify-indicators, test:unit, fullscreen график, fix expand hang |
| 2026-07-12 | PACC + poly parser; fix hang assign; линия нуля на графике; push в репо |
| 2026-07-12 | Оптимистичный drop: строка в таблице сразу; sync только async |
| 2026-07-12 | Убран SMAT3COMP; sma без скобок; SMAT3 = sma*sma*sma |
| 2026-07-12 | Async sync при drag; SMAT3 нормализация свёртки |
| 2026-07-12 | Единый formula engine, SMAT3, UI создать индикатор (+), справка «И.» |

---

## Запросы пользователя (текст)

### 2026-07-12 (ранние)

1. Обзор репо, исправления, split SQL, DROP в `00`, контекст в проект.
2. Локальный запуск, pgsql-http, logics + Angular + Express.
3. Правило БД: изменения в CREATE TABLE, прогон локально.

### 2026-07-12 (фьючерсы и загрузка)

4. «Загрузка фьючерсов по группам (CR/Si), обход контрактов назад, contract_prefix».
5. «Проверка SQL перед build, CI».
6. «Пустая futures_expirations — только sync при load; TRUNCATE и прогнать тест».
7. Ошибка id=51 (CNYRUBF): «Активный фьючерс не найден…» — исправить вечные фьючерсы.

### 2026-07-12 (контекст)

8. «Правила проекта: файлы контекста с каждой новой выкладкой…»

9. «Бумаги и индикаторы: 2-я вкладка; 3-я — Справочники; drag индикатора на бумагу → security_indicators; список и графики по calculate_indicator с параметрами по умолчанию; полный прогон 00–02.»

### 2026-07-12 (индикаторы, график, тесты)

10. «security_indicator_series, calc_ind_*_array, sync инкрементальный; пересоздать БД 00–02».
11. «Зависание при развороте акции без цен — исправить».
12. «Автотесты на expand без цен + prebuild».
13. «Загрузка цен без T-Bank — MOEX D1/H1; M15 нужен токен».
14. «На графике пересчёт индикаторов; полный экран с zoom/pan; крупнее подписи в fullscreen; выложить в репо».
15. «Индикатор ускорения цены PACC, парсер многочленов, формула pp*(1;-2;1)».
16. «Зависание при добавлении PACC на ALRS — fix + прогресс».
17. «Линия нуля на графике (fullscreen и обычный); обновить контекст; выложить в репо».
18. «Индикатор = многочлен: свёртки, умножение, pp, sma(), единый парсер для всех формул».
19. «Кнопка + в списке индикаторов; форма код/название/описание/формула; хинт и кнопка «И.» с подробной справкой; обновить контекст; в репо».
20. «При drag индикатора страница зависает — сразу показывать в списке, пересчёт в PostgreSQL в фоне, спиннер «Пересчёт …» как при загрузке цен».
21. «SMAT3 — sma(pp)*sma(pp)*sma(pp) (свёртка рядов); SMAT3COMP — sma(sma(sma(pp))) (композиция); при том же N числа разные; * без подмены ядром».
22. «После пересоздания БД теряется токен T-Bank — диалог ввода при загрузке цен, хранить в глобальных параметрах, отмена → MOEX; пересоздать БД; в репо».
26. «Drag индикатора: сразу в таблицу, расчёт async; жёсткий verify-async-sync в prebuild».
27. «SMAT3 при перемотке в одну сторону OK, в обратную — зависает; таблица tech log в БД; галочка Логирование (выкл.); логировать start/end по потокам; пересобрать БД; контекст; в репо».
