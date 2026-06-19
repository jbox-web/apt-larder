(function () {
  'use strict';

  // ── Tab switching ────────────────────────────────────────────────────────
  document.querySelectorAll('nav button').forEach(btn => {
    btn.addEventListener('click', () => {
      document.querySelectorAll('nav button').forEach(b => b.classList.remove('active'));
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
      document.getElementById('stat-errors').textContent = s.errors.toLocaleString();
      document.getElementById('stat-reval').textContent = s.revalidations.toLocaleString();
      document.getElementById('stat-tunnels').textContent = (s.tunnels || 0).toLocaleString();
    } catch (e) { console.error('stats fetch failed', e); }
  }
  refreshStats();
  setInterval(refreshStats, 10000);

  // ── Cache browser — DataTables for search/sort/pagination ────────────────
  // Loads all entries once; DataTables handles client-side filtering.
  const dt = new DataTable('#cache-table', {
    columns: [
      { title: 'Key' },
      // Store raw bytes for correct numeric sort, display formatted string.
      { title: 'Size', render: { display: (d) => fmt(d), sort: (d) => d } },
      { title: 'Last modified' },
      { title: 'Type', searchable: false },
      { title: '', orderable: false, searchable: false }
    ],
    order: [[0, 'asc']],
    pageLength: 50,
    language: { emptyTable: 'Cache is empty.' }
  });

  async function loadCache() {
    const data = await apiFetch('GET', '/api/cache?per_page=5000');
    dt.clear();
    data.entries.forEach(e => {
      const mtime = new Date(e.mtime).toLocaleString();
      const badge = e.immutable
        ? '<span class="badge badge-immutable">immutable</span>'
        : '<span class="badge badge-index">index</span>';
      const btn = `<button class="btn btn-danger btn-sm" data-key="${encodeURIComponent(e.key)}">Invalidate</button>`;
      dt.row.add([e.key, e.size, mtime, badge, btn]);
    });
    dt.draw();
  }

  // Invalidate a single row without reloading the whole table.
  document.getElementById('cache-table').addEventListener('click', async ev => {
    const btn = ev.target.closest('[data-key]');
    if (!btn) return;
    if (!confirm('Invalidate ' + decodeURIComponent(btn.dataset.key) + '?')) return;
    await apiFetch('DELETE', '/api/cache/' + btn.dataset.key);
    dt.row(btn.closest('tr')).remove().draw();
  });

  document.getElementById('flush-all').addEventListener('click', async () => {
    if (!confirm('Flush the entire cache? This cannot be undone.')) return;
    const r = await apiFetch('DELETE', '/api/cache');
    alert('Deleted ' + r.deleted + ' entries.');
    dt.clear().draw();
  });

  // Load cache data when its tab is first shown.
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
