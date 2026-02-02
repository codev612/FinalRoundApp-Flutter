import { WebSocket } from 'ws';

// In-memory registry of active sockets per auth session id (sid).
// This allows us to immediately disconnect a desktop/mobile/web client when their session is revoked.
const socketsBySid = new Map<string, Set<WebSocket>>();

export function registerWebSocketForSession(sid: string, ws: WebSocket): void {
  const s = String(sid || '').trim();
  if (!s) return;
  let set = socketsBySid.get(s);
  if (!set) {
    set = new Set<WebSocket>();
    socketsBySid.set(s, set);
  }
  set.add(ws);

  const cleanup = () => {
    const cur = socketsBySid.get(s);
    if (!cur) return;
    cur.delete(ws);
    if (cur.size === 0) socketsBySid.delete(s);
  };

  ws.on('close', cleanup);
  ws.on('error', cleanup);
}

export function closeWebSocketsForSession(sid: string, reason = 'Session revoked'): number {
  const s = String(sid || '').trim();
  const set = socketsBySid.get(s);
  if (!set || set.size === 0) return 0;

  // Copy to avoid mutation while iterating.
  const sockets = Array.from(set.values());
  for (const ws of sockets) {
    try {
      // Tell clients explicitly (so they can sign out immediately).
      ws.send(JSON.stringify({ type: 'session_revoked', message: reason }));
    } catch (_) {}
    try {
      // 4001 is an app-defined close code.
      ws.close(4001, reason);
    } catch (_) {}
  }
  socketsBySid.delete(s);
  return sockets.length;
}

