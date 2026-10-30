# Roda UMA vez, no 1º boot (volume vazio), antes de o servidor aceitar conexões pela rede:
# cria 1 banco + 1 usuário para cada nome de BANCOS, com as senhas das variáveis DB_<NOME>_PASSWORD.
# Nos boots seguintes o wpr-mariadb-entrypoint garante o mesmo (cria o que faltar, alinha as senhas).
if [ -n "${BANCOS:-}" ]; then
  wpr-bancos-sql | docker_process_sql --database=mysql
  mysql_note "bancos prontos (1º boot): ${BANCOS}"
else
  mysql_note "BANCOS vazio: nenhum banco de site criado"
fi
