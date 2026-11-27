<?php
/**
 * Media → Optimize video: upload, queue, review, adjust and redo, approve,
 * use in place of, and send to production. Every request checks
 * upload_files and a nonce.
 */

defined( 'ABSPATH' ) || exit;

class Encode_Review_Admin {

	const PAGE = 'encode-review';
	const CAP  = 'upload_files';

	/** @var Encode_Review_Spool */
	private static $spool;

	public static function boot() {
		self::$spool = new Encode_Review_Spool();
		add_action( 'admin_menu', array( __CLASS__, 'menu' ) );
		add_action( 'admin_enqueue_scripts', array( __CLASS__, 'assets' ) );
		foreach ( array( 'upload_start', 'upload_part', 'upload_remove', 'redo', 'approve', 'remove', 'swap', 'send', 'file' ) as $action ) {
			add_action( 'admin_post_encode_review_' . $action, array( __CLASS__, 'handle_' . $action ) );
		}
		Encode_Review_Fields::boot();
	}

	/** The site key: "ampas" or "guilds", from the install path, else the host. */
	public static function site() {
		if ( defined( 'ENCODE_REVIEW_SITE' ) ) {
			return ENCODE_REVIEW_SITE;
		}
		if ( preg_match( '/amazon-studios-(ampas|guilds)/', __DIR__, $match ) ) {
			return $match[1];
		}
		return sanitize_key( (string) wp_parse_url( home_url(), PHP_URL_HOST ) );
	}

	public static function menu() {
		add_media_page( 'Optimize video', 'Optimize video', self::CAP, self::PAGE, array( __CLASS__, 'render' ) );
	}

	public static function assets( $hook ) {
		if ( 'media_page_' . self::PAGE !== $hook ) {
			return;
		}
		$base = plugins_url( 'assets/', ENCODE_REVIEW_DIR . '/encode-review.php' );
		wp_enqueue_style( 'encode-review', $base . 'review.css', array(), ENCODE_REVIEW_VERSION );
		wp_enqueue_script( 'encode-review', $base . 'review.js', array(), ENCODE_REVIEW_VERSION, true );
	}

	// ---- helpers ------------------------------------------------------------

	private static function url( array $args = array() ) {
		return add_query_arg( array_merge( array( 'page' => self::PAGE ), $args ), admin_url( 'upload.php' ) );
	}

	private static function post_url() {
		return admin_url( 'admin-post.php' );
	}

	private static function guard( $nonce_action ) {
		if ( ! current_user_can( self::CAP ) ) {
			wp_die( 'You are not allowed to optimize video.', 403 );
		}
		check_admin_referer( $nonce_action );
	}

	private static function notice( $message, $type = 'success' ) {
		set_transient( 'encode_review_notice_' . get_current_user_id(), array( $message, $type ), 300 );
	}

	private static function back( array $args = array() ) {
		wp_safe_redirect( self::url( $args ) );
		exit;
	}

	private static function fail_back( Throwable $error, array $args = array() ) {
		self::notice( $error->getMessage(), 'error' );
		self::back( $args );
	}

	/** The job, only when it belongs to this site. */
	private static function own_job( $id ) {
		$found = self::$spool->find( $id );
		if ( ! $found ) {
			return null;
		}
		$job = self::$spool->load( $found[1] );
		if ( ! $job || ( $job['site'] ?? '' ) !== self::site() ) {
			return null;
		}
		$job['state'] = $found[0];
		$job['dir']   = $found[1];
		return $job;
	}

	private static function posted( $key ) {
		return isset( $_POST[ $key ] ) ? sanitize_text_field( wp_unslash( $_POST[ $key ] ) ) : ''; // phpcs:ignore WordPress.Security.NonceVerification -- guard() runs first.
	}

	private static function file_url( $id, $kind, $attempt = 0, $still = '' ) {
		return add_query_arg(
			array(
				'action'   => 'encode_review_file',
				'job'      => $id,
				'kind'     => $kind,
				'attempt'  => (int) $attempt,
				'still'    => $still,
				'_wpnonce' => wp_create_nonce( 'encode_review_file' ),
			),
			self::post_url()
		);
	}

	private static function stage_label( array $job ) {
		$attempt = end( $job['attempts'] );
		$stages = array(
			'reference' => 'Making the reference copy',
			'scoring'   => 'Scoring',
		);
		switch ( $job['state'] ) {
			case 'queue':
				return 'Waiting';
			case 'work':
				$stage = $stages[ $job['stage'] ?? '' ] ?? 'Encoding';
				return sprintf( '%s %d%%', $stage, (int) round( 100 * (float) ( $attempt['progress'] ?? 0 ) ) );
			case 'done':
				return 'Ready to review';
			case 'failed':
				return 'Failed';
		}
		return ucfirst( (string) $job['state'] );
	}

	private static function speed( array $status ) {
		return (float) ( $status['speed'] ?? 0 ) ?: (float) ( $status['default_speed'] ?? 6 );
	}

	/**
	 * Place in line and the seconds until each queued or running job is ready.
	 *
	 * @return array<string,array{place:int,seconds:int|null}>
	 */
	private static function estimates( array $status ) {
		$speed = self::speed( $status );
		$wait  = 0;
		$known = true;
		$out   = array();
		$place = 0;
		foreach ( self::$spool->line() as $job ) {
			$duration = (float) ( $job['probe']['duration'] ?? 0 );
			$total    = $duration > 0 ? $duration * $speed : null;
			if ( 'work' === $job['state'] ) {
				$attempt   = end( $job['attempts'] );
				$elapsed   = time() - (int) ( $attempt['started_at'] ?? time() );
				$remaining = null === $total ? null : max( 60, (int) ( $total - $elapsed ) );
			} else {
				$remaining = $total;
			}
			if ( null === $remaining ) {
				$known = false;
			} else {
				$wait += $remaining;
			}
			$out[ $job['id'] ] = array(
				'place'   => $place++,
				'seconds' => $known ? (int) $wait : null,
			);
		}
		return $out;
	}

	private static function minutes( $seconds ) {
		if ( null === $seconds ) {
			return 'estimating…';
		}
		$minutes = max( 1, (int) round( $seconds / 60 ) );
		return sprintf( 'about %d min', $minutes );
	}

	/**
	 * Why the job may not be approved for want of a moving comparison, or null:
	 * browsers do not reliably play the original and its reference copy is
	 * missing, because the worker refused or failed to make it (ruling 19 item 2).
	 * A redo makes it again. Jobs from before the copy existed have no
	 * original_playable and are judged as playable.
	 */
	private static function review_block( array $job ) {
		if ( empty( $job['original']['sha256'] ) ) {
			// Approval deletes the original, and the file record keeps its SHA-256.
			return 'The encoder has not recorded the original\'s SHA-256 yet, so this job cannot be approved yet. '
				. 'The file record keeps it after approval deletes the original. The encoder adds it within minutes while it runs; reload this page then.';
		}
		if ( false !== ( $job['original_playable'] ?? true ) ) {
			return null;
		}
		if ( ! empty( $job['reference']['file'] ) && is_file( $job['dir'] . '/' . $job['reference']['file'] ) ) {
			return null;
		}
		return 'Browsers do not reliably play the original\'s format, and there is no reference copy for side-by-side review, so this job cannot be approved yet. '
			. ( $job['reference_error'] ?? 'Redo to make the copy.' );
	}

	private static function done_attempts( array $job ) {
		return array_values( array_filter( $job['attempts'], fn( $a ) => 'done' === ( $a['status'] ?? '' ) ) );
	}

	private static function attempt( array $job, $n ) {
		foreach ( $job['attempts'] as $attempt ) {
			if ( (int) $attempt['n'] === (int) $n ) {
				return $attempt;
			}
		}
		return null;
	}

	/**
	 * An attachment this tool approved on this site, or 0. Its page carries
	 * "Use in place of…" and "Send to production" once the job is gone.
	 */
	private static function tool_attachment( $attachment_id ) {
		$attachment_id = (int) $attachment_id;
		$meta          = $attachment_id ? get_post_meta( $attachment_id, '_encode_review', true ) : null;
		return ( is_array( $meta ) && 'attachment' === get_post_type( $attachment_id ) ) ? $attachment_id : 0;
	}

