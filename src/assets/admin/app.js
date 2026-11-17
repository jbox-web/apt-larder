(function () {
  'use strict';

  // ── Tab switching ────────────────────────────────────────────────────────
  document.querySelectorAll('aside nav button').forEach(btn => {
    btn.addEventListener('click', () => {
      document.querySelectorAll('aside nav button').forEach(b => b.classList.remove('active'));
      document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
      btn.classList.add('active');
      document.getElementById(btn.dataset.tab).classList.add('active');
    });
  });

  // ── Utilities ────────────────────────────────────────────────────────────
  function fmt(bytes) {
    if (bytes >= 1e9) return (bytes / 1e9).toFixed(1) + ' GB';
    if (bytes >= 1e6) return (bytes / 1e6).toFixed(1) + ' MB';
    if (bytes >= 1e3) return (bytes / 1e3).toFixed(1) + ' KB';
    return bytes + ' B';
  }

  async function apiFetch(method, path, body) {
    const opts = { method, headers: { 'Content-Type': 'application/json' } };
    if (body !== undefined) opts.body = JSON.stringify(body);
    const res = await fetch(path, opts);
    if (res.status === 204) return null;
    return res.json();
  }

  // ── Dashboard — auto-refreshes every 10 s ────────────────────────────────
  // Populate version tag in sidebar footer once on load.
  apiFetch('GET', '/api/health').then(h => {
    const el = document.getElementById('server-version');
    if (el && h) el.textContent = 'v' + h.version;
  }).catch(() => {});

  async function refreshStats() {
    try {
      const s = await apiFetch('GET', '/api/stats');
      const total = s.hits + s.misses;
      const rate = total > 0 ? ((s.hits / total) * 100).toFixed(1) : '0.0';
      document.getElementById('stat-hits').textContent = s.hits.toLocaleString();
      document.getElementById('stat-misses').textContent = s.misses.toLocaleString();
      document.getElementById('stat-rate').textContent = rate + '%';
      document.getElementById('stat-bytes').textContent = fmt(s.bytes);
      document.getElementById('stat-cache-bytes').textContent = fmt(s.cache_bytes || 0);
      document.getElementById('stat-errors').textContent = s.errors.toLocaleString();
      document.getElementById('stat-reval').textContent = s.revalidations.toLocaleString();
      document.getElementById('stat-tunnels').textContent = (s.tunnels || 0).toLocaleString();
    } catch (e) { console.error('stats fetch failed', e); }
  }
  refreshStats();
  setInterval(refreshStats, 10000);

  // ── Cache browser — DataTables with server-side processing ───────────────
  // Each page, sort or search is one /api/cache request, so the browser only
  // ever holds the page on screen and the table covers the whole cache.
  const SORT_COLUMNS = ['key', 'size', 'mtime'];

  async function fetchCachePage(req, callback) {
    const order = req.order[0] || { column: 0, dir: 'asc' };
    const params = new URLSearchParams({
      page: Math.floor(req.start / req.length) + 1,
      per_page: req.length,
      search: req.search.value,
      sort: SORT_COLUMNS[order.column] || 'key',
      order: order.dir
    });
    try {
      const data = await apiFetch('GET', '/api/cache?' + params);
      callback({
        draw: req.draw,
        recordsTotal: data.total,
        recordsFiltered: data.total,
        data: data.entries
      });
    } catch (e) {
      console.error('cache fetch failed', e);
      callback({ draw: req.draw, recordsTotal: 0, recordsFiltered: 0, data: [] });
    }
  }

  const dt = new DataTable('#cache-table', {
    serverSide: true,
    ajax: fetchCachePage,
    columns: [
      // Keys come from request paths: render them as text, never as HTML.
      { title: 'Key', data: 'key', render: DataTable.render.text() },
      { title: 'Size', data: 'size', render: (d) => fmt(d) },
      { title: 'Last modified', data: 'mtime', render: (d) => new Date(d).toLocaleString() },
      { title: 'Type', data: 'immutable', orderable: false, searchable: false,
        render: (d) => d
          ? '<span class="badge badge-immutable">immutable</span>'
          : '<span class="badge badge-index">index</span>' },
      { title: '', data: 'key', orderable: false, searchable: false,
        render: (d) => `<button class="btn btn-danger btn-sm" data-key="${encodeURIComponent(d)}">Invalidate</button>` }
    ],
    order: [[0, 'asc']],
    pageLength: 50,
    // The API caps per_page at 200: keep every choice at or below it.
    lengthMenu: [10, 25, 50, 100, 200],
    searchDelay: 300,
    language: { emptyTable: 'Cache is empty.' }
  });

  // Re-fetches the current page, keeping the paging position.
  function loadCache() {
    dt.draw(false);
  }

  // Invalidate a single entry, then refresh the page it was on.
  document.getElementById('cache-table').addEventListener('click', async ev => {
    const btn = ev.target.closest('[data-key]');
    if (!btn) return;
    if (!confirm('Invalidate ' + decodeURIComponent(btn.dataset.key) + '?')) return;
    await apiFetch('DELETE', '/api/cache/' + btn.dataset.key);
    loadCache();
  });

  document.getElementById('flush-all').addEventListener('click', async () => {
    if (!confirm('Flush the entire cache? This cannot be undone.')) return;
    const r = await apiFetch('DELETE', '/api/cache');
    alert('Deleted ' + r.deleted + ' entries.');
    loadCache();
  });

  // Refresh cache data whenever its tab is shown.
  document.querySelector('[data-tab="tab-cache"]').addEventListener('click', () => loadCache());

  // ── Actions ──────────────────────────────────────────────────────────────
  document.getElementById('evict-form').addEventListener('submit', async e => {
    e.preventDefault();
    const days = parseInt(document.getElementById('evict-days').value, 10) || 30;
    const r = await apiFetch('POST', '/api/evict', { max_age_days: days });
    const el = document.getElementById('evict-result');
    el.style.display = 'block';
    el.textContent = `✓ Evicted ${r.deleted} files — freed ${fmt(r.freed_bytes)}.`;
    // Reload cache tab if it's visible to reflect evicted entries.
    if (document.getElementById('tab-cache').classList.contains('active')) loadCache();
  });
}());
