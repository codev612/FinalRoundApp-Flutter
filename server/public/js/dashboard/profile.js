async function loadProfileMe() {
  const errEl = $('profileError');
  const okEl = $('profileSuccess');
  if (errEl) errEl.style.display = 'none';

  try {
    const res = await fetch('/api/auth/me', { headers: { 'Authorization': 'Bearer ' + token } });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.error || data.message || ('HTTP ' + res.status));

    const u = data.user || {};
    const name = String(u.name || '').trim();
    const email = String(u.email || '').trim();

    const nameInput = $('profileName');
    const curEmailInput = $('profileEmailCurrent');
    if (nameInput) nameInput.value = name;
    if (curEmailInput) curEmailInput.value = email;

    // Email change state
    const pendingEmail = data?.emailChange?.pendingEmail ? String(data.emailChange.pendingEmail) : '';
    const step = data?.emailChange?.step ? String(data.emailChange.step) : '';
    const box = $('emailChangeBox');
    const hint = $('emailChangeHint');
    const s1 = $('emailChangeStep1');
    const s2 = $('emailChangeStep2');

    if (!pendingEmail) {
      if (box) box.style.display = 'none';
      if (s1) s1.style.display = 'none';
      if (s2) s2.style.display = 'none';
    } else {
      if (box) box.style.display = 'block';
      const isStep1 = step === 'verify_current' || !step;
      const isStep2 = step === 'verify_new';
      if (hint) {
        hint.textContent = isStep2
          ? ('We sent a verification code to your new email: ' + pendingEmail)
          : 'We sent a verification code to your current email.';
      }
      if (s1) s1.style.display = isStep1 ? 'flex' : 'none';
      if (s2) s2.style.display = isStep2 ? 'flex' : 'none';
    }
  } catch (e) {
    if (okEl) okEl.style.display = 'none';
    if (errEl) {
      errEl.textContent = String(e.message || e);
      errEl.style.display = 'block';
    }
  }
}