	// "video", not "approved": WordPress strips "approved" from admin URLs (wp_removable_query_args).
	private static function approved_url( $attachment_id, array $args = array() ) {
		return self::url( array_merge( array( 'video' => (int) $attachment_id ), $args ) );
	}

	private static function approved_attachment( array $job ) {
		$id = (int) ( $job['approved']['attachment_id'] ?? 0 );
		return ( $id && get_post( $id ) ) ? $id : 0;
	}

	// ---- handlers -----------------------------------------------------------

	/**
	 * Starts an upload in parts (or resumes the same file's unfinished one) and
	 * answers with where the next part starts. JSON only: the page's script
	 * sends the parts.
	 */
	public static function handle_upload_start() {
		if ( ! current_user_can( self::CAP ) || ! check_ajax_referer( 'encode_review_upload', '_wpnonce', false ) ) {
			wp_send_json( array( 'error' => 'Your login or this page expired. Reload the page and start again.' ), 403 );
		}
		$target = null;
		try {
			if ( self::posted( 'for' ) ) {
				$target = Encode_Review_Fields::target( (int) self::posted( 'for' ), self::posted( 'key' ) );
			}
			$upload = self::$spool->start_upload(
				array(
					'name'     => self::posted( 'name' ),
					'size'     => (int) self::posted( 'size' ),
					'modified' => (int) self::posted( 'modified' ),
				),
				self::site(),
				wp_get_current_user(),
				$target
			);
		} catch ( RuntimeException $error ) {
			wp_send_json( array( 'error' => $error->getMessage() ), 400 );
		}
		wp_send_json(
			array(
				'upload'    => $upload['id'],
				'received'  => (int) $upload['received'],
				'size'      => (int) $upload['size'],
				'part_size' => Encode_Review_Spool::PART_SIZE,
			)
		);
	}

	/**
	 * One part: the raw request body, appended at ?offset=. Answers with the
	 * bytes the server holds, or with the job's page once the last part is in.
	 */
	public static function handle_upload_part() {
		if ( ! current_user_can( self::CAP ) || ! check_ajax_referer( 'encode_review_upload', '_wpnonce', false ) ) {
			wp_send_json( array( 'error' => 'Your login or this page expired. Reload the page; the upload resumes where it stopped.' ), 403 );
		}
		// phpcs:disable WordPress.Security.NonceVerification -- checked above.
		$id     = sanitize_text_field( wp_unslash( $_GET['upload'] ?? '' ) );
		$offset = (int) ( $_GET['offset'] ?? -1 );
		// phpcs:enable
		$length = (int) ( $_SERVER['CONTENT_LENGTH'] ?? 0 );
		$input  = fopen( 'php://input', 'rb' );
		try {
			$reply = self::$spool->append_part( $id, $offset, $input, $length, self::site(), wp_get_current_user() );
		} catch ( Encode_Review_Offset_Error $error ) {
			wp_send_json(
				array(
					'error'    => $error->getMessage(),
					'received' => $error->received,
				),
				409
			);
		} catch ( RuntimeException $error ) {
			wp_send_json( array( 'error' => $error->getMessage() ), 400 );
		} finally {
			if ( $input ) {
				fclose( $input );
			}
		}
		if ( ! empty( $reply['job'] ) ) {
			self::notice( 'Uploaded. The trailer is in the queue.' );
			$reply['redirect'] = self::url( array( 'job' => $reply['job'] ) );
		}
		wp_send_json( $reply );
	}

	public static function handle_upload_remove() {
		$id = self::posted( 'upload' );
		self::guard( 'encode_review_upload_' . $id );
		$upload = self::$spool->upload( $id );
		if ( ! $upload || ( $upload['site'] ?? '' ) !== self::site() ) {
			wp_die( 'No such upload.', 404 );
		}
		try {
			self::$spool->remove_upload( $id );
			self::notice( 'Removed the unfinished upload.' );
		} catch ( RuntimeException $error ) {
			self::fail_back( $error );
		}
		self::back();
	}

	public static function handle_redo() {
		$id = self::posted( 'job' );
		self::guard( 'encode_review_job_' . $id );
		if ( ! self::own_job( $id ) ) {
			wp_die( 'No such job.', 404 );
		}
		try {
			$n = self::$spool->redo( $id, (int) self::posted( 'crf' ), (int) round( (float) self::posted( 'maxrate_mbps' ) * 1000 ), wp_get_current_user() );
			self::notice( sprintf( 'Attempt %d is in the queue. Earlier attempts stay here to compare.', $n ) );
		} catch ( RuntimeException $error ) {
			self::fail_back( $error, array( 'job' => $id ) );
		}
		self::back( array( 'job' => $id ) );
	}

	public static function handle_remove() {
		$id = self::posted( 'job' );
		self::guard( 'encode_review_job_' . $id );
		if ( ! self::own_job( $id ) ) {
			wp_die( 'No such job.', 404 );
		}
		try {
			self::$spool->remove( $id );
			self::notice( 'Removed the job and its files. Anything already approved stays in Media.' );
		} catch ( RuntimeException $error ) {
			self::fail_back( $error, array( 'job' => $id ) );
		}
		self::back();
	}

	public static function handle_approve() {
		$id = self::posted( 'job' );
		self::guard( 'encode_review_job_' . $id );
		$job = self::own_job( $id );
		$n   = (int) self::posted( 'attempt' );
		if ( ! $job || 'done' !== $job['state'] ) {
			wp_die( 'This job is not ready to approve.', 409 );
		}
		$block = self::review_block( $job );
		if ( $block ) {
			self::fail_back( new RuntimeException( $block ), array( 'job' => $id ) );
		}
		if ( self::approved_attachment( $job ) ) {
			self::fail_back( new RuntimeException( 'This job is already approved into Media.' ), array( 'job' => $id ) );
		}
		$attempt = self::attempt( $job, $n );
		$source  = $job['dir'] . '/attempts/' . $n . '/encode.mp4';
		if ( ! $attempt || 'done' !== $attempt['status'] || ! is_file( $source ) ) {
			self::fail_back( new RuntimeException( 'That attempt has no finished encode.' ), array( 'job' => $id ) );
		}

		require_once ABSPATH . 'wp-admin/includes/file.php';
		require_once ABSPATH . 'wp-admin/includes/media.php';
		require_once ABSPATH . 'wp-admin/includes/image.php';

		// Sideload moves its file, so it gets a copy and the spool keeps the attempt.
		$tmp = wp_tempnam( 'encode-review.mp4' );
		if ( ! copy( $source, $tmp ) ) {
			self::fail_back( new RuntimeException( 'The encode could not be copied for Media.' ), array( 'job' => $id ) );
		}
		$stem          = pathinfo( $job['original']['name'], PATHINFO_FILENAME );
		$attachment_id = media_handle_sideload(
			array(
				'name'     => $stem . '.mp4',
				'tmp_name' => $tmp,
			),
			0,
			$stem
		);
		if ( is_wp_error( $attachment_id ) ) {
			@unlink( $tmp ); // phpcs:ignore WordPress.PHP.NoSilencedErrors
			self::fail_back( new RuntimeException( 'Media refused the file: ' . $attachment_id->get_error_message() ), array( 'job' => $id ) );
		}
		$results = $attempt['results'] ?? array();
		$user    = wp_get_current_user();
		update_post_meta(
			$attachment_id,
			'_encode_review',
			array(
				'job'         => $id,
				'attempt'     => $n,
				'crf'         => $attempt['crf'] ?? null,
				'maxrate_k'   => $attempt['maxrate_k'] ?? null,
				'vmaf_mean'   => $results['vmaf']['mean'] ?? null,
				'size_before' => $results['size_before'] ?? null,
				'size_after'  => $results['size_after'] ?? null,
				'original'    => $job['original']['name'],
				'by'          => $user->user_login,
				'at'          => time(),
			)
		);
		// The worker hashed the original while it was on disk (review_block refuses a job
		// without the hash); the original goes with the job below.
		Encode_Review_Record::save(
			$attachment_id,
			Encode_Review_Record::for_encode(
				array(
					'name'   => (string) $job['original']['name'],
					'size'   => (int) ( $job['original']['size'] ?? 0 ),
					'sha256' => (string) $job['original']['sha256'],
				),
				array(
					'crf'       => $attempt['crf'] ?? null,
					'maxrate_k' => $attempt['maxrate_k'] ?? null,
				)
			)
		);
		$name = wp_basename( (string) get_attached_file( $attachment_id ) );

		// The spool copy goes only once Media holds the whole file.
		if ( ! self::safely_in_media( $attachment_id, (int) filesize( $source ) ) ) {
			self::$spool->update_job(
				$id,
				function ( array &$job ) use ( $n, $attachment_id, $user ) {
					$job['approved'] = array(
						'attempt'       => $n,
						'attachment_id' => (int) $attachment_id,
						'by'            => $user->user_login,
						'at'            => time(),
					);
				}
			);
			self::notice( sprintf( 'Approved attempt %d as "%s", but Media\'s copy could not be confirmed, so the original and attempts stay here (deleted after 7 days). Check the file in Media.', $n, $name ), 'warning' );
			self::back( array( 'job' => $id ) );
		}
		$swap = empty( $job['target'] ) ? '' : ' ' . self::swap_target( $job['target'], $attachment_id );
		try {
			self::$spool->remove( $id );
			$deleted = ' The original and every attempt are deleted from this server.';
		} catch ( RuntimeException $error ) {
			$deleted = ' The original and attempts could not be deleted yet; they go after 7 days.';
		}
		self::notice( sprintf( 'Approved attempt %d. It is now in Media as "%s".%s%s', $n, $name, $swap, $deleted ), str_contains( $swap, 'Not swapped' ) ? 'warning' : 'success' );
		wp_safe_redirect( self::approved_url( $attachment_id ) );
		exit;
	}

