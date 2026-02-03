function renderPlansInto(containerId, currentPlanKey) {
  const plansEl = $(containerId);
  if (!plansEl) return;
  const curIdx = planOffers.findIndex(p => p.key === currentPlanKey);
  plansEl.innerHTML = '';
  planOffers.forEach((p, idx) => {
    if (idx < curIdx) return; // only show current + upgradable
    const isCurrent = p.key === currentPlanKey;
    const div = document.createElement('div');
    div.className = 'plan' + (isCurrent ? ' current' : '');
    const isBilling = containerId === 'plansBilling';
    const paypalSlot = (!isCurrent && isBilling)
      ? `<div class="paypalWrap"><div id="paypalBtn_${p.key}"></div><div class="muted" id="paypalNote_${p.key}" style="margin-top:8px;"></div></div>`
      : '';
    div.innerHTML = `
          <div class="name">${p.name}${isCurrent ? '<span class="badge">Current</span>' : ''}</div>
          <ul>
            <li>${fmt(p.minutes)} transcription minutes / month</li>
            <li>${fmt(p.tokens)} AI tokens / month</li>
            <li>${fmt(p.requests)} AI requests / month</li>
            <li>Summary: ${p.summary ? 'enabled' : 'not included'}</li>
          </ul>
          ${paypalSlot}
        `;
    plansEl.appendChild(div);
  });
}

function setKpi(prefix, data) {
  const t = data.transcription || {};
  const a = data.ai || {};
  const plan = String(data.plan || 'free');
  const planUpper = plan.toUpperCase();

  const planEl = $(prefix + 'planValue');
  const minutesEl = $(prefix + 'minutesValue');
  const minutesBarEl = $(prefix + 'minutesBar');
  const tokensEl = $(prefix + 'tokensValue');
  const tokensBarEl = $(prefix + 'tokensBar');

  if (planEl) planEl.textContent = planUpper;
  if (minutesEl) minutesEl.textContent = fmt(t.remainingMinutes) + ' min';
  if (minutesBarEl) {
    const minPct = t.limitMinutes ? (100 * (t.usedMinutes / t.limitMinutes)) : 0;
    minutesBarEl.style.width = clampPct(minPct) + '%';
  }
  if (tokensEl) tokensEl.textContent = fmt(a.remainingTokens) + ' tokens';
  if (tokensBarEl) {
    const tokPct = a.limitTokens ? (100 * (a.usedTokens / a.limitTokens)) : 0;
    tokensBarEl.style.width = clampPct(tokPct) + '%';
  }
}

function setPeriodText(data) {
  const start = data.billingPeriod?.start || '—';
  const end = data.billingPeriod?.end || '—';
  const el = $('periodText');
  if (el) el.textContent = 'Billing period: ' + start + ' → ' + end;
}
