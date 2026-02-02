const token = localStorage.getItem('token');
if (!token) window.location.href = '/auth/signin';

const $ = (id) => document.getElementById(id);

function _parseJwt(tokenStr) {
  try {
    const parts = String(tokenStr || '').split('.');
    if (parts.length < 2) return null;
    // base64url decode
    const b64 = parts[1].replace(/-/g, '+').replace(/_/g, '/');
    const pad = b64.length % 4 === 0 ? '' : '='.repeat(4 - (b64.length % 4));
    const json = atob(b64 + pad);
    return JSON.parse(json);
  } catch (_) {
    return null;
  }
}

const _jwt = _parseJwt(token);
const userEmail = typeof _jwt?.email === 'string' ? _jwt.email : '';
const userAvatarText = (userEmail || 'U').trim().slice(0, 1).toUpperCase();

const planOffers = [
  { key: 'free', name: 'Free', minutes: 600, tokens: 50000, requests: 200, summary: false },
  { key: 'pro', name: 'Pro', minutes: 1500, tokens: 500000, requests: 5000, summary: true },
  { key: 'pro_plus', name: 'Pro+', minutes: 6000, tokens: 2000000, requests: 20000, summary: true },
];

let dailyPoints = [];
let currentRoute = 'overview';
let chartRangeDays = 30;
let chartStart = null; // YYYY-MM-DD
let chartEnd = null;   // YYYY-MM-DD
// Date picker limits. We only cap max to today to avoid selecting future dates.
let minSelectableDay = null; // YYYY-MM-DD (optional; keep null to allow previous months)
let maxSelectableDay = null; // YYYY-MM-DD (today UTC)
let currentAuthSessionId = null; // string | null
let billingPeriodStartYmd = null; // YYYY-MM-DD (UTC)
let billingInfoLoaded = false;
let sessionsLoaded = 0;
let sessionsTotal = null;
const sessionsPageSize = 10;

function fmt(n) { return String(n ?? 0); }
function clampPct(v) { return Math.max(0, Math.min(100, v)); }
function ymdUTC(d) {
  const y = d.getUTCFullYear();
  const m = String(d.getUTCMonth() + 1).padStart(2, '0');
  const day = String(d.getUTCDate()).padStart(2, '0');
  return `${y}-${m}-${day}`;
}
function addDaysUTC(ymd, deltaDays) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(ymd || ''));
  if (!m) return null;
  const y = parseInt(m[1], 10);
  const mo = parseInt(m[2], 10);
  const d = parseInt(m[3], 10);
  const dt = new Date(Date.UTC(y, mo - 1, d, 0, 0, 0, 0));
  dt.setUTCDate(dt.getUTCDate() + (deltaDays || 0));
  return ymdUTC(dt);
}
function clampYmd(v, minV, maxV) {
  if (!v) return v;
  if (minV && v < minV) return minV;
  if (maxV && v > maxV) return maxV;
  return v;
}
function setDateInputs(startYmd, endYmd) {
  const s = $('dailyStart');
  const e = $('dailyEnd');
  if (s && minSelectableDay) s.min = minSelectableDay;
  if (e && minSelectableDay) e.min = minSelectableDay;
  if (s && maxSelectableDay) s.max = maxSelectableDay;
  if (e && maxSelectableDay) e.max = maxSelectableDay;
  if (s) s.value = startYmd || '';
  if (e) e.value = endYmd || '';
}

function showError(msg) {
  const e1 = $('errorBox');
  const e2 = $('errorBoxUsage');
  const e3 = $('errorBoxSpending');
  if (e1) { e1.textContent = msg; e1.style.display = 'block'; }
  if (e2) { e2.textContent = msg; e2.style.display = 'block'; }
  if (e3) { e3.textContent = msg; e3.style.display = 'block'; }
}

function clearErrors() {
  const e1 = $('errorBox');
  const e2 = $('errorBoxUsage');
  const e3 = $('errorBoxSpending');
  if (e1) e1.style.display = 'none';
  if (e2) e2.style.display = 'none';
  if (e3) e3.style.display = 'none';
}
