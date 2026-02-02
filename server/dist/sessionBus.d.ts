import { WebSocket } from 'ws';
export declare function registerWebSocketForSession(sid: string, ws: WebSocket): void;
export declare function closeWebSocketsForSession(sid: string, reason?: string): number;
//# sourceMappingURL=sessionBus.d.ts.map