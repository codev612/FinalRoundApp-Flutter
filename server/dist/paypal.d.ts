export type PayPalSubscription = {
    id: string;
    status: string;
    plan_id: string;
    subscriber?: {
        email_address?: string;
    };
    billing_info?: {
        next_billing_time?: string;
    };
};
export declare function getPayPalAccessToken(): Promise<string>;
export declare function paypalApi<T = any>(path: string, init?: RequestInit): Promise<T>;
export declare function getPayPalSubscription(subscriptionId: string): Promise<PayPalSubscription>;
export declare function verifyPayPalWebhookSignature(args: {
    transmissionId: string;
    transmissionTime: string;
    transmissionSig: string;
    certUrl: string;
    authAlgo: string;
    webhookEvent: any;
}): Promise<boolean>;
//# sourceMappingURL=paypal.d.ts.map