	/**
	 * Points the job's chosen field at the approved video, only if it still holds
	 * the video it held at upload. Returns the sentence for the notice.
	 */
	private static function swap_target( array $target, $attachment_id ) {
		$where  = sprintf( '"%s" on "%s"', $target['label'], $target['post_title'] );
		$result = Encode_Review_Fields::swap( (int) $target['old_id'], (int) $attachment_id, array( $target['post_id'] . '|' . $target['meta_key'] ) );
		if ( $result['swapped'] ) {
			return sprintf( 'Swapped %s to the new video; no other field changed.', $where );
		}
		if ( $result['denied'] ) {
			return sprintf( 'Not swapped: you cannot edit "%s", so %s was left as it is. Someone who can edit it can use "Use in place of…" on the approved video\'s page.', $target['post_title'], $where );
		}
		return sprintf( 'Not swapped: %s no longer holds the video it held at upload, so it was left as it is. Use "Use in place of…" on the approved video\'s page.', $where );
	}

	/** Media has the attachment and its whole file. */
	private static function safely_in_media( $attachment_id, $size ) {
		$file = get_attached_file( $attachment_id );
		clearstatcache();
		return $file && is_file( $file ) && $size > 0 && filesize( $file ) === $size
			&& 'attachment' === get_post_type( $attachment_id );
	}

	public static function handle_swap() {
		$new_id = (int) self::posted( 'video' );
		self::guard( 'encode_review_swap_' . $new_id );
		$new_id = self::tool_attachment( $new_id );
		$old_id = (int) self::posted( 'old' );
		if ( ! $new_id || ! $old_id ) {
			wp_die( 'Approve a video before using it in place of another one.', 409 );
		}
		$choices = array_map( 'sanitize_text_field', (array) wp_unslash( $_POST['fields'] ?? array() ) ); // phpcs:ignore WordPress.Security
		$result  = Encode_Review_Fields::swap( $old_id, $new_id, $choices );
		$message = sprintf( 'Swapped %d field(s) to the new video.', count( $result['swapped'] ) );
		if ( $result['denied'] ) {
			$message .= sprintf(
				' Left %d alone because you cannot edit %s.',
				count( $result['denied'] ),
				implode( ', ', array_unique( array_map( fn( $r ) => '"' . $r['post_title'] . '"', $result['denied'] ) ) )
			);
		}
		if ( $result['skipped'] ) {
			$message .= sprintf( ' Skipped %d that no longer pointed at the old video.', count( $result['skipped'] ) );
		}
		self::notice( $message, ( $result['skipped'] || $result['denied'] ) ? 'warning' : 'success' );
		wp_safe_redirect( self::approved_url( $new_id ) );
		exit;
	}

	public static function handle_send() {
		$attachment_id = (int) self::posted( 'video' );
		self::guard( 'encode_review_send_' . $attachment_id );
		$attachment_id = self::tool_attachment( $attachment_id );
		if ( ! $attachment_id ) {
			wp_die( 'Approve the video before sending it to production.', 409 );
		}
		try {
			( new Encode_Review_Production( self::$spool, self::site() ) )->queue( $attachment_id, wp_get_current_user() );
			self::notice( 'Sending the file to production Media. Only this file goes; set its field in production by hand.' );
		} catch ( RuntimeException $error ) {
			self::notice( $error->getMessage(), 'error' );
		}
		wp_safe_redirect( self::approved_url( $attachment_id ) );
		exit;
	}

	/** Playback and stills: the login check here, then nginx serves the file. */
	public static function handle_file() {
		if ( ! current_user_can( self::CAP ) ) {
			status_header( 403 );
			exit;
		}
		check_admin_referer( 'encode_review_file' );
		// phpcs:disable WordPress.Security.NonceVerification -- checked above.
		$id   = sanitize_text_field( wp_unslash( $_GET['job'] ?? '' ) );
		$kind = sanitize_key( $_GET['kind'] ?? '' );
		$n    = (int) ( $_GET['attempt'] ?? 0 );
		$name = sanitize_file_name( wp_unslash( $_GET['still'] ?? '' ) );
		// phpcs:enable
		if ( ! self::own_job( $id ) ) {
			status_header( 404 );
			exit;
		}
		$file = self::$spool->media_path( $id, $kind, $n, $name );
		if ( ! $file ) {
			status_header( 404 );
			exit;
		}
		$types = array(
			'mp4'  => 'video/mp4',
			'm4v'  => 'video/mp4',
			'mov'  => 'video/quicktime',
			'webm' => 'video/webm',
			'mkv'  => 'video/x-matroska',
			'jpg'  => 'image/jpeg',
		);
		$ext = strtolower( pathinfo( $file['full'], PATHINFO_EXTENSION ) );
		header_remove( 'Expires' );
		header_remove( 'Pragma' );
		header( 'Content-Type: ' . ( $types[ $ext ] ?? 'application/octet-stream' ) );
		header( 'Cache-Control: private, max-age=3600' );
		header( 'X-Accel-Redirect: ' . ENCODE_REVIEW_ACCEL_PREFIX . $file['relative'] );
		exit;
	}

	// ---- pages --------------------------------------------------------------

	public static function render() {
		if ( ! current_user_can( self::CAP ) ) {
			wp_die( 'You are not allowed to optimize video.', 403 );
		}
		// phpcs:disable WordPress.Security.NonceVerification -- read-only views.
		$view     = sanitize_key( $_GET['view'] ?? '' );
		$id       = sanitize_text_field( wp_unslash( $_GET['job'] ?? '' ) );
		$approved = (int) ( $_GET['video'] ?? 0 );
		// phpcs:enable
		echo '<div class="wrap encode-review">';
		echo '<h1 class="wp-heading-inline">Optimize video</h1>';
		if ( $id || $approved ) {
			echo ' <a class="page-title-action" href="' . esc_url( self::url() ) . '">All videos</a>';
		}
		echo '<hr class="wp-header-end">';
		self::render_notice();
		$job = $id ? self::own_job( $id ) : null;
		if ( $approved ) {
			$approved = self::tool_attachment( $approved );
			if ( ! $approved ) {
				echo '<div class="notice notice-warning"><p>That video was not approved with this tool, or it is no longer in Media.</p></div>';
			} elseif ( 'swap' === $view ) {
				self::render_swap( $approved );
			} else {
				self::render_approved( $approved );
			}
		} elseif ( $id && ! $job ) {
			echo '<div class="notice notice-warning"><p>This job is gone. Approving a job deletes it from this server, and other jobs are deleted 7 days after their last activity. Approved videos are listed under All videos.</p></div>';
		} elseif ( $job ) {
			self::render_job( $job );
		} else {
			self::render_queue();
		}
		echo '</div>';
	}

