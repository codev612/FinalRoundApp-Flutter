import express from 'express';
import { createUser, getUserByEmail, getUserById, getUserByIdFull, createAuthSession, countAuthSessions, listAuthSessions, revokeAuthSession, revokeOtherAuthSessions, deleteUserAccount, countTrustedDevices, getTrustedDevice, upsertTrustedDeviceOnLogin, createLoginChallenge, getLoginChallengeById, incrementLoginChallengeAttempts, markLoginChallengeUsed, getUserByVerificationToken, getUserByResetCode, markEmailVerified, setVerificationCode, generateVerificationCode, setResetCode, updatePassword, updateUserName, setPendingEmailChange, verifyCurrentEmailForChange, setNewEmailCode, verifyNewEmailForChange, clearPendingEmailChange, } from '../database.js';
import { hashPassword, verifyPassword, generateToken } from '../auth.js';
import { sendVerificationEmail, sendPasswordResetEmail, sendProfileChangeAlert, sendLoginSecurityCodeEmail } from '../emailService.js';
import { authenticate } from '../auth.js';
import { closeWebSocketsForSession } from '../sessionBus.js';
const router = express.Router();
// Signup
router.post('/signup', async (req, res) => {
    try {
        const { email, name, password } = req.body;
        // Validation
        if (!email || !name || !password) {
            return res.status(400).json({ error: 'Email, name, and password are required' });
        }
        // Name validation
        const trimmedName = name.trim();
        if (trimmedName.length === 0) {
            return res.status(400).json({ error: 'Name cannot be empty' });
        }
        if (trimmedName.length < 2) {
            return res.status(400).json({ error: 'Name must be at least 2 characters long' });
        }
        // Email validation
        const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
        if (!emailRegex.test(email)) {
            return res.status(400).json({ error: 'Invalid email format' });
        }
        // Password validation (minimum 8 characters)
        if (password.length < 8) {
            return res.status(400).json({ error: 'Password must be at least 8 characters long' });
        }
        // Check if user already exists
        const existingUser = await getUserByEmail(email);
        if (existingUser) {
            return res.status(409).json({ error: 'Email already registered' });
        }
        // Hash password
        const passwordHash = await hashPassword(password);
        // Create user
        const user = await createUser(email, trimmedName, passwordHash);
        // Send verification email with 6-digit code
        const emailSent = await sendVerificationEmail(email, user.verification_code);
        if (!emailSent) {
            // In development, log the code to console if Mailgun is not configured
            console.warn(`⚠ Mailgun not configured. Verification code for ${email}: ${user.verification_code}`);
            console.warn(`⚠ For development: Use this code to verify the email`);
        }
        // In development mode (when Mailgun not configured), include code in response
        const isDevelopment = !process.env.MAILGUN_API_KEY || !process.env.MAILGUN_DOMAIN;
        const responseData = {
            message: emailSent
                ? 'User created successfully. Please check your email for the verification code.'
                : 'User created successfully. Please check your email for the verification code (or see server logs if Mailgun is not configured).',
            user: {
                id: user.id,
                email: user.email,
                name: trimmedName,
                email_verified: false,
            },
        };
        // Include code in response for development (when Mailgun not configured)
        if (isDevelopment) {
            responseData.verification_code = user.verification_code;
            responseData.message = 'User created successfully. Use the verification code below (Mailgun not configured).';
        }
        return res.status(201).json(responseData);
    }
    catch (error) {
        console.error('Signup error:', error);
        res.status(500).json({ error: 'Internal server error' });
        return;
    }
});
// Signin
router.post('/signin', async (req, res) => {
    try {
        const { email, password } = req.body;
        // Validation
        if (!email || !password) {
            return res.status(400).json({ error: 'Email and password are required' });
        }
        // Get user
        const user = await getUserByEmail(email);
        if (!user || !user.id) {
            return res.status(401).json({ error: 'Invalid email or password' });
        }
        // Verify password
        const isValidPassword = await verifyPassword(password, user.password_hash);
        if (!isValidPassword) {
            return res.status(401).json({ error: 'Invalid email or password' });
        }
        // Check if email is verified
        if (!user.email_verified) {
            return res.status(403).json({
                error: 'Email not verified',
                email_verified: false,
                message: 'Please verify your email before signing in. Check your inbox for the verification link.',
            });
        }
        const userAgent = String(req.headers['user-agent'] || '');
        const forwardedFor = String(req.headers['x-forwarded-for'] || '');
        const ip = (forwardedFor.split(',')[0] || req.ip || '').trim();
        const deviceId = String(req.body?.deviceId || '').trim();
        if (!deviceId) {
            return res.status(400).json({ error: 'deviceId is required' });
        }
        const locationKeyFromIp = (rawIp) => {
            const ip2 = (rawIp || '').trim();
            if (!ip2)
                return null;
            // Strip IPv6-mapped IPv4 prefix
            const v = ip2.startsWith('::ffff:') ? ip2.substring('::ffff:'.length) : ip2;
            if (v.includes('.')) {
                const parts = v.split('.');
                if (parts.length >= 3)
                    return `${parts[0]}.${parts[1]}.${parts[2]}.0/24`;
                return v;
            }
            // IPv6: keep first 4 hextets (rough /64-ish bucket)
            const hextets = v.split(':').filter((p) => p.length > 0);
            return hextets.length >= 4 ? `${hextets.slice(0, 4).join(':')}::/64` : v;
        };
        const locationKey = locationKeyFromIp(ip);
        const detectPlatform = (ua) => {
            const s = (ua || '').toLowerCase();
            if (s.includes('windows'))
                return 'windows';
            if (s.includes('mac os') || s.includes('macintosh'))
                return 'mac';
            if (s.includes('android'))
                return 'android';
            if (s.includes('iphone') || s.includes('ipad') || s.includes('ios'))
                return 'ios';
            if (s.includes('linux'))
                return 'linux';
            return 'unknown';
        };
        const detectClientType = (ua) => {
            const s = (ua || '').toLowerCase();
            // Browser UAs almost always include Mozilla/
            if (s.includes('mozilla/'))
                return 'web';
            // Flutter/Dart (desktop/mobile native) often shows Dart/.. or Flutter
            if (s.includes('dart/') || s.includes('flutter'))
                return 'desktop';
            return 'unknown';
        };
        const headerClient = String((req.headers['x-finalround-client'] || req.headers['x-client-type'] || '')).trim().toLowerCase();
        const headerPlatform = String((req.headers['x-finalround-platform'] || req.headers['x-platform'] || '')).trim().toLowerCase();
        const bodyClient = (req.body?.clientType || '').toString().trim().toLowerCase();
        const bodyPlatform = (req.body?.platform || '').toString().trim().toLowerCase();
        const clientType = (headerClient || bodyClient) ||
            detectClientType(userAgent);
        const platform = (headerPlatform || bodyPlatform) ||
            detectPlatform(userAgent);
        const normalizedClient = clientType === 'web' || clientType === 'desktop' || clientType === 'mobile' ? clientType : 'unknown';
        const normalizedPlatform = platform === 'windows' || platform === 'mac' || platform === 'linux' || platform === 'android' || platform === 'ios'
            ? platform
            : 'unknown';
        // Security check: if a new device is detected OR location changed for this device,
        // require email code before issuing a token.
        const trustedCount = await countTrustedDevices(user.id);
        const trusted = await getTrustedDevice(user.id, deviceId);
        const isNewDevice = !trusted && trustedCount > 0;
        const isLocationChanged = !!(trusted && (trusted.lastLocationKey ?? null) && (trusted.lastLocationKey ?? null) != (locationKey ?? null));
        if (isNewDevice || isLocationChanged) {
            const code = generateVerificationCode(); // 6 digits
            const expiresAt = new Date(Date.now() + 10 * 60 * 1000);
            const challenge = await createLoginChallenge({
                userId: user.id,
                email: user.email,
                deviceId,
                locationKey,
                clientType: normalizedClient,
                platform: normalizedPlatform,
                userAgent,
                ip,
                code,
                expiresAt,
            });
            const sent = await sendLoginSecurityCodeEmail(user.email, code);
            if (!sent) {
                console.warn(`⚠ Mailgun not configured. Login security code for ${user.email}: ${code}`);
            }
            const isDevelopment = !process.env.MAILGUN_API_KEY || !process.env.MAILGUN_DOMAIN;
            return res.status(403).json({
                error: 'Security check required',
                requiresSecurityCheck: true,
                challengeId: challenge.id,
                message: sent
                    ? 'We sent a security code to your email. Enter it to finish signing in.'
                    : 'We generated a security code. Enter it to finish signing in (see server logs in development).',
                ...(isDevelopment ? { devCode: code } : {}),
            });
        }
        // Trusted/first device: proceed and record as trusted.
        await upsertTrustedDeviceOnLogin({
            userId: user.id,
            deviceId,
            clientType: normalizedClient,
            platform: normalizedPlatform,
            locationKey,
            ip,
            userAgent,
        });
        const sid = await createAuthSession(user.id, normalizedClient, normalizedPlatform, userAgent, ip, deviceId, locationKey);
        // Generate JWT token bound to this auth session
        const token = generateToken(user.id, user.email, sid);
        return res.json({
            message: 'Sign in successful',
            token,
            user: {
                id: user.id,
                email: user.email,
                name: user.name,
                email_verified: user.email_verified,
            },
        });
    }
    catch (error) {
        console.error('Signin error:', error);
        res.status(500).json({ error: 'Internal server error' });
        return;
    }
});
// Verify security code to finish sign-in
router.post('/verify-login-challenge', async (req, res) => {
    try {
        const challengeId = String(req.body?.challengeId || '').trim();
        const code = String(req.body?.code || '').trim();
        if (!challengeId || !code) {
            return res.status(400).json({ error: 'challengeId and code are required' });
        }
        if (typeof code !== 'string' || code.length !== 6 || !/^\d{6}$/.test(code)) {
            return res.status(400).json({ error: 'Invalid code format. Must be 6 digits.' });
        }
        const challenge = await getLoginChallengeById(challengeId);
        if (!challenge || !challenge.id) {
            return res.status(404).json({ error: 'Challenge not found' });
        }
        if (challenge.usedAt) {
            return res.status(400).json({ error: 'Challenge already used' });
        }
        if (challenge.expiresAt && new Date(challenge.expiresAt).getTime() < Date.now()) {
            return res.status(400).json({ error: 'Code expired. Please sign in again.' });
        }
        if ((challenge.attempts ?? 0) >= 6) {
            return res.status(429).json({ error: 'Too many attempts. Please sign in again.' });
        }
        if (challenge.code !== code) {
            await incrementLoginChallengeAttempts(challenge.id);
            return res.status(400).json({ error: 'Invalid code' });
        }
        await markLoginChallengeUsed(challenge.id);
        // Mark device trusted and create an auth session
        await upsertTrustedDeviceOnLogin({
            userId: challenge.userId,
            deviceId: challenge.deviceId,
            clientType: challenge.clientType,
            platform: challenge.platform,
            locationKey: challenge.locationKey ?? null,
            ip: challenge.ip,
            userAgent: challenge.userAgent,
        });
        const sid = await createAuthSession(challenge.userId, challenge.clientType, challenge.platform, challenge.userAgent, challenge.ip, challenge.deviceId, challenge.locationKey ?? null);
        const token = generateToken(challenge.userId, challenge.email, sid);
        const user = await getUserById(String(challenge.userId));
        return res.json({
            message: 'Sign in successful',
            token,
            user: user
                ? {
                    id: user.id,
                    email: user.email,
                    name: user.name,
                    email_verified: user.email_verified,
                }
                : { id: challenge.userId, email: challenge.email, name: '', email_verified: true },
        });
    }
    catch (error) {
        console.error('Verify login challenge error:', error);
        return res.status(500).json({ error: error.message || 'Internal server error' });
    }
});
// Active auth sessions (devices/logins)
router.get('/sessions', authenticate, async (req, res) => {
    try {
        const userId = req.user.userId;
        const limitRaw = typeof req.query?.limit === 'string' ? parseInt(req.query.limit, 10) : NaN;
        const skipRaw = typeof req.query?.skip === 'string' ? parseInt(req.query.skip, 10) : NaN;
        const limit = Number.isFinite(limitRaw) ? limitRaw : 10;
        const skip = Number.isFinite(skipRaw) ? skipRaw : 0;
        const [total, sessions] = await Promise.all([
            countAuthSessions(userId),
            listAuthSessions(userId, { limit, skip }),
        ]);
        const clientLabel = (t, p) => {
            const type = String(t || 'unknown');
            const plat = String(p || 'unknown');
            const typeLabel = type === 'web' ? 'Web' :
                type === 'desktop' ? 'Desktop app' :
                    type === 'mobile' ? 'Mobile app' :
                        'Unknown';
            const platLabel = plat === 'windows' ? 'Windows' :
                plat === 'mac' ? 'macOS' :
                    plat === 'linux' ? 'Linux' :
                        plat === 'android' ? 'Android' :
                            plat === 'ios' ? 'iOS' :
                                '';
            return platLabel ? `${typeLabel} • ${platLabel}` : typeLabel;
        };
        return res.json({
            currentSessionId: req.user?.sid ?? null,
            total,
            limit,
            skip,
            sessions: sessions.map((s) => ({
                id: s.id,
                createdAt: s.createdAt,
                lastSeenAt: s.lastSeenAt,
                clientType: s.clientType ?? 'unknown',
                platform: s.platform ?? 'unknown',
                clientLabel: clientLabel(s.clientType, s.platform),
                userAgent: s.userAgent,
                ip: s.ip,
                revokedAt: s.revokedAt,
            })),
        });
    }
    catch (error) {
        console.error('List auth sessions error:', error);
        return res.status(500).json({ error: error.message || 'Failed to list sessions' });
    }
});
router.post('/sessions/:id/revoke', authenticate, async (req, res) => {
    try {
        const userId = req.user.userId;
        const id = String(req.params.id || '');
        if (!id)
            return res.status(400).json({ error: 'Session id is required' });
        const ok = await revokeAuthSession(userId, id);
        if (!ok)
            return res.status(404).json({ error: 'Session not found' });
        closeWebSocketsForSession(id);
        return res.json({ ok: true });
    }
    catch (error) {
        console.error('Revoke auth session error:', error);
        return res.status(500).json({ error: error.message || 'Failed to revoke session' });
    }
});
router.post('/sessions/revoke-others', authenticate, async (req, res) => {
    try {
        const userId = req.user.userId;
        const keep = req.user?.sid ? String(req.user.sid) : null;
        const revoked = await revokeOtherAuthSessions(userId, keep);
        return res.json({ ok: true, revoked });
    }
    catch (error) {
        console.error('Revoke other sessions error:', error);
        return res.status(500).json({ error: error.message || 'Failed to revoke other sessions' });
    }
});
// Delete account (permanent)
router.post('/delete-account', authenticate, async (req, res) => {
    try {
        const userId = req.user.userId;
        const password = String(req.body?.password || '');
        const confirm = String(req.body?.confirm || '');
        if (!password)
            return res.status(400).json({ error: 'Password is required' });
        if (confirm !== 'DELETE')
            return res.status(400).json({ error: 'Type DELETE to confirm' });
        const user = await getUserByIdFull(userId);
        if (!user)
            return res.status(404).json({ error: 'User not found' });
        const ok = await verifyPassword(password, user.password_hash);
        if (!ok)
            return res.status(401).json({ error: 'Invalid password' });
        await deleteUserAccount(userId);
        return res.json({ ok: true });
    }
    catch (error) {
        console.error('Delete account error:', error);
        return res.status(500).json({ error: error.message || 'Failed to delete account' });
    }
});
// Verify email with code (new endpoint)
router.post('/verify-email', async (req, res) => {
    try {
        const { email, code } = req.body;
        if (!email || !code) {
            return res.status(400).json({ error: 'Email and verification code are required' });
        }
        if (typeof code !== 'string' || code.length !== 6 || !/^\d{6}$/.test(code)) {
            return res.status(400).json({ error: 'Invalid verification code format. Must be 6 digits.' });
        }
        const user = await getUserByEmail(email);
        if (!user || !user.id) {
            return res.status(404).json({ error: 'User not found' });
        }
        // Check if code matches and is not expired
        if (user.verification_code !== code) {
            return res.status(400).json({ error: 'Invalid verification code' });
        }
        if (!user.verification_code_expires || user.verification_code_expires < Date.now()) {
            return res.status(400).json({ error: 'Verification code has expired' });
        }
        // Mark email as verified
        await markEmailVerified(user.id);
        return res.json({
            message: 'Email verified successfully',
            user: {
                id: user.id,
                email: user.email,
                name: user.name,
                email_verified: true,
            },
        });
    }
    catch (error) {
        console.error('Verify email error:', error);
        res.status(500).json({ error: 'Internal server error' });
        return;
    }
});
// Legacy verify email with token (for backward compatibility)
router.get('/verify-email', async (req, res) => {
    try {
        const { token } = req.query;
        if (!token || typeof token !== 'string') {
            return res.status(400).json({ error: 'Verification token is required' });
        }
        const user = await getUserByVerificationToken(token);
        if (!user || !user.id) {
            return res.status(400).json({ error: 'Invalid or expired verification token' });
        }
        // Mark email as verified
        await markEmailVerified(user.id);
        return res.json({
            message: 'Email verified successfully',
            user: {
                id: user.id,
                email: user.email,
                name: user.name,
                email_verified: true,
            },
        });
    }
    catch (error) {
        console.error('Verify email error:', error);
        res.status(500).json({ error: 'Internal server error' });
        return;
    }
});
// Resend verification email
router.post('/resend-verification', async (req, res) => {
    try {
        const { email } = req.body;
        if (!email) {
            return res.status(400).json({ error: 'Email is required' });
        }
        const user = await getUserByEmail(email);
        if (!user) {
            // Don't reveal if email exists or not for security
            return res.json({
                message: 'If the email exists and is not verified, a verification email has been sent.',
            });
        }
        if (user.email_verified) {
            return res.json({ message: 'Email is already verified' });
        }
        if (!user.id) {
            return res.status(500).json({ error: 'Invalid user data' });
        }
        // Generate new 6-digit verification code
        const newCode = generateVerificationCode();
        await setVerificationCode(user.id, newCode, 10); // 10 minutes expiration
        // Send verification email with code
        const emailSent = await sendVerificationEmail(email, newCode);
        if (!emailSent) {
            return res.status(500).json({ error: 'Failed to send verification email' });
        }
        return res.json({
            message: 'Verification email sent. Please check your inbox.',
        });
    }
    catch (error) {
        console.error('Resend verification error:', error);
        res.status(500).json({ error: 'Internal server error' });
        return;
    }
});
// Request password reset
router.post('/forgot-password', async (req, res) => {
    try {
        const { email } = req.body;
        if (!email) {
            return res.status(400).json({ error: 'Email is required' });
        }
        const user = await getUserByEmail(email);
        if (!user) {
            // Don't reveal if email exists or not for security
            return res.json({
                message: 'If the email exists, a password reset link has been sent.',
            });
        }
        if (!user.id) {
            return res.status(500).json({ error: 'Invalid user data' });
        }
        // Generate reset code (6-digit)
        const resetCode = generateVerificationCode();
        await setResetCode(user.id, resetCode);
        // Send password reset email with code
        const emailSent = await sendPasswordResetEmail(email, resetCode);
        if (!emailSent) {
            return res.status(500).json({ error: 'Failed to send password reset email' });
        }
        return res.json({
            message: 'If the email exists, a password reset link has been sent.',
        });
    }
    catch (error) {
        console.error('Forgot password error:', error);
        res.status(500).json({ error: 'Internal server error' });
        return;
    }
});
// Reset password
router.post('/reset-password', async (req, res) => {
    try {
        const { code, password } = req.body;
        if (!code || !password) {
            return res.status(400).json({ error: 'Reset code and password are required' });
        }
        if (password.length < 8) {
            return res.status(400).json({ error: 'Password must be at least 8 characters long' });
        }
        const user = await getUserByResetCode(code);
        if (!user || !user.id) {
            return res.status(400).json({ error: 'Invalid or expired reset code' });
        }
        // Update password
        try {
            const passwordHash = await hashPassword(password);
            console.log(`[Reset Password] Updating password for user ${user.id}`);
            await updatePassword(user.id, passwordHash);
            // Verify the password was updated correctly by fetching the user again
            const updatedUser = await getUserByIdFull(user.id);
            if (!updatedUser) {
                console.error(`[Reset Password] Failed to fetch user after update: ${user.id}`);
                return res.status(500).json({ error: 'Failed to verify password update' });
            }
            // Verify the new password works
            const passwordValid = await verifyPassword(password, updatedUser.password_hash);
            if (!passwordValid) {
                console.error(`[Reset Password] Password verification failed after update for user: ${user.id}`);
                return res.status(500).json({ error: 'Password update verification failed' });
            }
            console.log(`[Reset Password] Password updated and verified successfully for user ${user.id}`);
        }
        catch (error) {
            console.error('[Reset Password] Error updating password:', error);
            return res.status(500).json({ error: 'Failed to update password' });
        }
        return res.json({
            message: 'Password reset successfully',
        });
    }
    catch (error) {
        console.error('Reset password error:', error);
        res.status(500).json({ error: 'Internal server error' });
        return;
    }
});
// Get current user (protected route)
router.get('/me', authenticate, async (req, res) => {
    try {
        if (!req.user) {
            return res.status(401).json({ error: 'Unauthorized' });
        }
        const user = await getUserById(String(req.user.userId));
        const fullUser = await getUserByIdFull(String(req.user.userId));
        if (!user) {
            return res.status(404).json({ error: 'User not found' });
        }
        const pendingEmail = fullUser?.pending_email ?? null;
        const step = pendingEmail
            ? (fullUser?.current_email_code ? 'verify_current' : 'verify_new')
            : null;
        return res.json({
            user: {
                id: user.id,
                email: user.email,
                name: user.name,
                email_verified: user.email_verified,
                created_at: user.created_at,
            },
            emailChange: {
                pendingEmail,
                step,
            },
        });
    }
    catch (error) {
        console.error('Get user error:', error);
        res.status(500).json({ error: 'Internal server error' });
        return;
    }
});
// Update profile (name and/or email)
router.put('/profile', authenticate, async (req, res) => {
    try {
        if (!req.user) {
            return res.status(401).json({ error: 'Unauthorized' });
        }
        const { name, email } = req.body;
        if (!name && !email) {
            return res.status(400).json({ error: 'At least one field (name or email) is required' });
        }
        const user = await getUserById(String(req.user.userId));
        if (!user) {
            return res.status(404).json({ error: 'User not found' });
        }
        const oldName = user.name;
        let nameChanged = false;
        // Update name if provided
        if (name !== undefined) {
            if (name.trim().length < 2) {
                return res.status(400).json({ error: 'Name must be at least 2 characters' });
            }
            const newName = name.trim();
            if (newName !== oldName) {
                await updateUserName(String(req.user.userId), newName);
                nameChanged = true;
            }
        }
        // Update email if provided
        if (email !== undefined) {
            const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
            if (!emailRegex.test(email)) {
                return res.status(400).json({ error: 'Invalid email format' });
            }
            // Check if email is already taken by another user
            const existingUser = await getUserByEmail(email);
            if (existingUser && existingUser.id !== user.id) {
                return res.status(400).json({ error: 'Email already in use' });
            }
            // Don't update email yet - store as pending and send code to current email (step 1)
            const currentEmailCode = generateVerificationCode();
            await setPendingEmailChange(String(req.user.userId), email.trim(), currentEmailCode);
            // Send verification code to current email (step 1)
            await sendVerificationEmail(user.email, currentEmailCode);
        }
        // Fetch updated user
        const updatedUser = await getUserById(String(req.user.userId));
        if (!updatedUser) {
            return res.status(500).json({ error: 'Failed to fetch updated user' });
        }
        // Check if there's a pending email change
        const fullUser = await getUserByIdFull(String(req.user.userId));
        const hasPendingEmail = fullUser?.pending_email != null;
        // Send alert email if name was changed
        if (nameChanged) {
            await sendProfileChangeAlert(updatedUser.email, {
                nameChanged: true,
                oldName: oldName,
                newName: updatedUser.name,
            });
        }
        return res.json({
            message: hasPendingEmail
                ? 'Verification code sent to your current email. Please verify to complete email change.'
                : 'Profile updated successfully',
            user: {
                id: updatedUser.id,
                email: updatedUser.email,
                name: updatedUser.name,
                email_verified: updatedUser.email_verified,
                created_at: updatedUser.created_at,
            },
            pendingEmail: hasPendingEmail ? fullUser.pending_email : null,
        });
    }
    catch (error) {
        console.error('Update profile error:', error);
        res.status(500).json({ error: 'Internal server error' });
        return;
    }
});
// Change password
router.put('/change-password', authenticate, async (req, res) => {
    try {
        if (!req.user) {
            return res.status(401).json({ error: 'Unauthorized' });
        }
        const { currentPassword, newPassword } = req.body;
        if (!currentPassword || !newPassword) {
            return res.status(400).json({ error: 'Current password and new password are required' });
        }
        if (newPassword.length < 8) {
            return res.status(400).json({ error: 'New password must be at least 8 characters' });
        }
        // Get current user info
        const currentUser = await getUserById(String(req.user.userId));
        if (!currentUser) {
            return res.status(404).json({ error: 'User not found' });
        }
        // Get user with password hash for verification
        const user = await getUserByEmail(currentUser.email);
        if (!user || !user.id) {
            return res.status(404).json({ error: 'User not found' });
        }
        // Verify current password
        const isValid = await verifyPassword(currentPassword, user.password_hash);
        if (!isValid) {
            return res.status(401).json({ error: 'Current password is incorrect' });
        }
        // Update password
        const passwordHash = await hashPassword(newPassword);
        await updatePassword(user.id, passwordHash);
        // Send alert email about password change
        await sendProfileChangeAlert(currentUser.email, {
            passwordChanged: true,
        });
        return res.json({
            message: 'Password changed successfully',
        });
    }
    catch (error) {
        console.error('Change password error:', error);
        res.status(500).json({ error: 'Internal server error' });
        return;
    }
});
// Verify current email for email change (step 1)
router.post('/verify-current-email-change', authenticate, async (req, res) => {
    try {
        if (!req.user) {
            return res.status(401).json({ error: 'Unauthorized' });
        }
        const { currentEmailCode } = req.body;
        if (!currentEmailCode) {
            return res.status(400).json({ error: 'Verification code is required' });
        }
        const isValid = await verifyCurrentEmailForChange(String(req.user.userId), currentEmailCode);
        if (!isValid) {
            return res.status(400).json({ error: 'Invalid or expired verification code' });
        }
        // Get pending email
        const fullUser = await getUserByIdFull(String(req.user.userId));
        if (!fullUser || !fullUser.pending_email) {
            return res.status(400).json({ error: 'No pending email change found' });
        }
        // Generate and send verification code to new email (step 2)
        const newEmailCode = generateVerificationCode();
        await setNewEmailCode(String(req.user.userId), newEmailCode);
        await sendVerificationEmail(fullUser.pending_email, newEmailCode);
        return res.json({
            message: 'Current email verified. Verification code sent to new email.',
            pendingEmail: fullUser.pending_email,
        });
    }
    catch (error) {
        console.error('Verify current email change error:', error);
        res.status(500).json({ error: 'Internal server error' });
        return;
    }
});
// Verify new email for email change (step 2)
router.post('/verify-new-email-change', authenticate, async (req, res) => {
    try {
        if (!req.user) {
            return res.status(401).json({ error: 'Unauthorized' });
        }
        const { newEmailCode } = req.body;
        if (!newEmailCode) {
            return res.status(400).json({ error: 'Verification code is required' });
        }
        // Get old email before verification
        const fullUserBefore = await getUserByIdFull(String(req.user.userId));
        const oldEmail = fullUserBefore?.email;
        const isValid = await verifyNewEmailForChange(String(req.user.userId), newEmailCode);
        if (!isValid) {
            return res.status(400).json({ error: 'Invalid or expired verification code' });
        }
        // Fetch updated user
        const updatedUser = await getUserById(String(req.user.userId));
        if (!updatedUser) {
            return res.status(500).json({ error: 'Failed to fetch updated user' });
        }
        // Send alert email about email change
        if (oldEmail && oldEmail !== updatedUser.email) {
            await sendProfileChangeAlert(updatedUser.email, {
                emailChanged: true,
                oldEmail: oldEmail,
                newEmail: updatedUser.email,
            });
        }
        return res.json({
            message: 'Email changed successfully.',
            user: {
                id: updatedUser.id,
                email: updatedUser.email,
                name: updatedUser.name,
                email_verified: updatedUser.email_verified,
                created_at: updatedUser.created_at,
            },
        });
    }
    catch (error) {
        console.error('Verify new email change error:', error);
        res.status(500).json({ error: 'Internal server error' });
        return;
    }
});
// Cancel pending email change
router.post('/cancel-email-change', authenticate, async (req, res) => {
    try {
        if (!req.user) {
            return res.status(401).json({ error: 'Unauthorized' });
        }
        await clearPendingEmailChange(String(req.user.userId));
        return res.json({
            message: 'Email change cancelled',
        });
    }
    catch (error) {
        console.error('Cancel email change error:', error);
        res.status(500).json({ error: 'Internal server error' });
        return;
    }
});
export default router;
//# sourceMappingURL=auth.js.map