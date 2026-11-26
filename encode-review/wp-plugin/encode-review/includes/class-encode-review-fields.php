<?php
/**
 * "Use in place of…": the ACF file fields that point at a video attachment,
 * and the swap of the chosen ones to another attachment. Staging only.
 *
 * Each such field on the post edit screen also links into the tool with that
 * post and field chosen ("Encode a new version"); Approve then swaps that one
 * field (the job's target).
 *
 * ACF stores a file field as post meta: the field's meta key holds the
 * attachment ID, and "_<meta key>" holds the field key. Repeater rows use
 * keys like "videos_0_video".
 */

defined( 'ABSPATH' ) || exit;

class Encode_Review_Fields {

	public static function available() {
		return function_exists( 'acf_get_field' );
	}

	public static function boot() {
		add_action( 'acf/render_field/type=file', array( __CLASS__, 'render_link' ), 20 );
	}

	/** @var array<string,int> How many links each field and value got on this page. */
	private static $rendered = array();

	/**
	 * After an ACF file field that holds a video, on the post edit screen: a link
	 * into the tool with this post and field chosen.
	 */
	public static function render_link( $field ) {
		$screen = function_exists( 'get_current_screen' ) ? get_current_screen() : null;
		$post   = $GLOBALS['post'] ?? null;
		$value  = is_array( $field['value'] ?? null ) ? (int) ( $field['value']['ID'] ?? 0 ) : (int) ( $field['value'] ?? 0 );
		if ( ! $screen || 'post' !== $screen->base || ! $post instanceof WP_Post || ! $value
			|| ! current_user_can( 'upload_files' ) || ! current_user_can( 'edit_post', $post->ID )
			|| ! wp_attachment_is( 'video', $value ) ) {
			return;
		}
		$meta_key = self::rendered_meta_key( $post->ID, (string) ( $field['key'] ?? '' ), $value );
		if ( ! $meta_key ) {
			return;
		}
		printf(
			'<p class="er-field-link"><a href="%s" target="_blank" rel="noopener">Encode a new version<span class="screen-reader-text"> of this video (opens in a new tab)</span></a></p>',
			esc_url( self::link_url( $post->ID, $meta_key ) )
		);
	}

	public static function link_url( $post_id, $meta_key ) {
		return add_query_arg(
			array(
				'page' => 'encode-review',
				'for'  => (int) $post_id,
				'key'  => $meta_key,
			),
			admin_url( 'upload.php' )
		);
	}

	/**
	 * The saved meta key behind the field being rendered. ACF renders a field
	 * without its meta key, so this takes the post's meta rows that hold this
	 * field key and attachment, in row order, one per rendered field: two
	 * repeater rows with the same video still map to their own keys.
	 */
	private static function rendered_meta_key( $post_id, $field_key, $attachment_id ) {
		global $wpdb;
		if ( 0 !== strpos( $field_key, 'field_' ) ) {
			return null;
		}
		$keys = $wpdb->get_col(
			$wpdb->prepare(
				"SELECT meta_key FROM {$wpdb->postmeta} WHERE post_id = %d AND meta_value = %s AND meta_key NOT LIKE %s",
				$post_id,
				(string) $attachment_id,
				$wpdb->esc_like( '_' ) . '%'
			)
		);
		$keys = array_values( array_filter( $keys, fn( $key ) => get_post_meta( $post_id, '_' . $key, true ) === $field_key ) );
		natsort( $keys );
		$keys  = array_values( $keys );
		$count = $post_id . '|' . $field_key . '|' . $attachment_id;
		$index = self::$rendered[ $count ] ?? 0;
		self::$rendered[ $count ] = $index + 1;
		return $keys[ $index ] ?? null;
	}

	/**
	 * The field an upload is for, checked now: the person may edit the post, and
	 * the meta key is an ACF file field that holds a video.
	 *
	 * @return array{post_id:int,meta_key:string,old_id:int,label:string,post_title:string}
	 * @throws RuntimeException With the reason it cannot be used.
	 */
	public static function target( $post_id, $meta_key ) {
		$post_id  = (int) $post_id;
		$meta_key = (string) $meta_key;
		if ( ! self::available() ) {
			throw new RuntimeException( 'Advanced Custom Fields is not active on this site.' );
		}
		if ( ! $post_id || ! get_post( $post_id ) || ! current_user_can( 'edit_post', $post_id ) ) {
			throw new RuntimeException( 'You cannot edit that post, so the tool cannot swap its field.' );
		}
		$old_id = (int) get_post_meta( $post_id, $meta_key, true );
		if ( $old_id && wp_attachment_is( 'video', $old_id ) ) {
			foreach ( self::references( $old_id ) as $ref ) {
				if ( $ref['post_id'] === $post_id && $ref['meta_key'] === $meta_key ) {
					return array(
						'post_id'    => $post_id,
						'meta_key'   => $meta_key,
						'old_id'     => $old_id,
						'label'      => $ref['label'],
						'post_title' => $ref['post_title'],
					);
				}
			}
		}
		throw new RuntimeException( 'That field no longer holds a video. Open the post again and use its "Encode a new version" link.' );
	}

