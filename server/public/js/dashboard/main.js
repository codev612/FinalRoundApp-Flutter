function routeMeta(route) {
  switch (route) {
    case 'overview': return { title: 'Overview', sub: 'Plan snapshot and quick actions' };
    case 'usage': return { title: 'Usage', sub: 'Plan, limits, and usage details' };
    case 'profile': return { title: 'Profile', sub: 'Update your account details' };
    case 'settings': return { title: 'Settings', sub: 'Preferences and account settings' };
    case 'spending': return { title: 'Spending', sub: 'Costs and usage spend' };
    case 'billing': return { title: 'Billing & invoices', sub: 'Payment method and invoices' };
    case 'docs': return { title: 'Docs', sub: 'Product and API documentation' };
    case 'contact': return { title: 'Contact us', sub: 'Get help from support' };
    default: return { title: 'Overview', sub: 'Plan snapshot and quick actions' };
  }
}

function setRoute(route) {
  const r = route || 'overview';
  currentRoute = r;
  document.querySelectorAll('.view').forEach(v => v.classList.remove('active'));
  const view = document.getElementById('view-' + r);
  if (view) view.classList.add('active');

  document.querySelectorAll('.nav a').forEach(a => a.classList.remove('active'));
  const link = document.querySelector(`.nav a[data-route="${r}"]`);
  if (link) link.classList.add('active');

  const meta = routeMeta(r);
  const pageTitle = $('pageTitle');
  const pageSub = $('pageSub');
  if (pageTitle) pageTitle.textContent = meta.title;
  if (pageSub) pageSub.textContent = meta.sub;

  // Chart needs a visible canvas size to render correctly.
  if (r === 'overview') {
    if (Array.isArray(dailyPoints) && dailyPoints.length > 0) {
      setTimeout(() => drawDailyTokensChart(dailyPoints, 'dailyTokensChart'), 0);
    } else {
      loadDailyTokens();
    }
  }

  if (r === 'usage') {
    if (Array.isArray(dailyPoints) && dailyPoints.length > 0) {
      setTimeout(() => drawDailyTokensChart(dailyPoints, 'dailyTokensChartUsage'), 0);
    } else {
      loadDailyTokens();
    }
    loadMonthlyUsageTable();
  }

  if (r === 'settings') {
    loadAuthSessions();
  }

  if (r === 'profile') {
    if (typeof loadProfileMe === 'function') loadProfileMe();
  }

  if (r === 'billing') {
    loadInvoicesTable();
    if (typeof window.renderPayPalUpgradeUi === 'function') {
      // Render PayPal buttons once billing view is visible.
      window.renderPayPalUpgradeUi(window.__currentPlanKey || null);
    }
  }
}

