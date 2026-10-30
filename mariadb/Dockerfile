# MariaDB para sites WordPress (Railway ou qualquer Docker): 1 banco + 1 usuário por site, criados pelas variáveis.
#   BANCOS="site1 site2"            nomes dos bancos (cada banco N ganha o usuário N)
#   DB_SITE1_PASSWORD=...           senha do usuário de cada banco: DB_<NOME EM MAIÚSCULAS>_PASSWORD
#   MARIADB_ROOT_PASSWORD=...       senha do root (variável da imagem oficial)
# Volume: /var/lib/mysql (os dados ficam em /var/lib/mysql/data, fora do lost+found do volume).
# MariaDB e não MySQL: dumps de hospedagens com MariaDB >= 10.10 usam collations (ex.: utf8mb3_uca1400_ai_ci)
# que o MySQL 8/9 não conhece; com o mesmo motor o dump entra sem cirurgia.
ARG MARIADB_VERSION=11.8
FROM mariadb:${MARIADB_VERSION}
LABEL org.opencontainers.image.source="https://github.com/lemund-marketing/wordpress-railway" \
      org.opencontainers.image.description="MariaDB com bancos e usuários criados por variável (BANCOS + DB_<NOME>_PASSWORD)"
# atualiza as tabelas de sistema sozinho quando a versão do MariaDB muda
ENV MARIADB_AUTO_UPGRADE=1
COPY wpr.cnf /etc/mysql/conf.d/zz-wpr.cnf
COPY bin/ /usr/local/bin/
# .sh SEM bit de execução => o entrypoint oficial faz "source" (tem docker_process_sql)
COPY initdb/10-bancos.sh /docker-entrypoint-initdb.d/10-bancos.sh
RUN chmod 0644 /etc/mysql/conf.d/zz-wpr.cnf /docker-entrypoint-initdb.d/10-bancos.sh \
 && chmod 0755 /usr/local/bin/wpr-*
ENTRYPOINT ["wpr-mariadb-entrypoint"]
CMD ["mariadbd"]
