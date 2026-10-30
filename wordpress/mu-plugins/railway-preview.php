<?php
/**
 * Plugin Name: Railway — pré-visualização (*.up.railway.app)
 * Description: SÓ quando o site é aberto por um endereço *.up.railway.app: troca home/siteurl e as URLs absolutas do domínio oficial pelo endereço atual, para navegar no site novo antes da virada do DNS. Não grava nada no banco. No domínio oficial não faz nada.
 * Author: wordpress-railway
 * Version: 1.0.0
 *
 * Versão leiga: com isto dá para abrir o site novo pelo endereço provisório da Railway e clicar
 * em tudo, sem que as páginas pulem de volta para o site antigo. Quando o DNS virar, o arquivo
 * fica inerte (o endereço deixa de ser *.up.railway.app).
 *
 * Arquivo gerenciado pela imagem (wordpress/mu-plugins no repositório wordpress-railway):
 * o entrypoint copia por cima a cada boot. Desligar: variável RAILWAY_PREVIEW=0 no serviço.
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

( static function () {
	if ( '0' === getenv( 'RAILWAY_PREVIEW' ) || ( defined( 'WP_CLI' ) && WP_CLI ) ) {
		return;
	}
	$host = isset( $_SERVER['HTTP_HOST'] ) ? strtolower( (string) $_SERVER['HTTP_HOST'] ) : '';
	$host = preg_replace( '/:\d+$/', '', $host );
	if ( ! preg_match( '/^[a-z0-9-]+(?:\.[a-z0-9-]+)*\.up\.railway\.app$/', $host ) ) {
		return; // domínio oficial ou acesso interno: inerte
	}

	// Domínio oficial, lido do banco ANTES de colocar os filtros (sem alterar nada).
	$canon_hosts = array();
	$raw_values  = array(
		'home'    => get_option( 'home' ),
		'siteurl' => get_option( 'siteurl' ),
	);
	foreach ( $raw_values as $raw ) {
		$h = strtolower( (string) wp_parse_url( (string) $raw, PHP_URL_HOST ) );
		if ( '' === $h || $h === $host ) {
			continue;
		}
		$canon_hosts[ $h ] = true;
		$canon_hosts[ 0 === strpos( $h, 'www.' ) ? substr( $h, 4 ) : 'www.' . $h ] = true;
	}
	if ( ! $canon_hosts ) {
		return;
	}
	$canon_hosts = array_keys( $canon_hosts );
	$preview     = 'https://' . $host;

	// 1) home/siteurl apontam para o endereço atual (só em memória, nesta requisição).
	$swap_option = static function ( $value ) use ( $preview ) {
		$path = (string) wp_parse_url( (string) $value, PHP_URL_PATH );
		return $preview . rtrim( $path, '/' );
	};
	add_filter( 'option_home', $swap_option, 99 ); // depois do _config_wp_home (10), caso exista WP_HOME
	add_filter( 'option_siteurl', $swap_option, 99 );
	// Trava: salvar "Configurações > Geral" pelo endereço provisório NÃO grava o endereço provisório no banco:
	// o valor gravado volta a ser o original lido acima (o WP compara com o valor cru e não grava nada).
	foreach ( $raw_values as $opt => $raw ) {
		add_filter(
			"pre_update_option_{$opt}",
			static function () use ( $raw ) {
				return $raw;
			},
			PHP_INT_MAX
		);
	}
	add_action(
		'admin_notices',
		static function () {
			echo '<div class="notice notice-warning"><p><strong>Pré-visualização Railway:</strong> endereço provisório. '
				. 'O conteúdo aqui pode ser substituído pelo do site de origem na virada — não edite por aqui.</p></div>';
		}
	);

	// Nunca deixar o endereço provisório ser indexado.
	add_filter( 'pre_option_blog_public', static function () {
		return '0';
	} );
	add_action( 'send_headers', static function () {
		header( 'X-Robots-Tag: noindex, nofollow', true );
		header( 'X-Railway-Preview: 1', true );
	} );

	// 2) URLs absolutas que estão gravadas no conteúdo (Elementor, menus, opções) -> endereço atual.
	$from = array();
	$to   = array();
	foreach ( $canon_hosts as $h ) {
		foreach ( array( 'https://', 'http://' ) as $scheme ) {
			$from[] = $scheme . $h;
			$to[]   = $preview;
			$from[] = str_replace( '/', '\/', $scheme ) . $h;          // JSON: https:\/\/dominio
			$to[]   = str_replace( '/', '\/', $preview );
			$from[] = rawurlencode( $scheme ) . $h;                      // https%3A%2F%2Fdominio
			$to[]   = rawurlencode( 'https://' ) . $host;
		}
		$from[] = '//' . $h;                                             // //dominio (sem esquema)
		$to[]   = '//' . $host;
		$from[] = '\/\/' . $h;
		$to[]   = '\/\/' . $host;
	}

	$is_text_response = static function () {
		foreach ( headers_list() as $line ) {
			if ( 0 === stripos( $line, 'content-type:' ) ) {
				return (bool) preg_match( '#:\s*(text/|application/(?:json|ld\+json|xml|rss\+xml|atom\+xml|javascript|x-javascript))#i', $line );
			}
			if ( 0 === stripos( $line, 'content-encoding:' ) ) {
				return false; // corpo já comprimido pelo PHP: não mexer
			}
		}
		return true; // sem Content-Type explícito o PHP envia text/html
	};

	ob_start(
		static function ( $buffer ) use ( $from, $to, $is_text_response ) {
			if ( '' === $buffer || ! $is_text_response() ) {
				return $buffer;
			}
			return str_ireplace( $from, $to, $buffer );
		}
	);

	// Redirecionamentos montados com o domínio gravado (ex.: plugins) também ficam no endereço atual.
	add_filter(
		'wp_redirect',
		static function ( $location ) use ( $from, $to ) {
			return is_string( $location ) ? str_ireplace( $from, $to, $location ) : $location;
		},
		1
	);
} )();
