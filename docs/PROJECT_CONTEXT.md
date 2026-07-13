# MultiLogicTradePg — контекст проекта

> Живой файл контекста для продолжения работы с разных устройств и в Cursor.  
> **Обновлять перед каждым push в репозиторий** — см. `.cursor/rules/project-context.mdc`.
> Включать **запросы пользователя текстом** (секция «Запросы пользователя»).

**Репозиторий:** https://github.com/RobinZGit/MultiLogicTradePg  
**Последнее обновление:** 2026-07-13 (v21 demo: long+short по SMA; БД 00→02)

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
| `01_multilogictrade_tables_and_data.sql` | Таблицы, индексы, справочники (идемпотентно, **v21**) |
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
- **редактируемое не refresh'ить** — poll не перезаписывает черновики с кнопкой «Сохранить» — `.cursor/rules/no-refresh-while-editing.mdc`;
- панель цен: `contract_prefix`, `group_prefix`, остановка после пустых периодов по `records_loaded`.

### Индикаторы и logics

- справочник `indicators` (32 шт.: + **SMAT3**), классические + **PACC** + пользовательские через `formula`;
- **`indicators.sig_trend_def`**, **`indicators.sig_ct_def`** — условия тренда/контртренда по умолчанию (на сериях: `VALUE > 50`, `pp > VALUE`, …);
- **`logic_indicator_signals`** — сигналы индикаторов на логике (`position_side` long|short, `signal_kind` trend|counter, `formula`);
- **`logic_stops`** — стоп-лосс и тейк-профит по логике (`rule_kind` stop_loss|take_profit, `scope_type` security|portfolio, `value`, `value_unit` percent|atr);
- **`logic_securities`** — портфель бумаг логики (`logic_id`, `security_id`, `display_order`, `is_active`);
- **`logic_trades`** — сделки по сигналам: `is_simulated` (фейковый счёт), **`is_fictitious`** (резерв), `signal_kind`, `bar_dt`, `status`, `broker_order_id`;
- **`logic_param_defs`** + **`logic_params`** — параметры торговли (EAV: ключ, значение, value_type);
- **`indicators.formula`** — многочлен для `calc_poly_formula_array`; **`is_custom`** — подсветка в списке;
- **`sma`**, **`ema`**, **`ww()`** — от close; **`sma(period=20)`**, **`sma(period=20, series=VALUE)`** — параметры в ();
- **`@CODE`**, `*`, `#`, ядра `(1;-2;1)` — единый парсер `poly_*` в `02`;
- `invoke_formula` / `default_invoke_formula`: если не `calc_*` — многочлен;
- UI: **«+»** у «Индикаторы» → форма (код, название, описание, формула); **«И.»** — справка по синтаксису;
- API: `GET/POST /api/indicators`, `PUT /api/indicators/:id` (formula для `is_custom`);
- `logics` + `logics_detail` — движок формул **ещё не реализован**;
- UI **Операции** (`/operations`): пять сворачиваемых блоков — **«Параметры логики»**, **«Сигналы индикаторов»**, **«Стоп-лосс и тейк-профит»**, **«Ценные бумаги»**, **«Сделки»** (по умолчанию свёрнуты);
- API logics: **`GET/PUT /api/logic-params`** — чтение/запись `logic_params`; signals/stops/securities/trades;
- **Trade runner** (`api/trade-runner.js`): каждые ~15 с для `logics.is_enabled=TRUE` — **активные сигналы** `logic_indicator_signals` на бумагах `logic_securities`, M15; условие с `pp` (цена) и `VALUE` (индикатор); **long trend→Open Long**, **long counter→Close Long**, **short trend→Open Short**, **short counter→Close Short**; лот = `floor(остаток × % / 100 / цена)`; лимит `max_open_positions`; fake→`is_simulated=true` + пересчёт `current_balance`; real→`tbank_post_order`; env `TRADE_RUNNER_ENABLED=0` отключает;
- **Демо-логика** в `01`: `SMA Price Cross Demo` на `FAKE-EFF-001` — SMA(20): **long** при `pp > VALUE`, **short** при `pp < VALUE` (+ counter для закрытия), SBER, депозит 1M, 10%, макс. 3 позиции;

### Правило схемы БД

- изменения — в `00`–`02`; для существующих БД — `ALTER … ADD COLUMN IF NOT EXISTS` после `CREATE TABLE`;
- после правок — `npm run verify:sql`; правило: `.cursor/rules/database-scripts.mdc`.

---

## Что сделано (актуально на 2026-07-13)

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
27. **Logics — стопы:** таблица `logic_stops`, UI блок под сигналами, форма добавления, inline-редактирование строк.
28. **Fix hang при drag индикатора:** единый `syncGen` для assign/range/poll; блок full sync во время `mergeOnly` assign; отложенный full sync после assign; расширенное `app_tech_log` (poll start/ok, superseded, deferred).
29. **Fix multi-indicator assign:** очередь POST+mergeOnly по одному на бумагу; debounced flush после серии assign.
30. **Logics — ценные бумаги:** таблица `logic_securities`, блок «Ценные бумаги» (+ Добавить, picker акции/фьючерсы с «выбрать все», bulk add); все три подблока логики свёрнуты по умолчанию.
31. **Hotfix logics build:** у `ExchangeRow` нет `is_active` — MOEX по имени; удалён дубликат `toggleStopsBlock`.
32. **Logics — сделки:** таблица `logic_trades`, trade runner по включённым логикам, UI блок «Сделки»; поля `is_simulated` / `is_fictitious`.
33. **Logics — параметры торговли:** `position_size_pct`, `max_open_positions`, `initial_balance`, `current_balance`; UI блок «Параметры логики»; runner — расчёт лота и лимит позиций; демо `SMA Price Cross Demo`.
34. **Fix params UI:** черновик в Map (не теряются правки), % показывается как `10` не `10.0000`, сообщение об ошибке сохранения; T-Bank токен при включении фейковой логики.
35. **logic_indicator_signals.position_side:** Long/Short; кнопки «+ Индикатор Long/Short», тренд/к-тренд на форме picker.
36. **logic_params (v20):** таблица параметров логики EAV; сохранение через PUT /api/logic-params; runner читает из logic_params.
37. **Fix poll logics:** цикл 2 с больше не перезагружает «Параметры» и не затирает черновики формул; `paramsDirtyIds`; правило `no-refresh-while-editing.mdc`.
38. **Демо SMA v21:** 4 сигнала — long trend/counter + short trend/counter; long выше SMA, short ниже SMA.

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

