import { WebSocket } from 'ws';
import { JWTPayload } from './auth.js';
export interface AuthenticatedWebSocket extends WebSocket {
    user?: JWTPayload;
}
export interface WSMessage {
    type: string;
    [key: string]: any;
}
export interface StartMessage extends WSMessage {
    type: 'start';
}
export interface AudioMessage extends WSMessage {
    type: 'audio';
    source: 'mic' | 'system';
    audio: string;
}
export interface StopMessage extends WSMessage {
    type: 'stop';
}
export interface AIRequestMessage extends WSMessage {
    type: 'ai_request';
    requestId?: string;
    turns: Array<{
        source: string;
        text: string;
    }>;
    mode?: 'summary' | 'insights' | 'questions' | 'reply';
    question?: string;
}
export interface AICancelMessage extends WSMessage {
    type: 'ai_cancel';
    requestId: string;
}
export interface AuthenticatedRequest extends Express.Request {
    user?: JWTPayload;
}
//# sourceMappingURL=types.d.ts.map