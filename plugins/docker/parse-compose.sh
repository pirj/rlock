#!/usr/bin/env bash
set -euo pipefail

# Translate a known compose service image to Alpine provisioning commands.
# Usage: translate_compose_service service_name image env_string
# env_string is space-separated KEY=VALUE pairs.
# Outputs provisioning commands to stdout, one per line.
translate_compose_service() {
    local name="$1"
    local image="$2"
    local env_str="$3"

    # Strip tag from image name
    local base_image="${image%%:*}"
    # Strip org prefix
    base_image="${base_image##*/}"

    case "$base_image" in
        postgres|postgresql)
            echo "apk add postgresql postgresql-client"
            echo "rc-update add postgresql"
            local pg_user="" pg_db="" pg_pass=""
            local kv
            for kv in $env_str; do
                case "$kv" in
                    POSTGRES_USER=*)     pg_user="${kv#*=}" ;;
                    POSTGRES_DB=*)       pg_db="${kv#*=}" ;;
                    POSTGRES_PASSWORD=*) pg_pass="${kv#*=}" ;;
                esac
            done
            echo 'su -l postgres -c "initdb -D /var/lib/postgresql/data"'
            echo "rc-service postgresql start"
            if [[ -n "$pg_user" ]]; then
                echo "su -l postgres -c \"createuser ${pg_user}\""
            fi
            if [[ -n "$pg_db" ]]; then
                local owner_flag=""
                [[ -n "$pg_user" ]] && owner_flag=" -O ${pg_user}"
                echo "su -l postgres -c \"createdb${owner_flag} ${pg_db}\""
            fi
            if [[ -n "$pg_user" && -n "$pg_pass" ]]; then
                echo "su -l postgres -c \"psql -c \\\"ALTER USER ${pg_user} PASSWORD '${pg_pass}';\\\"\""
            fi
            ;;
        redis)
            echo "apk add redis"
            echo "rc-update add redis"
            echo "rc-service redis start"
            ;;
        mysql|mariadb)
            echo "apk add mariadb mariadb-client"
            echo "rc-update add mariadb"
            echo "/etc/init.d/mariadb setup"
            echo "rc-service mariadb start"
            local my_user="" my_db=""
            for kv in $env_str; do
                case "$kv" in
                    MYSQL_USER=*)     my_user="${kv#*=}" ;;
                    MYSQL_DATABASE=*) my_db="${kv#*=}" ;;
                esac
            done
            if [[ -n "$my_db" ]]; then
                echo "mysql -u root -e \"CREATE DATABASE IF NOT EXISTS ${my_db};\""
            fi
            if [[ -n "$my_user" ]]; then
                local grant_db="${my_db:-*}"
                echo "mysql -u root -e \"CREATE USER IF NOT EXISTS '${my_user}'@'localhost'; GRANT ALL ON ${grant_db}.* TO '${my_user}'@'localhost';\""
            fi
            ;;
        memcached)
            echo "apk add memcached"
            echo "rc-update add memcached"
            echo "rc-service memcached start"
            ;;
        *)
            echo "Warning: Service '$name' uses image '$image' — no Alpine mapping. Install manually via rl ssh." >&2
            ;;
    esac
}

# Translate a docker-compose.yml file to provisioning commands.
# Usage: translate_compose /path/to/docker-compose.yml
# Requires yq on the host.
translate_compose() {
    local composefile="$1"

    if ! command -v yq > /dev/null 2>&1; then
        echo "Warning: yq required to process docker-compose.yml. Install: brew install yq" >&2
        return 0
    fi

    # Get list of service names
    local services
    services=$(yq '.services | keys | .[]' "$composefile" 2>/dev/null) || return 0

    local service
    for service in $services; do
        local image
        image=$(yq ".services.${service}.image // \"\"" "$composefile")
        if [[ -z "$image" ]]; then
            local build_path
            build_path=$(yq ".services.${service}.build // \"\"" "$composefile")
            if [[ -n "$build_path" ]]; then
                echo "Warning: Service '$service' uses build — translate its Dockerfile separately" >&2
            fi
            continue
        fi

        # Collect environment variables
        local env_str=""
        local env_format
        env_format=$(yq ".services.${service}.environment | type" "$composefile" 2>/dev/null) || true

        if [[ "$env_format" == "!!map" ]]; then
            local env_keys
            env_keys=$(yq ".services.${service}.environment | keys | .[]" "$composefile" 2>/dev/null) || true
            local k
            for k in $env_keys; do
                local v
                v=$(yq ".services.${service}.environment.${k}" "$composefile")
                env_str="$env_str ${k}=${v}"
            done
        elif [[ "$env_format" == "!!seq" ]]; then
            local entries
            entries=$(yq ".services.${service}.environment[]" "$composefile" 2>/dev/null) || true
            env_str="$entries"
        fi

        translate_compose_service "$service" "$image" "${env_str# }"
    done
}
