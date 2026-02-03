let _paypalConfigPromise = null;
let _paypalSdkPromise = null;

async function loadPayPalConfig() {
  if (_paypalConfigPromise) return _paypalConfigPromise;
  _paypalConfigPromise = (async () => {
    const res = await fetch('/api/billing/paypal/config', { headers: { 'Authorization': 'Bearer ' + token } });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.error || data.message || ('HTTP ' + res.status));
    return data;
  })();
  return _paypalConfigPromise;
}

function ensurePayPalSdkLoaded(clientId) {
  if (_paypalSdkPromise) return _paypalSdkPromise;
  _paypalSdkPromise = new Promise((resolve, reject) => {
    const existing = document.querySelector('script[data-paypal-sdk="1"]');
    if (existing && window.paypal) return resolve(window.paypal);

    const s = document.createElement('script');
    s.setAttribute('data-paypal-sdk', '1');
    s.src = `https://www.paypal.com/sdk/js?client-id=${encodeURIComponent(clientId)}&vault=true&intent=subscription`;
    s.async = true;
    s.onload = () => resolve(window.paypal);
    s.onerror = () => reject(new Error('Failed to load PayPal SDK'));
    document.head.appendChild(s);
  });
  return _paypalSdkPromise;
}

async function attachSubscription(subscriptionId) {
  const res = await fetch('/api/billing/paypal/attach-subscription', {
    method: 'POST',
    headers: {
      'Authorization': 'Bearer ' + token,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ subscriptionId }),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || data.message || ('HTTP ' + res.status));
  return data;
}

async function renderPayPalForPlan(planKey, planId) {
  const mount = document.getElementById(`paypalBtn_${planKey}`);
  const note = document.getElementById(`paypalNote_${planKey}`);
  if (!mount) return;
  if (mount.getAttribute('data-rendered') === '1') return;

  if (!planId) {
    if (note) note.textContent = 'PayPal plan_id not configured on server.';
    return;
  }

  const cfg = await loadPayPalConfig();
  if (!cfg.enabled) {
    if (note) note.textContent = 'PayPal is not enabled on this server.';
    return;
  }

  const paypal = await ensurePayPalSdkLoaded(cfg.clientId);
  if (!paypal || !paypal.Buttons) {
    if (note) note.textContent = 'PayPal SDK not available.';
    return;
  }

  mount.setAttribute('data-rendered', '1');
  paypal.Buttons({
    style: { layout: 'vertical', label: 'subscribe' },
    createSubscription: (_data, actions) => actions.subscription.create({ plan_id: planId }),
    onApprove: async (data) => {
      try {
        if (note) note.textContent = 'Finalizing subscription…';
        await attachSubscription(data.subscriptionID);
        if (note) note.textContent = 'Subscription activated. Refreshing…';
        if (typeof load === 'function') await load();
        if (note) note.textContent = 'Done.';
      } catch (e) {
        if (note) note.textContent = String(e.message || e);
        mount.removeAttribute('data-rendered');
      }
    },
    onError: (err) => {
      if (note) note.textContent = String(err && (err.message || err) || 'PayPal error');
      mount.removeAttribute('data-rendered');
    },
  }).render(mount);
}

async function renderPayPalUpgradeUi(currentPlanKey) {
  try {
    const cfg = await loadPayPalConfig();
    if (!cfg.enabled) {
      // Show notes on any visible plan cards in billing view.
      ['pro', 'pro_plus'].forEach((k) => {
        const note = document.getElementById(`paypalNote_${k}`);
        if (note) note.textContent = 'PayPal not configured (missing env vars).';
      });
      return;
    }

    // Only render upgrade options (not for current plan).
    if (currentPlanKey !== 'pro') await renderPayPalForPlan('pro', cfg.planIds?.pro);
    if (currentPlanKey !== 'pro_plus') await renderPayPalForPlan('pro_plus', cfg.planIds?.pro_plus);
  } catch (e) {
    ['pro', 'pro_plus'].forEach((k) => {
      const note = document.getElementById(`paypalNote_${k}`);
      if (note) note.textContent = String(e.message || e);
    });
  }
}

// Expose for main.js
window.renderPayPalUpgradeUi = renderPayPalUpgradeUi;

