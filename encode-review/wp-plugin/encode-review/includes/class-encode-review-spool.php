<?php
/**
 * The WordPress side of the spool. Mirrors encode-review/worker/encode_review/spool.py:
 * every move and every job.json write happens under state.lock.
 */

defined( 'ABSPATH' ) || exit;

class Encode_Review_Spool {

	const STATES          = array( 'incoming', 'queue', 'work', 'done', 'failed' );
	const DISK_FLOOR      = 10737418240; // 10 GiB.
	// The largest original the tool takes. It arrives in parts of PART_SIZE, each
	// one short request well inside CloudFront's 30-second origin wait and the
	// sites' own request limits (nginx 600m, PHP 512M).
	const UPLOAD_LIMIT    = 5368709120; // 5 GiB.
	const PART_SIZE       = 67108864; // 64 MiB.
	const CRF_MIN         = 18;
	const CRF_MAX         = 26;
	const CRF_DEFAULT     = 21;
	const MAXRATE_MIN_K   = 1000;
	const MAXRATE_MAX_K   = 12000;
	const HEARTBEAT_STALE = 120;

	/** @var string */
	private $root;

	public function __construct( $root = ENCODE_REVIEW_SPOOL ) {
		$this->root = rtrim( $root, '/' );
	}

	public function root() {
		return $this->root;
	}

	public function path( $name ) {
		return $this->root . '/' . $name;
	}

	public function is_ready() {
		foreach ( array_merge( self::STATES, array( 'sends' ) ) as $dir ) {
			if ( ! is_dir( $this->path( $dir ) ) || ! is_writable( $this->path( $dir ) ) ) {
				return false;
			}
		}
		return true;
	}

	/**
	 * Runs a callback under the short state lock and returns its result.
	 */
	public function locked( callable $callback ) {
		$handle = fopen( $this->path( 'state.lock' ), 'c' );
		if ( ! $handle ) {
			throw new RuntimeException( 'The spool lock could not be opened.' );
		}
		try {
			flock( $handle, LOCK_EX );
			return $callback();
		} finally {
			flock( $handle, LOCK_UN );
			fclose( $handle );
		}
	}

	public static function valid_id( $id ) {
		return is_string( $id ) && 1 === preg_match( '/^[0-9]{8}-[0-9]{6}-[a-f0-9]{6}$/', $id );
	}

	/**
	 * @return array{0:string,1:string}|null State and folder of a job.
	 */
	public function find( $id ) {
		if ( ! self::valid_id( $id ) ) {
			return null;
		}
		foreach ( self::STATES as $state ) {
			$dir = $this->path( $state ) . '/' . $id;
			if ( is_dir( $dir ) ) {
				return array( $state, $dir );
			}
		}
		return null;
	}

	public function read_json( $file ) {
		$text = @file_get_contents( $file ); // phpcs:ignore WordPress.PHP.NoSilencedErrors
		if ( false === $text ) {
			return null;
		}
		$data = json_decode( $text, true );
		return is_array( $data ) ? $data : null;
	}

	public function write_json( $file, array $data ) {
		$tmp = dirname( $file ) . '/.' . basename( $file ) . '.' . getmypid() . '.tmp';
		$json = wp_json_encode( $data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE );
		if ( false === file_put_contents( $tmp, $json . "\n" ) ) {
			throw new RuntimeException( 'The spool could not be written.' );
		}
		chmod( $tmp, 0664 );
		if ( ! rename( $tmp, $file ) ) {
			@unlink( $tmp ); // phpcs:ignore WordPress.PHP.NoSilencedErrors
			throw new RuntimeException( 'The spool could not be written.' );
		}
	}

	public function load( $dir ) {
		return $this->read_json( $dir . '/job.json' );
	}

	/** Rewrites job.json and stamps the last activity. Call inside locked(). */
	public function save( $dir, array $job ) {
		$job['updated_at'] = time();
		$this->write_json( $dir . '/job.json', $job );
	}

	/** Moves a job folder to another state. Call inside locked(). */
	public function move( $dir, $state ) {
		$target = $this->path( $state ) . '/' . basename( $dir );
		if ( ! rename( $dir, $target ) ) {
			throw new RuntimeException( 'The job could not be moved.' );
		}
		return $target;
	}

