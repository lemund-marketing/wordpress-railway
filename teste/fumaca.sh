#!/bin/bash
# Teste de fumaça de ponta a ponta das imagens (roda no GitHub Actions; precisa de Docker).
#   WP_IMAGE=wordpress-railway:teste DB_IMAGE=mariadb-railway:teste bash teste/fumaca.sh
# Cenário: MariaDB com BANCOS; um WordPress de verdade (wp-cli dentro da imagem) faz o papel do site antigo;
# dump + tar no formato do pacote servidos por HTTP com Basic Auth; um segundo WordPress com volume vazio se
# restaura sozinho pelas variáveis RESTAURAR_* e depois passa pelos casos de reinício, versão nova e sha256 errado.
set -euo pipefail
WP="${WP_IMAGE:?defina WP_IMAGE}"
DB="${DB_IMAGE:?defina DB_IMAGE}"
DIR="$(cd "$(dirname "$0")" && pwd)"
ID="wprt$$"
NET="$ID-rede"
HOST=site-um.exemplo.test
OLD=/home/usuario-antigo/domains/site-um.exemplo.test/public_html
TRAB="$(mktemp -d)"
PACOTE="$TRAB/pacote"
mkdir -p "$PACOTE/v1" "$PACOTE/v2"

senha() { openssl rand -hex 16; }
ROOTPW="$(senha)"; PW_ORIGEM="$(senha)"; PW_TESTE="$(senha)"; PW_EXTRA="$(senha)"; SRVPW="$(senha)"

passo() { echo; echo "=== $*"; }
ok() { echo "  OK: $*"; }
falha() { echo "  FALHOU: $*"; exit 1; }

fim() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    for c in $(docker ps -a --filter "name=^${ID}-" --format '{{.Names}}'); do
      echo "----- logs de $c (últimas 150 linhas)"; docker logs --tail 150 "$c" 2>&1 || true
    done
  fi
  docker ps -a -q --filter "name=^${ID}-" | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker volume ls -q --filter "name=^${ID}-" | xargs -r docker volume rm >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$TRAB"
  exit "$rc"
}
trap fim EXIT

docker network create "$NET" >/dev/null

# ------------------------------------------------------------------------------------------- MariaDB
db_run() { # BANCOS
  docker run -d --name "$ID-db" --network "$NET" --network-alias db -v "$ID-db":/var/lib/mysql \
    -e MARIADB_ROOT_PASSWORD="$ROOTPW" -e DB_ORIGEM_PASSWORD="$PW_ORIGEM" -e DB_TESTE_PASSWORD="$PW_TESTE" \
    -e DB_EXTRA_PASSWORD="$PW_EXTRA" -e BANCOS="$1" "$DB" >/dev/null
}
db_login() { # usuario senha (pela rede: só o servidor definitivo atende)
  docker exec -e MYSQL_PWD="$2" "$ID-db" mariadb --protocol=tcp -h 127.0.0.1 -u "$1" -N -B -e 'SELECT 1' "$1" >/dev/null 2>&1
}
esperar_login() { # usuario senha segundos
  local i
  for i in $(seq 1 "$3"); do db_login "$1" "$2" && return 0; sleep 1; done
  return 1
}
db_sql() { # usuario senha sql
  docker exec -e MYSQL_PWD="$2" "$ID-db" mariadb --protocol=tcp -h 127.0.0.1 -u "$1" -N -B -e "$3" "$1"
}

passo "MariaDB: 1º boot com BANCOS='origem teste'"
docker volume create "$ID-db" >/dev/null
db_run "origem teste"
esperar_login teste "$PW_TESTE" 180 || falha "o usuário teste não conectou no banco teste"
esperar_login origem "$PW_ORIGEM" 20 || falha "o usuário origem não conectou no banco origem"
docker exec "$ID-db" test -d /var/lib/mysql/data/mysql || falha "os dados não estão em /var/lib/mysql/data"
ok "bancos origem e teste criados no 1º boot; dados em /var/lib/mysql/data"

passo "MariaDB: banco acrescentado em BANCOS depois do 1º boot (conferido a cada boot)"
docker rm -f "$ID-db" >/dev/null
db_run "origem teste extra"
esperar_login extra "$PW_EXTRA" 180 || falha "o banco/usuário extra não foi criado no boot seguinte"
esperar_login teste "$PW_TESTE" 20 || falha "o usuário teste parou de conectar"
ok "banco extra criado no 2º boot; os anteriores seguem"
docker logs "$ID-db" 2>&1 | grep -E '\[bancos\]|bancos prontos' | sed 's/^/    /' || true

