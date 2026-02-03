const paypalMode = () => {
    const v = String(process.env.PAYPAL_MODE || 'sandbox').trim().toLowerCase();
    return v === 'live' ? 'live' : 'sandbox';
};
const paypalBaseUrl = () => {
    return paypalMode() === 'live'
        ? 'https://api-m.paypal.com'
        : 'https://api-m.sandbox.paypal.com';
};
let cachedAccessToken = null;
export async function getPayPalAccessToken() {
    const now = Date.now();
    if (cachedAccessToken && cachedAccessToken.expiresAtMs - now > 60_000) {
        return cachedAccessToken.token;
    }
    const clientId = String(process.env.PAYPAL_CLIENT_ID || '').trim();
    const secret = String(process.env.PAYPAL_CLIENT_SECRET || '').trim();
    if (!clientId || !secret) {
        throw new Error('PayPal is not configured (PAYPAL_CLIENT_ID / PAYPAL_CLIENT_SECRET missing)');
    }
    const basic = Buffer.from(`${clientId}:${secret}`).toString('base64');
    const res = await fetch(`${paypalBaseUrl()}/v1/oauth2/token`, {
        method: 'POST',
        headers: {
            'Authorization': `Basic ${basic}`,
            'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: 'grant_type=client_credentials',
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) {
        throw new Error(data?.error_description || data?.error || `PayPal token error (HTTP ${res.status})`);
    }
    const token = String(data.access_token || '');
    const expiresIn = Number(data.expires_in || 0) || 0;
    if (!token)
        throw new Error('PayPal token error (missing access_token)');
    cachedAccessToken = { token, expiresAtMs: now + (expiresIn * 1000) };
    return token;
}
export async function paypalApi(path, init) {
    const token = await getPayPalAccessToken();
    const res = await fetch(`${paypalBaseUrl()}${path}`, {
        ...init,
        headers: {
            'Authorization': `Bearer ${token}`,
            'Content-Type': 'application/json',
            ...(init?.headers || {}),
        },
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) {
        const msg = data?.message || data?.name || data?.error || `PayPal API error (HTTP ${res.status})`;
        throw new Error(msg);
    }
    return data;
}
export async function getPayPalSubscription(subscriptionId) {
    const id = String(subscriptionId || '').trim();
    if (!id)
        throw new Error('subscriptionId is required');
    return await paypalApi(`/v1/billing/subscriptions/${encodeURIComponent(id)}`, {
        method: 'GET',
    });
}
export async function verifyPayPalWebhookSignature(args) {
    const webhookId = String(process.env.PAYPAL_WEBHOOK_ID || '').trim();
    if (!webhookId) {
        throw new Error('PAYPAL_WEBHOOK_ID is required to verify webhooks');
    }
    const data = await paypalApi(`/v1/notifications/verify-webhook-signature`, {
        method: 'POST',
        body: JSON.stringify({
            auth_algo: args.authAlgo,
            cert_url: args.certUrl,
            transmission_id: args.transmissionId,
            transmission_sig: args.transmissionSig,
            transmission_time: args.transmissionTime,
            webhook_id: webhookId,
            webhook_event: args.webhookEvent,
        }),
    });
    return String(data?.verification_status || '').toUpperCase() === 'SUCCESS';
}
//# sourceMappingURL=paypal.js.map