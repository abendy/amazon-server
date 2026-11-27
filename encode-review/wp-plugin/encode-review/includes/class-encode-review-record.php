<?php
/**
 * The file record: one post-meta entry per attachment, "_amzn_media", saying
 * where the file came from and where it went. The encode tool writes it at
 * approve and fills "production" once a send finishes (Encode_Review_Production
 * copies it in: WP-Cron, a read here, or the approved video's page); the image
 * tool, the upload check, sharing and the archive fill their own parts later.
 *
 *   source       "encode" (later "image" and "upload")
 *   original     name, size in bytes, SHA-256 of the original upload
 *   settings     the encode's CRF and cap (maxrate_k, kbit/s)
 *   check        empty until the upload check fills it
 *   shared_with  empty until sharing between sites fills it
 *   production   site, attachment ID and URL, once a send finishes
 *   archive      empty until the archive fills it
 *
 * The tool's own metas (_encode_review, _encode_review_send,
 * _encode_review_swaps) are written as before. An attachment approved before
 * the record existed has none stored: get() builds one from those metas on
 * read, with an empty SHA-256, and nothing is written back.
 */

defined( 'ABSPATH' ) || exit;

class Encode_Review_Record {

	const META = '_amzn_media';

	/** A record with every part present and empty. */
	public static function blank() {
		return array(
			'source'      => '',
			'original'    => array(
				'name'   => '',
				'size'   => 0,
				'sha256' => '',
			),
			'settings'    => array(),
			'check'       => array(),
			'shared_with' => array(),
			'production'  => array(),
			'archive'     => array(),
		);
	}

	/**
	 * An attachment's record: the stored one, or for an attachment this tool
	 * approved before the record existed, one built from its metas. Null when
	 * the attachment has neither.
	 *
	 * A stored record without "production" first takes a send that finished
	 * since the last sweep, so a reader never waits for WP-Cron or a page visit.
	 */
	public static function get( $attachment_id ) {
		$stored = get_post_meta( (int) $attachment_id, self::META, true );
		if ( is_array( $stored ) && empty( $stored['production'] ) ) {
			( new Encode_Review_Production( new Encode_Review_Spool(), Encode_Review_Admin::site() ) )->record( $attachment_id );
			$stored = get_post_meta( (int) $attachment_id, self::META, true );
		}
		if ( is_array( $stored ) ) {
			return array_replace( self::blank(), $stored );
		}
		$meta = get_post_meta( (int) $attachment_id, '_encode_review', true );
		if ( ! is_array( $meta ) ) {
			return null;
		}
		$record             = self::blank();
		$record['source']   = 'encode';
		$record['original'] = array(
			'name'   => (string) ( $meta['original'] ?? '' ),
			'size'   => (int) ( $meta['size_before'] ?? 0 ),
			'sha256' => '',
		);
		$record['settings'] = array(
			'crf'       => $meta['crf'] ?? null,
			'maxrate_k' => $meta['maxrate_k'] ?? null,
		);
		$send = get_post_meta( (int) $attachment_id, Encode_Review_Production::META, true );
		if ( is_array( $send ) && 'sent' === ( $send['status'] ?? '' ) ) {
			$record['production'] = array(
				'site'          => Encode_Review_Admin::site(),
				'attachment_id' => (int) $send['production_id'],
				'url'           => (string) ( $send['production_url'] ?? '' ),
			);
		}
		return $record;
	}

	/** Stores an attachment's record, every part present. */
	public static function save( $attachment_id, array $record ) {
		update_post_meta( (int) $attachment_id, self::META, array_replace( self::blank(), $record ) );
	}

	/**
	 * The record of an approved encode.
	 *
	 * @param array $original name, size, sha256 of the original upload.
	 * @param array $settings crf and maxrate_k of the approved attempt.
	 */
	public static function for_encode( array $original, array $settings ) {
		$record             = self::blank();
		$record['source']   = 'encode';
		$record['original'] = array_replace( $record['original'], $original );
		$record['settings'] = $settings;
		return $record;
	}

	/**
	 * Fills "production" on a stored record when a send finished. An
	 * attachment with no stored record keeps none: its record is built from
	 * _encode_review_send on read.
	 *
	 * @param array $production site, attachment_id, url.
	 */
	public static function set_production( $attachment_id, array $production ) {
		$stored = get_post_meta( (int) $attachment_id, self::META, true );
		if ( ! is_array( $stored ) || ( $stored['production'] ?? null ) === $production ) {
			return;
		}
		$stored['production'] = $production;
		self::save( $attachment_id, $stored );
	}
}
