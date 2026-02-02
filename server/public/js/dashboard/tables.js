async function loadMonthlyUsageTable() {
  const table = $('monthlyUsageTable');
  const errEl = $('monthlyTableError');
  if (errEl) errEl.style.display = 'none';
  if (!table) return;
  table.innerHTML = '<tr><td>Loading…</td></tr>';
  try {
    if (!billingPeriodStartYmd || !maxSelectableDay || !billingInfoLoaded) {
      // Billing info is fetched by load(); this can run before it finishes.
      // Keep the "Loading…" state and retry once shortly.
      setTimeout(() => {
        if (currentRoute === 'usage') loadMonthlyUsageTable();
      }, 250);
      return;
    }
    const url = '/api/billing/ai-daily-tokens-by-model?start=' + encodeURIComponent(billingPeriodStartYmd) +
      '&end=' + encodeURIComponent(maxSelectableDay);
    const res = await fetch(url, { headers: { 'Authorization': 'Bearer ' + token } });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.error || data.message || ('HTTP ' + res.status));
    const rows = Array.isArray(data.days) ? data.days : [];
    const models = Array.isArray(data.models) ? data.models : [];
    const totalsByModel = data && typeof data.totalsByModel === 'object' && data.totalsByModel ? data.totalsByModel : {};
    const total = Number(data.totalTokens || 0) || 0;

    table.innerHTML = `
          <thead><tr><th>Date</th><th>Model</th><th class="num">Total</th></tr></thead>
          <tbody></tbody>
          <tfoot></tfoot>
        `;
    const tbody = table.querySelector('tbody');
    for (const r of rows) {
      const date = String(r.date || '');
      const byModel = r.byModel && typeof r.byModel === 'object' ? r.byModel : {};

      const entries = [];
      for (const m of models) {
        const v = Number(byModel[m] || 0) || 0;
        if (v > 0) entries.push([m, v]);
      }
      if (entries.length === 0) {
        const tr = document.createElement('tr');
        tr.innerHTML = `<td>${date}</td><td>—</td><td class="num">0</td>`;
        tbody.appendChild(tr);
        continue;
      }
      for (let i = 0; i < entries.length; i++) {
        const [m, v] = entries[i];
        const tr = document.createElement('tr');
        tr.innerHTML = `<td>${i === 0 ? date : ''}</td><td>${String(m)}</td><td class="num">${String(v)}</td>`;
        tbody.appendChild(tr);
      }
    }

    const tfoot = table.querySelector('tfoot');
    const totalRows = [];
    totalRows.push(`<tr><th>Total</th><th>All</th><th class="num">${String(total)}</th></tr>`);
    for (const m of models) {
      const v = Number(totalsByModel[m] || 0) || 0;
      if (v <= 0) continue;
      totalRows.push(`<tr><th>Total</th><th>${String(m)}</th><th class="num">${String(v)}</th></tr>`);
    }
    tfoot.innerHTML = totalRows.join('');
  } catch (e) {
    table.innerHTML = '';
    if (errEl) {
      errEl.textContent = String(e.message || e);
      errEl.style.display = 'block';
    }
  }
}

function fmtMoneyCents(cents, currency) {
  const cur = (currency || 'USD').toUpperCase();
  const v = Number(cents || 0) || 0;
  const amount = (v / 100);
  try {
    return new Intl.NumberFormat(undefined, { style: 'currency', currency: cur }).format(amount);
  } catch (_) {
    return cur + ' ' + amount.toFixed(2);
  }
}

async function loadInvoicesTable() {
  const table = $('invoicesTable');
  const errEl = $('invoicesError');
  if (errEl) errEl.style.display = 'none';
  if (!table) return;
  table.innerHTML = '<tr><td>Loading…</td></tr>';
  try {
    const res = await fetch('/api/billing/invoices', {
      headers: { 'Authorization': 'Bearer ' + token }
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.error || data.message || ('HTTP ' + res.status));

    const rows = Array.isArray(data.invoices) ? data.invoices : [];
    table.innerHTML = `
          <thead>
            <tr>
              <th>Date</th>
              <th>Description</th>
              <th>Status</th>
              <th class="num">Amount</th>
              <th>Invoice</th>
            </tr>
          </thead>
          <tbody></tbody>
        `;
    const tbody = table.querySelector('tbody');
    if (!rows.length) {
      const tr = document.createElement('tr');
      tr.innerHTML = `<td colspan="5" style="color:#555;">No invoices yet.</td>`;
      tbody.appendChild(tr);
      return;
    }
    for (const inv of rows) {
      const date = String(inv.date || '');
      const desc = String(inv.description || '');
      const status = String(inv.status || '');
      const amountCents = Number(inv.amountCents || 0) || 0;
      const currency = String(inv.currency || 'USD');
      const url = inv.invoiceUrl ? String(inv.invoiceUrl) : '';
      const view = url
        ? `<a href="${url}" target="_blank" rel="noopener" style="color:#4c1d95; text-decoration: underline;">View</a>`
        : `<span style="color:#777;">—</span>`;

      const tr = document.createElement('tr');
      tr.innerHTML = `
            <td>${date}</td>
            <td>${desc}</td>
            <td>${status}</td>
            <td class="num">${fmtMoneyCents(amountCents, currency)}</td>
            <td>${view}</td>
          `;
      tbody.appendChild(tr);
    }
  } catch (e) {
    table.innerHTML = '';
    if (errEl) {
      errEl.textContent = String(e.message || e);
      errEl.style.display = 'block';
    }
  }
}