	/**
	 * Every job of one site, with its state, newest first.
	 *
	 * @return array<int,array> Jobs with 'state' and 'dir' added.
	 */
	public function jobs( $site = null ) {
		$jobs = array();
		foreach ( array( 'queue', 'work', 'done', 'failed' ) as $state ) {
			foreach ( (array) glob( $this->path( $state ) . '/*', GLOB_ONLYDIR ) as $dir ) {
				$job = $this->load( $dir );
				if ( ! $job || ( $site && ( $job['site'] ?? '' ) !== $site ) ) {
					continue;
				}
				$job['state'] = $state;
				$job['dir']   = $dir;
				$jobs[]       = $job;
			}
		}
		usort(
			$jobs,
			function ( $a, $b ) {
				return ( $b['created_at'] ?? 0 ) <=> ( $a['created_at'] ?? 0 );
			}
		);
		return $jobs;
	}

	/**
	 * The queue in run order across both sites: the running job, then waiting ones.
	 *
	 * @return array<int,array>
	 */
	public function line() {
		$line = array();
		foreach ( (array) glob( $this->path( 'work' ) . '/*', GLOB_ONLYDIR ) as $dir ) {
			$job = $this->load( $dir );
			if ( $job ) {
				$job['state'] = 'work';
				$line[]       = $job;
			}
		}
		$waiting = array();
		foreach ( (array) glob( $this->path( 'queue' ) . '/*', GLOB_ONLYDIR ) as $dir ) {
			$job = $this->load( $dir );
			if ( $job ) {
				$job['state'] = 'queue';
				$waiting[]    = $job;
			}
		}
		usort(
			$waiting,
			function ( $a, $b ) {
				return array( $a['queued_at'] ?? 0, $a['id'] ) <=> array( $b['queued_at'] ?? 0, $b['id'] );
			}
		);
		return array_merge( $line, $waiting );
	}

	public function status() {
		$status = $this->read_json( $this->path( 'status.json' ) );
		if ( ! $status ) {
			return array( 'online' => false );
		}
		$status['online'] = ( time() - (int) ( $status['updated_at'] ?? 0 ) ) < self::HEARTBEAT_STALE;
		return $status;
	}

	public function free_bytes() {
		$free = @disk_free_space( $this->root ); // phpcs:ignore WordPress.PHP.NoSilencedErrors
		return false === $free ? 0 : (int) $free;
	}

	/** Why uploads are refused right now, or null when they are accepted. */
	public function upload_block_reason() {
		if ( ! $this->is_ready() ) {
			return 'The encode spool is not set up on this server.';
		}
		return $this->floor_reason( 0, 'New uploads' );
	}

	/**
	 * Why a new encode cannot be admitted, or null: free space, less what the
	 * admission still has to write, must stay above the floor.
	 *
	 * @param int    $to_write Bytes still to be written into the spool.
	 * @param string $what     "New uploads" or "A redo", for the message.
	 */
	public function floor_reason( $to_write, $what ) {
		$free = $this->free_bytes();
		if ( $free - $to_write < self::DISK_FLOOR ) {
			return sprintf(
				'The server has %s free, under the %s floor%s. %s wait until old jobs are cleaned up (7 days after their last activity) or removed.',
				size_format( $free, 1 ),
				size_format( self::DISK_FLOOR ),
				$to_write ? sprintf( ' once this file\'s %s is stored', size_format( $to_write, 1 ) ) : '',
				$what
			);
		}
		return null;
	}

	public static function default_maxrate_k( $height ) {
		return ( $height && $height <= 720 ) ? 3000 : 5000;
	}

	public static function clamp_crf( $crf ) {
		return max( self::CRF_MIN, min( self::CRF_MAX, (int) $crf ) );
	}

	public static function clamp_maxrate( $kbps ) {
		return max( self::MAXRATE_MIN_K, min( self::MAXRATE_MAX_K, (int) $kbps ) );
	}

	public static function new_id() {
		return gmdate( 'Ymd-His' ) . '-' . bin2hex( random_bytes( 3 ) );
	}

