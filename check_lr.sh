#!/usr/bin/env bash

# =====================================================
# Скрипт мониторинга logical replication
# PostgreSQL 16 - тестовый макет
# =====================================================

set -euo pipefail

# ---------- Конфигурация по умолчанию ----------
HOST=${1:-localhost}
PORT=${2:-5432}
DB=app
USER=replicator
PASS=replicator

# Пороговые значения для проверок
MAX_LAG_MB=10
MAX_LAG_BYTES=$((MAX_LAG_MB * 1024 * 1024))

export PGPASSWORD=$PASS

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ---------- Функции логирования ----------
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

# ---------- Функция показа справки ----------
show_usage() {
    cat << EOF
Использование: $0 [HOST] [PORT]

Параметры:
  HOST    Хост PostgreSQL (по умолчанию: localhost)
  PORT    Порт PostgreSQL (по умолчанию: 5432)

Переменные окружения:
  PGPASSWORD  Пароль для подключения к PostgreSQL

Примеры:
  $0                    # Проверить localhost:5432
  $0 shard1 5433       # Проверить shard1:5433
  $0 192.168.1.100 5432 # Проверить удалённый хост

Выходные коды:
  0 - Все подписки работают нормально, лаг < ${MAX_LAG_MB} MB
  1 - Есть проблемы с подписками или лаг превышает порог
  2 - Ошибка подключения к базе данных

EOF
}

# ---------- Функция проверки подключения ----------
check_connection() {
    if ! pg_isready -h "$HOST" -p "$PORT" -U "$USER" -d "$DB" > /dev/null 2>&1; then
        log_error "Не удалось подключиться к PostgreSQL на $HOST:$PORT"
        return 1
    fi
    return 0
}

# ---------- Функция конвертации размера в байты ----------
size_to_bytes() {
    local size_str=$1
    local size_value
    local size_unit
    
    # Извлекаем числовое значение и единицу измерения
    if [[ $size_str =~ ^([0-9.]+)\s*(bytes?|[KMGT]?B)$ ]]; then
        size_value=${BASH_REMATCH[1]}
        size_unit=${BASH_REMATCH[2]}
    else
        # Если не удалось распарсить, считаем что это 0 байт
        echo "0"
        return 0
    fi
    
    # Конвертируем в байты
    case $size_unit in
        "B"|""|"byte"|"bytes")
            echo "${size_value%.*}"
            ;;
        "KB")
            echo "$(($(echo "$size_value * 1024" | bc -l | cut -d. -f1)))"
            ;;
        "MB")
            echo "$(($(echo "$size_value * 1024 * 1024" | bc -l | cut -d. -f1)))"
            ;;
        "GB")
            echo "$(($(echo "$size_value * 1024 * 1024 * 1024" | bc -l | cut -d. -f1)))"
            ;;
        "TB")
            echo "$(($(echo "$size_value * 1024 * 1024 * 1024 * 1024" | bc -l | cut -d. -f1)))"
            ;;
        *)
            echo "$size_value"
            ;;
    esac
}

# ---------- Функция проверки подписок ----------
check_subscriptions() {
    local exit_code=0
    
    log_info "Проверяем подписки на $HOST:$PORT..."
    
    # Получаем информацию о подписках
    local subscriptions_sql="
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
    "
    
    local subscriptions_output
    if ! subscriptions_output=$(psql -h "$HOST" -p "$PORT" -U "$USER" -d "$DB" \
                                   -v ON_ERROR_STOP=1 \
                                   -c "$subscriptions_sql" \
                                   -t -A -F $'\t' 2>/dev/null); then
        log_error "Не удалось получить информацию о подписках"
        return 1
    fi
    
    if [ -z "$subscriptions_output" ]; then
        log_warning "Подписки не найдены на узле $HOST:$PORT"
        return 1
    fi
    
    echo
    echo "=== СТАТУС ПОДПИСОК НА $HOST:$PORT ==="
    echo "Подписка                    | Статус    | Лаг        | PID"
    echo "----------------------------|-----------|------------|--------"
    
    local has_errors=false
    local has_high_lag=false
    
    while IFS=$'\t' read -r subname status lag last_msg_time latest_end_lsn pid; do
        # Проверяем статус
        local status_icon="✅"
        if [ "$status" != "running" ]; then
            status_icon="❌"
            has_errors=true
            exit_code=1
        fi
        
        # Проверяем лаг
        local lag_icon="✅"
        local lag_bytes
        lag_bytes=$(size_to_bytes "$lag")
        
        if [ "$lag_bytes" -gt "$MAX_LAG_BYTES" ]; then
            lag_icon="⚠️"
            has_high_lag=true
            exit_code=1
        fi
        
        # Форматируем вывод
        printf "%-28s | %-9s | %-10s | %s\n" \
               "$subname" \
               "$status_icon $status" \
               "$lag_icon $lag" \
               "${pid:-нет}"
    done <<< "$subscriptions_output"
    
    echo
    
    # Проверяем слоты репликации
    log_info "Проверяем слоты репликации..."
    local slots_sql="
        SELECT 
            slot_name,
            slot_type,
            active,
            restart_lsn,
            confirmed_flush_lsn
        FROM pg_replication_slots 
        WHERE slot_name LIKE 'sub_from_shard_%'
        ORDER BY slot_name;
    "
    
    local slots_output
    if slots_output=$(psql -h "$HOST" -p "$PORT" -U "$USER" -d "$DB" \
                        -v ON_ERROR_STOP=1 \
                        -c "$slots_sql" \
                        -t -A -F $'\t' 2>/dev/null); then
        
        if [ -n "$slots_output" ]; then
            echo "=== СЛОТЫ РЕПЛИКАЦИИ ==="
            echo "Слот                      | Тип      | Активен | Restart LSN | Confirmed Flush LSN"
            echo "--------------------------|----------|---------|-------------|---------------------"
            
            while IFS=$'\t' read -r slot_name slot_type active restart_lsn confirmed_flush_lsn; do
                local active_icon="✅"
                if [ "$active" != "t" ]; then
                    active_icon="❌"
                fi
                
                printf "%-26s | %-8s | %-7s | %-11s | %s\n" \
                       "$slot_name" \
                       "$slot_type" \
                       "$active_icon" \
                       "${restart_lsn:-NULL}" \
                       "${confirmed_flush_lsn:-NULL}"
            done <<< "$slots_output"
            echo
        fi
    fi
    
    # Итоговая оценка
    if [ $exit_code -eq 0 ]; then
        log_success "Все подписки работают нормально, лаг в пределах нормы (< ${MAX_LAG_MB} MB)"
    else
        if [ "$has_errors" = true ]; then
            log_error "Обнаружены проблемы с подписками"
        fi
        if [ "$has_high_lag" = true ]; then
            log_warning "Обнаружен высокий лаг репликации (> ${MAX_LAG_MB} MB)"
        fi
    fi
    
    return $exit_code
}

# ---------- Основная функция ----------
main() {
    # Проверяем аргументы
    if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
        show_usage
        exit 0
    fi
    
    log_info "Мониторинг logical replication для $HOST:$PORT"
    log_info "Максимально допустимый лаг: ${MAX_LAG_MB} MB"
    
    # Проверяем подключение
    if ! check_connection; then
        log_error "Ошибка подключения к базе данных"
        exit 2
    fi
    
    # Проверяем подписки
    if ! check_subscriptions; then
        exit 1
    fi
    
    exit 0
}

# ---------- Обработка ошибок ----------
trap 'log_error "Скрипт прерван пользователем"; exit 1' INT TERM

# ---------- Запуск ----------
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
