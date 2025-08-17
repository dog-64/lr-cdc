#!/usr/bin/env bash

# =====================================================
# Скрипт настройки logical replication для 3-нодового кластера
# PostgreSQL 16 - тестовый макет
# =====================================================

set -euo pipefail

# ---------- Конфигурация ----------
SHARDS=(0 1 2)
HOSTS=(localhost localhost localhost)
PORTS=(5433 5434 5435)
# Имена контейнеров для внутренних соединений между шардами
CONTAINER_HOSTS=(shard0 shard1 shard2)
CONTAINER_PORTS=(5432 5432 5432)  # Внутренние порты в контейнерах
DB=app
USER=replicator
PASS=replicator

export PGPASSWORD=$PASS

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ---------- Вспомогательные функции ----------
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Функция ожидания готовности PostgreSQL
wait_until_ready() {
    local host=$1
    local port=$2
    local max_attempts=60
    local attempt=1
    
    log_info "Ожидаем готовности PostgreSQL на $host:$port..."
    
    while [ $attempt -le $max_attempts ]; do
        if pg_isready -h "$host" -p "$port" -U "$USER" -d "$DB" > /dev/null 2>&1; then
            log_success "PostgreSQL на $host:$port готов!"
            return 0
        fi
        
        if [ $attempt -eq $max_attempts ]; then
            log_error "PostgreSQL на $host:$port не готов после $max_attempts попыток"
            return 1
        fi
        
        log_info "Попытка $attempt/$max_attempts - PostgreSQL ещё не готов, ждём..."
        sleep 2
        ((attempt++))
    done
}

# Функция выполнения SQL команды
execute_sql() {
    local host=$1
    local port=$2
    local sql=$3
    
    psql -h "$host" -p "$port" -U "$USER" -d "$DB" \
         -v ON_ERROR_STOP=1 \
         -c "$sql" \
         -t -A -F $'\t' 2>/dev/null || {
        log_error "Ошибка выполнения SQL на $host:$port"
        return 1
    }
}

# Функция выполнения SQL команды без транзакционного блока (для подписок)
execute_sql_no_transaction() {
    local host=$1
    local port=$2
    local sql=$3
    
    psql -h "$host" -p "$port" -U "$USER" -d "$DB" \
         --no-psqlrc \
         -c "$sql" \
         -t -A -F $'\t' 2>/dev/null || {
        log_error "Ошибка выполнения SQL на $host:$port"
        return 1
    }
}