	// ---- uploads in parts ------------------------------------------------------
	//
	// incoming/<id>/ holds upload.json (who, what, how many bytes so far) and
	// original.<ext>.part. Each part appends at the offset the server last
	// confirmed, under the upload's own lock. When the bytes reach the announced
	// size, the file becomes original.<ext>, job.json is written and the folder
	// moves to queue/: only then does the worker see it. An upload idle for
	// 7 days goes with the worker's cleanup (upload.json's updated_at).

	/** An upload in progress, or null. */
	public function upload( $id ) {
		if ( ! self::valid_id( $id ) ) {
			return null;
		}
		return $this->read_json( $this->path( 'incoming' ) . '/' . $id . '/upload.json' );
	}

	/**
	 * Uploads still arriving, newest first.
	 *
	 * @return array<int,array>
	 */
	public function uploads( $site = null ) {
		$uploads = array();
		foreach ( (array) glob( $this->path( 'incoming' ) . '/*/upload.json' ) as $file ) {
			$upload = $this->read_json( $file );
			if ( $upload && ( ! $site || ( $upload['site'] ?? '' ) === $site ) ) {
				$uploads[] = $upload;
			}
		}
		usort( $uploads, fn( $a, $b ) => ( $b['updated_at'] ?? 0 ) <=> ( $a['updated_at'] ?? 0 ) );
		return $uploads;
	}

	/** Bytes that uploads still arriving have yet to write. */
	public function pending_upload_bytes( $except = '' ) {
		$bytes = 0;
		foreach ( $this->uploads() as $upload ) {
			if ( $upload['id'] !== $except ) {
				$bytes += max( 0, (int) $upload['size'] - (int) $upload['received'] );
			}
		}
		return $bytes;
	}

	/**
	 * Starts an upload, or picks up the same person's unfinished upload of the
	 * same file (name, size and modification time), so a reload or a lost
	 * connection resumes instead of starting over.
	 *
	 * @param array      $file   name, size, modified (ms since the epoch, from the browser).
	 * @param string     $site   Site key.
	 * @param WP_User    $user   Uploader.
	 * @param array|null $target The video field Approve swaps (Encode_Review_Fields::target()).
	 * @return array The upload record.
	 */
	public function start_upload( array $file, $site, $user, $target = null ) {
		if ( ! $this->is_ready() ) {
			throw new RuntimeException( 'The encode spool is not set up on this server.' );
		}
		$size = (int) $file['size'];
		if ( $size <= 0 ) {
			throw new RuntimeException( 'Choose a video file to upload.' );
		}
		if ( $size > self::UPLOAD_LIMIT ) {
			throw new RuntimeException( sprintf( 'This file is %s. The tool takes originals up to %s.', size_format( $size, 1 ), size_format( self::UPLOAD_LIMIT ) ) );
		}
		$name     = sanitize_file_name( wp_basename( (string) $file['name'] ) );
		$modified = (int) ( $file['modified'] ?? 0 );
		foreach ( $this->uploads( $site ) as $upload ) {
			if ( (int) $upload['uploader']['id'] === (int) $user->ID && $upload['name'] === $name
				&& (int) $upload['size'] === $size && (int) ( $upload['modified'] ?? 0 ) === $modified
				&& ( $upload['target'] ?? null ) == $target ) { // phpcs:ignore Universal.Operators.StrictComparisons -- same keys, any order.
				return $upload;
			}
		}
		// The whole file is still to be written, next to every other upload still
		// arriving, plus one part's temporary copy while it is received.
		$reason = $this->floor_reason( $size + self::PART_SIZE + $this->pending_upload_bytes(), 'New uploads' );
		if ( $reason ) {
			throw new RuntimeException( $reason );
		}
		$ext = strtolower( pathinfo( $name, PATHINFO_EXTENSION ) );
		// Any file may come in; the encoder's probe decides whether it is a video.
		// The stored name keeps a plain extension only.
		$ext = preg_match( '/^[a-z0-9]{1,8}$/', $ext ) ? $ext : 'bin';
		$id  = self::new_id();
		$dir = $this->path( 'incoming' ) . '/' . $id;
		if ( ! mkdir( $dir, 02775 ) ) {
			throw new RuntimeException( 'The upload folder could not be created.' );
		}
		chmod( $dir, 02775 );
		if ( false === file_put_contents( $dir . '/original.' . $ext . '.part', '' ) ) {
			self::rmtree( $dir );
			throw new RuntimeException( 'The upload could not be stored.' );
		}
		chmod( $dir . '/original.' . $ext . '.part', 0664 );
		$now    = time();
		$upload = array(
			'id'         => $id,
			'site'       => $site,
			'uploader'   => array(
				'id'    => (int) $user->ID,
				'login' => $user->user_login,
				'name'  => $user->display_name,
			),
			'name'       => $name,
			'file'       => 'original.' . $ext,
			'size'       => $size,
			'modified'   => $modified,
			'received'   => 0,
			'target'     => $target,
			'created_at' => $now,
			'updated_at' => $now,
		);
		$this->write_json( $dir . '/upload.json', $upload );
		return $upload;
	}

