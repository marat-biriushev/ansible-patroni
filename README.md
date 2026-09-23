# HA-кластер PostgreSQL 18 + Patroni 4.1.5 (RHEL 9 / RHEL 10)

Ansible-проект разворачивает отказоустойчивый кластер PostgreSQL 18 под управлением Patroni:

```
                    приложения
                        │
              VIP (keepalived, unicast VRRP)
        ┌───────────────┴───────────────┐
   haproxy01 (MASTER)              haproxy02 (BACKUP)
   :5000 → primary  :5001 → replicas  :7000 → stats
        └───────────────┬───────────────┘
        ┌───────────────┼───────────────┐
      pg01            pg02            pg03        PostgreSQL 18 + Patroni (REST :8008)
        └───────────────┼───────────────┘         synchronous_mode: true
      etcd01          etcd02          etcd03      DCS: etcd v3, TLS + auth
```

- 3 узла PostgreSQL 18 + Patroni (1 primary + 2 реплики, `synchronous_mode: true`).
- 3 узла etcd (DCS) — отдельная группа, можно совместить с узлами БД (`etcd_colocated`).
- 2 узла HAProxy + keepalived с общим VIP.
- pgBackRest (S3) и PgBouncer — по флагам, по умолчанию выключены.
- Пакеты PostgreSQL-экосистемы ставятся **только** из внутреннего зеркала
  `http://mirror.ipotekabank.uz/repos/`. HAProxy и keepalived ставятся из AppStream (`redhat.repo`).

## Границы ответственности

Проект настраивает только то, что нужно кластеру PostgreSQL/Patroni. Он **не трогает**:
chrony/NTP, DNS, hostname, `/etc/hosts`, SSSD/LDAP, SSH, базовый hardening, proxy,
системный logrotate, агенты мониторинга, `redhat.repo` и подписку RHEL, монтирование дисков.

Исключения, без которых не работают функции кластера:

- `policycoreutils-python-utils` ставится при `manage_selinux: true` — он нужен для меток портов (`seport`).
- `python3-psycopg2` ставится при `pgbouncer_enabled: true` — через него создаётся функция `auth_query`.

## Структура

```
├── ansible.cfg  requirements.yml  .ansible-lint  .yamllint
├── scripts/check_mirror.sh             # проверка зеркала с целевого хоста
├── inventories/prod/
│   ├── hosts.yml                       # группы etcd, postgres, haproxy
│   ├── group_vars/all/{main,repos,secrets}.yml, vault.yml.example
│   ├── group_vars/{etcd,postgres,haproxy}.yml
│   └── host_vars/{pg01..pg03,haproxy01,haproxy02}.yml
├── playbooks/
│   ├── site.yml                        # всё по порядку
│   ├── preflight.yml                   # assert'ы (запускается всегда)
│   ├── repos.yml  etcd.yml  patroni.yml  haproxy.yml  pgbackrest.yml
└── roles/
    ├── pg_repos     # postgres-local.repo, module disable (RHEL 9), проверки репо/пакетов
    ├── pki          # CA и сертификаты узлов на контроллере (selfsigned | provided)
    ├── etcd         # пакет, systemd, TLS client+peer, RBAC (root + patroni)
    ├── postgresql   # postgresql18-server/contrib, каталоги data/WAL (без initdb)
    ├── patroni      # patroni.yml, systemd, REST TLS+Basic Auth, watchdog, sysctl, DCS
    ├── haproxy      # бэкенды с health-check на :8008, stats, bind на VIP
    ├── keepalived   # unicast VRRP, track_script, VIP, ip_nonlocal_bind
    ├── pgbouncer    # под флагом
    └── pgbackrest   # под флагом: S3, archive/restore_command, stanza-create, таймеры
```

## Репозитории и зеркало

Все репозитории описываются списком `pg_repos_list` в `inventories/prod/group_vars/all/repos.yml`
и пишутся в один файл `/etc/yum.repos.d/postgres-local.repo` (`ansible.builtin.yum_repository`):

