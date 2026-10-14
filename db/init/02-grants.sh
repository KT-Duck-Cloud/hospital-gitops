#!/bin/bash
# 로컬 docker compose 전용. MySQL 첫 시작 때 schema.sql 다음, seed.sql 전에 실행된다.
# db/grants.sql 의 비밀번호 자리표시자를 컨테이너 환경변수(.env 에서 옴) 값으로 바꿔 root 로 실행한다.
# 비밀번호 값은 화면·로그에 출력하지 않는다.
(
    set -euo pipefail

    for name in APP_RUNTIME_PASSWORD APP_READONLY_PASSWORD APP_MIGRATE_PASSWORD; do
        value="${!name:-}"
        # sed·SQL 따옴표가 깨지지 않도록 영문·숫자만 허용한다 (scripts/make_env.ps1 이 이 형식으로 만든다).
        if [[ ! "$value" =~ ^[A-Za-z0-9]{16,}$ ]]; then
            echo "02-grants.sh: $name 이 비었거나 형식이 틀렸습니다 (영문·숫자 16자 이상)." >&2
            exit 1
        fi
    done

    sed -e "s/__APP_RUNTIME_PASSWORD__/${APP_RUNTIME_PASSWORD}/" \
        -e "s/__APP_READONLY_PASSWORD__/${APP_READONLY_PASSWORD}/" \
        -e "s/__APP_MIGRATE_PASSWORD__/${APP_MIGRATE_PASSWORD}/" \
        /db/grants.sql \
    | MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql --protocol=socket -uroot

    echo "02-grants.sh: app_runtime, app_readonly, app_migrate 계정을 만들었습니다."
)
