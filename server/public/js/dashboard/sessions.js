function formatLocalDateTime(v) {
  try {
    const d = new Date(v);
    if (!Number.isFinite(d.getTime())) return String(v || '');
    return d.toLocaleString();
  } catch (_) {
    return String(v || '');
  }
}

function updateSessionsShowMore() {
  const btn = $('sessionsShowMoreBtn');
  if (!btn) return;
  if (typeof sessionsTotal === 'number' && sessionsTotal > sessionsLoaded) {
    btn.style.display = 'inline-flex';
    btn.textContent = 'Show more';
  } else {
    btn.style.display = 'none';
  }
}

function _buildSessionRow(s, currentId, errEl) {
  const row = document.createElement('div');
  row.className = 'sessionRow';

  const meta = document.createElement('div');
  meta.className = 'sessionMeta';

  const title = document.createElement('div');
  title.className = 'sessionTitle';
  const label = document.createElement('span');
  const ct = String(s.clientType || '').toLowerCase();
  const typeLabel =
    ct === 'web' ? 'Web' :
      ct === 'desktop' ? 'Desktop app' :
        ct === 'mobile' ? 'Mobile app' :
          'Session';
  label.textContent = typeLabel;
  title.appendChild(label);

  const isCurrent = currentId && s.id && String(s.id) === currentId;
  const isRevoked = !!s.revokedAt;

  if (isCurrent) {
    const b = document.createElement('span');
    b.className = 'badgeSmall badgeCurrent';
    b.textContent = 'Current';
    title.appendChild(b);
  }
  if (isRevoked) {
    const b = document.createElement('span');
    b.className = 'badgeSmall badgeRevoked';
    b.textContent = 'Revoked';
    title.appendChild(b);
  }

  const sub = document.createElement('div');
  sub.className = 'sessionSub';
  sub.textContent = 'Last active: ' + formatLocalDateTime(s.lastSeenAt);

  meta.appendChild(title);
  meta.appendChild(sub);

  const actions = document.createElement('div');
  actions.className = 'sessionActions';
  const btn = document.createElement('button');
  btn.className = 'btn btn-sm btn-revoke';
  btn.textContent = 'Sign out';
  btn.disabled = isRevoked || !s.id;
  btn.addEventListener('click', async () => {
    try {
      btn.disabled = true;
      const rr = await fetch('/api/auth/sessions/' + encodeURIComponent(String(s.id)) + '/revoke', {
        method: 'POST',
        headers: { 'Authorization': 'Bearer ' + token }
      });
      const dd = await rr.json().catch(() => ({}));
      if (!rr.ok) throw new Error(dd.error || dd.message || ('HTTP ' + rr.status));
      // If the user revoked the current session, sign out immediately.
      if (currentAuthSessionId && String(s.id) === String(currentAuthSessionId)) {
        localStorage.removeItem('token');
        window.location.href = '/auth/signin';
        return;
      }
      await loadAuthSessions({ append: false });
    } catch (e) {
      if (errEl) {
        errEl.textContent = String(e.message || e);
        errEl.style.display = 'block';
      }
      const msg = String(e && (e.message || e) || '');
      if (msg.includes('revoked') || msg.includes('401')) {
        localStorage.removeItem('token');
        window.location.href = '/auth/signin';
        return;
      }
      await loadAuthSessions({ append: false });
    }
  });

  actions.appendChild(btn);
  row.appendChild(meta);
  row.appendChild(actions);
  return row;
}

async function loadAuthSessions(opts) {
  const append = !!(opts && opts.append);
  const box = $('sessionsList');
  const errEl = $('sessionsError');
  if (errEl) errEl.style.display = 'none';
  const showMoreBtn = $('sessionsShowMoreBtn');
  if (!append) {
    sessionsLoaded = 0;
    sessionsTotal = null;
    if (box) box.textContent = 'Loading…';
  } else {
    if (showMoreBtn) showMoreBtn.disabled = true;
  }
  try {
    const skip = append ? sessionsLoaded : 0;
    const url = '/api/auth/sessions?limit=' + encodeURIComponent(String(sessionsPageSize)) +
      '&skip=' + encodeURIComponent(String(skip));
    const res = await fetch(url, {
      headers: { 'Authorization': 'Bearer ' + token }
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.error || data.message || ('HTTP ' + res.status));

    const currentId = data.currentSessionId ? String(data.currentSessionId) : null;
    currentAuthSessionId = currentId;
    const total = typeof data.total === 'number' ? data.total : null;
    sessionsTotal = total;
    const sessions = Array.isArray(data.sessions) ? data.sessions : [];

    if (!box) return;
    if (!append) box.innerHTML = '';
    if (!append && sessions.length === 0) {
      const empty = document.createElement('div');
      empty.className = 'placeholder';
      empty.textContent = 'No sessions found yet.';
      box.appendChild(empty);
      updateSessionsShowMore();
      return;
    }

    sessions.forEach((s) => {
      box.appendChild(_buildSessionRow(s, currentId, errEl));
    });
    sessionsLoaded += sessions.length;
    updateSessionsShowMore();
  } catch (e) {
    if (errEl) {
      errEl.textContent = String(e.message || e);
      errEl.style.display = 'block';
    }
    if (!append && box) box.textContent = '';
    updateSessionsShowMore();
  } finally {
    if (showMoreBtn) showMoreBtn.disabled = false;
  }
}
