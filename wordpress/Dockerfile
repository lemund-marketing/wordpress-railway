# WordPress para Railway (ou qualquer Docker) — Apache + mod_php: lê os .htaccess como a hospedagem compartilhada
# (LiteSpeed lê .htaccess; Apache também). Tags publicadas: php8.3 e php8.2 (build arg PHP_VERSION).
# Os ARQUIVOS do site NÃO estão na imagem: ficam no volume montado em /var/www (docroot /var/www/html).
# Autorrestauração opcional por variáveis RESTAURAR_* (ver README e bin/wpr-restaurar).
ARG PHP_VERSION=8.3
FROM php:${PHP_VERSION}-apache
LABEL org.opencontainers.image.source="https://github.com/lemund-marketing/wordpress-railway" \
      org.opencontainers.image.description="WordPress (Apache + mod_php) com o site no volume /var/www e autorrestauração por variáveis"

# extensões comuns em hospedagem compartilhada e usadas por WordPress/plugins
COPY --from=mlocati/php-extension-installer:2 /usr/bin/install-php-extensions /usr/local/bin/
RUN install-php-extensions bcmath bz2 calendar exif gd gettext gmp imagick intl mysqli pdo_mysql opcache soap sockets xsl zip

# ghostscript: miniatura de PDF no WP; rsync/mariadb-client/wp-cli: operação e migração
RUN apt-get update \
 && apt-get install -y --no-install-recommends ghostscript rsync mariadb-client less unzip \
 && rm -rf /var/lib/apt/lists/* \
 && curl -fsSL -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
 && chmod +x /usr/local/bin/wp \
 && mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"

RUN a2enmod rewrite headers expires remoteip substitute filter \
 && sed -ri 's/([[:space:]]*LogFormat[[:space:]]+"[^"]*)%h([^"]*")/\1%a\2/g' /etc/apache2/apache2.conf \
 && sed -ri '/^LogFormat .* combined$/ s/"( combined)$/ peer=%{c}a"\1/' /etc/apache2/apache2.conf

COPY apache/wpr.conf /etc/apache2/conf-available/wpr.conf
COPY apache/cloudflare-ips.txt /etc/apache2/cloudflare-ips.txt
COPY php/wpr.ini "$PHP_INI_DIR/conf.d/zz-wpr.ini"
COPY mu-plugins/ /usr/local/share/wpr/mu-plugins/
COPY bin/ /usr/local/bin/
RUN a2enconf wpr && chmod 0755 /usr/local/bin/wpr-* \
 && APACHE_MAX_WORKERS=25 apache2ctl -t

ENTRYPOINT ["wpr-entrypoint"]
CMD ["apache2-foreground"]