	/**
	 * Appends one part at $offset. A part the server already holds (its reply was
	 * lost) is acknowledged without writing it again; a part at any other offset
	 * is refused with the offset the server expects.
	 *
	 * @param string   $id     Upload id.
	 * @param int      $offset Where the part starts in the file.
	 * @param resource $input  The request body.
	 * @param int      $length The body's length.
	 * @param string   $site   Site key.
	 * @param WP_User  $user   The person sending it; only the uploader may.
	 * @return array{received:int,size:int,job?:string}
	 * @throws Encode_Review_Offset_Error When $offset is not where the file ends.
	 */
	public function append_part( $id, $offset, $input, $length, $site, $user ) {
		$done = $this->finished_upload( $id, $site );
		if ( $done ) {
			return $done;
		}
		$dir = $this->path( 'incoming' ) . '/' . $id;
		if ( ! self::valid_id( $id ) || ! is_dir( $dir ) ) {
			throw new RuntimeException( 'This upload is gone: it was removed, or nothing arrived for 7 days. Start it again.' );
		}
		$lock = fopen( $dir . '/upload.lock', 'c' );
		if ( ! $lock ) {
			throw new RuntimeException( 'The upload lock could not be opened.' );
		}
		try {
			flock( $lock, LOCK_EX );
			// Another request may have finished the upload while this one waited.
			$done = $this->finished_upload( $id, $site );
			if ( $done ) {
				return $done;
			}
			$upload = $this->upload( $id );
			if ( ! $upload || ( $upload['site'] ?? '' ) !== $site || (int) $upload['uploader']['id'] !== (int) $user->ID ) {
				throw new RuntimeException( 'This upload belongs to someone else.' );
			}
			$received = (int) $upload['received'];
			$size     = (int) $upload['size'];
			if ( $length > 0 && $offset + $length <= $received ) {
				// Sent again after a lost reply: those bytes are already stored once.
				return $received === $size ? $this->finish_upload( $dir, $upload ) : array( 'received' => $received, 'size' => $size );
			}
			if ( 0 === $length && $offset === $received && $received === $size ) {
				// Every byte is stored but the queue refused it (disk floor): an
				// empty part at the end, from a resume, asks again.
				return $this->finish_upload( $dir, $upload );
			}
			if ( $offset !== $received ) {
				throw new Encode_Review_Offset_Error( sprintf( 'The server has %d bytes of this upload; the next part starts there.', $received ), $received );
			}
			if ( $length <= 0 || $length > self::PART_SIZE ) {
				throw new RuntimeException( sprintf( 'A part must hold 1 to %d bytes.', self::PART_SIZE ) );
			}
			if ( $offset + $length > $size ) {
				throw new RuntimeException( sprintf( 'The parts add up to more than the %s announced for this file. Start the upload again.', size_format( $size, 1 ) ) );
			}
			// The rest of the file is still to be written.
			$reason = $this->floor_reason( $size - $received + $this->pending_upload_bytes( $id ), 'Uploads' );
			if ( $reason ) {
				throw new RuntimeException( $reason );
			}
			$part   = $dir . '/' . $upload['file'] . '.part';
			$handle = fopen( $part, 'c+b' );
			if ( ! $handle ) {
				throw new RuntimeException( 'The upload could not be stored.' );
			}
			// Anything past the confirmed bytes is a part cut off mid-write: drop it,
			// so every byte is stored exactly once.
			ftruncate( $handle, $received );
			fseek( $handle, $received );
			$copied = (int) stream_copy_to_stream( $input, $handle, $length );
			fflush( $handle );
			if ( $copied !== $length ) {
				ftruncate( $handle, $received );
				fclose( $handle );
				throw new RuntimeException( sprintf( 'The part arrived short (%d of %d bytes). It is sent again.', $copied, $length ) );
			}
			fclose( $handle );
			$upload['received']   = $received + $length;
			$upload['updated_at'] = time();
			$this->write_json( $dir . '/upload.json', $upload );
			if ( $upload['received'] === $size ) {
				return $this->finish_upload( $dir, $upload );
			}
			return array(
				'received' => $upload['received'],
				'size'     => $size,
			);
		} finally {
			flock( $lock, LOCK_UN );
			fclose( $lock );
		}
	}

