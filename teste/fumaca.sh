#!/bin/bash
# Teste de fumaça de ponta a ponta das imagens (roda no GitHub Actions; precisa de Docker).
#   WP_IMAGE=wordpress-railway:teste DB_IMAGE=mariadb-railway:teste bash teste/fumaca.sh
# Cenário: MariaDB com BANCOS; um WordPress de verdade (wp-cli dentro da imagem) faz o papel do site antigo;
# dump + tar no formato do pacote servidos por HTTP com Basic Auth; um segundo WordPress com volume vazio se
# restaura sozinho pelas variáveis RESTAURAR_* e depois passa pelos casos de reinício, versão nova, sha256 errado,
# importação interrompida, banco fora do ar, sha256 novo com a mesma versão, importação que falha no meio (o banco
# anterior volta) e volume ausente ou no lugar errado. Os sites restaurados rodam com PORT=8080, como na Railway.
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
mkdir -p "$PACOTE/v1" "$PACOTE/v2" "$PACOTE/v3" "$PACOTE/v4"

senha() { openssl rand -hex 16; }
ROOTPW="$(senha)"; PW_ORIGEM="$(senha)"; PW_TESTE="$(senha)"; PW_EXTRA="$(senha)"; SRVPW="$(senha)"

passo() { echo; echo "=== $*"; }
ok() { echo "  OK: $*"; }
falha() { echo "  FALHOU: $*" >&2; exit 1; }   # stderr: aparece mesmo dentro de $(...)

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
passo "Pacote v3 (título 'Site Teste Tres' + arquivo novo; usado com a MESMA versão 2 e sha256 novo)"
wpcli option update blogname "Site Teste Tres" >/dev/null
docker exec -u www-data "$ID-origem" sh -c 'echo v3 > /var/www/html/versao3.txt'
empacotar v3
passo "Pacote v4 (arquivos do v3; dump com título 'Site Teste Quatro' e um comando inválido no meio)"
cp "$PACOTE/v3/site-arquivos.tar.gz" "$PACOTE/v4/"
linhas="$(gzip -dc "$PACOTE/v3/site-banco.sql.gz" | wc -l)"
gzip -dc "$PACOTE/v3/site-banco.sql.gz" | sed 's/Site Teste Tres/Site Teste Quatro/g' \
  | awk -v meio="$(( linhas / 2 ))" 'NR >= meio && !feito && /^DROP TABLE IF EXISTS/ { print "INSERT INTO wpr_tabela_que_nao_existe VALUES (1);"; feito = 1 } { print }' \
  | gzip -6 > "$PACOTE/v4/site-banco.sql.gz"