	/**
	 * The ACF file fields whose value is the attachment.
	 *
	 * @return array<int,array{post_id:int,meta_key:string,post_title:string,post_type:string,label:string}>
	 */
	public static function references( $attachment_id ) {
		global $wpdb;
		if ( ! self::available() ) {
			return array();
		}
		$rows = $wpdb->get_results(
			$wpdb->prepare(
				"SELECT pm.post_id, pm.meta_key FROM {$wpdb->postmeta} pm
				 INNER JOIN {$wpdb->posts} p ON p.ID = pm.post_id
				 WHERE pm.meta_value = %s AND pm.meta_key NOT LIKE %s
				 AND p.post_type NOT IN ('revision', 'attachment')
				 ORDER BY pm.post_id, pm.meta_key",
				(string) (int) $attachment_id,
				$wpdb->esc_like( '_' ) . '%'
			)
		);
		$found = array();
		foreach ( $rows as $row ) {
			$field_key = get_post_meta( (int) $row->post_id, '_' . $row->meta_key, true );
			if ( ! is_string( $field_key ) || 0 !== strpos( $field_key, 'field_' ) ) {
				continue;
			}
			$field = acf_get_field( $field_key );
			if ( ! $field || 'file' !== ( $field['type'] ?? '' ) ) {
				continue;
			}
			$post    = get_post( (int) $row->post_id );
			$found[] = array(
				'post_id'    => (int) $row->post_id,
				'meta_key'   => $row->meta_key,
				'post_title' => $post ? get_the_title( $post ) : '#' . $row->post_id,
				'post_type'  => $post ? $post->post_type : '',
				'post_status' => $post ? $post->post_status : '',
				'label'      => self::label( $field, $row->meta_key ),
			);
		}
		return $found;
	}

	/** "Videos › Video (row 2)" from the field and its parents. */
	public static function label( array $field, $meta_key ) {
		$parts  = array( $field['label'] ?: $field['name'] );
		$parent = $field['parent'] ?? 0;
		$guard  = 0;
		while ( $parent && $guard++ < 10 ) {
			$up = acf_get_field( $parent );
			if ( ! $up ) {
				break;
			}
			array_unshift( $parts, $up['label'] ?: $up['name'] );
			$parent = $up['parent'] ?? 0;
		}
		$label = implode( ' › ', $parts );
		if ( preg_match_all( '/_([0-9]+)_/', $meta_key, $rows ) && $rows[1] ) {
			$label .= ' (row ' . implode( ', ', array_map( fn( $n ) => (int) $n + 1, $rows[1] ) ) . ')';
		}
		return $label;
	}

	/**
	 * Points each chosen field at the new attachment, if it still holds the old one
	 * and the current user may edit its post. Every caller writes through here, so
	 * the permission is checked at the write, per post.
	 *
	 * @param array<int,string> $choices "post_id|meta_key" strings.
	 * @return array{swapped:array,skipped:array,denied:array} skipped: no longer
	 *         holds the old video (or never was a reference); denied: the user
	 *         cannot edit that post. Both untouched.
	 */
	public static function swap( $old_id, $new_id, array $choices ) {
		$allowed = array();
		foreach ( self::references( $old_id ) as $ref ) {
			$allowed[ $ref['post_id'] . '|' . $ref['meta_key'] ] = $ref;
		}
		$swapped = array();
		$skipped = array();
		$denied  = array();
		foreach ( $choices as $choice ) {
			if ( ! isset( $allowed[ $choice ] ) ) {
				$skipped[] = $choice;
				continue;
			}
			$ref = $allowed[ $choice ];
			if ( ! current_user_can( 'edit_post', $ref['post_id'] ) ) {
				$denied[] = $ref;
				continue;
			}
			if ( (string) get_post_meta( $ref['post_id'], $ref['meta_key'], true ) !== (string) $old_id ) {
				$skipped[] = $choice;
				continue;
			}
			update_post_meta( $ref['post_id'], $ref['meta_key'], (int) $new_id );
			$swapped[] = $ref;
		}
		if ( $swapped ) {
			$log   = (array) get_post_meta( $new_id, '_encode_review_swaps', true );
			$log[] = array(
				'from'   => (int) $old_id,
				'fields' => array_map( fn( $r ) => $r['post_id'] . '|' . $r['meta_key'], $swapped ),
				'by'     => wp_get_current_user()->user_login,
				'at'     => time(),
			);
			update_post_meta( $new_id, '_encode_review_swaps', array_values( array_filter( $log ) ) );
		}
		return array(
			'swapped' => $swapped,
			'skipped' => $skipped,
			'denied'  => $denied,
		);
	}

	/**
	 * Video attachments people may replace, newest first.
	 *
	 * @return WP_Post[]
	 */
	public static function video_attachments( $exclude = 0 ) {
		return get_posts(
			array(
				'post_type'      => 'attachment',
				'post_status'    => 'inherit',
				'post_mime_type' => 'video',
				'posts_per_page' => 300,
				'orderby'        => 'date',
				'order'          => 'DESC',
				'exclude'        => $exclude ? array( (int) $exclude ) : array(),
			)
		);
	}
}
