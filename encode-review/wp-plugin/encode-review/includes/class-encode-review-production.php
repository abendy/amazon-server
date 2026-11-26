<?php
/**
 * Send to production: one approved attachment's file into production Media.
 *
 * Each staging attachment has one send record in the spool,
 * sends/<site>-<attachment id>/record.json (see encode-review/worker/encode_review/send.py
 * for the states). WordPress creates or reopens it under state.lock, so two
 * clicks cannot both start a send; the worker holds the production login and
 * does the upload, so PHP-FPM never reads it. Nothing else moves: no
 * database, fields or posts.
 *
 * The record is the decision. The attachment's "_encode_review_send" meta
 * keeps a copy of a finished send for the Media screens.
 */

defined( 'ABSPATH' ) || exit;

class Encode_Review_Production {

	const META    = '_encode_review_send';
	const RECORD  = 'record.json';
	const PAYLOAD = 'file.mp4';

	/** @var Encode_Review_Spool */
	private $spool;

	/** @var string */
	private $site;

	public function __construct( Encode_Review_Spool $spool, $site ) {
		$this->spool = $spool;
		$this->site  = $site;
	}

	private function dir( $attachment_id ) {
		return $this->spool->path( 'sends' ) . '/' . $this->site . '-' . (int) $attachment_id;
	}

	/** The send record of an attachment, or null when it was never sent. */
	public function record( $attachment_id ) {
		$record = $this->spool->read_json( $this->dir( $attachment_id ) . '/' . self::RECORD );
		if ( $record && 'sent' === ( $record['state'] ?? '' ) ) {
			$this->mirror( $attachment_id, $record );
		}
		return $record;
	}

	/** Copies a finished send onto the attachment, once. */
	private function mirror( $attachment_id, array $record ) {
		$meta = get_post_meta( $attachment_id, self::META, true );
		if ( is_array( $meta ) && ( $meta['production_id'] ?? 0 ) === (int) $record['production_id'] ) {
			return;
		}
		$try = end( $record['tries'] );
		update_post_meta(
			$attachment_id,
			self::META,
			array(
				'status'          => 'sent',
				'production_id'   => (int) $record['production_id'],
				'production_url'  => (string) ( $record['production_url'] ?? '' ),
				'production_host' => (string) ( $record['production_host'] ?? '' ),
				'sent_at'         => (int) ( $record['sent_at'] ?? time() ),
				'requested_by'    => (string) ( $try['requested_by'] ?? '' ),
			)
		);
	}

	/**
	 * Why this attachment cannot be sent now, or null.
	 *
	 * @param array|null $record The current send record.
	 */
	public function block_reason( $attachment_id, array $status, $record = null ) {
		$state = $record['state'] ?? '';
		if ( 'sent' === $state ) {
			return sprintf( 'Already in production Media (attachment %d).', (int) $record['production_id'] );
		}
		if ( in_array( $state, array( 'queued', 'sending' ), true ) ) {
			return 'Sending now. This page updates when production answers.';
		}
		if ( 'unknown' === $state ) {
			return 'The last send was cut off, so it may have reached production. The encoder checks production Media before anything is sent again.';
		}
		$meta = get_post_meta( $attachment_id, self::META, true );
		if ( is_array( $meta ) && 'sent' === ( $meta['status'] ?? '' ) ) {
			return sprintf( 'Already in production Media (attachment %d).', (int) $meta['production_id'] );
		}
		if ( empty( $status['send_configured'][ $this->site ] ) ) {
			return 'Send to production is not set up yet: the production upload login is missing on this server.';
		}
		$file = get_attached_file( $attachment_id );
		if ( ! $file || ! is_file( $file ) ) {
			return 'The attachment file is missing.';
		}
		return null;
	}

	/**
	 * Queues a send: a first send, or a new try after a known failure.
	 *
	 * The file is copied outside the lock; the decision is made under it, so of
	 * two concurrent clicks exactly one queues a send.
	 */
	public function queue( $attachment_id, WP_User $user ) {
		$status = $this->spool->status();
		$reason = $this->block_reason( $attachment_id, $status, $this->record( $attachment_id ) );
		if ( $reason ) {
			throw new RuntimeException( $reason );
		}
		$source = get_attached_file( $attachment_id );
		$tmp    = $this->spool->path( 'sends' ) . '/.new-' . Encode_Review_Spool::new_id();
		if ( ! mkdir( $tmp, 02775 ) || ! copy( $source, $tmp . '/' . self::PAYLOAD ) ) {
			if ( is_dir( $tmp ) ) {
				Encode_Review_Spool::rmtree( $tmp );
			}
			throw new RuntimeException( 'The file could not be staged for sending.' );
		}
		chmod( $tmp, 02775 );
		chmod( $tmp . '/' . self::PAYLOAD, 0664 );

		$dir = $this->dir( $attachment_id );
		try {
			$this->spool->locked(
				function () use ( $attachment_id, $user, $source, $tmp, $dir ) {
					$record = $this->spool->read_json( $dir . '/' . self::RECORD );
					$state  = $record['state'] ?? '';
					if ( $record && 'failed' !== $state ) {
						throw new RuntimeException( $this->block_reason( $attachment_id, array(), $record ) ?: 'A send is already recorded.' );
					}
					$tries = $record['tries'] ?? array();
					$n     = count( $tries ) + 1;
					$now   = time();
					$tries[] = array(
						'n'            => $n,
						'token'        => sprintf( 'er-%s-%d-%d-%s', $this->site, $attachment_id, $n, bin2hex( random_bytes( 4 ) ) ),
						'requested_by' => $user->user_login,
						'requested_at' => $now,
					);
					$next = array(
						'site'                  => $this->site,
						'staging_attachment_id' => (int) $attachment_id,
						'filename'              => wp_basename( $source ),
						'mime'                  => get_post_mime_type( $attachment_id ) ?: 'video/mp4',
						'title'                 => get_the_title( $attachment_id ),
						'state'                 => 'queued',
						'tries'                 => $tries,
						'updated_at'            => $now,
					);
					if ( $record ) {
						// A new try on a known failure: the file copy moves in beside the record.
						if ( ! rename( $tmp . '/' . self::PAYLOAD, $dir . '/' . self::PAYLOAD ) ) {
							throw new RuntimeException( 'The file could not be staged for sending.' );
						}
						$this->spool->write_json( $dir . '/' . self::RECORD, $next );
						return;
					}
					// The first send: the folder appears whole, record and file together.
					$this->spool->write_json( $tmp . '/' . self::RECORD, $next );
					if ( ! rename( $tmp, $dir ) ) {
						throw new RuntimeException( 'The send could not be recorded.' );
					}
				}
			);
		} finally {
			if ( is_dir( $tmp ) ) {
				Encode_Review_Spool::rmtree( $tmp );
			}
		}
	}
}