[ "$(gzip -dc "$PACOTE/v4/site-banco.sql.gz" | grep -c wpr_tabela_que_nao_existe)" = 1 ] || falha "dump v4 sem o comando inválido"
case "$(gzip -dc "$PACOTE/v4/site-banco.sql.gz" | tail -n 1)" in "-- Dump completed"*) ;; *) falha "dump v4 sem '-- Dump completed'" ;; esac
echo "texto neutro para testar alcance" > "$PACOTE/teste.txt"
chmod -R a+rX "$TRAB"
SHA2_ARQ="$(grep site-arquivos "$PACOTE/v2/SHA256SUMS" | cut -d' ' -f1)"
SHA2_BANCO="$(grep site-banco "$PACOTE/v2/SHA256SUMS" | cut -d' ' -f1)"
SHA3_ARQ="$(grep site-arquivos "$PACOTE/v3/SHA256SUMS" | cut -d' ' -f1)"
SHA3_BANCO="$(grep site-banco "$PACOTE/v3/SHA256SUMS" | cut -d' ' -f1)"

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
restaurador() { # NOME VERSAO URL_BASE [opções extras do docker run...]  (PORT=8080: a Railway injeta essa porta)
  local n="$1" v="$2" u="$3"; shift 3
  docker rm -f "$ID-$n" >/dev/null 2>&1 || true
  docker run -d --name "$ID-$n" --network "$NET" -e PORT=8080 \
    -e WORDPRESS_DB_HOST=db:3306 -e WORDPRESS_DB_NAME=teste -e WORDPRESS_DB_USER=teste -e WORDPRESS_DB_PASSWORD="$PW_TESTE" \
    -e CAMINHO_ANTIGO="$OLD" -e SITE_DOMAIN="$HOST" -e PHP_AUTO_PREPEND_FILE=/var/www/html/wordfence-waf.php \
    -e RESTAURAR_AUTH="pacote:$SRVPW" -e RESTAURAR_ARQUIVOS_URL="$u/site-arquivos.tar.gz" \
    -e RESTAURAR_BANCO_URL="$u/site-banco.sql.gz" -e RESTAURAR_VERSAO="$v" "$@" "$WP" >/dev/null
}
destino() { # VERSAO URL_BASE [opções extras do docker run...]
  local v="$1" u="$2"; shift 2
  restaurador destino "$v" "$u" -v "$ID-destino":/var/www "$@"
}
esperar_saida() { # NOME -> imprime o código de saída (falha se não parar em 4 min)
  local i
  for i in $(seq 1 120); do
    [ "$(docker inspect -f '{{.State.Status}}' "$ID-$1")" = exited ] && break
    sleep 2
  done
  [ "$(docker inspect -f '{{.State.Status}}' "$ID-$1")" = exited ] || falha "o contêiner $1 deveria ter parado com erro"
  docker inspect -f '{{.State.ExitCode}}' "$ID-$1"
}
# volume do destino visto de fora, logo depois de uma falha (antes de qualquer boot novo, que limparia sobras)
volume_destino() { docker run --rm -v "$ID-destino":/v --entrypoint sh "$WP" -c "$1"; }
dx() { docker exec "$ID-destino" "$@"; }
codigo() { docker exec "$ID-destino" curl -s -o /dev/null -w '%{http_code}' -H "Host: $HOST" -H 'X-Forwarded-Proto: https' "http://127.0.0.1:${1:-80}/" 2>/dev/null || true; }
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
# portas: com PORT=8080 (Railway) o Apache atende na 80 E na 8080
[ "$(codigo 8080)" = 200 ] || falha "com PORT=8080 a porta 8080 não respondeu 200"
[ "$(codigo 80)" = 200 ] || falha "com PORT=8080 a porta 80 deixou de responder"
grep -q 'portas 80 e 8080' <<<"$l" || falha "log sem 'portas 80 e 8080'"
ok "PORT=8080: o Apache atende na 80 e na 8080"
# o PHP não enxerga as RESTAURAR_* (URL e senha da pasta de download), mas enxerga o resto do ambiente
docker exec -i "$ID-destino" sh -c 'cat > /var/www/html/wpr-env-teste.php' <<'PHP'
<?php
$vazou = array();
foreach (array('RESTAURAR_AUTH', 'RESTAURAR_ARQUIVOS_URL', 'RESTAURAR_BANCO_URL', 'RESTAURAR_VERSAO') as $v) {
  if (getenv($v) !== false || isset($_SERVER[$v]) || isset($_ENV[$v])) { $vazou[] = $v; }
}
if (getenv('WORDPRESS_DB_NAME') === false) { echo 'sem-ambiente'; } else { echo $vazou ? 'vazou: ' . implode(' ', $vazou) : 'limpo'; }
PHP
r="$(docker exec "$ID-destino" curl -s -H "Host: $HOST" -H 'X-Forwarded-Proto: https' http://127.0.0.1/wpr-env-teste.php || true)"
dx rm -f /var/www/html/wpr-env-teste.php
[ "$r" = limpo ] || falha "o PHP deveria ver WORDPRESS_DB_NAME e não ver RESTAURAR_* (veio: '$r')"
[ "$(dx sh -c "tr '\\0' '\\n' < /proc/1/environ | grep -c '^RESTAURAR_'" || true)" = 0 ] || falha "RESTAURAR_* no ambiente do Apache (PID 1)"
grep -q 'variáveis RESTAURAR_\* retiradas' <<<"$l" || falha "log sem 'variáveis RESTAURAR_* retiradas'"
ok "o PHP e o Apache não veem as RESTAURAR_*"
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
rc="$(esperar_saida destino)"
[ "$rc" != 0 ] || falha "o contêiner saiu com código 0"
grep -q "sha256 diferente do informado" <<<"$(logs)" || falha "log sem o motivo (sha256)"
mostrar_log
if [ -n "$(volume_destino 'ls -d /v/.wpr-tmp-* 2>/dev/null' || true)" ]; then falha "a tentativa com sha256 errado deixou temporários no volume"; fi
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

