# Макет 3-нодового кластера PostgreSQL 16 с Logical Replication

## 📋 Описание проекта

Это прототип 3-нодового кластера PostgreSQL 16, использующего **logical replication** в топологии "каждый-к-каждому" (full mesh). Каждый узел публикует свои изменения и подписывается на изменения от других узлов.

### 🎯 Что будет создано

- **3 Docker-контейнера** (`shard0`, `shard1`, `shard2`) на портах **5433-5435**
- **Одна таблица** `public.users` на каждом узле с идентичной структурой
- **Полный mesh**: каждый узел публикует изменения и подписывается на остальные два
- **Автоматический мониторинг** состояния репликации и лагов

### 🚫 Ограничения

- ❌ Без партиций таблиц
- ❌ Без Row Level Security (RLS)
- ❌ Без внешних расширений (pglogical, BDR)
- ❌ Без sequence-шардинга

## 🚀 Быстрый старт

### 1. Подготовка окружения

```bash
# Клонируйте репозиторий или скопируйте файлы
git clone <your-repo>
cd <repo>

# Сделайте скрипты исполняемыми
chmod +x *.sh
```

### 2. Запуск кластера

```bash
# Запустите все контейнеры
docker-compose up -d

# Дождитесь готовности (можно проверить статус)
docker-compose ps
```

### 3. Настройка репликации

```bash
# Запустите скрипт настройки репликации
./setup-replication.sh

# Если используете fish shell и возникают проблемы:
bash setup-replication.sh
```

### 4. Проверка работы

```bash
# Проверьте статус репликации на любом узле
./check_lr.sh localhost 5433
./check_lr.sh localhost 5434
./check_lr.sh localhost 5435
```

## 📊 Структура таблицы

Все узлы содержат одинаковую таблицу `public.users`:

```sql
CREATE TABLE public.users (
    user_id    BIGINT       NOT NULL,
    shard_id   SMALLINT     NOT NULL CHECK (shard_id BETWEEN 0 AND 2),
    email      TEXT         NOT NULL,
    created_at TIMESTAMPTZ  NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id)
);

-- REPLICA IDENTITY FULL для избежания конфликтов
ALTER TABLE public.users REPLICA IDENTITY FULL;
```

## 🔄 Как работает репликация

### Топология

```
shard0 (5433) ←→ shard1 (5434) ←→ shard2 (5435)
    ↕              ↕              ↕
    └──────────────┴──────────────┘
```

### Публикации

Каждый узел создаёт одну публикацию:
- `shard0`: `pub_shard_0`
- `shard1`: `pub_shard_1`  
- `shard2`: `pub_shard_2`

### Подписки

Каждый узел подписывается на два других:
- `shard0`: `sub_from_shard_1`, `sub_from_shard_2`
- `shard1`: `sub_from_shard_0`, `sub_from_shard_2`
- `shard2`: `sub_from_shard_0`, `sub_from_shard_1`

**Важно**: 
- Подписки создаются с параметром `copy_data = false`, что означает репликацию только новых изменений. Это предотвращает конфликты дублирующихся ключей при начальной синхронизации.
- Слоты репликации имеют уникальные имена в формате `sub_from_shard_X_to_Y` для избежания конфликтов между узлами.

## 🧪 Тестирование репликации

### Вставка данных

```bash
# Подключитесь к shard0 и вставьте тестовую запись
psql -h localhost -p 5433 -U replicator -d app

INSERT INTO public.users (user_id, shard_id, email) 
VALUES (123456789, 0, 'test@shard0.com');
```

### Проверка репликации

```bash
# Проверьте, что данные появились на shard1
psql -h localhost -p 5434 -U replicator -d app

SELECT * FROM public.users WHERE user_id = 123456789;

# Проверьте на shard2
psql -h localhost -p 5435 -U replicator -d app

SELECT * FROM public.users WHERE user_id = 123456789;
```

### Обновление данных

```bash
# Обновите запись на shard0
psql -h localhost -p 5433 -U replicator -d app

UPDATE public.users 
SET email = 'updated@shard0.com' 
WHERE user_id = 123456789;

# Проверьте, что изменения реплицировались
psql -h localhost -p 5434 -U replicator -d app

SELECT * FROM public.users WHERE user_id = 123456789;
```