	private static function render_notice() {
		$key    = 'encode_review_notice_' . get_current_user_id();
		$notice = get_transient( $key );
		if ( ! $notice ) {
			return;
		}
		delete_transient( $key );
		printf( '<div class="notice notice-%s is-dismissible"><p>%s</p></div>', esc_attr( $notice[1] ), esc_html( $notice[0] ) );
	}

	private static function render_worker_line( array $status ) {
		if ( empty( $status['online'] ) ) {
			echo '<div class="notice notice-error inline"><p><strong>The encoder is not running.</strong> Uploads wait in the queue until it is back. Tell the platform team.</p></div>';
			return;
		}
		printf(
			'<p class="er-worker">Encoder running · %s free on the server · one encode at a time</p>',
			esc_html( size_format( (int) ( $status['free_bytes'] ?? 0 ), 1 ) )
		);
	}

	private static function render_queue() {
		$status = self::$spool->status();
		$block  = self::$spool->upload_block_reason();
		echo '<p class="er-intro">Upload a raw trailer here, not in Media. The server encodes it, scores it against the original, and lets you compare the two side by side before anything reaches Media.</p>';
		self::render_worker_line( $status );

		$target = self::requested_target();
		echo '<div class="er-card"><h2>Upload an original</h2>';
		if ( is_array( $target ) ) {
			printf(
				'<div class="notice notice-info inline er-target"><p>For %s on <a href="%s">%s</a>, which now plays <code>%s</code>. Approving the encode puts it in that field only.</p></div>',
				esc_html( '"' . $target['label'] . '"' ),
				esc_url( (string) get_edit_post_link( $target['post_id'] ) ),
				esc_html( $target['post_title'] ),
				esc_html( wp_basename( (string) get_attached_file( $target['old_id'] ) ) )
			);
		} elseif ( is_string( $target ) ) {
			echo '<div class="notice notice-warning inline"><p>' . esc_html( $target ) . ' The upload below is not tied to a field.</p></div>';
			$target = null;
		}
		if ( $block ) {
			echo '<div class="notice notice-warning inline"><p>' . esc_html( $block ) . '</p></div>';
		} else {
			?>
			<form class="er-upload" method="post" action="<?php echo esc_url( self::post_url() ); ?>"
				data-er-nonce="<?php echo esc_attr( wp_create_nonce( 'encode_review_upload' ) ); ?>"
				data-er-limit="<?php echo esc_attr( (string) Encode_Review_Spool::UPLOAD_LIMIT ); ?>">
				<?php if ( $target ) : ?>
					<input type="hidden" name="for" value="<?php echo (int) $target['post_id']; ?>">
					<input type="hidden" name="key" value="<?php echo esc_attr( $target['meta_key'] ); ?>">
				<?php endif; ?>
				<label for="er-original">Original video</label>
				<input type="file" id="er-original" name="original" accept="video/*,.mxf,.mkv" aria-describedby="er-upload-help" required>
				<button type="submit" class="button button-primary">Upload and queue</button>
				<button type="button" class="button" data-er-resume hidden>Resume upload</button>
				<p class="description" id="er-upload-help">Up to <?php echo esc_html( size_format( Encode_Review_Spool::UPLOAD_LIMIT ) ); ?>. It goes up in parts, so a dropped connection resumes where it stopped; choosing the same file again later picks it up too. The encoder checks that the file is a video. It stays out of Media until you approve an encode.</p>
				<noscript><p><strong>Uploading needs JavaScript.</strong></p></noscript>
				<progress class="er-progress" max="100" value="0" hidden aria-label="Upload progress"></progress>
				<p class="er-upload-status" aria-live="polite"></p>
			</form>
			<?php
		}
		echo '</div>';
		self::render_uploads();

		$jobs      = self::$spool->jobs( self::site() );
		$estimates = self::estimates( $status );
		$active    = false;
		echo '<h2>Videos</h2>';
		if ( ! $jobs ) {
			echo '<p>No videos in progress.</p>';
			self::render_approved_list();
			return;
		}
		echo '<table class="widefat striped er-jobs"><thead><tr><th>Original</th><th>Uploaded by</th><th>Stage</th><th>Ready in</th><th>Attempts</th><th>Last activity</th></tr></thead><tbody>';
		foreach ( $jobs as $job ) {
			$estimate = $estimates[ $job['id'] ] ?? null;
			$ready_in = '—';
			if ( $estimate ) {
				$active   = true;
				$ready_in = esc_html( self::minutes( $estimate['seconds'] ) );
				if ( $estimate['place'] > 0 ) {
					$ready_in .= '<br><span class="description">' . esc_html( sprintf( '%d ahead in line', $estimate['place'] ) ) . '</span>';
				}
			}
			$approved = self::approved_attachment( $job ) ? ' · approved' : '';
			printf(
				'<tr><td><a href="%s"><strong>%s</strong></a></td><td>%s</td><td><span class="er-stage er-stage-%s">%s</span>%s</td><td>%s</td><td>%d</td><td>%s ago</td></tr>',
				esc_url( self::url( array( 'job' => $job['id'] ) ) ),
				esc_html( $job['original']['name'] ),
				esc_html( $job['uploader']['name'] ?? $job['uploader']['login'] ),
				esc_attr( $job['state'] ),
				esc_html( self::stage_label( $job ) ),
				esc_html( $approved ),
				$ready_in, // Escaped above.
				count( $job['attempts'] ),
				esc_html( human_time_diff( (int) $job['updated_at'] ) )
			);
		}
		echo '</tbody></table>';
		echo '<p class="description">Originals and attempts are deleted 7 days after their last activity. Approved files stay in Media.</p>';
		if ( $active ) {
			echo '<div data-er-refresh="30"></div>';
		}
		self::render_approved_list();
	}

	/**
	 * The field chosen by an "Encode a new version" link (?for=&key=): its
	 * target, the reason it cannot be used, or null without a link.
	 *
	 * @return array|string|null
	 */
	private static function requested_target() {
		// phpcs:disable WordPress.Security.NonceVerification -- read-only view choice; the upload checks it again.
		if ( empty( $_GET['for'] ) ) {
			return null;
		}
		$post_id  = (int) $_GET['for'];
		$meta_key = sanitize_text_field( wp_unslash( $_GET['key'] ?? '' ) );
		// phpcs:enable
		try {
			return Encode_Review_Fields::target( $post_id, $meta_key );
		} catch ( RuntimeException $error ) {
			return $error->getMessage();
		}
	}

	/** Uploads of this site still arriving in parts. */
	private static function render_uploads() {
		$uploads = self::$spool->uploads( self::site() );
		if ( ! $uploads ) {
			return;
		}
		echo '<h2>Unfinished uploads</h2><table class="widefat striped er-uploads"><thead><tr><th>File</th><th>Uploaded by</th><th>Received</th><th>Last part</th><th></th></tr></thead><tbody>';
		foreach ( $uploads as $upload ) {
			echo '<tr><td><strong>' . esc_html( $upload['name'] ) . '</strong>';
			if ( ! empty( $upload['target'] ) ) {
				echo '<br><span class="description">' . esc_html( sprintf( 'for "%s" on "%s"', $upload['target']['label'], $upload['target']['post_title'] ) ) . '</span>';
			}
			$complete = (int) $upload['received'] >= (int) $upload['size'];
			printf(
				'</td><td>%s</td><td>%s</td><td>%s ago</td><td>',
				esc_html( $upload['uploader']['name'] ?? $upload['uploader']['login'] ),
				esc_html(
					$complete
						? sprintf( 'All %s; waiting for disk space to join the queue', size_format( (int) $upload['size'], 1 ) )
						: sprintf( '%s of %s', (int) $upload['received'] ? size_format( (int) $upload['received'], 1 ) : 'nothing yet', size_format( (int) $upload['size'], 1 ) )
				),
				esc_html( human_time_diff( (int) $upload['updated_at'] ) )
			);
			?>
			<form method="post" action="<?php echo esc_url( self::post_url() ); ?>" data-er-confirm="Remove this unfinished upload?">
				<input type="hidden" name="action" value="encode_review_upload_remove">
				<input type="hidden" name="upload" value="<?php echo esc_attr( $upload['id'] ); ?>">
				<?php wp_nonce_field( 'encode_review_upload_' . $upload['id'] ); ?>
				<button type="submit" class="button-link button-link-delete" aria-label="<?php echo esc_attr( 'Remove the unfinished upload of ' . $upload['name'] ); ?>">Remove</button>
			</form>
			<?php
			echo '</td></tr>';
		}
		echo '</tbody></table>';
		echo '<p class="description">To finish one, choose the same file again above: it resumes where it stopped, and a complete one joins the queue without sending anything again. Unfinished uploads are deleted 7 days after their last part.</p>';
	}

