-- ============================================
-- MultiLogicTrade — шаг 0: создание базы данных
-- ============================================
-- Выполнить ОДИН РАЗ от имени суперпользователя,
-- подключившись к служебной БД postgres (не к multilogictrade).
--
-- PostgreSQL не позволяет CREATE DATABASE внутри функции/транзакции,
-- поэтому этот файл отделён от скриптов схемы.
--
-- Порядок развёртывания:
--   00_create_database.sql          (если БД ещё нет)
--   01_multilogictrade_tables_and_data.sql
--   02_multilogictrade_functions_and_procedures.sql
--   03_multilogictrade_examples.sql  (необязательно)
-- ============================================

-- Если база уже существует — будет ошибка «already exists», её можно игнорировать.
CREATE DATABASE multilogictrade
    ENCODING 'UTF8'
    TEMPLATE template0;

-- После создания подключитесь к multilogictrade и выполните файлы 01, 02, 03.
-- pgAdmin: правый клик на multilogictrade → Query Tool.
-- psql:    psql -d multilogictrade -f 01_multilogictrade_tables_and_data.sql