## 📈 Мониторинг

### Скрипт check_lr.sh

```bash
# Проверка конкретного узла
./check_lr.sh localhost 5433

# Проверка с указанием хоста и порта
./check_lr.sh shard1 5434

# Справка по использованию
./check_lr.sh --help
```

### Что проверяет скрипт

- ✅ **Статус подписок**: должны быть `running`
- ✅ **Лаг репликации**: должен быть < 10 MB
- ✅ **Ошибки синхронизации**: должны отсутствовать
- ✅ **Слоты репликации**: должны быть активны

### Выходные коды

- `0` - Все подписки работают нормально
- `1` - Есть проблемы с подписками или высокий лаг
- `2` - Ошибка подключения к базе данных

## 🛠️ Управление кластером

### Остановка

```bash
# Остановить контейнеры
docker-compose stop

# Остановить и удалить контейнеры с томами
docker-compose down -v
```

### Перезапуск

```bash
# Перезапустить контейнеры
docker-compose restart

# Полный перезапуск с пересозданием
docker-compose down
docker-compose up -d
```

### Логи

```bash
# Просмотр логов всех контейнеров
docker-compose logs

# Логи конкретного узла
docker-compose logs shard0
docker-compose logs shard1
docker-compose logs shard2

# Логи в реальном времени
docker-compose logs -f
```

## 🔧 Конфигурация

### Docker Compose

Основные параметры PostgreSQL:
- `wal_level=logical` - включение logical replication
- `max_wal_senders=10` - максимальное количество WAL отправителей
- `max_replication_slots=10` - максимальное количество слотов репликации
- `shared_buffers=256MB` - размер разделяемых буферов
- `max_worker_processes=10` - максимальное количество рабочих процессов
- `max_logical_replication_workers=4` - максимальное количество логических репликационных воркеров

### Порты

- `shard0`: 5433 → 5432 (localhost:5433)
- `shard1`: 5434 → 5432 (localhost:5434)
- `shard2`: 5435 → 5432 (localhost:5435)

## 🚨 Устранение неполадок

### Частые проблемы

| Проблема | Решение |
|----------|---------|
| **Подписка "failed"** | Проверьте `sync_error` в `check_lr.sh`, чаще всего это сетевой таймаут |
| **Высокий лаг** | Увеличьте `max_worker_processes` и `max_logical_replication_workers` |
| **Конфликт duplicate key** | Убедитесь, что приложение пишет только в строки со своим `shard_id` |
| **Контейнер не стартует** | Проверьте, что порты 5433-5435 свободны |
| **Ошибка "unbound variable"** | Используйте bash вместо fish: `bash setup-replication.sh` |
| **Команды зависают** | Избегайте циклов в fish shell, используйте простые команды |

### Диагностика

```bash
# Проверка состояния контейнеров
docker-compose ps

# Проверка ресурсов
docker stats

# Проверка сетевых соединений
docker network ls
docker network inspect postgres-cluster

# Подключение к контейнеру для отладки
docker exec -it shard0 bash
```

### Сброс репликации

```bash
# Остановить кластер
docker-compose down -v

# Запустить заново
docker-compose up -d

# Настроить репликацию
./setup-replication.sh
```

## 📁 Структура файлов

```
.
├── docker-compose.yml          # Описание Docker-контейнеров
├── init-shard-0.sql           # Инициализация shard0
├── init-shard-1.sql           # Инициализация shard1
├── init-shard-2.sql           # Инициализация shard2
├── setup-replication.sh       # Настройка репликации
├── check_lr.sh                # Мониторинг состояния
└── README.md                  # Этот файл
```

## 🔄 Расширение функциональности

### Добавление новых таблиц

1. Отредактируйте `init-shard-*.sql` файлы
2. Добавьте новые таблицы в публикации
3. Перезапустите кластер или выполните `REFRESH PUBLICATION`

### Изменение конфигурации

1. Отредактируйте `docker-compose.yml`
2. Перезапустите кластер: `docker-compose down && docker-compose up -d`
3. Выполните `./setup-replication.sh`

## 📚 Дополнительные ресурсы

