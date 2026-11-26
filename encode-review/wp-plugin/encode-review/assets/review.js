/* Encode review admin page: upload progress, synced side-by-side playback,
 * wipe, swap sides, blind names, jump links and auto refresh. Plain JS. */
(function () {
  'use strict';

  function $(root, selector) { return root.querySelector(selector); }
  function $all(root, selector) { return Array.prototype.slice.call(root.querySelectorAll(selector)); }

  function clock(seconds) {
    var m = Math.floor(seconds / 60);
    var s = Math.floor(seconds - 60 * m);
    return m + ':' + (s < 10 ? '0' : '') + s;
  }

  function gib(bytes) {
    return (bytes / 1073741824).toFixed(1) + ' GB';
  }

  function minutes(seconds) {
    if (!isFinite(seconds) || seconds <= 0) { return ''; }
    return seconds < 90 ? 'under 2 min left' : 'about ' + Math.round(seconds / 60) + ' min left';
  }

  // Refuses a file over the size limit before contacting the server. Free
  // space is the server's call: only it knows how many bytes of this file it
  // already holds (a resume needs room for the rest only), and it answers the
  // start request before any part is sent.
  function uploadProblem(form, file) {
    var limit = parseFloat(form.getAttribute('data-er-limit')) || 0;
    if (!file) { return 'Choose a video file to upload.'; }
    if (limit && file.size > limit) {
      return 'This file is ' + gib(file.size) + '. The tool takes originals up to ' + gib(limit) + '.';
    }
    return '';
  }

  // ---- upload in parts --------------------------------------------------------
  // The file goes up in parts of the size the server names, each its own request,
  // so no request waits on a whole multi-GB body. The server answers each part
  // with the bytes it holds; that answer, not this script, decides where the
  // next part starts. A failed part is sent again after a pause; after several
  // failures the upload pauses with a Resume button. Choosing the same file
  // again (even after a reload) resumes it on the server.
  var RETRY_WAITS = [2, 5, 10, 20, 30];
  var uploading = false; // holds off the page's auto refresh

  $all(document, 'form.er-upload').forEach(function (form) {
    var bar = $(form, '.er-progress');
    var status = $(form, '.er-upload-status');
    var button = $(form, 'button[type=submit]');
    var resume = $(form, '[data-er-resume]');
    var input = $(form, 'input[type=file]');
    var nonce = form.getAttribute('data-er-nonce');
    var post = form.getAttribute('action');
    var job = null; // {file, id, received, size, partSize, failures, started, startBytes}
    var busy = false;

    function say(text) { status.textContent = text; }

    function finish(text) {
      busy = uploading = false;
      button.disabled = false;
      say(text);
    }

    function pause(text) {
      busy = uploading = false;
      resume.hidden = false;
      say(text + (job.received ? ' The server keeps the ' + gib(job.received) + ' it has.' : ' Nothing has reached the server yet.') +
        ' Resume when the connection is back.');
    }

    function show(loaded) {
      var done = job.received + loaded;
      var elapsed = (Date.now() - job.started) / 1000;
      var rate = elapsed > 5 ? (done - job.startBytes) / elapsed : 0;
      bar.hidden = false;
      bar.value = Math.floor(100 * done / job.size);
      say('Uploading… ' + bar.value + '% (' + gib(done) + ' of ' + gib(job.size) + ')' +
        (rate > 0 ? ', ' + minutes((job.size - done) / rate) : ''));
    }

    function reply(xhr) {
      try { return JSON.parse(xhr.responseText) || {}; } catch (err) { return {}; }
    }

    function retry(why) {
      job.failures += 1;
      if (job.failures > RETRY_WAITS.length) {
        pause('The upload paused: ' + why + '.');
        return;
      }
      var wait = RETRY_WAITS[job.failures - 1];
      say(why + '. Sending that part again in ' + wait + ' s (try ' + job.failures + ' of ' + RETRY_WAITS.length + ')…');
      window.setTimeout(sendPart, wait * 1000);
    }

    function sendPart() {
      var end = Math.min(job.size, job.received + job.partSize);
      var xhr = new XMLHttpRequest();
      xhr.open('POST', post + '?action=encode_review_upload_part&_wpnonce=' + encodeURIComponent(nonce) +
        '&upload=' + encodeURIComponent(job.id) + '&offset=' + job.received);
      xhr.setRequestHeader('Content-Type', 'application/octet-stream');
      xhr.timeout = 600000;
      xhr.upload.addEventListener('progress', function (e) { show(e.loaded); });
      xhr.addEventListener('load', function () {
        var data = reply(xhr);
        if (xhr.status === 200 && data.redirect) {
          busy = false;
          bar.value = 100;
          say('Uploaded. Opening the job…');
          window.location.href = data.redirect;
        } else if (xhr.status === 200 && typeof data.received === 'number') {
          job.received = data.received;
          job.failures = 0;
          sendPart();
        } else if (xhr.status === 409 && typeof data.received === 'number') {
          job.received = data.received; // the server's count wins
          sendPart();
        } else if (xhr.status === 400 || xhr.status === 403) {
          finish(data.error || 'The server refused the upload.');
        } else {
          retry('The server answered ' + xhr.status);
        }
      });
      xhr.addEventListener('error', function () { retry('The connection dropped'); });
      xhr.addEventListener('timeout', function () { retry('A part took over 10 minutes'); });
      xhr.send(job.file.slice(job.received, end));
    }

    function start(file) {
      var data = new FormData();
      data.append('action', 'encode_review_upload_start');
      data.append('_wpnonce', nonce);
      data.append('name', file.name);
      data.append('size', String(file.size));
      data.append('modified', String(file.lastModified || 0));
      $all(form, 'input[type=hidden]').forEach(function (field) { data.append(field.name, field.value); });
      var xhr = new XMLHttpRequest();
      xhr.open('POST', post);
      xhr.addEventListener('load', function () {
        var answer = reply(xhr);
        if (xhr.status !== 200 || !answer.upload) {
          finish(answer.error || 'The upload could not start (' + xhr.status + '). Try again.');
          return;
        }
        job = { file: file, id: answer.upload, received: answer.received, size: answer.size,
          partSize: answer.part_size, failures: 0, started: Date.now(), startBytes: answer.received };
        if (answer.received >= answer.size) {
          say('The server already has the whole file. Queuing it…');
        } else if (answer.received > 0) {
          say('Resuming: the server already has ' + gib(answer.received) + '.');
        }
        sendPart(); // with every byte stored, an empty part asks the server to queue the file
      });
      xhr.addEventListener('error', function () { finish('The upload could not start: the connection dropped. Try again.'); });
      xhr.send(data);
    }

    form.addEventListener('submit', function (event) {
      event.preventDefault();
      if (busy) { return; }
      var file = input.files && input.files[0];
      var problem = uploadProblem(form, file);
      if (problem) { say(problem); return; }
      busy = uploading = true;
      button.disabled = true;
      resume.hidden = true;
      say('Starting the upload…');
      start(file);
    });

    resume.addEventListener('click', function () {
      if (busy || !job) { return; }
      busy = uploading = true;
      resume.hidden = true;
      job.failures = 0;
      job.started = Date.now();
      job.startBytes = job.received;
      say('Resuming…');
      sendPart();
    });

    window.addEventListener('beforeunload', function (event) {
      if (busy) { event.preventDefault(); event.returnValue = ''; }
    });
  });

  // ---- confirm prompts ----------------------------------------------------
  $all(document, 'form[data-er-confirm]').forEach(function (form) {
    form.addEventListener('submit', function (event) {
      if (!window.confirm(form.getAttribute('data-er-confirm'))) { event.preventDefault(); }
    });
  });

  // ---- CRF readout ----------------------------------------------------------
  $all(document, '[data-er-crf]').forEach(function (input) {
    var out = $(input.form, '[data-er-crf-out]');
    input.addEventListener('input', function () { out.textContent = input.value; });
  });

  // ---- synced player --------------------------------------------------------
  var player = $(document, '[data-er-player]');
  var playing = false;
  if (player) {
    var box = $(player, '[data-er-videos]');
    var sides = $all(player, '.er-side');
    var videos = $all(player, 'video');
    var playBtn = $(player, '[data-er-play]');
    var seek = $(player, '[data-er-seek]');
    var time = $(player, '[data-er-time]');
    var wipe = $(player, '[data-er-wipe]');
    var wipePos = $(player, '[data-er-wipe-pos]');
    var blind = $(player, '[data-er-blind]');
    var mute = $(player, '[data-er-mute]');
    var lead = videos[0];

    var duration = function () {
      return Math.min.apply(null, videos.map(function (v) { return v.duration || Infinity; }));
    };
    var seekAll = function (t) {
      videos.forEach(function (v) { v.currentTime = t; });
    };

    playBtn.addEventListener('click', function () {
      if (playing) {
        videos.forEach(function (v) { v.pause(); });
      } else {
        seekAll(lead.currentTime);
        videos.forEach(function (v) { v.play().catch(function () {}); });
      }
      playing = !playing;
      playBtn.textContent = playing ? 'Pause' : 'Play';
    });

    // Keep the follower within a frame or two of the lead.
    lead.addEventListener('timeupdate', function () {
      var d = duration();
      if (isFinite(d) && d > 0) { seek.value = Math.round(1000 * lead.currentTime / d); }
      time.textContent = clock(lead.currentTime);
      videos.slice(1).forEach(function (v) {
        if (Math.abs(v.currentTime - lead.currentTime) > 0.08) { v.currentTime = lead.currentTime; }
      });
    });
    lead.addEventListener('ended', function () {
      playing = false;
      playBtn.textContent = 'Play';
    });
    seek.addEventListener('input', function () {
      var d = duration();
      if (isFinite(d)) { seekAll(d * seek.value / 1000); }
    });

    $all(document, '[data-er-jump]').forEach(function (btn) {
      btn.addEventListener('click', function () {
        seekAll(parseFloat(btn.getAttribute('data-er-jump')));
        player.scrollIntoView({ behavior: 'smooth', block: 'start' });
      });
    });

    // Wipe: both videos stacked, the right one clipped by the slider.
    var applyWipe = function () {
      box.classList.toggle('er-wiping', wipe.checked);
      wipePos.hidden = !wipe.checked;
      sides[1].style.clipPath = wipe.checked ? 'inset(0 0 0 ' + wipePos.value + '%)' : '';
    };
    wipe.addEventListener('change', applyWipe);
    wipePos.addEventListener('input', applyWipe);

    $(player, '[data-er-swap]').addEventListener('click', function () {
      box.classList.toggle('er-swapped');
      sides.reverse();
      applyWipe();
      sides[0].style.clipPath = '';
    });

    blind.addEventListener('change', function () {
      $all(player, 'figcaption').forEach(function (cap, i) {
        cap.textContent = blind.checked ? (i === 0 ? 'A' : 'B') : cap.getAttribute('data-er-name');
      });
    });

    mute.addEventListener('change', function () {
      // Sound from one side only, the original or left one, to avoid echo.
      videos[0].muted = mute.checked;
    });

    videos.forEach(function (v) {
      v.addEventListener('error', function () { $(player, '[data-er-unplayable]').hidden = false; });
    });
  }

  // ---- auto refresh while something is running -----------------------------
  var refresh = $(document, '[data-er-refresh]');
  if (refresh) {
    var seconds = parseInt(refresh.getAttribute('data-er-refresh'), 10) || 30;
    window.setInterval(function () {
      var busy = playing || uploading || (document.activeElement && /INPUT|SELECT|TEXTAREA/.test(document.activeElement.tagName));
      if (!busy && !document.hidden) { window.location.reload(); }
    }, seconds * 1000);
  }
})();