| Секция | Путь в зеркале | Пакеты | По умолчанию |
|---|---|---|---|
| `postgres18` | `postgre/yum/18/redhat/rhel-N-x86_64/` | postgresql18-* | включён |
| `postgres-common` | `postgre/yum/common/redhat/rhel-N-x86_64/` | patroni, patroni-etcd, pgbackrest, pgbouncer | выключен |
| `postgres-extras` | `postgre/yum/common/pgdg-rhelN-extras/redhat/rhel-N-x86_64/` | etcd | выключен |

Пути `common` и `extras` повторяют структуру PGDG, но в зеркале могут отличаться.
Если путь другой, переопределите `baseurl` нужной записи. Новый репозиторий добавляется одной записью в список.

**Проверка зеркала** (на любом RHEL 9 и RHEL 10 хосте внутри сети):

```bash
scripts/check_mirror.sh                         # HTTP-код repomd.xml и найденные пакеты
```

Защита от установки из недоступного источника:

- **Pre-flight (тег `preflight`).** Для каждого включённого репозитория проверяется
  `<baseurl>repodata/repomd.xml`. Если файл недоступен, запуск падает с ошибкой
  *«Репозиторий … недоступен в зеркале. Запросите добавление у команды зеркала.»*
- **Проверка перед установкой пакетов.** Каждая роль смотрит, есть ли пакет в подключённых репозиториях.
  Если пакета нет, запуск падает с ошибкой *«Пакет … не найден в подключённых репозиториях. Нужен репо
  postgres-common|postgres-extras, …»*. Обходов (pip, get_url, сторонние репо) нет.

На RHEL 9 выполняется `dnf module disable postgresql`. На RHEL 10 модулей нет, и шаг пропускается.

## Подготовка контроллера

```bash
# ansible-core >= 2.15; для pki_mode: selfsigned нужен python3-cryptography на контроллере
ansible-galaxy collection install -r requirements.yml -p collections
# без интернета: скачайте tar.gz коллекций заранее и установите из файлов
```

## Секреты

```bash
cd inventories/prod/group_vars/all
cp vault.yml.example vault.yml     # заполнить
ansible-vault encrypt vault.yml
```

Все пароли лежат в `vault.yml` с префиксом `vault_*`. Файл `secrets.yml` связывает их с переменными ролей.
Задачи с секретами выполняются с `no_log: "{{ secrets_no_log }}"`. По умолчанию значение `true`,
`false` ставьте только для отладки. Файл `vault.yml` внесён в `.gitignore`, в репозитории хранится только `vault.yml.example`.

| Переменная vault | Назначение |
|---|---|
| `vault_patroni_superuser_password` | суперпользователь `postgres` |
| `vault_patroni_replication_password` | роль репликации `replicator` |
| `vault_patroni_rewind_password` | роль `rewind_user` для pg_rewind |
| `vault_patroni_restapi_password` | Basic Auth REST API Patroni |
| `vault_etcd_root_password` | пользователь `root` etcd |
| `vault_etcd_patroni_password` | пользователь `patroni` etcd |
| `vault_keepalived_auth_pass` | VRRP `auth_pass` (≤ 8 символов) |
| `vault_haproxy_stats_password` | страница статистики HAProxy |
| `vault_pgbouncer_auth_password` | `auth_user` PgBouncer (при `pgbouncer_enabled`) |
| `vault_pgbackrest_s3_key`, `_s3_key_secret`, `_cipher_pass` | pgBackRest (при `pgbackrest_enabled`) |

## PKI (TLS)

По TLS работают:

- etcd: клиентские и peer-соединения;
- REST API Patroni (`https://<node>:8008`);
- SSL PostgreSQL (тот же сертификат узла);
- health-check'и HAProxy (`check-ssl verify required`).

Источник сертификатов задаёт `pki_mode`:

- **`selfsigned`** (по умолчанию). Роль `pki` один раз генерирует CA и сертификаты узлов на контроллере
  в `inventories/prod/pki/`. Повторные запуски переиспользуют уже созданные файлы. Каталог в `.gitignore`.
  **Храните `ca.key` как секрет** (например, в зашифрованном архиве или vault).