	/** Videos approved with this tool on this site, newest first, for swap and send. */
	private static function render_approved_list() {
		$ids = get_posts(
			array(
				'post_type'      => 'attachment',
				'post_status'    => 'inherit',
				'meta_key'       => '_encode_review', // phpcs:ignore WordPress.DB.SlowDBQuery
				'posts_per_page' => 20,
				'fields'         => 'ids',
			)
		);
		if ( ! $ids ) {
			return;
		}
		$production = new Encode_Review_Production( self::$spool, self::site() );
		echo '<h2>Approved videos</h2><table class="widefat striped er-approved"><thead><tr><th>In Media as</th><th>Approved by</th><th>Production</th></tr></thead><tbody>';
		foreach ( $ids as $id ) {
			$meta   = get_post_meta( $id, '_encode_review', true );
			$record = $production->record( $id );
			$state  = $record['state'] ?? '';
			printf(
				'<tr><td><a href="%s"><strong>%s</strong></a></td><td>%s</td><td>%s</td></tr>',
				esc_url( self::approved_url( $id ) ),
				esc_html( wp_basename( (string) get_attached_file( $id ) ) ),
				esc_html( trim( ( $meta['by'] ?? '' ) . ( isset( $meta['at'] ) ? ', ' . human_time_diff( (int) $meta['at'] ) . ' ago' : '' ), ', ' ) ),
				esc_html( 'sent' === $state ? sprintf( 'Sent (attachment %d)', (int) $record['production_id'] ) : ( $state ? ucfirst( $state ) : 'Not sent' ) )
			);
		}
		echo '</tbody></table>';
		echo '<p class="description">Open one to use it in place of another video or to send it to production.</p>';
	}

	private static function render_job( array $job ) {
		$status = self::$spool->status();
		$latest = end( $job['attempts'] );
		$done   = self::done_attempts( $job );
		printf( '<h2 class="er-title">%s</h2>', esc_html( $job['original']['name'] ) );
		printf(
			'<p class="er-meta">Uploaded by %s, %s ago · %s · %s</p>',
			esc_html( $job['uploader']['name'] ?? $job['uploader']['login'] ),
			esc_html( human_time_diff( (int) $job['created_at'] ) ),
			esc_html( size_format( (int) $job['original']['size'], 1 ) ),
			esc_html( isset( $job['probe'] ) ? sprintf( '%d×%d, %s s, %s', $job['probe']['width'], $job['probe']['height'], $job['probe']['duration'], $job['probe']['vcodec'] ) : 'not probed yet' )
		);

		if ( ! empty( $job['target'] ) ) {
			printf(
				'<p class="er-target">For %s on <a href="%s">%s</a>. Approving puts the encode in that field only, if it still holds the video it held at upload.</p>',
				esc_html( '"' . $job['target']['label'] . '"' ),
				esc_url( (string) get_edit_post_link( (int) $job['target']['post_id'] ) ),
				esc_html( $job['target']['post_title'] )
			);
		}

		if ( in_array( $job['state'], array( 'queue', 'work' ), true ) ) {
			$estimate = self::estimates( $status )[ $job['id'] ] ?? null;
			echo '<div class="er-card er-wait">';
			printf( '<p><strong>Attempt %d: %s</strong>', (int) $latest['n'], esc_html( self::stage_label( $job ) ) );
			if ( $estimate ) {
				echo ' · ready ' . esc_html( self::minutes( $estimate['seconds'] ) );
				if ( $estimate['place'] > 0 ) {
					echo esc_html( sprintf( ' · %d ahead in line', $estimate['place'] ) );
				}
			}
			echo '</p>';
			if ( 'work' === $job['state'] ) {
				printf( '<progress max="100" value="%d"></progress>', (int) round( 100 * (float) ( $latest['progress'] ?? 0 ) ) );
			}
			echo '<p class="description">This page refreshes by itself. You can leave and come back.</p>';
			self::render_worker_line( $status );
			echo '</div><div data-er-refresh="15"></div>';
		} elseif ( 'failed' === $job['state'] ) {
			printf(
				'<div class="notice notice-error inline"><p><strong>Attempt %d failed.</strong> %s</p></div>',
				(int) $latest['n'],
				esc_html( $latest['error'] ?? $job['probe_error'] ?? 'Unknown error.' )
			);
		}

		if ( $done ) {
			self::render_review( $job, $done );
		}
		if ( in_array( $job['state'], array( 'done', 'failed' ), true ) && empty( $job['probe_error'] ) ) {
			self::render_adjust( $job );
		}
		if ( $done && 'done' === $job['state'] ) {
			self::render_approval( $job, $done, $status );
		}
		self::render_attempts( $job );
		if ( 'work' !== $job['state'] ) {
			?>
			<form method="post" action="<?php echo esc_url( self::post_url() ); ?>" class="er-remove" data-er-confirm="Remove this job and all its attempts? Anything approved stays in Media.">
				<input type="hidden" name="action" value="encode_review_remove">
				<input type="hidden" name="job" value="<?php echo esc_attr( $job['id'] ); ?>">
				<?php wp_nonce_field( 'encode_review_job_' . $job['id'] ); ?>
				<button type="submit" class="button-link button-link-delete">Remove this job</button>
			</form>
			<?php
		}
	}

