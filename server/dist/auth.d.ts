import { Request, Response, NextFunction } from 'express';
export interface JWTPayload {
    userId: string;
    email: string;
    sid?: string;
}
export interface AuthRequest extends Request {
    user?: JWTPayload;
}
export declare const hashPassword: (password: string) => Promise<string>;
export declare const verifyPassword: (password: string, hash: string) => Promise<boolean>;
export declare const generateToken: (userId: string, email: string, sid?: string) => string;
export declare const verifyToken: (token: string) => JWTPayload | null;
export declare const authenticate: (req: AuthRequest, res: Response, next: NextFunction) => void;
export declare const optionalAuthenticate: (req: AuthRequest, _res: Response, next: NextFunction) => void;
//# sourceMappingURL=auth.d.ts.map