- **`provided`**. Сертификаты выпущены корпоративным CA. Положите в `pki_local_dir` файлы
  `ca.crt`, `<host>-etcd.crt/.key` (узлы etcd) и `<host>-patroni.crt/.key` (узлы postgres).
  В SAN должны быть имя узла, его IP и `127.0.0.1`, а в сертификатах patroni — ещё и VIP.

## Основные переменные

### Общие (`group_vars/all/main.yml`)

| Переменная | По умолчанию | Описание |
|---|---|---|
| `pg_major_version` | `18` | мажорная версия PostgreSQL |
| `patroni_scope` | `pg18-ipoteka-cluster` | имя кластера Patroni |
| `patroni_namespace` | `/db/` | префикс ключей в etcd |
| `patroni_bootstrap_leader` | первый узел `postgres` | узел, инициализирующий кластер |
| `cluster_node_ip` | `{{ ansible_host }}` | адрес узла для межузлового трафика |
| `cluster_vip` / `cluster_vip_prefix` | `10.10.10.100` / `24` | VIP keepalived |
| `postgresql_port` | `5432` | |
| `patroni_restapi_port` | `8008` | |
| `patroni_restapi_tls` | `true` | REST API по HTTPS |
| `etcd_client_port` / `etcd_peer_port` | `2379` / `2380` | |
| `pgbouncer_port` | `6432` | |
| `haproxy_primary_port` / `haproxy_replicas_port` / `haproxy_stats_port` | `5000` / `5001` / `7000` | |
| `etcd_colocated` | `false` | etcd на узлах БД |
| `pgbouncer_enabled` | `false` | PgBouncer (HAProxy переключается на порт 6432) |
| `pgbackrest_enabled` | `false` | pgBackRest + archive_command/restore_command |
| `pgbackrest_stanza` | `{{ patroni_scope }}` | имя stanza |
| `manage_firewalld` / `firewalld_zone` | `false` / `public` | открытие портов в firewalld |
| `manage_selinux` | `true` | метки портов и `haproxy_connect_any` (если SELinux включён) |
| `pki_mode` / `pki_local_dir` | `selfsigned` / `inventories/prod/pki` | источник сертификатов |
| `secrets_no_log` | `true` | скрывать секреты в выводе |

### Репозитории (`group_vars/all/repos.yml`)

| Переменная | По умолчанию |
|---|---|
| `pg_mirror_base` | `http://mirror.ipotekabank.uz/repos` |
| `pg_repo_gpgcheck` | `false` |
| `pg_repos_list` | `postgres18` (вкл.), `postgres-common` (выкл.), `postgres-extras` (выкл.) |

### PostgreSQL / Patroni (`group_vars/postgres.yml`, `roles/patroni/defaults`)

| Переменная | По умолчанию | Описание |
|---|---|---|
| `postgresql_data_dir` | `/var/lib/pgsql/18/data` | PGDATA (монтирование — не в проекте) |
| `postgresql_wal_dir` | `/var/lib/pgsql/18/wal` | отдельный каталог WAL (`initdb --waldir`) |
| `patroni_version` | `4.1.5` | версия пакетов patroni/patroni-etcd |
| `patroni_dcs_defaults` | ttl 30, loop_wait 10, retry_timeout 10, maximum_lag_on_failover 1048576, synchronous_mode true, synchronous_mode_strict false, use_pg_rewind, use_slots | `bootstrap.dcs` |
| `patroni_dcs_parameters` | wal_level replica, hot_standby on, io_method, shared_buffers, max_connections, … | параметры в DCS |
| `patroni_dcs_overrides` | `{}` | переопределения DCS (рекурсивный merge) |
| `patroni_io_method` / `patroni_io_method_fallback` | `io_uring` / `worker` | см. «io_method» ниже |
| `patroni_shared_buffers` | 25% RAM | |
| `patroni_max_connections` | `200` | |
| `patroni_postgresql_parameters` | `{}` | локальные параметры узла, мержатся с `patroni_postgresql_parameters_default` |
| `patroni_pg_hba_app_networks` | `[]` | сети приложений с прямым доступом |
| `patroni_pg_hba_extra` | `[]` | дополнительные строки pg_hba |
| `patroni_tags` (host_vars) | `{}` | `nofailover`, `noloadbalance`, `nosync`, `clonefrom` |
| `patroni_watchdog_mode` | `automatic` | `off` / `automatic` / `required` |
| `patroni_watchdog_module` | `softdog` | модуль ядра |
| `patroni_sysctl` | `vm.overcommit_memory: 2`, `vm.overcommit_ratio: 80` | `/etc/sysctl.d/90-patroni.conf` |
| `patroni_malloc_arena_max` | `1` | `MALLOC_ARENA_MAX` в юните |
| `patroni_switchover_before_restart` | `true` | switchover перед рестартом Patroni на лидере |
| `patroni_dcs_restart_pending` | `false` | после `dcs_config` перезапустить узлы с pending restart |

