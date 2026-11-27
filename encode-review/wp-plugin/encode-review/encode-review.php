<?php
/**
 * Plugin Name: Encode review
 * Description: Media → Optimize video. Encode a raw trailer on staging, review it side by side, approve it into Media, and send single files to production. Installed on staging by amazon-server-converge.
 * Version: 1.3.0
 * Author: Amazon FYC platform
 *
 * The plugin lives in the _server repository (encode-review/wp-plugin/) and is
 * copied into each staging site's web/app/mu-plugins/encode-review/. The
 * queue worker (encode-review/worker/) does the encoding; both meet in the
 * spool folder.
 */

defined( 'ABSPATH' ) || exit;

// Staging only. Production never runs this tool, even if the files arrive there.
if ( defined( 'WP_ENV' ) && 'production' === WP_ENV ) {
	return;
}

if ( ! defined( 'ENCODE_REVIEW_SPOOL' ) ) {
	define( 'ENCODE_REVIEW_SPOOL', getenv( 'ENCODE_REVIEW_SPOOL' ) ?: '/srv/encode-review' );
}
// The nginx internal location that maps onto the spool (X-Accel-Redirect).
if ( ! defined( 'ENCODE_REVIEW_ACCEL_PREFIX' ) ) {
	define( 'ENCODE_REVIEW_ACCEL_PREFIX', '/_encode-review/' );
}

define( 'ENCODE_REVIEW_DIR', __DIR__ );
define( 'ENCODE_REVIEW_VERSION', '1.3.0' );

require_once __DIR__ . '/includes/class-encode-review-spool.php';
require_once __DIR__ . '/includes/class-encode-review-fields.php';
require_once __DIR__ . '/includes/class-encode-review-production.php';
require_once __DIR__ . '/includes/class-encode-review-record.php';
require_once __DIR__ . '/includes/class-encode-review-admin.php';

// Finished sends reach the attachment's metas through WP-Cron, not only admin pages.
add_action( 'plugins_loaded', array( 'Encode_Review_Production', 'boot' ) );

if ( is_admin() ) {
	add_action( 'plugins_loaded', array( 'Encode_Review_Admin', 'boot' ) );
}
