-- ============================================
-- MultiLogicTrade — шаг 0: пересоздание базы данных
-- ============================================
-- Выполнить от имени суперпользователя,
-- подключившись к служебной БД postgres (НЕ к multilogictrade).
--
-- Скрипт:
--   1) завершает активные подключения к multilogictrade
--   2) удаляет базу, если она есть (DROP DATABASE IF EXISTS)
--   3) создаёт базу заново
--
-- ВНИМАНИЕ: все данные в multilogictrade будут уничтожены.
--
-- Порядок полного развёртывания «с нуля»:
--   00_create_database.sql
--   01_multilogictrade_tables_and_data.sql
--   02_multilogictrade_functions_and_procedures.sql
--   03_multilogictrade_examples.sql  (необязательно)
-- ============================================

-- ============================================
-- Шаг 1: завершить активные сессии к целевой БД
-- ============================================
-- Без этого DROP DATABASE может не выполниться, если открыт pgAdmin/DBeaver/psql.
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = 'multilogictrade'
  AND pid <> pg_backend_pid();

-- ============================================
-- Шаг 2: удалить базу (если существует — без ошибки)
-- ============================================
DROP DATABASE IF EXISTS multilogictrade;

-- ============================================
-- Шаг 3: создать пустую базу
-- ============================================
CREATE DATABASE multilogictrade
    ENCODING 'UTF8'
    TEMPLATE template0;

-- После выполнения подключитесь к multilogictrade и запустите 01, 02, 03.
-- pgAdmin: Query Tool на multilogictrade → открыть 01_...sql
-- psql:    psql -d multilogictrade -f 01_multilogictrade_tables_and_data.sql
