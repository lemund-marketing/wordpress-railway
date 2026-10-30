<?php
/**
 * Plugin Name: Railway — saída de e-mail por SMTP (variáveis do serviço)
 * Description: Na Railway não existe mail()/sendmail. Se o serviço tiver SMTP_HOST, o wp_mail() sai por esse SMTP. Se outro plugin (ex.: WP Mail SMTP) já configurou SMTP, ele é respeitado (a menos que SMTP_FORCE=1). Falhas de envio vão para o log do serviço.
 * Author: wordpress-railway
 * Version: 1.0.0
 *
 * Versão leiga: é a "agência de correio" do site. Sem as credenciais do provedor de e-mail,
 * o site não envia e-mail — e cada tentativa fica registrada no log da Railway.
 *
 * Variáveis: SMTP_HOST, SMTP_PORT (587), SMTP_SECURE (tls|ssl|''), SMTP_USER, SMTP_PASSWORD,
 *            SMTP_FROM (remetente alinhado ao SPF/DKIM do provedor), SMTP_FROM_NAME, SMTP_FORCE.
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

add_action(
	'phpmailer_init',
	static function ( $mailer ) {
		$host = getenv( 'SMTP_HOST' );
		if ( ! $host ) {
			return;
		}
		if ( 'smtp' === $mailer->Mailer && '1' !== getenv( 'SMTP_FORCE' ) ) {
			return; // já configurado por plugin SMTP do site
		}
		$mailer->isSMTP();
		$mailer->Host       = $host;
		$mailer->Port       = (int) ( getenv( 'SMTP_PORT' ) ?: 587 );
		$secure             = getenv( 'SMTP_SECURE' );
		$mailer->SMTPSecure = false === $secure ? 'tls' : $secure;
		$user               = getenv( 'SMTP_USER' );
		$mailer->SMTPAuth   = (bool) $user;
		if ( $user ) {
			$mailer->Username = $user;
			$mailer->Password = (string) getenv( 'SMTP_PASSWORD' );
		}
		$from = getenv( 'SMTP_FROM' );
		if ( $from ) {
			$name = getenv( 'SMTP_FROM_NAME' );
			$mailer->setFrom( $from, $name ? $name : $mailer->FromName, false );
			$mailer->Sender = $from;
		}
	},
	999
);

add_action(
	'wp_mail_failed',
	static function ( $error ) {
		$data = $error->get_error_data();
		$to   = is_array( $data ) && isset( $data['to'] ) ? implode( ',', (array) $data['to'] ) : '?';
		error_log( '[railway-smtp] wp_mail falhou para ' . $to . ': ' . $error->get_error_message() . ( getenv( 'SMTP_HOST' ) ? '' : ' (SMTP_HOST não configurado)' ) );
	}
);
