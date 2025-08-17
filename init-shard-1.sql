-- =====================================================
-- Инициализация shard1 для logical replication
-- PostgreSQL 16 - тестовый макет
-- =====================================================

-- Создаём таблицу users (одинаковая на всех узлах)
CREATE TABLE IF NOT EXISTS public.users (
    user_id    BIGINT       NOT NULL,
    shard_id   SMALLINT     NOT NULL CHECK (shard_id BETWEEN 0 AND 2),
    email      TEXT         NOT NULL,
    created_at TIMESTAMPTZ  NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id)
);

-- Устанавливаем REPLICA IDENTITY FULL для избежания конфликтов репликации
-- Это гарантирует, что все колонки будут переданы при UPDATE/DELETE
ALTER TABLE public.users REPLICA IDENTITY FULL;

-- Создаём индексы для оптимизации запросов
CREATE INDEX IF NOT EXISTS idx_users_shard_id ON public.users(shard_id);
CREATE INDEX IF NOT EXISTS idx_users_email ON public.users(email);
CREATE INDEX IF NOT EXISTS idx_users_created_at ON public.users(created_at);

-- Вставляем тестовую строку для данного шарда
-- Эта строка будет реплицирована на другие узлы
INSERT INTO public.users (user_id, shard_id, email) 
VALUES (2000000, 1, 'shard1@example.com')
ON CONFLICT (user_id) DO NOTHING;

-- Создаём пользователя для репликации (если не существует)
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'replicator') THEN
        CREATE USER replicator WITH REPLICATION LOGIN PASSWORD 'replicator';
    END IF;
END
$$;

-- Даём права на таблицу
GRANT ALL PRIVILEGES ON TABLE public.users TO replicator;
GRANT USAGE ON SCHEMA public TO replicator;

-- Логируем завершение инициализации
SELECT 'Shard 1 initialized successfully' as status;