passo "8. Mesma RESTAURAR_VERSAO (2) com sha256 novo (pacote v3): sem SOBRESCREVER avisa; com SOBRESCREVER substitui"
destino 2 "http://arquivos:8000/v3" -e RESTAURAR_ARQUIVOS_SHA256="$SHA3_ARQ" -e RESTAURAR_BANCO_SHA256="$SHA3_BANCO"
esperar_site
t="$(titulo)"; [ "$t" = "Site Teste Dois" ] || falha "sem SOBRESCREVER o título mudou para '$t'"
[ "$(baixados v3)" = 0 ] || falha "baixou o v3 sem RESTAURAR_SOBRESCREVER"
[ "$(grep -c 'NÃO sobrescrito' <<<"$(logs)")" = 2 ] || falha "log sem os 2 avisos de 'NÃO sobrescrito'"
[ "$(grep -c 'sha256 informado' <<<"$(logs)")" = 2 ] || falha "log sem o motivo (sha256 informado diferente do restaurado)"
ok "sem SOBRESCREVER: o pedido novo é avisado e nada muda"
destino 2 "http://arquivos:8000/v3" -e RESTAURAR_SOBRESCREVER=sim \
  -e RESTAURAR_ARQUIVOS_SHA256="$SHA3_ARQ" -e RESTAURAR_BANCO_SHA256="$SHA3_BANCO"
esperar_site
t="$(titulo)"; [ "$t" = "Site Teste Tres" ] || falha "título '$t' (esperado 'Site Teste Tres')"
[ "$(blogname)" = "Site Teste Tres" ] || falha "o banco não foi substituído pelo v3"
[ "$(dx cat /var/www/html/versao3.txt)" = v3 ] || falha "arquivo novo do v3 ausente"
[ "$(marca arquivos)" = 2 ] && [ "$(marca banco)" = 2 ] || falha "marcadores deveriam continuar '2'"
[ "$(dx sed -n '3s/^sha256 //p' /var/www/.wpr-restauracao/arquivos)" = "$SHA3_ARQ" ] || falha "marcador de arquivos sem o sha256 do v3"
[ "$(dx sed -n '3s/^sha256 //p' /var/www/.wpr-restauracao/banco)" = "$SHA3_BANCO" ] || falha "marcador do banco sem o sha256 do v3"
grep -q 'guardando cópia do banco atual' <<<"$(logs)" || falha "log sem a cópia do banco antes de substituir"
if dx test -e /var/www/.wpr-restauracao/banco-anterior.sql.gz; then falha "a cópia do banco anterior ficou depois do sucesso"; fi
ok "com SOBRESCREVER=sim: v3 no ar com a mesma versão '2'"
antes="$(baixados v3)"
destino 2 "http://arquivos:8000/v3" -e RESTAURAR_SOBRESCREVER=sim \
  -e RESTAURAR_ARQUIVOS_SHA256="$SHA3_ARQ" -e RESTAURAR_BANCO_SHA256="$SHA3_BANCO"