pg_hba строится автоматически. В него входят:

- `local all all peer`;
- `127.0.0.1` (нужен для PgBouncer);
- репликация и rewind между узлами БД;
- IP узлов HAProxy (PostgreSQL видит клиентов с их адресов);
- `patroni_pg_hba_app_networks`;
- `patroni_pg_hba_extra`.

### etcd (`roles/etcd/defaults`)

| Переменная | По умолчанию |
|---|---|
| `etcd_data_dir` | `/var/lib/etcd` |
| `etcd_patroni_user` / `etcd_patroni_role` | `patroni` / `patroni` (readwrite на `patroni_namespace`) |
| `etcd_client_cert_auth` | `false` (клиенты — по логину/паролю поверх TLS) |
| `etcd_heartbeat_interval` / `etcd_election_timeout` | `100` / `1000` |
| `etcd_extra_config` | `{}` — любые ключи `etcd.yml` |

### HAProxy / keepalived (`group_vars/haproxy.yml`, `host_vars/haproxy0N.yml`)

| Переменная | По умолчанию | Где |
|---|---|---|
| `keepalived_state` | `MASTER` / `BACKUP` | host_vars |
| `keepalived_priority` | `150` / `100` | host_vars |
| `keepalived_virtual_router_id` | `51` | group_vars |
| `keepalived_interface` | интерфейс default route | group_vars |
| `keepalived_check_script` | `/usr/bin/pidof haproxy` | defaults (`/usr/bin/killall -0 haproxy` при наличии psmisc) |
| `keepalived_check_interval` / `_weight` / `_fall` / `_rise` | `2` / `-60` / `2` / `2` | group_vars |
| `haproxy_check_inter` / `_fall` / `_rise` | `3s` / `3` / `2` | defaults |
| `haproxy_replicas_check_uri` | `/replica` | например `/replica?lag=16MB` |
| `haproxy_stats_user` | `admin` | defaults |

### pgBackRest (`roles/pgbackrest/defaults`)

| Переменная | По умолчанию |
|---|---|
| `pgbackrest_s3_endpoint` / `_bucket` / `_region` / `_uri_style` | `s3.example.local` / `pgbackrest` / `us-east-1` / `path` |
| `pgbackrest_s3_verify_tls` / `pgbackrest_s3_ca_file` | `true` / `""` |
| `pgbackrest_repo_path` | `/{{ patroni_scope }}` |
| `pgbackrest_retention_full` / `_diff` | `2` / `7` |
| `pgbackrest_schedule_full` / `_diff` | `Sun 01:00` / `Mon..Sat 01:00` (systemd timers, только на лидере) |

## Assert'ы (preflight)

Выполняются при каждом запуске (теги `always`, `preflight`):