	/** The reply for an upload that already became a job, or null. */
	private function finished_upload( $id, $site ) {
		$found = $this->find( $id );
		if ( ! $found || 'incoming' === $found[0] ) {
			return null;
		}
		$job = $this->load( $found[1] );
		if ( ! $job || ( $job['site'] ?? '' ) !== $site ) {
			return null;
		}
		return array(
			'received' => (int) $job['original']['size'],
			'size'     => (int) $job['original']['size'],
			'job'      => $id,
		);
	}

	/**
	 * Turns a complete upload into a queued job. Call under the upload's lock.
	 * Admission holds at the moment the job joins the queue; below the floor the
	 * bytes stay in incoming/ and the next try (or a resend of the last part)
	 * queues it.
	 */
	private function finish_upload( $dir, array $upload ) {
		$part   = $dir . '/' . $upload['file'] . '.part';
		$target = $dir . '/' . $upload['file'];
		clearstatcache();
		if ( is_file( $part ) && (int) filesize( $part ) !== (int) $upload['size'] ) {
			throw new RuntimeException( sprintf( 'The stored file has %d bytes, not the %d announced. Start the upload again.', (int) filesize( $part ), (int) $upload['size'] ) );
		}
		$now = time();
		$job = array(
			'id'         => $upload['id'],
			'site'       => $upload['site'],
			'uploader'   => $upload['uploader'],
			'original'   => array(
				'name' => $upload['name'],
				'file' => $upload['file'],
				'size' => (int) $upload['size'],
			),
			'stage'      => 'waiting',
			'attempts'   => array(
				array(
					'n'            => 1,
					'status'       => 'waiting',
					'crf'          => self::CRF_DEFAULT,
					'maxrate_k'    => null,
					'requested_at' => $now,
					'requested_by' => $upload['uploader']['login'],
				),
			),
			'created_at' => (int) $upload['created_at'],
			'queued_at'  => $now,
		);
		if ( ! empty( $upload['target'] ) ) {
			$job['target'] = $upload['target'];
		}
		$this->locked(
			function () use ( $dir, $part, $target, $job ) {
				$reason = $this->floor_reason( 0, 'New uploads' );
				if ( $reason ) {
					throw new RuntimeException( $reason . ' Every byte of the upload is stored and waits here: once space is back, choose the same file again to queue it without sending it again.' );
				}
				if ( is_file( $part ) && ! rename( $part, $target ) ) {
					throw new RuntimeException( 'The upload could not be stored.' );
				}
				$this->save( $dir, $job );
				@unlink( $dir . '/upload.json' ); // phpcs:ignore WordPress.PHP.NoSilencedErrors
				@unlink( $dir . '/upload.lock' ); // phpcs:ignore WordPress.PHP.NoSilencedErrors
				$this->move( $dir, 'queue' );
			}
		);
		return array(
			'received' => (int) $upload['size'],
			'size'     => (int) $upload['size'],
			'job'      => $upload['id'],
		);
	}

	/** Deletes an upload still arriving. */
	public function remove_upload( $id ) {
		$dir = $this->path( 'incoming' ) . '/' . $id;
		if ( ! self::valid_id( $id ) || ! is_dir( $dir ) ) {
			throw new RuntimeException( 'That upload is already gone.' );
		}
		$this->locked( fn() => self::rmtree( $dir ) );
	}