esperar_site
[ "$(baixados v3)" = "$antes" ] || falha "baixou de novo um pacote já restaurado"
[ "$(grep -c 'RESTAURAR_SOBRESCREVER=sim ignorado' <<<"$(logs)")" = 2 ] || falha "log sem os 2 avisos de SOBRESCREVER ignorado"
ok "mesmo pedido com SOBRESCREVER=sim: nada baixado e aviso de 'ignorado'"

passo "9. Importação que falha no meio (dump v4 inválido) com SOBRESCREVER=sim: o banco anterior volta"
dx touch /var/www/html/sentinela9.txt
n_tab() { db_sql teste "$PW_TESTE" "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='teste'"; }
nt_antes="$(n_tab)"
destino 4 "http://arquivos:8000/v4" -e RESTAURAR_SOBRESCREVER=sim
rc="$(esperar_saida destino)"
[ "$rc" != 0 ] || falha "o contêiner saiu com código 0"
mostrar_log
grep -q 'devolvendo o banco anterior' <<<"$(logs)" || falha "log sem 'devolvendo o banco anterior'"
grep -q 'o banco anterior foi devolvido' <<<"$(logs)" || falha "log sem 'o banco anterior foi devolvido'"
[ "$(blogname)" = "Site Teste Tres" ] || falha "o banco não voltou ao v3 (blogname '$(blogname)')"
[ "$(n_tab)" = "$nt_antes" ] || falha "número de tabelas mudou ($nt_antes -> $(n_tab))"
v="$(volume_destino 'ls -A /v /v/.wpr-restauracao' || true)"
if grep -qE 'wpr-tmp-|banco-anterior|em-andamento' <<<"$v"; then falha "sobras no volume depois da falha: $(tr '\n' ' ' <<<"$v")"; fi
destino 2 "http://arquivos:8000/v3"
esperar_site
t="$(titulo)"; [ "$t" = "Site Teste Tres" ] || falha "o site mudou depois da falha (título '$t')"
dx test -f /var/www/html/sentinela9.txt || falha "os arquivos foram trocados apesar da falha no banco"
[ "$(marca arquivos)" = 2 ] && [ "$(marca banco)" = 2 ] || falha "marcadores mudaram depois da falha"
ok "saiu com código $rc; banco v3 devolvido ($nt_antes tabelas), arquivos e marcadores intactos, sem sobras"

passo "10. Sem volume, ou volume montado em /var/www/html: recusa restaurar"
antes="$(baixados v1)"
restaurador semvol 1 "http://arquivos:8000/v1"
rc="$(esperar_saida semvol)"
[ "$rc" != 0 ] || falha "sem volume o contêiner saiu com código 0"
docker logs "$ID-semvol" 2>&1 | grep -q '/var/www não é um volume' || falha "sem volume: log sem o motivo"
docker volume create "$ID-volhtml" >/dev/null
restaurador volhtml 1 "http://arquivos:8000/v1" -v "$ID-volhtml":/var/www/html
rc2="$(esperar_saida volhtml)"
[ "$rc2" != 0 ] || falha "com volume em /var/www/html o contêiner saiu com código 0"
docker logs "$ID-volhtml" 2>&1 | grep -q 'montado em /var/www/html' || falha "volume em /var/www/html: log sem o motivo"
[ "$(baixados v1)" = "$antes" ] || falha "baixou o pacote mesmo sem volume"
docker logs "$ID-semvol" 2>&1 | grep -E '^\[(restaurar|entrypoint)\]' | sed 's/^/    /' || true
docker logs "$ID-volhtml" 2>&1 | grep -E '^\[(restaurar|entrypoint)\]' | sed 's/^/    /' || true
ok "recusou nos dois casos (códigos $rc e $rc2), sem baixar nada"

echo
echo "TESTE DE FUMAÇA: TUDO OK ($WP + $DB)"
