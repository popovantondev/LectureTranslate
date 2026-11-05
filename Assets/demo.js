/* Live demo on the landing page: German subtitles before and Russian subtitles after translation, same timecodes.
 * The cues and labels come from the JSON block #demo-data, which tools/build_presentation.py fills from
 * Tests/Fixtures/Beispiel.de.srt and Beispiel.ru.srt. The result is a prepared example, not a real translation.
 * Runs only in the page memory: no network, no storage. */
(function () {
  'use strict';
  var root = document.getElementById('demo');
  var dataNode = document.getElementById('demo-data');
  if (!root || !dataNode || root.getAttribute('data-demo') !== 'lecturetranslate') return;
  var body = root.querySelector('.ppk-demo-body');
  var data;
  try { data = JSON.parse(dataNode.textContent); } catch (err) { return; }
  if (!body || !data || !data.before || !data.after) return;
  var L = data.labels;
  var reduced = !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);

  function el(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = text;
    return n;
  }
  function field(label, value) {
    var f = el('div', 'ppk-field');
    f.appendChild(el('small', null, label));
    f.appendChild(document.createTextNode(value));
    return f;
  }

  /* translated cue by timecode: the pairs are matched by their identical timecodes */
  var afterByTime = {};
  data.after.forEach(function (c) { afterByTime[c.t] = c; });

  body.textContent = '';
  var side = el('div', 'ppk-demo-side');
  var main = el('div', 'ppk-demo-main');
  var translateBtn = el('button', 'ppk-btn ppk-btn-primary', L.translate);
  translateBtn.type = 'button';
  var resetBtn = el('button', 'ppk-btn', L.reset);
  resetBtn.type = 'button';
  resetBtn.disabled = true;
  side.appendChild(field(L.source, L.sourceName));
  side.appendChild(field(L.target, L.targetName));
  side.appendChild(translateBtn);
  side.appendChild(resetBtn);

  var head = el('div', 'demo-head');
  head.appendChild(el('span', null, L.before));
  head.appendChild(el('span', null, L.after));
  var list = el('ol', 'demo-cues');
  list.setAttribute('aria-label', L.cues);
  var msg = el('div', 'ppk-demo-empty', L.hint);
  msg.setAttribute('role', 'status');
  msg.setAttribute('aria-live', 'polite');
  msg.tabIndex = -1;
  main.appendChild(head);
  main.appendChild(list);
  main.appendChild(msg);
  body.appendChild(side);
  body.appendChild(main);

  var rows = data.before.map(function (cue) {
    var li = el('li');
    var time = el('button', 'demo-time');
    time.type = 'button';
    time.setAttribute('aria-pressed', 'false');
    time.setAttribute('aria-label', L.mark + ': ' + cue.t);
    time.appendChild(el('span', null, cue.n + ' · ' + cue.t));
    var badge = el('span', 'ppk-badge ppk-badge-ok', L.same);
    badge.hidden = true;
    time.appendChild(badge);
    var src = el('p', null, cue.x);
    src.lang = 'de';
    var dst = el('p', 'is-pending', L.pending);
    li.appendChild(time);
    li.appendChild(src);
    li.appendChild(dst);
    list.appendChild(li);
    time.addEventListener('click', function () {
      var on = !li.classList.contains('is-marked');
      li.classList.toggle('is-marked', on);
      time.setAttribute('aria-pressed', on ? 'true' : 'false');
    });
    return { cue: cue, li: li, dst: dst, badge: badge };
  });

  var timers = [];
  function later(fn, ms) { timers.push(setTimeout(fn, reduced ? 0 : ms)); }
  function cancelAll() { while (timers.length) clearTimeout(timers.pop()); }

  translateBtn.addEventListener('click', function () {
    cancelAll();
    translateBtn.disabled = true;
    resetBtn.disabled = false;
    resetBtn.focus();
    msg.className = 'ppk-demo-empty';
    msg.textContent = '';
    rows.forEach(function (r, i) {
      later(function () {
        var t = afterByTime[r.cue.t];
        r.dst.textContent = t ? t.x : '';
        r.dst.lang = 'ru';
        r.dst.className = '';
        r.badge.hidden = false;
        if (i === rows.length - 1) {
          msg.className = 'ppk-demo-empty ppk-demo-done';
          msg.textContent = L.done;
        }
      }, 250 * (i + 1));
    });
  });

  resetBtn.addEventListener('click', function () {
    cancelAll();
    rows.forEach(function (r) {
      r.dst.textContent = L.pending;
      r.dst.className = 'is-pending';
      r.dst.removeAttribute('lang');
      r.badge.hidden = true;
      r.li.classList.remove('is-marked');
      r.li.querySelector('.demo-time').setAttribute('aria-pressed', 'false');
    });
    resetBtn.disabled = true;
    translateBtn.disabled = false;
    msg.className = 'ppk-demo-empty';
    msg.textContent = L.hint;
    translateBtn.focus();
  });
})();