# ------------------------------------------------------------------------------- site de origem
passo "Site de origem: WordPress de verdade criado com o wp-cli da imagem (sem RESTAURAR_*)"
docker volume create "$ID-origem" >/dev/null
docker run -d --name "$ID-origem" --network "$NET" -v "$ID-origem":/var/www "$WP" >/dev/null
for i in $(seq 1 60); do
  c="$(docker exec "$ID-origem" curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/ 2>/dev/null || true)"
  [ -n "$c" ] && [ "$c" != 000 ] && break
  sleep 1
done
wpcli() { docker exec -u www-data -e WP_CLI_CACHE_DIR=/tmp/wp-cli-cache -w /var/www/html "$ID-origem" wp "$@"; }
wpcli core download --quiet
wpcli config create --dbname=origem --dbuser=origem --dbpass="$PW_ORIGEM" --dbhost=db:3306 --skip-check --quiet
wpcli core install --url="https://$HOST" --title="Site Teste Um" --admin_user=admin --admin_password="$(senha)" \
  --admin_email=admin@exemplo.test --skip-email
docker exec -i "$ID-origem" bash -s -- "$OLD" <<'EOF'
set -euo pipefail
OLD="$1"; cd /var/www/html
mkdir -p wp-content/uploads
echo "arquivo enviado" > wp-content/uploads/teste.txt
ln -s "$OLD/wp-content/uploads" atalho-uploads
printf '<?php header("X-Teste-Prepend: 1");\n' > wordfence-waf.php
cat > .htaccess <<HT
# BEGIN teste (bloco que só o LiteSpeed lê)
<IfModule LiteSpeed>
php_value auto_prepend_file '$OLD/wordfence-waf.php'
</IfModule>
# END teste
# BEGIN WordPress
<IfModule mod_rewrite.c>
RewriteEngine On
RewriteBase /
RewriteRule ^index\.php$ - [L]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule . /index.php [L]
</IfModule>
# END WordPress
HT
mkdir -p /var/www/privado-fora
echo "fora do docroot" > /var/www/privado-fora/nota.txt
chown -R www-data:www-data /var/www/html /var/www/privado-fora
EOF
t="$(docker exec "$ID-origem" curl -s -H "Host: $HOST" -H 'X-Forwarded-Proto: https' http://127.0.0.1/ | grep -o '<title>[^<]*' | sed -n '1s/<title>//p' || true)"
[ "$t" = "Site Teste Um" ] || falha "a origem não respondeu com o título esperado (veio: '$t')"
if docker logs "$ID-origem" 2>&1 | grep -q '\[restaurar\]'; then falha "sem RESTAURAR_* o entrypoint não deveria restaurar"; fi
ok "origem no ar com o título 'Site Teste Um'; sem RESTAURAR_* nada foi restaurado"

empacotar() { # versão
  local d="$PACOTE/$1"
  docker exec "$ID-origem" tar -C /var/www -czf - html privado-fora > "$d/site-arquivos.tar.gz"
  docker exec -e MYSQL_PWD="$ROOTPW" "$ID-db" mariadb-dump -uroot --single-transaction --quick --routines --triggers \
    --hex-blob --default-character-set=utf8mb4 --no-tablespaces --max-allowed-packet=1G --add-drop-table origem \
    | gzip -6 > "$d/site-banco.sql.gz"
  local ultima; ultima="$(gzip -dc "$d/site-banco.sql.gz" | tail -n 1)"
  case "$ultima" in "-- Dump completed"*) ;; *) falha "dump sem a linha final '-- Dump completed'" ;; esac
  (cd "$d" && sha256sum site-arquivos.tar.gz site-banco.sql.gz > SHA256SUMS)
  echo "  pacote $1: $(du -h "$d/site-arquivos.tar.gz" | cut -f1) de arquivos, $(du -h "$d/site-banco.sql.gz" | cut -f1) de banco"
}
passo "Pacote v1 (tar com html/ + pasta irmã; dump do mariadb-dump)"
empacotar v1
passo "Pacote v2 (título 'Site Teste Dois' + arquivo novo)"
wpcli option update blogname "Site Teste Dois" >/dev/null
docker exec -u www-data "$ID-origem" sh -c 'echo v2 > /var/www/html/versao2.txt'
empacotar v2
echo "texto neutro para testar alcance" > "$PACOTE/teste.txt"
chmod -R a+rX "$TRAB"
SHA2_ARQ="$(grep site-arquivos "$PACOTE/v2/SHA256SUMS" | cut -d' ' -f1)"
SHA2_BANCO="$(grep site-banco "$PACOTE/v2/SHA256SUMS" | cut -d' ' -f1)"