	private static function render_review( array $job, array $done ) {
		// phpcs:disable WordPress.Security.NonceVerification -- read-only view choice.
		$right_n = isset( $_GET['right'] ) ? (int) $_GET['right'] : (int) end( $done )['n'];
		$left_n  = isset( $_GET['left'] ) ? (int) $_GET['left'] : 0;
		// phpcs:enable
		$right = self::attempt( $job, $right_n );
		if ( ! $right || 'done' !== $right['status'] ) {
			$right   = end( $done );
			$right_n = (int) $right['n'];
		}
		$left = $left_n ? self::attempt( $job, $left_n ) : null;
		if ( $left_n && ( ! $left || 'done' !== $left['status'] ) ) {
			$left   = null;
			$left_n = 0;
		}
		$res = $right['results'];
		// When browsers do not reliably play the original, the left side is the
		// near-lossless reference copy, labelled as such. Scores and stills still
		// come from the original itself.
		$reference = ! empty( $job['reference']['file'] );
		$source    = $reference ? 'Reference copy' : 'Original';
		if ( $left ) {
			$left_src  = self::file_url( $job['id'], 'encode', $left_n );
			$left_name = sprintf( 'Attempt %d', $left_n );
		} else {
			$left_src  = self::file_url( $job['id'], $reference ? 'reference' : 'original' );
			$left_name = $reference ? 'Reference copy (near-lossless H.264 of the original)' : 'Original';
		}
		$right_name = sprintf( 'Attempt %d (CRF %d, cap %s Mbit/s)', $right_n, $right['crf'], self::mbps( $right['maxrate_k'] ) );
		?>
		<div class="er-card er-review">
			<h2>Compare</h2>
			<form method="get" class="er-pick">
				<input type="hidden" name="page" value="<?php echo esc_attr( self::PAGE ); ?>">
				<input type="hidden" name="job" value="<?php echo esc_attr( $job['id'] ); ?>">
				<label>Left <select name="left">
					<option value="0"><?php echo esc_html( $source ); ?></option>
					<?php foreach ( $done as $a ) : ?>
						<option value="<?php echo (int) $a['n']; ?>" <?php selected( $left_n, (int) $a['n'] ); ?>>Attempt <?php echo (int) $a['n']; ?></option>
					<?php endforeach; ?>
				</select></label>
				<label>Right <select name="right">
					<?php foreach ( $done as $a ) : ?>
						<option value="<?php echo (int) $a['n']; ?>" <?php selected( $right_n, (int) $a['n'] ); ?>>Attempt <?php echo (int) $a['n']; ?> (CRF <?php echo (int) $a['crf']; ?>)</option>
					<?php endforeach; ?>
				</select></label>
				<button class="button">Show</button>
			</form>

			<div class="er-player" data-er-player>
				<div class="er-toolbar">
					<button type="button" class="button button-primary" data-er-play>Play</button>
					<input type="range" min="0" max="1000" value="0" step="1" data-er-seek aria-label="Position">
					<span class="er-time" data-er-time>0:00</span>
					<label><input type="checkbox" data-er-wipe> Wipe</label>
					<button type="button" class="button" data-er-swap>Swap sides</button>
					<label><input type="checkbox" data-er-blind> Hide names</label>
					<label><input type="checkbox" data-er-mute checked> Mute</label>
				</div>
				<div class="er-stage-videos" data-er-videos>
					<figure class="er-side" data-er-side="a">
						<video preload="auto" playsinline muted src="<?php echo esc_url( $left_src ); ?>"></video>
						<figcaption data-er-name="<?php echo esc_attr( $left_name ); ?>"><?php echo esc_html( $left_name ); ?></figcaption>
					</figure>
					<figure class="er-side" data-er-side="b">
						<video preload="auto" playsinline muted src="<?php echo esc_url( self::file_url( $job['id'], 'encode', $right_n ) ); ?>"></video>
						<figcaption data-er-name="<?php echo esc_attr( $right_name ); ?>"><?php echo esc_html( $right_name ); ?></figcaption>
					</figure>
					<input type="range" class="er-wipe-handle" min="0" max="100" value="50" data-er-wipe-pos aria-label="Wipe position" hidden>
				</div>
				<p class="er-unplayable" data-er-unplayable hidden>Your browser cannot play one of these files. Tell the platform team which browser you use.</p>
			</div>
			<?php if ( $reference ) : ?>
				<p class="description er-reference-note">Browsers do not reliably play the original's format (<?php echo esc_html( (string) ( $job['probe']['vcodec'] ?? '' ) ); ?>), so the side marked "Reference copy" plays a near-lossless H.264 copy of it at its own size and frame rate. Quality scores and the stills compare against the original itself.</p>
			<?php elseif ( false === ( $job['original_playable'] ?? null ) ) : ?>
				<div class="notice notice-warning inline"><p>Browsers do not reliably play the original's format (<?php echo esc_html( (string) ( $job['probe']['vcodec'] ?? '' ) ); ?>), and there is no reference copy, so the left side may not play and approval is off until a redo makes the copy. <?php echo esc_html( $job['reference_error'] ?? '' ); ?></p></div>
			<?php endif; ?>

			<div class="er-columns">
				<div>
					<h3>Worst moments (attempt <?php echo (int) $right_n; ?>)</h3>
					<ol class="er-worst">
						<?php foreach ( $res['worst'] as $w ) : ?>
							<li><button type="button" class="button-link" data-er-jump="<?php echo esc_attr( $w['start'] ); ?>"><?php echo esc_html( self::clock( $w['start'] ) . '–' . self::clock( $w['end'] ) ); ?></button>
								VMAF <?php echo esc_html( number_format( $w['mean'], 1 ) ); ?> (lowest <?php echo esc_html( number_format( $w['worst_vmaf'], 1 ) ); ?> at <?php echo esc_html( self::clock( $w['worst_time'], true ) ); ?>)</li>
						<?php endforeach; ?>
					</ol>
				</div>
				<div>
					<h3>Numbers</h3>
					<?php self::render_numbers( $right ); ?>
				</div>
			</div>

			<?php self::render_advice( $res ); ?>

			<?php if ( ! empty( $res['stills'] ) ) : ?>
				<h3>Worst frames: original left, attempt <?php echo (int) $right_n; ?> right</h3>
				<?php foreach ( $res['stills'] as $still ) : ?>
					<figure class="er-still">
						<figcaption><button type="button" class="button-link" data-er-jump="<?php echo esc_attr( max( 0, $still['time'] - 1 ) ); ?>"><?php echo esc_html( self::clock( $still['time'], true ) ); ?></button> · VMAF <?php echo esc_html( number_format( $still['vmaf'], 1 ) ); ?></figcaption>
						<div class="er-still-pair">
							<a href="<?php echo esc_url( self::file_url( $job['id'], 'still', $right_n, basename( $still['original'] ) ) ); ?>" target="_blank" rel="noopener"><img loading="lazy" alt="Original" src="<?php echo esc_url( self::file_url( $job['id'], 'still', $right_n, basename( $still['original'] ) ) ); ?>"></a>
							<a href="<?php echo esc_url( self::file_url( $job['id'], 'still', $right_n, basename( $still['encode'] ) ) ); ?>" target="_blank" rel="noopener"><img loading="lazy" alt="Encode" src="<?php echo esc_url( self::file_url( $job['id'], 'still', $right_n, basename( $still['encode'] ) ) ); ?>"></a>
						</div>
					</figure>
				<?php endforeach; ?>
			<?php endif; ?>
		</div>
		<?php
	}

	private static function render_numbers( array $attempt ) {
		$r    = $attempt['results'];
		$rows = array(
			'Size'           => sprintf( '%s → %s (%s%% smaller)', size_format( $r['size_before'], 1 ), size_format( $r['size_after'], 1 ), number_format( 100 * $r['rule_553']['reduction'], 1 ) ),
			'Bitrate'        => sprintf( '%s → %s Mbit/s', self::mbps( $r['bit_rate_before'] / 1000 ), self::mbps( $r['bit_rate_after'] / 1000 ) ),
			'VMAF mean'      => number_format( $r['vmaf']['mean'], 2 ),
			'VMAF minimum'   => number_format( $r['vmaf']['min'], 2 ),
			'VMAF 1st pct'   => number_format( $r['vmaf']['p1'], 2 ),
			'Duration'       => sprintf( '%s s → %s s (%s)', $r['duration_before'], $r['duration_after'], $r['duration_match'] ? 'match' : 'MISMATCH' ),
			'Faststart'      => $r['faststart'] ? 'yes: plays before it fully downloads' : 'NO',
			'Settings'       => sprintf( 'CRF %d, cap %s Mbit/s, buffer %s Mbit', $attempt['crf'], self::mbps( $attempt['maxrate_k'] ), self::mbps( $attempt['bufsize_k'] ) ),
			'Time on server' => sprintf( '%s min (encode %s, score %s)', number_format( $r['timings']['total_s'] / 60, 1 ), number_format( $r['timings']['encode_s'] / 60, 1 ), number_format( $r['timings']['score_s'] / 60, 1 ) ),
		);
		echo '<table class="er-numbers"><tbody>';
		foreach ( $rows as $label => $value ) {
			printf( '<tr><th>%s</th><td>%s</td></tr>', esc_html( $label ), esc_html( $value ) );
		}
		echo '</tbody></table>';
	}

	private static function render_advice( array $res ) {
		$rule = $res['rule_553'];
		$ok   = $rule['smaller_enough'] && $rule['vmaf_enough'];
		printf(
			'<div class="er-advice %s"><p><strong>Advice only. You decide by eye.</strong> Past trailers did well when the encode was at least 15%% smaller and scored a VMAF mean of 90 or more.</p><ul><li>%s At least 15%% smaller: %s%%</li><li>%s VMAF mean 90 or more: %s</li></ul></div>',
			$ok ? 'er-advice-ok' : 'er-advice-check',
			$rule['smaller_enough'] ? '✓' : '✗',
			esc_html( number_format( 100 * $rule['reduction'], 1 ) ),
			$rule['vmaf_enough'] ? '✓' : '✗',
			esc_html( number_format( $res['vmaf']['mean'], 2 ) )
		);
	}

