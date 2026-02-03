import express from 'express';
import { authenticate } from '../auth.js';
import { getPayPalSubscription, verifyPayPalWebhookSignature } from '../paypal.js';
import { setUserPayPalSubscription, updatePayPalSubscriptionStatusBySubscriptionId } from '../database.js';
const router = express.Router();
const planIdsFromEnv = () => ({
    pro: String(process.env.PAYPAL_PLAN_ID_PRO || '').trim(),
    pro_plus: String(process.env.PAYPAL_PLAN_ID_PRO_PLUS || '').trim(),
});
const mapPlanIdToTier = (planId) => {
    const ids = planIdsFromEnv();
    const p = String(planId || '').trim();
    if (p && ids.pro && p === ids.pro)
        return 'pro';
    if (p && ids.pro_plus && p === ids.pro_plus)
        return 'pro_plus';
    return null;
};
router.get('/config', authenticate, async (_req, res) => {
    const clientId = String(process.env.PAYPAL_CLIENT_ID || '').trim();
    const mode = String(process.env.PAYPAL_MODE || 'sandbox').trim().toLowerCase();
    const planIds = planIdsFromEnv();
    const enabled = !!(clientId && planIds.pro && planIds.pro_plus);
    return res.json({ enabled, clientId, mode, planIds });
});
router.post('/attach-subscription', authenticate, async (req, res) => {
    try {
        const userId = req.user.userId;
        const subscriptionId = String(req.body?.subscriptionId || '').trim();
        if (!subscriptionId)
            return res.status(400).json({ error: 'subscriptionId is required' });
        const sub = await getPayPalSubscription(subscriptionId);
        const status = String(sub.status || '').toUpperCase();
        if (status !== 'ACTIVE') {
            return res.status(400).json({ error: `Subscription is not active yet (status=${status || 'unknown'})` });
        }
        const planId = String(sub.plan_id || '').trim();
        const tier = mapPlanIdToTier(planId);
        if (!tier)
            return res.status(400).json({ error: 'Unknown PayPal plan_id for this server' });
        await setUserPayPalSubscription(userId, {
            subscriptionId,
            planId,
            status,
            plan: tier,
            subscriberEmail: String(sub?.subscriber?.email_address || '').trim() || null,
            nextBillingTime: String(sub?.billing_info?.next_billing_time || '').trim() || null,
        });
        return res.json({
            message: 'Subscription attached successfully.',
            plan: tier,
            subscriptionId,
            status,
        });
    }
    catch (error) {
        return res.status(500).json({ error: error?.message || 'Failed to attach subscription' });
    }
});
// PayPal webhook (no auth). Requires PAYPAL_WEBHOOK_ID.
router.post('/webhook', async (req, res) => {
    try {
        const transmissionId = String(req.header('paypal-transmission-id') || '');
        const transmissionTime = String(req.header('paypal-transmission-time') || '');
        const transmissionSig = String(req.header('paypal-transmission-sig') || '');
        const certUrl = String(req.header('paypal-cert-url') || '');
        const authAlgo = String(req.header('paypal-auth-algo') || '');
        const ok = await verifyPayPalWebhookSignature({
            transmissionId,
            transmissionTime,
            transmissionSig,
            certUrl,
            authAlgo,
            webhookEvent: req.body,
        });
        if (!ok)
            return res.status(400).json({ error: 'Invalid webhook signature' });
        const eventType = String(req.body?.event_type || '');
        const resource = req.body?.resource || {};
        const subscriptionId = String(resource?.id || '').trim();
        const status = String(resource?.status || '').trim();
        const planId = String(resource?.plan_id || '').trim();
        const tier = mapPlanIdToTier(planId);
        const nextBillingTime = String(resource?.billing_info?.next_billing_time || '').trim() || null;
        if (subscriptionId) {
            if (eventType.includes('BILLING.SUBSCRIPTION.CANCELLED') || eventType.includes('BILLING.SUBSCRIPTION.EXPIRED') || eventType.includes('BILLING.SUBSCRIPTION.SUSPENDED')) {
                await updatePayPalSubscriptionStatusBySubscriptionId(subscriptionId, status || 'CANCELLED', 'free', nextBillingTime);
            }
            else if (eventType.includes('BILLING.SUBSCRIPTION.ACTIVATED') && tier) {
                await updatePayPalSubscriptionStatusBySubscriptionId(subscriptionId, status || 'ACTIVE', tier, nextBillingTime);
            }
            else {
                await updatePayPalSubscriptionStatusBySubscriptionId(subscriptionId, status || 'UNKNOWN', undefined, nextBillingTime);
            }
        }
        return res.json({ ok: true });
    }
    catch (error) {
        return res.status(500).json({ error: error?.message || 'Webhook error' });
    }
});
export default router;
//# sourceMappingURL=paypal.js.map