import jwt from 'jsonwebtoken';
import bcrypt from 'bcrypt';
import { validateAuthSessionAndMaybeTouch } from './database.js';
const JWT_SECRET = process.env.JWT_SECRET || 'your-secret-key-change-in-production';
const JWT_EXPIRES_IN = process.env.JWT_EXPIRES_IN || '7d';
// Hash password
export const hashPassword = async (password) => {
    const saltRounds = 10;
    return await bcrypt.hash(password, saltRounds);
};
// Verify password
export const verifyPassword = async (password, hash) => {
    return await bcrypt.compare(password, hash);
};
// Generate JWT token
export const generateToken = (userId, email, sid) => {
    return jwt.sign({ userId, email, ...(sid ? { sid } : {}) }, JWT_SECRET, { expiresIn: JWT_EXPIRES_IN });
};
// Verify JWT token
export const verifyToken = (token) => {
    try {
        return jwt.verify(token, JWT_SECRET);
    }
    catch (error) {
        return null;
    }
};
// Authentication middleware
export const authenticate = (req, res, next) => {
    try {
        const authHeader = req.headers.authorization;
        if (!authHeader || !authHeader.startsWith('Bearer ')) {
            if (req.method === 'DELETE' && req.path?.includes('custom-mode-configs')) {
                console.log('[RemoveMode] Auth 401: No token provided', { method: req.method, path: req.path });
            }
            res.status(401).json({ error: 'No token provided' });
            return;
        }
        const token = authHeader.substring(7); // Remove 'Bearer ' prefix
        const decoded = verifyToken(token);
        if (!decoded) {
            if (req.method === 'DELETE' && req.path?.includes('custom-mode-configs')) {
                console.log('[RemoveMode] Auth 401: Invalid or expired token', { method: req.method, path: req.path });
            }
            res.status(401).json({ error: 'Invalid or expired token' });
            return;
        }
        req.user = decoded;
        // If the token is bound to a session, enforce it and update lastSeen.
        const sid = decoded?.sid;
        if (typeof sid === 'string' && sid.length > 0) {
            validateAuthSessionAndMaybeTouch(decoded.userId, sid, 60_000)
                .then((ok) => {
                if (!ok) {
                    res.status(401).json({ error: 'Session has been revoked. Please sign in again.' });
                    return;
                }
                next();
            })
                .catch((_e) => {
                // If DB is temporarily unavailable, fail closed for session-bound tokens.
                res.status(503).json({ error: 'Session validation failed. Please try again.' });
            });
            return;
        }
        next();
    }
    catch (error) {
        if (req.method === 'DELETE' && req.path?.includes('custom-mode-configs')) {
            console.log('[RemoveMode] Auth 401: Exception', error);
        }
        res.status(401).json({ error: 'Authentication failed' });
    }
};
// Optional authentication (doesn't fail if no token)
export const optionalAuthenticate = (req, _res, next) => {
    try {
        const authHeader = req.headers.authorization;
        if (authHeader && authHeader.startsWith('Bearer ')) {
            const token = authHeader.substring(7);
            const decoded = verifyToken(token);
            if (decoded) {
                req.user = decoded;
            }
        }
        next();
    }
    catch (error) {
        next();
    }
};
//# sourceMappingURL=auth.js.map