- ОС — RHEL 9 или RHEL 10;
- в группе `etcd` нечётное число узлов;
- в группе `postgres` не меньше 2 узлов;
- в группе `haproxy` ровно 2 узла;
- ровно один `keepalived_state: MASTER`;
- `priority(MASTER) + keepalived_check_weight < priority(BACKUP)`, иначе VIP не переедет;
- `virtual_router_id` в диапазоне 1..255;
- все секреты заданы и не равны `CHANGE_ME`, `auth_pass` не длиннее 8 символов;
- VIP — свободный IPv4-адрес;
- группы соответствуют `etcd_colocated`;
- `patroni_bootstrap_leader` входит в группу `postgres`.

## Порядок запуска

Полное развёртывание:

```bash
ansible-playbook playbooks/site.yml --ask-vault-pass
```

Порядок внутри `site.yml`:

1. preflight
2. pg_repos (etcd, postgres)
3. etcd
4. postgresql
5. patroni (`serial: 1`)
6. keepalived + haproxy (`serial: 1`)
7. pgbackrest

Patroni раскатывается так:

- **Первичный bootstrap.** Первым идёт `patroni_bootstrap_leader`. Каждый следующий узел стартует
  только после того, как предыдущий ответил `/health = 200`.
- **Работающий кластер.** Сначала реплики, текущий лидер последним. Если нужен рестарт Patroni,
  на лидере перед ним выполняется `switchover` на реплику.

**Поэтапно** (пока в зеркале есть только репозиторий 18):

```bash
# 1. Репозитории и пакеты PostgreSQL — доступно сразу
ansible-playbook playbooks/site.yml --tags pg_repos,postgresql

# 2. После появления postgres-extras (etcd) — включить его в pg_repos_list
ansible-playbook playbooks/site.yml --tags pg_repos,etcd

# 3. После появления postgres-common (patroni) — включить его в pg_repos_list
ansible-playbook playbooks/site.yml --tags pg_repos,patroni

# 4. VIP и балансировка (AppStream, зеркало не нужно)
ansible-playbook playbooks/haproxy.yml

# 5. Опционально (pgbackrest_enabled / pgbouncer_enabled: true)
ansible-playbook playbooks/site.yml --tags pgbouncer
ansible-playbook playbooks/pgbackrest.yml
```

| Тег | Что делает |
|---|---|
| `preflight` | assert'ы + доступность `repomd.xml` |
| `pg_repos` | `postgres-local.repo`, module disable |
| `etcd`, `etcd_auth` | etcd целиком / только RBAC |
| `postgresql` | пакеты и каталоги |
| `patroni` | Patroni |
| `dcs_config` | изменение DCS через `patronictl edit-config` (запускается только явно) |
| `haproxy`, `keepalived` | балансировщик / VIP |
| `pgbouncer`, `pgbackrest` | опциональные компоненты |

Поддерживаются `--check` и `--diff`. У шаблонов с секретами diff скрыт через `no_log`.
При первом запуске в `--check` сертификатов ещё нет, поэтому шаги их копирования пропускаются.

## Изменение конфигурации DCS после bootstrap

`bootstrap.dcs` применяется только при инициализации кластера. Для последующих изменений:

1. Задайте изменения в `patroni_dcs_overrides` (`group_vars/postgres.yml`):

   ```yaml
   patroni_dcs_overrides:
     postgresql:
       parameters:
         max_connections: 500
   ```

2. Примените их:

   ```bash
   ansible-playbook playbooks/patroni.yml --tags dcs_config
   # с перезапуском узлов, где изменились параметры, требующие рестарта:
   ansible-playbook playbooks/patroni.yml --tags dcs_config -e patroni_dcs_restart_pending=true
   ```

Playbook сравнивает `patronictl show-config` с желаемой конфигурацией. Если есть разница,
он применяет её через `patronictl edit-config --apply - --force`.

## Проверка

```bash
# Patroni: роли узлов, sync standby, lag
sudo -iu postgres patronictl list          # на любом узле postgres (PATRONICTL_CONFIG_FILE задан)

# etcd: здоровье и члены кластера
source /etc/profile.d/etcdctl.sh
etcdctl endpoint health
etcdctl --user root member list -w table   # спросит пароль root

# VIP: должен быть только на MASTER
ip -brief a show | grep 10.10.10.100       # на haproxy01 / haproxy02

# HAProxy: запись и чтение через VIP
psql "host=10.10.10.100 port=5000 user=postgres" -c 'select pg_is_in_recovery()'   # f
psql "host=10.10.10.100 port=5001 user=postgres" -c 'select pg_is_in_recovery()'   # t

# Статистика HAProxy: http://10.10.10.100:7000/ (admin / vault_haproxy_stats_password)
```