async function load() {
  clearErrors();
  const refreshBtn = $('refreshBtn');
  if (refreshBtn) {
    refreshBtn.disabled = true;
    refreshBtn.classList.add('loading');
    refreshBtn.setAttribute('aria-busy', 'true');
    refreshBtn.setAttribute('title', 'Refreshing…');
  }
  billingInfoLoaded = false;

  try {
    const res = await fetch('/api/billing/me', {
      headers: { 'Authorization': 'Bearer ' + token }
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) {
      const msg = data.error || data.message || ('HTTP ' + res.status);
      throw new Error(msg);
    }

    // User identity (name/email) for avatar dropdown.
    try {
      const name = String(data?.user?.name || '').trim();
      const email = String(data?.user?.email || userEmail || '').trim();
      const userNameTextEl = $('userNameText');
      const userEmailTextEl = $('userEmailText');
      const userAvatarTextEl = $('userAvatarText');
      const fallbackName = email ? String(email.split('@')[0] || '').trim() : '';
      if (userNameTextEl) userNameTextEl.textContent = name || fallbackName || '—';
      if (userEmailTextEl) userEmailTextEl.textContent = email || '—';
      const avatarSeed = (name || fallbackName || email || 'U').trim();
      if (userAvatarTextEl) userAvatarTextEl.textContent = (avatarSeed.slice(0, 1) || 'U').toUpperCase();
    } catch (_) {
      // ignore
    }

    setPeriodText(data);
    setKpi('', data); // overview ids
    // usage ids have a suffix; map via a small prefix trick
    // (we use explicit ids in the DOM, not dynamic creation)
    const minutesUsageEl = $('minutesValueUsage');
    const tokensUsageEl = $('tokensValueUsage');
    if (minutesUsageEl) minutesUsageEl.textContent = fmt((data.transcription || {}).remainingMinutes) + ' min';
    if (tokensUsageEl) tokensUsageEl.textContent = fmt((data.ai || {}).remainingTokens) + ' tokens';
    const t = data.transcription || {};
    const a = data.ai || {};
    const minutesBarUsage = $('minutesBarUsage');
    const tokensBarUsage = $('tokensBarUsage');
    if (minutesBarUsage) minutesBarUsage.style.width = clampPct(t.limitMinutes ? (100 * (t.usedMinutes / t.limitMinutes)) : 0) + '%';
    if (tokensBarUsage) tokensBarUsage.style.width = clampPct(a.limitTokens ? (100 * (a.usedTokens / a.limitTokens)) : 0) + '%';

    const planKey = String(data.plan || 'free');
    window.__currentPlanKey = planKey;
    renderPlansInto('plansOverview', planKey);
    renderPlansInto('plansBilling', planKey);
    if (typeof window.renderPayPalUpgradeUi === 'function') {
      window.renderPayPalUpgradeUi(planKey);
    }

    // Spending view snapshot
    const usedSpendEl = $('tokensUsedSpending');
    const remSpendEl = $('tokensRemainingSpending');
    const barSpendEl = $('tokensBarSpending');
    if (usedSpendEl) usedSpendEl.textContent = fmt(a.usedTokens) + ' / ' + fmt(a.limitTokens) + ' tokens';
    if (remSpendEl) remSpendEl.textContent = fmt(a.remainingTokens) + ' tokens';
    if (barSpendEl) {
      const tokPct = a.limitTokens ? (100 * (a.usedTokens / a.limitTokens)) : 0;
      barSpendEl.style.width = clampPct(tokPct) + '%';
    }

    // Initialize date pickers (allow selecting previous months; only cap max to today UTC).
    try {
      const bpStartIso = data.billingPeriod?.start;
      const bpEndIso = data.billingPeriod?.end; // end is exclusive start-of-next-period
      if (bpStartIso && bpEndIso) {
        const bpStart = new Date(bpStartIso);
        billingPeriodStartYmd = ymdUTC(bpStart);
        const today = ymdUTC(new Date());
        maxSelectableDay = today;
        // Keep minSelectableDay = null to allow selecting previous months.

        // Default date range reflects the active (30D) selection (ending today).
        const endYmd = maxSelectableDay;
        const startYmd = clampYmd(addDaysUTC(endYmd, -(chartRangeDays - 1)), minSelectableDay, maxSelectableDay);
        setDateInputs(startYmd, endYmd);
      }
    } catch (_) {
      // If parsing fails, inputs remain unconstrained.
    }

    billingInfoLoaded = true;
    loadDailyTokens();
    if (currentRoute === 'usage') {
      loadMonthlyUsageTable();
    }
  } catch (e) {
    showError(String(e.message || e));
  } finally {
    if (refreshBtn) {
      refreshBtn.disabled = false;
      refreshBtn.classList.remove('loading');
      refreshBtn.removeAttribute('aria-busy');
      refreshBtn.setAttribute('title', 'Refresh');
    }
  }
}

// Wire events + init after DOM is parsed (this file is loaded with defer).
(() => {
  // Responsive sidebar drawer (mobile)
  const appRoot = $('appRoot');
  const sidebarToggleBtn = $('sidebarToggleBtn');
  const sidebarCloseBtn = $('sidebarCloseBtn');
  const sidebarBackdrop = $('sidebarBackdrop');

  function isSidebarOpen() {
    return !!(appRoot && appRoot.classList.contains('sidebarOpen'));
  }
  function setSidebarOpen(open) {
    if (!appRoot) return;
    appRoot.classList.toggle('sidebarOpen', !!open);
    if (sidebarToggleBtn) sidebarToggleBtn.setAttribute('aria-expanded', open ? 'true' : 'false');
    if (sidebarBackdrop) sidebarBackdrop.setAttribute('aria-hidden', open ? 'false' : 'true');
  }
  function toggleSidebar() { setSidebarOpen(!isSidebarOpen()); }

  if (sidebarToggleBtn) sidebarToggleBtn.addEventListener('click', (e) => { e.preventDefault(); toggleSidebar(); });
  if (sidebarCloseBtn) sidebarCloseBtn.addEventListener('click', (e) => { e.preventDefault(); setSidebarOpen(false); });
  if (sidebarBackdrop) sidebarBackdrop.addEventListener('click', () => setSidebarOpen(false));

  function signOut() {
    localStorage.removeItem('token');
    window.location.href = '/';
  }

  // Avatar + user menu
  const userMenuWrap = $('userMenuWrap');
  const userMenuBtn = $('userMenuBtn');
  const userMenu = $('userMenu');
  const userAvatarTextEl = $('userAvatarText');
  const userNameTextEl = $('userNameText');
  const userEmailTextEl = $('userEmailText');
  const menuSignOut = $('menuSignOut');

  const emailFallback = (typeof userEmail === 'string' ? userEmail : '').trim();
  const nameFallback = emailFallback ? String(emailFallback.split('@')[0] || '').trim() : '';
  if (userNameTextEl) userNameTextEl.textContent = nameFallback || '—';
  if (userEmailTextEl) userEmailTextEl.textContent = emailFallback || '—';
  if (userAvatarTextEl) userAvatarTextEl.textContent = (typeof userAvatarText === 'string' && userAvatarText.length ? userAvatarText : 'U');

  function closeUserMenu() {
    if (!userMenuWrap || !userMenuBtn || !userMenu) return;
    userMenuWrap.classList.remove('open');
    userMenuBtn.setAttribute('aria-expanded', 'false');
    userMenu.setAttribute('aria-hidden', 'true');
  }
  function toggleUserMenu() {
    if (!userMenuWrap || !userMenuBtn || !userMenu) return;
    const open = userMenuWrap.classList.toggle('open');
    userMenuBtn.setAttribute('aria-expanded', open ? 'true' : 'false');
    userMenu.setAttribute('aria-hidden', open ? 'false' : 'true');
  }

  if (userMenuBtn) userMenuBtn.addEventListener('click', (e) => { e.preventDefault(); toggleUserMenu(); });
  if (menuSignOut) menuSignOut.addEventListener('click', () => signOut());
  document.addEventListener('click', (e) => {
    if (!userMenuWrap) return;
    const t = e.target;
    if (!(t instanceof Node)) return;
    if (!userMenuWrap.contains(t)) closeUserMenu();
  });
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') {
      closeUserMenu();
      setSidebarOpen(false);
    }
  });

  const refreshBtn = $('refreshBtn');
  if (refreshBtn) refreshBtn.addEventListener('click', load);

  // Settings: active sessions + delete account
  const revokeOthersBtn = $('revokeOthersBtn');
  if (revokeOthersBtn) {
    revokeOthersBtn.addEventListener('click', async () => {
      const errEl = $('sessionsError');
      if (errEl) errEl.style.display = 'none';
      try {
        revokeOthersBtn.disabled = true;
        const res = await fetch('/api/auth/sessions/revoke-others', {
          method: 'POST',
          headers: { 'Authorization': 'Bearer ' + token }
        });
        const data = await res.json().catch(() => ({}));
        if (!res.ok) throw new Error(data.error || data.message || ('HTTP ' + res.status));
        await loadAuthSessions({ append: false });
      } catch (e) {
        if (errEl) {
          errEl.textContent = String(e.message || e);
          errEl.style.display = 'block';
        }
      } finally {
        revokeOthersBtn.disabled = false;
      }
    });
  }

  const sessionsShowMoreBtn = $('sessionsShowMoreBtn');
  if (sessionsShowMoreBtn) {
    sessionsShowMoreBtn.addEventListener('click', async () => {
      await loadAuthSessions({ append: true });
    });
  }

  const deletePasswordEl = $('deletePassword');
  const deleteConfirmEl = $('deleteConfirm');
  const deleteBtn = $('deleteAccountBtn');
  function updateDeleteBtn() {
    if (!deleteBtn) return;
    const p = String(deletePasswordEl?.value || '');
    const c = String(deleteConfirmEl?.value || '');
    deleteBtn.disabled = !(p.length > 0 && c === 'DELETE');
  }
  if (deletePasswordEl) deletePasswordEl.addEventListener('input', updateDeleteBtn);
  if (deleteConfirmEl) deleteConfirmEl.addEventListener('input', updateDeleteBtn);
  updateDeleteBtn();

  if (deleteBtn) {
    deleteBtn.addEventListener('click', async () => {
      const errEl = $('deleteError');
      if (errEl) errEl.style.display = 'none';
      const password = String(deletePasswordEl?.value || '');
      const confirm = String(deleteConfirmEl?.value || '');
      try {
        deleteBtn.disabled = true;
        const res = await fetch('/api/auth/delete-account', {
          method: 'POST',
          headers: {
            'Authorization': 'Bearer ' + token,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({ password, confirm }),
        });
        const data = await res.json().catch(() => ({}));
        if (!res.ok) throw new Error(data.error || data.message || ('HTTP ' + res.status));
        localStorage.removeItem('token');
        window.location.href = '/';
      } catch (e) {
        if (errEl) {
          errEl.textContent = String(e.message || e);
          errEl.style.display = 'block';
        }
        updateDeleteBtn();
      }
    });
  }

  // Sidebar navigation + route switching
  function routeFromHash() {
    const h = (window.location.hash || '').replace('#', '').trim();
    return h || 'overview';
  }
  window.addEventListener('hashchange', () => {
    setRoute(routeFromHash());
    setSidebarOpen(false);
  });
  window.addEventListener('resize', () => {
    if (currentRoute === 'overview' && Array.isArray(dailyPoints) && dailyPoints.length > 0) {
      drawDailyTokensChart(dailyPoints, 'dailyTokensChart');
    }
    if (currentRoute === 'usage' && Array.isArray(dailyPoints) && dailyPoints.length > 0) {
      drawDailyTokensChart(dailyPoints, 'dailyTokensChartUsage');
    }
  });

  // Range selector for chart
  const rangeEl = $('dailyRange');
  if (rangeEl) {
    rangeEl.addEventListener('click', (e) => {
      const btn = e.target.closest('button[data-days]');
      if (!btn) return;
      const days = parseInt(btn.getAttribute('data-days'), 10);
      if (!Number.isFinite(days) || days <= 0) return;
      chartRangeDays = days;
      chartStart = null;
      chartEnd = null;
      rangeEl.querySelectorAll('button[data-days]').forEach(b => b.classList.remove('active'));
      btn.classList.add('active');
      // Sync date inputs to match the quick range (ending today).
      if (maxSelectableDay) {
        const endYmd = maxSelectableDay;
        const startYmd = clampYmd(addDaysUTC(endYmd, -(chartRangeDays - 1)), minSelectableDay, maxSelectableDay);
        setDateInputs(startYmd, endYmd);
      }
      loadDailyTokens();
    });
  }

  // Custom date range apply
  const applyBtn = $('dailyApply');
  if (applyBtn) {
    applyBtn.addEventListener('click', () => {
      const errEl = $('dailyChartError');
      if (errEl) errEl.style.display = 'none';
      const s = $('dailyStart')?.value;
      const e = $('dailyEnd')?.value;
      if (!s || !e) return;
      const startYmd = clampYmd(s, minSelectableDay, maxSelectableDay);
      const endYmd = clampYmd(e, minSelectableDay, maxSelectableDay);
      if (startYmd > endYmd) {
        if (errEl) {
          errEl.textContent = 'Start date must be on or before end date.';
          errEl.style.display = 'block';
        }
        return;
      }
      chartStart = startYmd;
      chartEnd = endYmd;
      setDateInputs(chartStart, chartEnd);
      // Clear quick-range active state to avoid confusion.
      const rangeEl2 = $('dailyRange');
      if (rangeEl2) rangeEl2.querySelectorAll('button[data-days]').forEach(b => b.classList.remove('active'));
      loadDailyTokens();
    });
  }

  const nav = $('nav');
  if (nav) {
    nav.addEventListener('click', (e) => {
      const a = e.target.closest('a[data-route]');
      const quick = e.target.closest('a[data-route-link]');
      if (a) {
        // Allow hash navigation; route handler will switch view.
        setSidebarOpen(false);
        return;
      }
      if (quick) {
        const r = quick.getAttribute('data-route-link');
        if (r) window.location.hash = '#' + r;
      }
    });
  }

  setRoute(routeFromHash());
  load();
})();