# ---------- Основная логика ----------
main() {
    log_info "Запуск настройки logical replication для 3-нодового кластера"
    
    # 1. Ожидаем готовности всех узлов
    log_info "Шаг 1: Проверяем готовность всех узлов PostgreSQL..."
    for i in "${!SHARDS[@]}"; do
        if ! wait_until_ready "${HOSTS[i]}" "${PORTS[i]}"; then
            log_error "Не удалось дождаться готовности shard${SHARDS[i]}"
            exit 1
        fi
    done
    
    log_success "Все узлы PostgreSQL готовы!"
    
    # 2. Создаём публикации на каждом узле
    log_info "Шаг 2: Создаём публикации на всех узлах..."
    for i in "${!SHARDS[@]}"; do
        local shard_id=${SHARDS[i]}
        local host=${HOSTS[i]}
        local port=${PORTS[i]}
        
        log_info "Создаём публикацию pub_shard_${shard_id} на shard${shard_id}..."
        
        local create_pub_sql="
            DROP PUBLICATION IF EXISTS pub_shard_${shard_id};
            CREATE PUBLICATION pub_shard_${shard_id}
                FOR TABLE public.users
                WITH (
                    publish = 'insert,update,delete,truncate',
                    publish_via_partition_root = false
                );
        "
        
        if execute_sql "$host" "$port" "$create_pub_sql"; then
            log_success "Публикация pub_shard_${shard_id} создана на shard${shard_id}"
        else
            log_error "Не удалось создать публикацию на shard${shard_id}"
            exit 1
        fi
    done
    
    # 3. Очищаем старые слоты репликации
    log_info "Шаг 3: Очищаем старые слоты репликации..."
    for i in "${!SHARDS[@]}"; do
        local shard_id=${SHARDS[i]}
        local host=${HOSTS[i]}
        local port=${PORTS[i]}
        
        log_info "Очищаем слоты репликации на shard${shard_id}..."
        
        # Сначала удаляем все подписки
        local cleanup_subs_sql="
            SELECT 'DROP SUBSCRIPTION IF EXISTS ' || subname || ';' as cmd
            FROM pg_subscription 
            WHERE subname LIKE 'sub_from_shard_%';
        "
        execute_sql "$host" "$port" "$cleanup_subs_sql" || true
        
        # Затем удаляем неактивные слоты репликации
        local cleanup_slots_sql="
            SELECT pg_drop_replication_slot(slot_name) 
            FROM pg_replication_slots 
            WHERE slot_name LIKE 'sub_from_shard_%' AND NOT active;
        "
        execute_sql "$host" "$port" "$cleanup_slots_sql" || true
    done
    
    # 4. Создаём подписки (mesh topology)
    log_info "Шаг 4: Создаём подписки для полного mesh..."
    for i in "${!SHARDS[@]}"; do
        local source_shard=${SHARDS[i]}
        local source_host=${HOSTS[i]}
        local source_port=${PORTS[i]}
        
        for j in "${!SHARDS[@]}"; do
            local target_shard=${SHARDS[j]}
            
            # Пропускаем само-подписку
            if [ "$source_shard" = "$target_shard" ]; then
                continue
            fi
            
            local target_container_host=${CONTAINER_HOSTS[j]}
            local target_container_port=${CONTAINER_PORTS[j]}
            
            log_info "Создаём подписку sub_from_shard_${target_shard} на shard${source_shard}..."
            
            # Сначала удаляем подписку если существует
            local drop_sub_sql="DROP SUBSCRIPTION IF EXISTS sub_from_shard_${target_shard};"
            execute_sql "$source_host" "$source_port" "$drop_sub_sql" || true
            
            # Затем создаём новую подписку (без транзакционного блока)
            # Используем имена контейнеров для внутренних соединений
            # Имя слота делаем уникальным: sub_from_shard_X_to_Y
            local slot_name="sub_from_shard_${target_shard}_to_${source_shard}"
            local create_sub_sql="
                CREATE SUBSCRIPTION sub_from_shard_${target_shard}
                    CONNECTION 'host=${target_container_host} port=${target_container_port} dbname=${DB} user=${USER} password=${PASS}'
                    PUBLICATION pub_shard_${target_shard}
                    WITH (
                        create_slot = true,
                        slot_name = '${slot_name}',
                        enabled = true,
                        copy_data = false,
                        streaming = on,
                        binary = on,
                        synchronous_commit = 'off',
                        origin = 'none'
                    );
            "
            
            if execute_sql_no_transaction "$source_host" "$source_port" "$create_sub_sql"; then
                log_success "Подписка sub_from_shard_${target_shard} создана на shard${source_shard}"
            else
                log_error "Не удалось создать подписку sub_from_shard_${target_shard} на shard${source_shard}"
                exit 1
            fi
        done
    done
    
    # 5. Проверяем статус созданных публикаций и подписок
    log_info "Шаг 5: Проверяем статус репликации..."
    echo
    echo "=== СТАТУС ПУБЛИКАЦИЙ ==="
    for i in "${!SHARDS[@]}"; do
        local shard_id=${SHARDS[i]}
        local host=${HOSTS[i]}
        local port=${PORTS[i]}
        
        echo "--- Shard ${shard_id} (${host}:${port}) ---"
        execute_sql "$host" "$port" "
            SELECT 
                pubname as publication_name,
                puballtables as all_tables,
                pubinsert as insert_enabled,
                pubupdate as update_enabled,
                pubdelete as delete_enabled,
                pubtruncate as truncate_enabled
            FROM pg_publication 
            WHERE pubname LIKE 'pub_shard_%';
        " || echo "Ошибка получения информации о публикациях"
        echo
    done
    
    echo "=== СТАТУС ПОДПИСОК ==="
    for i in "${!SHARDS[@]}"; do
        local shard_id=${SHARDS[i]}
        local host=${HOSTS[i]}
        local port=${PORTS[i]}
        
        echo "--- Shard ${shard_id} (${host}:${port}) ---"
        execute_sql "$host" "$port" "
            SELECT 
                subname as subscription_name,
                subscription_status,
                pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), latest_end_lsn)) as lag,
                sync_error
            FROM pg_stat_subscription 
            WHERE subname LIKE 'sub_from_shard_%';
        " || echo "Ошибка получения информации о подписках"
        echo
    done
    
    log_success "Настройка logical replication завершена успешно!"
    log_info "Используйте скрипт check_lr.sh для мониторинга состояния репликации"
}

# ---------- Обработка ошибок ----------
trap 'log_error "Скрипт прерван пользователем"; exit 1' INT TERM

# ---------- Запуск ----------
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