- [PostgreSQL Logical Replication](https://www.postgresql.org/docs/16/logical-replication.html)
- [Docker Compose Documentation](https://docs.docker.com/compose/)
- [PostgreSQL Configuration](https://www.postgresql.org/docs/16/runtime-config.html)

## 🤝 Поддержка

При возникновении проблем:

1. Проверьте логи: `docker-compose logs`
2. Запустите диагностику: `./check_lr.sh`
3. Убедитесь, что все порты свободны
4. Проверьте версию Docker и Docker Compose

## Восстановление репликации после DDL

### Вставка или удаление поля

Допустим на `shard0` добавляется колонка
(в результате миграции)
```sql
ALTER TABLE users ADD COLUMN t text ;
```
и вставляется запись
```sql
INSERT INTO users (user_id, shard_id, email, t)
VALUES (1000001, 0, 'OlegDuletsky@Gmail.Com', 'OlegDuletsky@Gmail.Com');
```

тгда на shard1 и shard2 подписки останавливаются:
```shell
 ./check_lr.sh localhost 5434
[INFO] Мониторинг logical replication для localhost:5434
[INFO] Максимально допустимый лаг: 10 MB
[INFO] Проверяем подписки на localhost:5434...

=== СТАТУС ПОДПИСОК НА localhost:5434 ===
Подписка                    | Статус    | Лаг        | PID
----------------------------|-----------|------------|--------
sub_from_shard_0             | ❌ stopped | ✅ 0 B    | нет
sub_from_shard_2             | ✅ running | ✅ 8 bytes | 3562

 ./check_lr.sh localhost 5435
[INFO] Мониторинг logical replication для localhost:5435
[INFO] Максимально допустимый лаг: 10 MB
[INFO] Проверяем подписки на localhost:5435...

=== СТАТУС ПОДПИСОК НА localhost:5435 ===
Подписка                    | Статус    | Лаг        | PID
----------------------------|-----------|------------|--------
sub_from_shard_0             | ❌ stopped | ✅ 0 B    | нет
sub_from_shard_1             | ✅ running | ✅ -8 bytes | 3564
```

проверка статуса подписок на shard1 и shard2:
```sql
SELECT 
    subname,
    CASE 
        WHEN pid IS NOT NULL THEN 'running'
        ELSE 'stopped'
    END as status,
    COALESCE(pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), latest_end_lsn)), '0 B') as lag,
    COALESCE(last_msg_send_time::text, '') as last_msg_time,
    latest_end_lsn,
    pid
FROM pg_stat_subscription 
WHERE subname LIKE 'sub_from_shard_%'
ORDER BY subname;

    subname      | status  |   lag   |         last_msg_time         | latest_end_lsn | pid  
------------------+---------+---------+-------------------------------+----------------+------
 sub_from_shard_0 | stopped | 0 B     |                               |                |     
 sub_from_shard_2 | running | 8 bytes | 2025-08-18 19:38:52.154824+00 | 0/1975150      | 3562
```

выполняем миграцию на shard1 и shard2:
```sql
ALTER TABLE users ADD COLUMN t text ;
```

обновляем подписки на shard1 и shard2:
```sql
ALTER SUBSCRIPTION sub_from_shard_0 REFRESH PUBLICATION;
```

после этого статусы подписок становятся активными:
```shell
  ./check_lr.sh localhost 5434
[INFO] Мониторинг logical replication для localhost:5434
[INFO] Максимально допустимый лаг: 10 MB
[INFO] Проверяем подписки на localhost:5434...

=== СТАТУС ПОДПИСОК НА localhost:5434 ===
Подписка                    | Статус    | Лаг        | PID
----------------------------|-----------|------------|--------
sub_from_shard_0             | ✅ running | ✅ -288 bytes | 6311
sub_from_shard_2             | ✅ running | ✅ 8 bytes | 3562

[INFO] Проверяем слоты репликации...
=== СЛОТЫ РЕПЛИКАЦИИ ===
Слот                      | Тип      | Активен | Restart LSN | Confirmed Flush LSN
--------------------------|----------|---------|-------------|---------------------
sub_from_shard_1_to_0      | logical  | ✅     | 0/19794E8   | 0/1979520
sub_from_shard_1_to_2      | logical  | ✅     | 0/19794E8   | 0/1979520

[SUCCESS] Все подписки работают нормально, лаг в пределах нормы (< 10 MB)

 ./check_lr.sh localhost 5435
[INFO] Мониторинг logical replication для localhost:5435
[INFO] Максимально допустимый лаг: 10 MB
[INFO] Проверяем подписки на localhost:5435...

=== СТАТУС ПОДПИСОК НА localhost:5435 ===
Подписка                    | Статус    | Лаг        | PID
----------------------------|-----------|------------|--------
sub_from_shard_0             | ✅ running | ✅ -296 bytes | 6311
sub_from_shard_1             | ✅ running | ✅ -8 bytes | 3564

[INFO] Проверяем слоты репликации...
=== СЛОТЫ РЕПЛИКАЦИИ ===
Слот                      | Тип      | Активен | Restart LSN | Confirmed Flush LSN
--------------------------|----------|---------|-------------|---------------------
sub_from_shard_2_to_0      | logical  | ✅     | 0/19794E0   | 0/1979518
sub_from_shard_2_to_1      | logical  | ✅     | 0/19794E0   | 0/1979518

[SUCCESS] Все подписки работают нормально, лаг в пределах нормы (< 10 MB)
```

### Добавление или удаление таблицы

На shard0:
```sql
CREATE TABLE t1 (t1 BIGSERIAL PRIMARY KEY);
INSERT INTO t1 DEFAULT VALUES;

ALTER PUBLICATION pub_shard_0  ADD TABLE t1;
```

выполняем миграцию на shard1 и shard2:
```sql
CREATE TABLE t1 (t1 BIGSERIAL PRIMARY KEY);
```

обновляем подписки на shard1 и shard2:
```sql
ALTER SUBSCRIPTION sub_from_shard_0 REFRESH PUBLICATION;
```

После этого статусы репликации активны:
```shell
 ./check_lr.sh localhost 5434
[INFO] Мониторинг logical replication для localhost:5434
[INFO] Максимально допустимый лаг: 10 MB
[INFO] Проверяем подписки на localhost:5434...

=== СТАТУС ПОДПИСОК НА localhost:5434 ===
Подписка                    | Статус    | Лаг        | PID
----------------------------|-----------|------------|--------
sub_from_shard_0             | ✅ running | ✅ -285 kB | 6311
sub_from_shard_2             | ✅ running | ✅ 8 bytes | 3562

[INFO] Проверяем слоты репликации...
=== СЛОТЫ РЕПЛИКАЦИИ ===
Слот                      | Тип      | Активен | Restart LSN | Confirmed Flush LSN
--------------------------|----------|---------|-------------|---------------------
sub_from_shard_1_to_0      | logical  | ✅     | 0/19794E8   | 0/1979520
sub_from_shard_1_to_2      | logical  | ✅     | 0/19794E8   | 0/1979520

[SUCCESS] Все подписки работают нормально, лаг в пределах нормы (< 10 MB)
~/Sites/lr-cdc  cursor-init 22:00:18  ./check_lr.sh localhost 5435
[INFO] Мониторинг logical replication для localhost:5435
[INFO] Максимально допустимый лаг: 10 MB
[INFO] Проверяем подписки на localhost:5435...

=== СТАТУС ПОДПИСОК НА localhost:5435 ===
Подписка                    | Статус    | Лаг        | PID
----------------------------|-----------|------------|--------
sub_from_shard_0             | ✅ running | ✅ -301 kB | 6311
sub_from_shard_1             | ✅ running | ✅ -8 bytes | 3564

[INFO] Проверяем слоты репликации...
=== СЛОТЫ РЕПЛИКАЦИИ ===
Слот                      | Тип      | Активен | Restart LSN | Confirmed Flush LSN
--------------------------|----------|---------|-------------|---------------------
sub_from_shard_2_to_0      | logical  | ✅     | 0/19794E0   | 0/1979518
sub_from_shard_2_to_1      | logical  | ✅     | 0/19794E0   | 0/1979518

[SUCCESS] Все подписки работают нормально, лаг в пределах нормы (< 10 MB)
```
