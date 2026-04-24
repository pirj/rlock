#!/usr/bin/env bats

setup() {
    load 'test_helper/common'
    _common_setup

    PLUGIN_DIR="$PROJECT_ROOT/plugins/docker"
    source "$PLUGIN_DIR/parse-compose.sh"
}

@test "translate_compose_service generates postgres setup" {
    run translate_compose_service "db" "postgres:15" "POSTGRES_USER=myuser POSTGRES_DB=mydb POSTGRES_PASSWORD=secret"
    assert_success
    assert_line "apk add postgresql postgresql-client"
    assert_line --partial "initdb"
    assert_line --partial "createuser"
    assert_line --partial "createdb"
    assert_line --partial "rc-update add postgresql"
}

@test "translate_compose_service generates redis setup" {
    run translate_compose_service "cache" "redis:7" ""
    assert_success
    assert_line "apk add redis"
    assert_line "rc-update add redis"
    assert_line "rc-service redis start"
}

@test "translate_compose_service generates mariadb setup" {
    run translate_compose_service "db" "mariadb:10" "MYSQL_USER=app MYSQL_DATABASE=appdb MYSQL_ROOT_PASSWORD=secret"
    assert_success
    assert_line "apk add mariadb mariadb-client"
    assert_line --partial "rc-update add mariadb"
}

@test "translate_compose_service generates memcached setup" {
    run translate_compose_service "mem" "memcached:latest" ""
    assert_success
    assert_line "apk add memcached"
    assert_line "rc-update add memcached"
}

@test "translate_compose_service warns on unknown image" {
    run translate_compose_service "search" "elasticsearch:8" ""
    assert_success
    assert_output --partial "no Alpine mapping"
}

@test "translate_compose parses full compose file" {
    local composefile="$BATS_TEST_TMPDIR/docker-compose.yml"
    cat > "$composefile" <<'EOF'
services:
  db:
    image: postgres:15
    environment:
      POSTGRES_USER: myuser
      POSTGRES_DB: mydb
      POSTGRES_PASSWORD: secret
  cache:
    image: redis:7
EOF
    if ! command -v yq > /dev/null 2>&1; then
        skip "yq not installed"
    fi
    run bash -c "source '$PLUGIN_DIR/parse-compose.sh' && translate_compose '$composefile' 2>/dev/null"
    assert_success
    assert_line --partial "apk add postgresql"
    assert_line --partial "apk add redis"
}