	private static function render_adjust( array $job ) {
		$last   = end( $job['attempts'] );
		$height = (int) ( $job['probe']['height'] ?? 0 );
		$crf    = (int) ( $last['crf'] ?? Encode_Review_Spool::CRF_DEFAULT );
		$caps   = $job['video_caps'] ?? null;
		$cap    = (int) ( $last['maxrate_k'] ?? Encode_Review_Spool::default_maxrate_k( $height, $caps ) );
		?>
		<div class="er-card er-adjust">
			<h2>Adjust and redo</h2>
			<form method="post" action="<?php echo esc_url( self::post_url() ); ?>">
				<input type="hidden" name="action" value="encode_review_redo">
				<input type="hidden" name="job" value="<?php echo esc_attr( $job['id'] ); ?>">
				<?php wp_nonce_field( 'encode_review_job_' . $job['id'] ); ?>
				<p><label>Quality (CRF): <output data-er-crf-out><?php echo (int) $crf; ?></output><br>
					<input type="range" name="crf" min="<?php echo (int) Encode_Review_Spool::CRF_MIN; ?>" max="<?php echo (int) Encode_Review_Spool::CRF_MAX; ?>" step="1" value="<?php echo (int) $crf; ?>" data-er-crf>
					<span class="description">Lower is better quality and a bigger file. 21 is the usual start.</span></label></p>
				<p><label>Bitrate cap (Mbit/s):
					<input type="number" name="maxrate_mbps" min="1" max="12" step="0.5" value="<?php echo esc_attr( self::mbps( $cap ) ); ?>" class="small-text">
					<span class="description">The default is <?php echo esc_html( self::mbps( Encode_Review_Spool::default_maxrate_k( $height, $caps ) ) ); ?> for this size. The buffer is always 4× the cap.</span></label></p>
				<button type="submit" class="button">Redo with these settings</button>
				<span class="description">Earlier attempts stay here to compare.</span>
			</form>
		</div>
		<?php
	}

	private static function render_approval( array $job, array $done, array $status ) {
		$attachment_id = self::approved_attachment( $job );
		echo '<div class="er-card er-approve"><h2>Approve</h2>';
		$block = $attachment_id ? null : self::review_block( $job );
		if ( $block ) {
			printf( '<p class="er-approve-blocked">%s</p></div>', esc_html( $block ) );
			return;
		}
		if ( ! $attachment_id ) {
			?>
			<form method="post" action="<?php echo esc_url( self::post_url() ); ?>" aria-describedby="er-approve-warning" data-er-confirm="Approve into Media? The original and every attempt are then deleted from this server; a redo needs a fresh upload.">
				<input type="hidden" name="action" value="encode_review_approve">
				<input type="hidden" name="job" value="<?php echo esc_attr( $job['id'] ); ?>">
				<?php wp_nonce_field( 'encode_review_job_' . $job['id'] ); ?>
				<label>Attempt <select name="attempt">
					<?php foreach ( array_reverse( $done ) as $a ) : ?>
						<option value="<?php echo (int) $a['n']; ?>">Attempt <?php echo (int) $a['n']; ?>: CRF <?php echo (int) $a['crf']; ?>, VMAF <?php echo esc_html( number_format( $a['results']['vmaf']['mean'], 1 ) ); ?>, <?php echo esc_html( size_format( $a['results']['size_after'], 1 ) ); ?></option>
					<?php endforeach; ?>
				</select></label>
				<button type="submit" class="button button-primary">Approve into Media</button>
				<p class="description">Adds the encode to this site's Media as <code><?php echo esc_html( pathinfo( $job['original']['name'], PATHINFO_FILENAME ) . '.mp4' ); ?></code>. WordPress adds -1 if the name is taken.</p>
				<p class="er-approve-warning" id="er-approve-warning"><strong>Approving deletes the original and every attempt from this server</strong> once the file is safely in Media. To redo it later, upload the master again (from Vimeo).</p>
			</form>
			<?php
			echo '</div>';
			return;
		}
		// Only when the spool copy could not be deleted at approval.
		printf(
			'<p>Approved attempt %d by %s. In Media as <a href="%s">%s</a>: use it in place of another video or send it to production from <a href="%s">its page</a>.</p></div>',
			(int) $job['approved']['attempt'],
			esc_html( $job['approved']['by'] ),
			esc_url( get_edit_post_link( $attachment_id ) ),
			esc_html( wp_basename( (string) get_attached_file( $attachment_id ) ) ),
			esc_url( self::approved_url( $attachment_id ) )
		);
	}

	/** An approved video: what it is, then "Use in place of…" and "Send to production". */
	private static function render_approved( $attachment_id ) {
		$meta = get_post_meta( $attachment_id, '_encode_review', true );
		printf( '<h2 class="er-title">%s</h2>', esc_html( wp_basename( (string) get_attached_file( $attachment_id ) ) ) );
		printf(
			'<p class="er-meta">In this site\'s Media as <a href="%s">attachment %d</a> · attempt %d of %s, CRF %s, VMAF %s, %s · approved by %s%s</p>',
			esc_url( get_edit_post_link( $attachment_id ) ),
			(int) $attachment_id,
			(int) ( $meta['attempt'] ?? 0 ),
			esc_html( $meta['original'] ?? '' ),
			esc_html( (string) ( $meta['crf'] ?? '' ) ),
			esc_html( isset( $meta['vmaf_mean'] ) ? number_format( (float) $meta['vmaf_mean'], 1 ) : '—' ),
			esc_html( isset( $meta['size_after'] ) ? size_format( (int) $meta['size_after'], 1 ) : '' ),
			esc_html( $meta['by'] ?? get_the_author_meta( 'user_login', (int) get_post_field( 'post_author', $attachment_id ) ) ),
			isset( $meta['at'] ) ? esc_html( ', ' . human_time_diff( (int) $meta['at'] ) . ' ago' ) : ''
		);
		echo '<p class="description">The original and attempts are deleted from this server. To redo, upload the master again.</p>';
		self::render_use_in_place( $attachment_id );
		self::render_send( $attachment_id, self::$spool->status() );
	}

	private static function render_use_in_place( $attachment_id ) {
		echo '<div class="er-card"><h2>Use in place of…</h2>';
		if ( ! Encode_Review_Fields::available() ) {
			echo '<p>Advanced Custom Fields is not active on this site.</p></div>';
			return;
		}
		$videos = Encode_Review_Fields::video_attachments( $attachment_id );
		?>
		<p>Pick the video this one replaces. The next page lists every field that uses it, and you choose which to change. Staging only.</p>
		<form method="get">
			<input type="hidden" name="page" value="<?php echo esc_attr( self::PAGE ); ?>">
			<input type="hidden" name="video" value="<?php echo (int) $attachment_id; ?>">
			<input type="hidden" name="view" value="swap">
			<label for="er-old">Video to replace</label>
			<select name="old" id="er-old" required>
				<option value="">Choose a video…</option>
				<?php foreach ( $videos as $video ) : ?>
					<option value="<?php echo (int) $video->ID; ?>"><?php echo esc_html( get_the_title( $video ) . ' — ' . wp_basename( (string) get_attached_file( $video->ID ) ) ); ?></option>
				<?php endforeach; ?>
			</select>
			<button class="button">List its fields</button>
		</form>
		</div>
		<?php
	}