- [ ] Расширить оценку формул сигналов (CROSS, AND/OR) и привязку таймфрейма к логике.
- [ ] `logic_stops` в runner, `is_fictitious` — логика заполнения; шорты (Open Short).
- [ ] Заполнить `tbank_figi` где возможно (частично через `resolve_tbank_instrument_id`).
- [ ] Влить реструктуризацию параметров индикаторов (черновик `Indicators_parameters_todo`).
- [ ] Реализовать движок `logics_detail.formula`.
- [ ] Прогнать полный UI-тест загрузки для вечных (`USDRUBF` и др.).
- [ ] Параметры индикаторов per-security (редактирование колонок `param_*` в UI).
- [ ] Параметр периода ATR для `logic_stops.value_unit = atr` (сейчас только хранение единицы).

---

## Заметки для агента

- Коммиты и push — **по запросу** пользователя.
- **Перед каждым push** — обновить `docs/PROJECT_CONTEXT.md` и включить в выкладку (правило `.cursor/rules/project-context.mdc`). Не считать выкладку завершённой без актуального контекста в `origin`.
- Sergey — **2–3 устройства**; в начале сессии читать этот файл + `git log`.
- Язык: русский (English note — только если пользователь пишет по-английски).
- Пароль локального postgres часто: `111`.
- Объём репо (2026-07-12): ~22–26 тыс. строк исходного кода без `package-lock.json`; ~41 тыс. с lock-файлом.

---

## История сессий (кратко)

| Дата | Суть |
|------|------|
| 2026-07-13 | v21 demo SMA: long выше / short ниже средней; БД 00→02 |
| 2026-07-13 | fix poll: параметры/формулы не сбрасываются при редактировании; правило UI |
| 2026-07-13 | v20 logic_params EAV + position_side Long/Short; БД 00→02 |
| 2026-07-13 | параметры logics (% депозита, макс. позиций, остаток) + SMA demo + sizing в runner |
| 2026-07-13 | logic_trades + trade runner + UI «Сделки» |
| 2026-07-12 | правило: контекст обязателен перед каждым push; hotfix logics build |
| 2026-07-12 | logic_securities + UI блок «Ценные бумаги» на logics |
| 2026-07-12 | assign queue + debounced flush; fix multi-indicator drag hang |
| 2026-07-12 | fix assign indicator sync race; tech log poll/superseded |
| 2026-07-12 | logic_stops scope: security (по бумаге) / portfolio (портфель) |
| 2026-07-12 | logic_stops + UI стоп-лосс/тейк-профит; обновление PROJECT_CONTEXT |
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
28. «На странице logics под сигналами — блок стоп-лосс/тейк-профит; кнопки + стоп-лосс и + тейк-профит; таблица logic_stops; форма: вид, тип (по логике / портфель логики), значение, единица % или ATR; строки в списке; контекст; в репо».
29. «Файлы контекста обновлять локально и выкладывать в репо каждый раз — правило проекта, не забывать».
30. «Тип стопа: не «по логике», а **по бумаге** и **по всему портфелю логики**; исправить и в репо».
31. «Зависание при добавлении индикатора с логированием — исправить гонку sync (gen, defer full sync, лог poll); в репо».
32. «Снова зависание при добавлении нескольких индикаторов на бумагу — разбор app_tech_log; очередь assign + debounced flush; в репо».
33. «На logics третий блок «Ценные бумаги»: таблица logic_securities, picker акции/фьючерсы с галочками и «выбрать все», bulk add; все три блока свёрнуты по умолчанию; контекст; в репо».
34. «Контекст обновляй при каждой выкладке; запиши в правила проекта, что перед push нужно обновлять PROJECT_CONTEXT.md».
35. «Сделки по включённой логике в реальном времени по сигналам; реальный/фейковый счёт; поле Фиктивная (резерв); блок «Сделки» на logics; таблица сделок».
36. «Параметры логики: % депозита, макс. открытых позиций, начальный остаток (фейк); текущий остаток в logics; блок «Параметры» сверху; расчёт лота и лимит позиций; сделки по выбранным сигналам индикаторов; демо SMA на FAKE-EFF-001 (выше SMA покупаем, ниже продаём) + SBER».
37. «Fix: % депозита 10.0000 / не сохраняются параметры; TS2322; T-Bank токен при включении фейковой логики; в репо».
38. «Сигналы: поле Long/Short; кнопки + Long/+ Short; тренд/к-тренд на форме; выложить».
39. «Параметры логики не сохраняются — таблица logic_params (ключ/значение/тип); выложить».
40. «Собери базу с нуля и выложи в репозиторий».
41. «Poll каждые 2 с сбрасывает параметры — не refresh'ить редактируемое; правило проекта; выложить».
42. «Демо-логика: long при цене выше SMA, short при ниже; пересобрать БД; в репо».
