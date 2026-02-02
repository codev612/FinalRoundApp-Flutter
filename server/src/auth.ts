import jwt from 'jsonwebtoken';
import bcrypt from 'bcrypt';
import { Request, Response, NextFunction } from 'express';
import { validateAuthSessionAndMaybeTouch } from './database.js';

const JWT_SECRET = process.env.JWT_SECRET || 'your-secret-key-change-in-production';
const JWT_EXPIRES_IN = process.env.JWT_EXPIRES_IN || '7d';

export interface JWTPayload {
  userId: string; // MongoDB uses string IDs
  email: string;
  sid?: string; // auth session id
}

export interface AuthRequest extends Request {
  user?: JWTPayload;
}

// Hash password
export const hashPassword = async (password: string): Promise<string> => {
  const saltRounds = 10;
  return await bcrypt.hash(password, saltRounds);
};

// Verify password
export const verifyPassword = async (password: string, hash: string): Promise<boolean> => {
  return await bcrypt.compare(password, hash);
};

// Generate JWT token
export const generateToken = (userId: string, email: string, sid?: string): string => {
  return jwt.sign(
    { userId, email, ...(sid ? { sid } : {}) },
    JWT_SECRET,
    { expiresIn: JWT_EXPIRES_IN } as jwt.SignOptions
  );
};

// Verify JWT token
export const verifyToken = (token: string): JWTPayload | null => {
  try {
    return jwt.verify(token, JWT_SECRET) as JWTPayload;
  } catch (error) {
    return null;
  }
};

// Authentication middleware
export const authenticate = (req: AuthRequest, res: Response, next: NextFunction): void => {
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
    const sid = (decoded as any)?.sid;
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
  } catch (error) {
    if (req.method === 'DELETE' && req.path?.includes('custom-mode-configs')) {
      console.log('[RemoveMode] Auth 401: Exception', error);
    }
    res.status(401).json({ error: 'Authentication failed' });
  }
};

// Optional authentication (doesn't fail if no token)
export const optionalAuthenticate = (req: AuthRequest, _res: Response, next: NextFunction): void => {
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
  } catch (error) {
    next();
  }
};