## Тест переключения VIP

```bash
# 1. На haproxy01 (MASTER) — VIP на месте
ip a | grep 10.10.10.100
# 2. Остановить haproxy на MASTER
sudo systemctl stop haproxy
# 3. Через ~(interval × fall) = 4 с приоритет MASTER падает на 60 (150 → 90 < 100),
#    VIP переезжает на haproxy02
journalctl -u keepalived -n 20        # на обоих узлах
ip a | grep 10.10.10.100              # на haproxy02 — VIP есть
psql "host=10.10.10.100 port=5000 user=postgres" -c 'select 1'
# 4. Вернуть haproxy — VIP вернётся на haproxy01 (preempt)
sudo systemctl start haproxy
```

## Процедура switchover

```bash
sudo -iu postgres patronictl list
# Плановое переключение на выбранную синхронную реплику:
sudo -iu postgres patronictl switchover pg18-ipoteka-cluster --leader pg01 --candidate pg02
# Отложенное:
sudo -iu postgres patronictl switchover pg18-ipoteka-cluster --leader pg01 --candidate pg02 --scheduled "2026-10-01T02:00"
sudo -iu postgres patronictl list     # pg02 — Leader, pg01 — Sync Standby/Replica
```

HAProxy переключит трафик на порту 5000 сам (`on-marked-down shutdown-sessions` рвёт старые сессии).
Аварийный failover без живого лидера: `patronictl failover --candidate pg02`.

## Важные замечания

- **io_method.** `io_uring` включается, только если **все** узлы поддерживают его: `postgres` слинкован
  с liburing и `kernel.io_uring_disabled = 0`. В RHEL 9/10 io_uring по умолчанию запрещён ядром.
  Это настройка hardening, и проект её не меняет, поэтому обычно действует fallback `worker`
  с предупреждением в выводе.
- **vm.overcommit_memory = 2.** Лимит памяти равен `swap + RAM × overcommit_ratio%`.
  Проверьте, что shared_buffers и память процессов в него укладываются.
  При `etcd_colocated: true` учитывайте, что etcd (Go) резервирует много виртуальной памяти.
- **Watchdog.** По умолчанию `automatic`. Для строгого режима (лидер без watchdog не поднимется)
  выставьте `patroni_watchdog_mode: required`, предварительно проверив `ls -l /dev/watchdog`
  (владелец должен быть postgres).
- **SELinux** не отключается.
  - Метки портов ставятся, если SELinux включён: 8008, 2379, 2380, 5000, 5001, 7000 → `http_port_t`.
    Тип меняется в `*_selinux_ports`.
  - `haproxy_connect_any=on` позволяет HAProxy подключаться к 5432/6432/8008.
  - Patroni/PostgreSQL и etcd работают в `unconfined_service_t`, поэтому нестандартные пути данных
    не требуют fcontext.
- **etcd.**
  - Первый старт выполняется на всех узлах параллельно. Рестарты по изменению конфигурации идут
    по одному узлу, чтобы не терять кворум.
  - Смена пароля пользователя `patroni` применяется автоматически.
  - Смену пароля `root` делайте вручную: `etcdctl --user root user passwd root`.
    Потом обновите vault.
  - Добавление или замена члена кластера — ручная процедура (`etcdctl member add`,
    `etcd_initial_cluster_state: existing`).
- **Patroni** запускается с `Restart=no` (рекомендация Patroni). Рестарт юнита на лидере предваряется switchover.

## Проверка качества

```bash
ansible-lint                       # profile: production
ansible-playbook playbooks/site.yml --syntax-check
ansible-playbook playbooks/site.yml --check --diff
```
