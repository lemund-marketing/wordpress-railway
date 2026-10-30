# wordpress-railway

Imagens Docker genéricas para rodar sites WordPress vindos de hospedagem compartilhada na [Railway](https://railway.com)
(ou em qualquer Docker), criando os serviços só pelo painel, sem SSH e sem CLI.

| Imagem | Para quê |
|---|---|
| `ghcr.io/lemund-marketing/wordpress-railway:php8.3` | WordPress com Apache + mod_php 8.3 (lê `.htaccess` como a hospedagem) |
| `ghcr.io/lemund-marketing/wordpress-railway:php8.2` | o mesmo, com PHP 8.2 |
| `ghcr.io/lemund-marketing/mariadb-railway:11.8` | MariaDB 11.8 que cria 1 banco + 1 usuário por site a partir das variáveis |

Cada publicação também ganha uma tag fixa com o commit (ex.: `php8.3-1a2b3c4`), para voltar a uma versão anterior.
As imagens só são publicadas depois de passar no [teste de fumaça](teste/fumaca.sh) de ponta a ponta.

> **Versão leiga:** um serviço de banco guarda os bancos de todos os sites; cada site é um serviço com um disco
> próprio (volume) onde ficam todos os arquivos. Na primeira vez que o site sobe com o disco vazio, ele baixa sozinho
> o backup (arquivos + banco) de um endereço protegido por senha e se instala. Depois disso, reiniciar não baixa nada
> de novo.

## Volumes

| Serviço | Montar o volume em | O que fica lá |
|---|---|---|
| MariaDB | `/var/lib/mysql` | dados em `/var/lib/mysql/data` (fora do `lost+found` do volume) |
| WordPress | `/var/www` | docroot em `/var/www/html`; pastas que ficavam ao lado do `public_html` ficam em `/var/www/<pasta>`; controle da restauração em `/var/www/.wpr-restauracao` |

## Variáveis do MariaDB

| Variável | Obrigatória | Para quê |
|---|---|---|
| `MARIADB_ROOT_PASSWORD` | sim | senha do root |
| `BANCOS` | sim | nomes dos bancos, separados por espaço (ex.: `site1 site2`). Cada banco `N` ganha o usuário `N` com acesso só a ele |
| `DB_<NOME>_PASSWORD` | sim, 1 por banco | senha do usuário de cada banco, com o nome em maiúsculas (ex.: `DB_SITE1_PASSWORD`) |

Os bancos são criados no 1º boot e conferidos a cada boot: um nome acrescentado depois em `BANCOS` é criado ao
reiniciar, e a senha de cada usuário acompanha a variável. O banco não precisa de porta pública: os sites falam com
ele pela rede privada (na Railway, `${{<serviço do banco>.RAILWAY_PRIVATE_DOMAIN}}:3306`).

## Variáveis do WordPress

| Variável | Obrigatória | Para quê |
|---|---|---|
| `WORDPRESS_DB_HOST` | sim | `host:porta` do MariaDB (na Railway: `${{mariadb.RAILWAY_PRIVATE_DOMAIN}}:3306`) |
| `WORDPRESS_DB_NAME`, `WORDPRESS_DB_USER` | sim | banco e usuário do site (iguais ao nome em `BANCOS`) |
| `WORDPRESS_DB_PASSWORD` | sim | senha (na Railway, referência: `${{mariadb.DB_SITE1_PASSWORD}}`) |
| `SITE_DOMAIN` | recomendada | domínio oficial (ex.: `exemplo.com.br`), usado na pré-visualização |
| `CAMINHO_ANTIGO` | não | caminho absoluto do docroot no servidor antigo (ex.: `/home/usuario/domains/exemplo.com.br/public_html`): vira atalho para `/var/www/html`, e symlinks/`.htaccess` que usam esse caminho são corrigidos |
| `PHP_AUTO_PREPEND_FILE` | não | arquivo carregado antes de todo PHP (ex.: `/var/www/html/wordfence-waf.php`, Wordfence em proteção estendida) |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_SECURE`, `SMTP_USER`, `SMTP_PASSWORD`, `SMTP_FROM`, `SMTP_FROM_NAME`, `SMTP_FORCE` | não | e-mail de saída por SMTP (no contêiner não há `mail()`); um plugin SMTP do site é respeitado, a menos que `SMTP_FORCE=1` |
| `BLOQUEAR_ARQUIVOS` | não | nomes de arquivo que passam a responder 403 em qualquer pasta (ex.: `backup.zip debug.log`) |
| `APACHE_MAX_WORKERS` | não | processos do Apache (padrão `25`) |
| `PORT` | não | porta do Apache (padrão `80`) |
| `RAILWAY_PREVIEW` | não | `0` desliga a pré-visualização pelo endereço `*.up.railway.app` |
| `WP_DISABLE_CRON` | não | `1` desliga o WP-Cron |

### Autorrestauração (`RESTAURAR_*`)

Sem estas variáveis o contêiner só sobe o site que já estiver no volume.

| Variável | Para quê |
|---|---|
| `RESTAURAR_ARQUIVOS_URL` | URL `https://` de um `.tar.gz` com entradas relativas a `/var/www`: `html/...` é o docroot; outras pastas entram ao lado dele |
| `RESTAURAR_BANCO_URL` | URL `https://` do `.sql.gz` gerado por `mariadb-dump` (tem de terminar com `-- Dump completed`) |
| `RESTAURAR_AUTH` | `usuario:senha` do HTTP Basic Auth da pasta de download (opcional) |
| `RESTAURAR_ARQUIVOS_SHA256`, `RESTAURAR_BANCO_SHA256` | opcionais: se o arquivo baixado tiver outro sha256, nada é alterado e o contêiner para com erro |
| `RESTAURAR_VERSAO` | texto livre (padrão `1`) que marca o que já foi restaurado |
| `RESTAURAR_SOBRESCREVER` | `sim` permite substituir conteúdo existente quando a `RESTAURAR_VERSAO` muda (sincronização final antes da troca de DNS) |

Como decide (arquivos e banco separadamente):

- volume vazio / banco sem tabelas: restaura;
- mesma `RESTAURAR_VERSAO` já restaurada: não faz nada (reiniciar não baixa de novo);
- conteúdo existente e versão nova **sem** `RESTAURAR_SOBRESCREVER=sim`: não toca e avisa no log;
- conteúdo existente e versão nova **com** `RESTAURAR_SOBRESCREVER=sim`: substitui.

Tudo é baixado e conferido (sha256, gzip, fim do dump, extração e ajuste do `wp-config.php`) antes de mexer no site, e
os arquivos entram por troca de pasta, então o site nunca fica pela metade. Se algo falhar, o contêiner para com erro,
nada é marcado e o log diz o motivo. O log nunca mostra senha nem a URL completa. O `wp-config.php` restaurado passa a
ler o banco das variáveis `WORDPRESS_DB_*` (a senha antiga some do arquivo); chaves e salts ficam iguais.

Para gerar o pacote no servidor antigo (a partir da pasta que contém o `public_html`):

```sh
tar -czf site-arquivos.tar.gz --transform 'flags=r;s,^public_html,html,' public_html [outras pastas ao lado]
mariadb-dump --single-transaction --quick --routines --triggers --hex-blob --default-character-set=utf8mb4 \
  --no-tablespaces --add-drop-table <banco> | gzip > site-banco.sql.gz
sha256sum site-arquivos.tar.gz site-banco.sql.gz > SHA256SUMS
```

## Ferramentas dentro da imagem do WordPress

- `wpr-banco importar|conferir|shell|limpar --sim`: banco do site com as credenciais das variáveis;
- `wpr-manifesto <pasta>`: sha256 + bytes de todos os arquivos, pastas e links (para comparar origem e destino com `diff`);
- `wpr-pos-copia`: ajustes depois de copiar arquivos à mão (wp-config, symlinks, `.htaccess`, mu-plugins, dono);
- `wp` (wp-cli).

## Repositório

- `wordpress/` e `mariadb/`: Dockerfiles, configuração e scripts (`bin/wpr-*`);
- `teste/fumaca.sh`: teste de ponta a ponta que o GitHub Actions roda antes de publicar;
- `.github/workflows/imagens.yml`: build, teste e publicação no GHCR;
- `.github/workflows/alcance.yml`: testa, a partir de um runner do GitHub, se uma URL protegida responde 401 da origem
  (sem bloqueio da Cloudflare).