passo "Servidor HTTP local com Basic Auth"
docker run -d --name "$ID-arquivos" --network "$NET" --network-alias arquivos -e AUTH_USER=pacote -e AUTH_PASS="$SRVPW" \
  -v "$PACOTE":/srv:ro -v "$DIR/servidor.py":/servidor.py:ro python:3.12-alpine python -u /servidor.py >/dev/null
for i in $(seq 1 30); do
  c="$(docker exec "$ID-origem" curl -s -o /dev/null -w '%{http_code}' http://arquivos:8000/teste.txt 2>/dev/null || true)"
  [ "$c" = 401 ] && break
  sleep 1
done
[ "$c" = 401 ] || falha "sem senha o servidor deveria responder 401 (veio $c)"
c="$(docker exec "$ID-origem" curl -s -o /dev/null -w '%{http_code}' -u "pacote:$SRVPW" http://arquivos:8000/teste.txt)"
[ "$c" = 200 ] || falha "com senha o servidor deveria responder 200 (veio $c)"
ok "401 sem senha, 200 com senha"
baixados() { docker logs "$ID-arquivos" 2>&1 | grep -c "\"GET /$1/site-arquivos.tar.gz HTTP/1.1\" 200" || true; }

# ------------------------------------------------------------------------------- site restaurado
docker volume create "$ID-destino" >/dev/null
destino() { # VERSAO URL_BASE [opções extras do docker run...]
  local v="$1" u="$2"; shift 2
  docker rm -f "$ID-destino" >/dev/null 2>&1 || true
  docker run -d --name "$ID-destino" --network "$NET" -v "$ID-destino":/var/www \
    -e WORDPRESS_DB_HOST=db:3306 -e WORDPRESS_DB_NAME=teste -e WORDPRESS_DB_USER=teste -e WORDPRESS_DB_PASSWORD="$PW_TESTE" \
    -e CAMINHO_ANTIGO="$OLD" -e SITE_DOMAIN="$HOST" -e PHP_AUTO_PREPEND_FILE=/var/www/html/wordfence-waf.php \
    -e RESTAURAR_AUTH="pacote:$SRVPW" -e RESTAURAR_ARQUIVOS_URL="$u/site-arquivos.tar.gz" \
    -e RESTAURAR_BANCO_URL="$u/site-banco.sql.gz" -e RESTAURAR_VERSAO="$v" "$@" "$WP" >/dev/null
}
dx() { docker exec "$ID-destino" "$@"; }
codigo() { docker exec "$ID-destino" curl -s -o /dev/null -w '%{http_code}' -H "Host: $HOST" -H 'X-Forwarded-Proto: https' http://127.0.0.1/ 2>/dev/null || true; }
esperar_site() {
  local i st
  for i in $(seq 1 150); do
    st="$(docker inspect -f '{{.State.Status}}' "$ID-destino")"
    [ "$st" = running ] || falha "o contêiner parou ($st, código de saída $(docker inspect -f '{{.State.ExitCode}}' "$ID-destino"))"
    [ "$(codigo)" = 200 ] && return 0
    sleep 2
  done
  falha "a home não respondeu 200 em 5 min"
}
pagina() { docker exec "$ID-destino" curl -s -D - -H "Host: ${1:-$HOST}" -H 'X-Forwarded-Proto: https' http://127.0.0.1/; }
titulo() { local p; p="$(pagina || true)"; printf '%s' "$p" | grep -o '<title>[^<]*' | sed -n '1s/<title>//p' || true; }
marca() { dx sh -c "head -n 1 /var/www/.wpr-restauracao/$1 2>/dev/null" || true; }
logs() { docker logs "$ID-destino" 2>&1; }
blogname() { db_sql teste "$PW_TESTE" "SELECT option_value FROM wp_options WHERE option_name='blogname'"; }
mostrar_log() { # o que o dono do serviço vê no log da Railway
  echo "  --- log do contêiner (linhas da imagem):"
  logs | grep -E '^\[(restaurar|entrypoint|pos-copia|banco|mu-plugins|preview|bloqueios)\]' | sed 's/^/    /' || true
}

passo "1. Volume vazio + RESTAURAR_* (versão 1): restaura sozinho"
destino 1 "http://arquivos:8000/v1"
esperar_site
t="$(titulo)"; [ "$t" = "Site Teste Um" ] || falha "título '$t' (esperado 'Site Teste Um')"
ok "home 200 com o título 'Site Teste Um'"
[ "$(blogname)" = "Site Teste Um" ] || falha "o banco teste não recebeu o dump"
[ "$(marca arquivos)" = 1 ] && [ "$(marca banco)" = 1 ] || falha "marcadores da versão 1 ausentes"
dx grep -q "getenv( 'WORDPRESS_DB_PASSWORD' )" /var/www/html/wp-config.php || falha "wp-config não lê a senha do ambiente"
if dx grep -qF "$PW_ORIGEM" /var/www/html/wp-config.php; then falha "a senha antiga ficou no wp-config"; fi
[ "$(dx readlink /var/www/html/atalho-uploads)" = "wp-content/uploads" ] || falha "symlink absoluto não virou relativo"
dx grep -q "'/var/www/html/wordfence-waf.php'" /var/www/html/.htaccess || falha "caminho antigo não trocado no .htaccess"
if dx grep -qF "$OLD" /var/www/html/.htaccess; then falha "o caminho antigo ficou no .htaccess"; fi
[ "$(dx cat /var/www/privado-fora/nota.txt)" = "fora do docroot" ] || falha "a pasta irmã do docroot não foi restaurada"
[ "$(dx readlink "$OLD")" = "/var/www/html" ] || falha "atalho CAMINHO_ANTIGO -> /var/www/html ausente"
[ "$(dx stat -c %U /var/www/html/index.php)" = www-data ] || falha "dono dos arquivos não é www-data"
dx test -f /var/www/html/wp-content/mu-plugins/railway-preview.php || falha "mu-plugins da Railway não instalados"
if dx sh -c 'ls -d /var/www/.wpr-tmp-* >/dev/null 2>&1'; then falha "temporários não foram apagados"; fi
h="$(pagina)"; grep -qi '^x-teste-prepend: 1' <<<"$h" || falha "auto_prepend_file não ligado depois da restauração"
h="$(pagina teste-123.up.railway.app)"; grep -qi '^x-railway-preview: 1' <<<"$h" || falha "pré-visualização *.up.railway.app inativa"
l="$(logs)"
if grep -qF -e "$SRVPW" -e "$PW_TESTE" -e "$PW_ORIGEM" -e "/v1/" <<<"$l"; then falha "o log mostrou senha ou URL completa"; fi
ok "wp-config pelo ambiente, symlink relativo, .htaccess, pasta irmã, atalho antigo, dono, mu-plugins, auto_prepend, preview, marcadores, log sem segredo"
mostrar_log

passo "2. Reiniciar não restaura de novo"
dx touch /var/www/html/sentinela.txt
antes="$(baixados v1)"
docker restart "$ID-destino" >/dev/null
esperar_site
[ "$(baixados v1)" = "$antes" ] || falha "baixou o pacote de novo no reinício"
dx test -f /var/www/html/sentinela.txt || falha "o reinício substituiu os arquivos"
grep -q "arquivos: versão '1' já restaurada" <<<"$(logs)" || falha "log sem 'já restaurada'"
ok "nenhum download, sentinela intacta"

passo "3. Versão nova sem RESTAURAR_SOBRESCREVER: não toca"
destino 2 "http://arquivos:8000/v2"
esperar_site
t="$(titulo)"; [ "$t" = "Site Teste Um" ] || falha "título mudou para '$t'"
dx test -f /var/www/html/sentinela.txt || falha "arquivos substituídos sem RESTAURAR_SOBRESCREVER"
[ "$(baixados v2)" = 0 ] || falha "baixou a versão 2 sem precisar"
[ "$(marca arquivos)" = 1 ] && [ "$(marca banco)" = 1 ] || falha "marcadores mudaram"
[ "$(grep -c 'NÃO sobrescrito' <<<"$(logs)")" = 2 ] || falha "log sem os 2 avisos de 'NÃO sobrescrito'"
ok "conteúdo da versão 1 intacto e aviso no log"

passo "4. Versão nova com RESTAURAR_SOBRESCREVER=sim (e sha256 certos): substitui"
destino 2 "http://arquivos:8000/v2" -e RESTAURAR_SOBRESCREVER=sim \
  -e RESTAURAR_ARQUIVOS_SHA256="$SHA2_ARQ" -e RESTAURAR_BANCO_SHA256="$SHA2_BANCO"
esperar_site
t="$(titulo)"; [ "$t" = "Site Teste Dois" ] || falha "título '$t' (esperado 'Site Teste Dois')"
[ "$(blogname)" = "Site Teste Dois" ] || falha "o banco não foi substituído"
[ "$(dx cat /var/www/html/versao2.txt)" = v2 ] || falha "arquivo novo da versão 2 ausente"
if dx test -e /var/www/html/sentinela.txt; then falha "a sentinela deveria ter sumido com a troca de pasta"; fi
[ "$(marca arquivos)" = 2 ] && [ "$(marca banco)" = 2 ] || falha "marcadores da versão 2 ausentes"
[ "$(grep -c 'sha256 confere' <<<"$(logs)")" = 2 ] || falha "log sem as 2 conferências de sha256"
ok "conteúdo da versão 2 no ar"

passo "5. sha256 errado: falha sem estragar o site"
destino 3 "http://arquivos:8000/v1" -e RESTAURAR_SOBRESCREVER=sim -e RESTAURAR_ARQUIVOS_SHA256="$(printf '0%.0s' $(seq 64))"
for i in $(seq 1 120); do
  [ "$(docker inspect -f '{{.State.Status}}' "$ID-destino")" = exited ] && break
  sleep 2
done
[ "$(docker inspect -f '{{.State.Status}}' "$ID-destino")" = exited ] || falha "o contêiner deveria ter parado com erro"
rc="$(docker inspect -f '{{.State.ExitCode}}' "$ID-destino")"
[ "$rc" != 0 ] || falha "o contêiner saiu com código 0"
grep -q "sha256 diferente do informado" <<<"$(logs)" || falha "log sem o motivo (sha256)"
mostrar_log
[ "$(blogname)" = "Site Teste Dois" ] || falha "o banco foi alterado apesar do sha256 errado"
destino 2 "http://arquivos:8000/v2"
esperar_site
t="$(titulo)"; [ "$t" = "Site Teste Dois" ] || falha "o site mudou depois da falha (título '$t')"
[ "$(marca arquivos)" = 2 ] && [ "$(marca banco)" = 2 ] || falha "marcadores mudaram depois da falha"
dx test -f /var/www/html/versao2.txt || falha "arquivos alterados depois da falha"
if dx sh -c 'ls -d /var/www/.wpr-tmp-* >/dev/null 2>&1'; then falha "temporários da tentativa falha ficaram no volume"; fi
ok "saiu com código $rc, site e marcadores da versão 2 intactos"

passo "6. Importação do banco interrompida (marcador 'em andamento'): o boot seguinte refaz, mesmo sem SOBRESCREVER"
dx sh -c 'echo 2 > /var/www/.wpr-restauracao/banco.em-andamento'
dx touch /var/www/html/sentinela6.txt
antes="$(docker logs "$ID-arquivos" 2>&1 | grep -c '"GET /v2/site-banco.sql.gz HTTP/1.1" 200' || true)"
docker restart "$ID-destino" >/dev/null
esperar_site
depois="$(docker logs "$ID-arquivos" 2>&1 | grep -c '"GET /v2/site-banco.sql.gz HTTP/1.1" 200' || true)"
[ "$depois" -gt "$antes" ] || falha "o banco não foi baixado de novo"
grep -q "refazer a importação interrompida" <<<"$(logs)" || falha "log sem 'refazer a importação interrompida'"
if dx test -e /var/www/.wpr-restauracao/banco.em-andamento; then falha "marcador 'em andamento' não foi apagado"; fi
dx test -f /var/www/html/sentinela6.txt || falha "os arquivos não deveriam ter sido trocados"
[ "$(blogname)" = "Site Teste Dois" ] || falha "banco errado depois de refazer"
ok "banco reimportado, arquivos intactos"

passo "7. Banco fora do ar num boot comum (versão já restaurada): o site sobe mesmo assim"
docker stop "$ID-db" >/dev/null
docker restart "$ID-destino" >/dev/null
for i in $(seq 1 45); do
  grep -q "seguindo sem conferir" <<<"$(logs)" && [ "$(codigo)" != 000 ] && [ -n "$(codigo)" ] && break
  sleep 2
done
grep -q "seguindo sem conferir" <<<"$(logs)" || falha "o boot ficou preso esperando o banco"
[ "$(docker inspect -f '{{.State.Status}}' "$ID-destino")" = running ] || falha "o contêiner parou com o banco fora"
c="$(codigo)"; case "$c" in 000|000000|"") falha "o Apache não subiu com o banco fora" ;; esac
docker start "$ID-db" >/dev/null
esperar_login teste "$PW_TESTE" 120 || falha "o banco não voltou"
esperar_site
ok "Apache no ar com o banco fora (home $c) e de volta a 200 quando o banco voltou"

echo
echo "TESTE DE FUMAÇA: TUDO OK ($WP + $DB)"