	/**
	 * Queues another attempt with new settings. Allowed when the job is done or failed.
	 */
	public function redo( $id, $crf, $maxrate_k, $user ) {
		return $this->locked(
			function () use ( $id, $crf, $maxrate_k, $user ) {
				$found = $this->find( $id );
				if ( ! $found || ! in_array( $found[0], array( 'done', 'failed' ), true ) ) {
					throw new RuntimeException( 'This job is already waiting or encoding.' );
				}
				// Every new attempt obeys the floor, checked where it is published.
				$reason = $this->floor_reason( 0, 'Redos' );
				if ( $reason ) {
					throw new RuntimeException( $reason );
				}
				$job = $this->load( $found[1] );
				$now = time();
				$job['attempts'][] = array(
					'n'            => count( $job['attempts'] ) + 1,
					'status'       => 'waiting',
					'crf'          => self::clamp_crf( $crf ),
					'maxrate_k'    => self::clamp_maxrate( $maxrate_k ),
					'requested_at' => $now,
					'requested_by' => $user->user_login,
				);
				$job['stage']     = 'waiting';
				$job['queued_at'] = $now;
				$this->save( $found[1], $job );
				$this->move( $found[1], 'queue' );
				return count( $job['attempts'] );
			}
		);
	}

	/** Deletes a job that is not running. */
	public function remove( $id ) {
		$this->locked(
			function () use ( $id ) {
				$found = $this->find( $id );
				if ( ! $found || 'work' === $found[0] ) {
					throw new RuntimeException( 'A running job cannot be removed. Wait for it to finish.' );
				}
				self::rmtree( $found[1] );
			}
		);
	}

	/** Applies a change to job.json of a finished job. */
	public function update_job( $id, callable $change ) {
		return $this->locked(
			function () use ( $id, $change ) {
				$found = $this->find( $id );
				if ( ! $found || 'work' === $found[0] ) {
					throw new RuntimeException( 'The job is not available right now.' );
				}
				$job    = $this->load( $found[1] );
				$result = $change( $job );
				$this->save( $found[1], $job );
				return $result;
			}
		);
	}

	public static function rmtree( $dir ) {
		$items = new RecursiveIteratorIterator(
			new RecursiveDirectoryIterator( $dir, FilesystemIterator::SKIP_DOTS ),
			RecursiveIteratorIterator::CHILD_FIRST
		);
		foreach ( $items as $item ) {
			$item->isDir() ? rmdir( $item->getPathname() ) : unlink( $item->getPathname() );
		}
		rmdir( $dir );
	}

	/**
	 * The spool-relative path of a file a viewer may play or see, or null.
	 *
	 * @param string $kind original|reference|encode|still.
	 */
	public function media_path( $id, $kind, $attempt = 0, $still = '' ) {
		$found = $this->find( $id );
		if ( ! $found ) {
			return null;
		}
		$job = $this->load( $found[1] );
		if ( ! $job ) {
			return null;
		}
		if ( 'original' === $kind ) {
			$relative = $job['original']['file'];
		} elseif ( 'reference' === $kind && ! empty( $job['reference']['file'] ) ) {
			$relative = $job['reference']['file'];
		} elseif ( 'encode' === $kind ) {
			$relative = 'attempts/' . (int) $attempt . '/encode.mp4';
		} elseif ( 'still' === $kind && preg_match( '/^[0-9]+-(original|encode)\.jpg$/', $still ) ) {
			$relative = 'attempts/' . (int) $attempt . '/stills/' . $still;
		} else {
			return null;
		}
		$full = $found[1] . '/' . $relative;
		if ( ! is_file( $full ) ) {
			return null;
		}
		return array(
			'relative' => $found[0] . '/' . $id . '/' . $relative,
			'full'     => $full,
		);
	}
}

/** A part sent at the wrong offset; carries the offset the server expects. */
class Encode_Review_Offset_Error extends RuntimeException {

	/** @var int */
	public $received;

	public function __construct( $message, $received ) {
		parent::__construct( $message );
		$this->received = (int) $received;
	}
}