	private static function render_send( $attachment_id, array $status ) {
		$production = new Encode_Review_Production( self::$spool, self::site() );
		$record     = $production->record( $attachment_id );
		$reason     = $production->block_reason( $attachment_id, $status, $record );
		$state      = $record['state'] ?? '';
		$try        = $record ? end( $record['tries'] ) : null;
		echo '<div class="er-card er-send"><h2>Send to production</h2>';
		echo '<p>Sends this one file to production Media. Nothing else moves: no posts, no fields. Afterwards, pick the file in the production field by hand.</p>';
		if ( 'sent' === $state ) {
			printf(
				'<p class="er-sent">✓ In production Media as attachment %d, sent by %s %s ago.%s</p>',
				(int) $record['production_id'],
				esc_html( $try['requested_by'] ?? '' ),
				esc_html( human_time_diff( (int) $record['sent_at'] ) ),
				! empty( $record['production_url'] ) ? ' <a href="' . esc_url( $record['production_url'] ) . '" target="_blank" rel="noopener">Open the file</a>' : ''
			);
			if ( 'found' === ( $try['outcome'] ?? '' ) ) {
				echo '<p class="description">The upload was cut off, then found in production Media, so it was not sent again.</p>';
			}
		} elseif ( 'failed' === $state ) {
			echo '<div class="notice notice-error inline"><p>The last send did not reach production: ' . esc_html( $try['error'] ?? 'Unknown error.' ) . '</p></div>';
		} elseif ( 'unknown' === $state ) {
			echo '<div class="notice notice-warning inline"><p><strong>Not sure the file reached production.</strong> ' . esc_html( $try['error'] ?? '' ) . '</p>';
			printf(
				'<p>The encoder looks for it in production Media %s. If it is there, this page shows it as sent; if not, you can send again. It never sends twice on its own.</p>',
				! empty( $record['check_after'] ) && (int) $record['check_after'] > time()
					? esc_html( 'in about ' . human_time_diff( (int) $record['check_after'] ) )
					: 'now'
			);
			if ( ! empty( $record['check_error'] ) ) {
				echo '<p>The last check could not reach production: ' . esc_html( $record['check_error'] ) . '. It tries again every few minutes. If this lasts, tell the platform team.</p>';
			}
			echo '</div>';
		}
		if ( $reason ) {
			if ( 'sent' !== $state && 'unknown' !== $state ) {
				echo '<p class="description">' . esc_html( $reason ) . '</p>';
			}
			if ( in_array( $state, array( 'queued', 'sending', 'unknown' ), true ) ) {
				echo '<div data-er-refresh="15"></div>';
			}
		} else {
			?>
			<form method="post" action="<?php echo esc_url( self::post_url() ); ?>" data-er-confirm="Send this file to production Media?">
				<input type="hidden" name="action" value="encode_review_send">
				<input type="hidden" name="video" value="<?php echo (int) $attachment_id; ?>">
				<?php wp_nonce_field( 'encode_review_send_' . $attachment_id ); ?>
				<button type="submit" class="button button-primary"><?php echo 'failed' === $state ? 'Send again' : 'Send to production Media'; ?></button>
			</form>
			<?php
		}
		echo '</div>';
	}

	private static function render_attempts( array $job ) {
		echo '<h2>Attempts</h2><table class="widefat striped er-attempts"><thead><tr><th>#</th><th>Settings</th><th>Status</th><th>Size</th><th>VMAF mean / min</th><th>Requested</th></tr></thead><tbody>';
		foreach ( array_reverse( $job['attempts'] ) as $a ) {
			$r = $a['results'] ?? null;
			printf(
				'<tr><td>%d</td><td>CRF %s, cap %s</td><td>%s</td><td>%s</td><td>%s</td><td>%s, %s ago</td></tr>',
				(int) $a['n'],
				esc_html( (string) ( $a['crf'] ?? Encode_Review_Spool::CRF_DEFAULT ) ),
				esc_html( isset( $a['maxrate_k'] ) ? self::mbps( $a['maxrate_k'] ) . ' Mbit/s' : 'default' ),
				esc_html( ucfirst( $a['status'] ) . ( ! empty( $a['error'] ) ? ': ' . $a['error'] : '' ) ),
				esc_html( $r ? size_format( $r['size_after'], 1 ) : '—' ),
				esc_html( $r ? number_format( $r['vmaf']['mean'], 2 ) . ' / ' . number_format( $r['vmaf']['min'], 2 ) : '—' ),
				esc_html( $a['requested_by'] ?? '' ),
				esc_html( human_time_diff( (int) ( $a['requested_at'] ?? time() ) ) )
			);
		}
		echo '</tbody></table>';
	}

	private static function render_swap( $new_id ) {
		$old_id = (int) ( $_GET['old'] ?? 0 ); // phpcs:ignore WordPress.Security.NonceVerification
		$picked = array_map( 'sanitize_text_field', (array) wp_unslash( $_GET['fields'] ?? array() ) ); // phpcs:ignore WordPress.Security
		$back   = self::approved_url( $new_id );
		if ( ! $new_id || ! $old_id || ! get_post( $old_id ) ) {
			echo '<p>Approve the job and choose a video first. <a href="' . esc_url( $back ) . '">Back</a></p>';
			return;
		}
		$refs = Encode_Review_Fields::references( $old_id );
		printf(
			'<h2>Use %s in place of %s</h2>',
			'<code>' . esc_html( wp_basename( (string) get_attached_file( $new_id ) ) ) . '</code>',
			'<code>' . esc_html( wp_basename( (string) get_attached_file( $old_id ) ) ) . '</code>'
		);
		if ( ! $refs ) {
			echo '<p>No field uses that video. Nothing to change. <a href="' . esc_url( $back ) . '">Back</a></p>';
			return;
		}
		$confirm = ! empty( $_GET['confirm'] ) && $picked; // phpcs:ignore WordPress.Security.NonceVerification
		if ( $confirm ) {
			$refs = array_values( array_filter( $refs, fn( $r ) => in_array( $r['post_id'] . '|' . $r['meta_key'], $picked, true ) && current_user_can( 'edit_post', $r['post_id'] ) ) );
			echo '<p><strong>Check before you confirm.</strong> These fields will point at the new video. Nothing else changes.</p>';
		} else {
			echo '<p>Tick the fields to change. The next step shows your choice again before anything is written.</p>';
		}
		?>
		<form method="<?php echo $confirm ? 'post' : 'get'; ?>" action="<?php echo esc_url( $confirm ? self::post_url() : admin_url( 'upload.php' ) ); ?>">
			<?php if ( $confirm ) : ?>
				<input type="hidden" name="action" value="encode_review_swap">
				<?php wp_nonce_field( 'encode_review_swap_' . $new_id ); ?>
			<?php else : ?>
				<input type="hidden" name="page" value="<?php echo esc_attr( self::PAGE ); ?>">
				<input type="hidden" name="view" value="swap">
				<input type="hidden" name="confirm" value="1">
			<?php endif; ?>
			<input type="hidden" name="video" value="<?php echo (int) $new_id; ?>">
			<input type="hidden" name="old" value="<?php echo (int) $old_id; ?>">
			<table class="widefat striped"><thead><tr><th></th><th>Post</th><th>Field</th><th>Meta key</th></tr></thead><tbody>
			<?php foreach ( $refs as $ref ) : ?>
				<?php $value = $ref['post_id'] . '|' . $ref['meta_key']; ?>
				<tr>
					<td><?php if ( ! current_user_can( 'edit_post', $ref['post_id'] ) ) : ?><span class="description">You cannot edit this post</span><?php elseif ( $confirm ) : ?><input type="hidden" name="fields[]" value="<?php echo esc_attr( $value ); ?>">✓<?php else : ?><input type="checkbox" name="fields[]" value="<?php echo esc_attr( $value ); ?>" aria-label="<?php echo esc_attr( sprintf( 'Change %s on %s', $ref['label'], $ref['post_title'] ) ); ?>" <?php checked( in_array( $value, $picked, true ) ); ?>><?php endif; ?></td>
					<td><a href="<?php echo esc_url( (string) get_edit_post_link( $ref['post_id'] ) ); ?>"><?php echo esc_html( $ref['post_title'] ); ?></a> <span class="description"><?php echo esc_html( $ref['post_type'] . ', ' . $ref['post_status'] ); ?></span></td>
					<td><?php echo esc_html( $ref['label'] ); ?></td>
					<td><code><?php echo esc_html( $ref['meta_key'] ); ?></code></td>
				</tr>
			<?php endforeach; ?>
			</tbody></table>
			<p>
				<?php if ( $confirm ) : ?>
					<button type="submit" class="button button-primary">Confirm: change <?php echo count( $refs ); ?> field(s)</button>
				<?php else : ?>
					<button type="submit" class="button button-primary">Review my choice</button>
				<?php endif; ?>
				<a class="button" href="<?php echo esc_url( $back ); ?>">Cancel</a>
			</p>
		</form>
		<?php
	}

	// ---- formatting ---------------------------------------------------------

	private static function mbps( $kbps ) {
		return rtrim( rtrim( number_format( (float) $kbps / 1000, 1, '.', '' ), '0' ), '.' );
	}

	private static function clock( $seconds, $tenths = false ) {
		$seconds = (float) $seconds;
		$minutes = (int) floor( $seconds / 60 );
		$rest    = $seconds - 60 * $minutes;
		return $tenths ? sprintf( '%d:%04.1f', $minutes, $rest ) : sprintf( '%d:%02d', $minutes, (int) floor( $rest ) );
	}
}