(function wireProfile() {
  const errEl = $('profileError');
  const okEl = $('profileSuccess');

  const clearStatus = () => {
    if (errEl) errEl.style.display = 'none';
    if (okEl) okEl.style.display = 'none';
  };

  const showOk = (msg) => {
    const m = String(msg || '').trim();
    if (!m) {
      if (okEl) okEl.style.display = 'none';
      return;
    }
    if (okEl) {
      okEl.textContent = m;
      okEl.style.display = 'block';
    }
    if (errEl) errEl.style.display = 'none';
  };
  const showErr = (msg) => {
    const m = String(msg || '').trim();
    if (!m) {
      if (errEl) errEl.style.display = 'none';
      return;
    }
    if (errEl) {
      errEl.textContent = m;
      errEl.style.display = 'block';
    }
    if (okEl) okEl.style.display = 'none';
  };

  const saveNameBtn = $('profileSaveNameBtn');
  if (saveNameBtn) {
    saveNameBtn.addEventListener('click', async () => {
      try {
        clearStatus();
        const name = String($('profileName')?.value || '').trim();
        if (name.length < 2) throw new Error('Name must be at least 2 characters');
        saveNameBtn.disabled = true;
        const res = await fetch('/api/auth/profile', {
          method: 'PUT',
          headers: {
            'Authorization': 'Bearer ' + token,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({ name }),
        });
        const data = await res.json().catch(() => ({}));
        if (!res.ok) throw new Error(data.error || data.message || ('HTTP ' + res.status));
        showOk('Name updated.');
        // Refresh avatar dropdown + current email/name in UI.
        if (typeof load === 'function') load();
        await loadProfileMe();
      } catch (e) {
        showErr(String(e.message || e));
      } finally {
        saveNameBtn.disabled = false;
      }
    });
  }

  const startEmailBtn = $('profileStartEmailChangeBtn');
  if (startEmailBtn) {
    startEmailBtn.addEventListener('click', async () => {
      try {
        clearStatus();
        const email = String($('profileEmailNew')?.value || '').trim();
        if (!email) throw new Error('New email is required');
        startEmailBtn.disabled = true;
        const res = await fetch('/api/auth/profile', {
          method: 'PUT',
          headers: {
            'Authorization': 'Bearer ' + token,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({ email }),
        });
        const data = await res.json().catch(() => ({}));
        if (!res.ok) throw new Error(data.error || data.message || ('HTTP ' + res.status));
        showOk(data.message || 'Email change started.');
        await loadProfileMe();
      } catch (e) {
        showErr(String(e.message || e));
      } finally {
        startEmailBtn.disabled = false;
      }
    });
  }

  const verifyCurrentBtn = $('profileVerifyCurrentEmailBtn');
  if (verifyCurrentBtn) {
    verifyCurrentBtn.addEventListener('click', async () => {
      try {
        clearStatus();
        const code = String($('profileCurrentEmailCode')?.value || '').trim();
        if (!code) throw new Error('Code is required');
        verifyCurrentBtn.disabled = true;
        const res = await fetch('/api/auth/verify-current-email-change', {
          method: 'POST',
          headers: {
            'Authorization': 'Bearer ' + token,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({ currentEmailCode: code }),
        });
        const data = await res.json().catch(() => ({}));
        if (!res.ok) throw new Error(data.error || data.message || ('HTTP ' + res.status));
        showOk(data.message || 'Current email verified.');
        $('profileCurrentEmailCode').value = '';
        await loadProfileMe();
      } catch (e) {
        showErr(String(e.message || e));
      } finally {
        verifyCurrentBtn.disabled = false;
      }
    });
  }

  const verifyNewBtn = $('profileVerifyNewEmailBtn');
  if (verifyNewBtn) {
    verifyNewBtn.addEventListener('click', async () => {
      try {
        clearStatus();
        const code = String($('profileNewEmailCode')?.value || '').trim();
        if (!code) throw new Error('Code is required');
        verifyNewBtn.disabled = true;
        const res = await fetch('/api/auth/verify-new-email-change', {
          method: 'POST',
          headers: {
            'Authorization': 'Bearer ' + token,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({ newEmailCode: code }),
        });
        const data = await res.json().catch(() => ({}));
        if (!res.ok) throw new Error(data.error || data.message || ('HTTP ' + res.status));
        showOk(data.message || 'Email updated.');
        $('profileNewEmailCode').value = '';
        $('profileEmailNew').value = '';
        if (typeof load === 'function') load();
        await loadProfileMe();
      } catch (e) {
        showErr(String(e.message || e));
      } finally {
        verifyNewBtn.disabled = false;
      }
    });
  }

  const cancelEmailBtn = $('profileCancelEmailChangeBtn');
  if (cancelEmailBtn) {
    cancelEmailBtn.addEventListener('click', async () => {
      try {
        clearStatus();
        cancelEmailBtn.disabled = true;
        const res = await fetch('/api/auth/cancel-email-change', {
          method: 'POST',
          headers: { 'Authorization': 'Bearer ' + token }
        });
        const data = await res.json().catch(() => ({}));
        if (!res.ok) throw new Error(data.error || data.message || ('HTTP ' + res.status));
        showOk(data.message || 'Email change cancelled.');
        await loadProfileMe();
      } catch (e) {
        showErr(String(e.message || e));
      } finally {
        cancelEmailBtn.disabled = false;
      }
    });
  }

  const changePwBtn = $('profileChangePasswordBtn');
  if (changePwBtn) {
    changePwBtn.addEventListener('click', async () => {
      try {
        clearStatus();
        const currentPassword = String($('profileCurrentPassword')?.value || '');
        const newPassword = String($('profileNewPassword')?.value || '');
        if (!currentPassword || !newPassword) throw new Error('Current password and new password are required');
        if (newPassword.length < 8) throw new Error('New password must be at least 8 characters');
        changePwBtn.disabled = true;
        const res = await fetch('/api/auth/change-password', {
          method: 'PUT',
          headers: {
            'Authorization': 'Bearer ' + token,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({ currentPassword, newPassword }),
        });
        const data = await res.json().catch(() => ({}));
        if (!res.ok) throw new Error(data.error || data.message || ('HTTP ' + res.status));
        showOk(data.message || 'Password changed.');
        $('profileCurrentPassword').value = '';
        $('profileNewPassword').value = '';
      } catch (e) {
        showErr(String(e.message || e));
      } finally {
        changePwBtn.disabled = false;
      }
    });
  }
})();

