import express from 'express';
import { createUser, getUserByEmail, getUserById, getUserByIdFull, getUserByVerificationToken, getUserByResetCode, markEmailVerified, setVerificationCode, generateVerificationCode, setResetCode, updatePassword, updateUserName, setPendingEmailChange, verifyCurrentEmailForChange, setNewEmailCode, verifyNewEmailForChange, clearPendingEmailChange, } from '../database.js';
import { hashPassword, verifyPassword, generateToken } from '../auth.js';
import { sendVerificationEmail, sendPasswordResetEmail, sendProfileChangeAlert } from '../emailService.js';
import { authenticate } from '../auth.js';
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
        // Generate JWT token
        const token = generateToken(user.id, user.email);
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
        if (!user) {
            return res.status(404).json({ error: 'User not found' });
        }
        return res.json({
            user: {
                id: user.id,
                email: user.email,
                name: user.name,
                email_verified: user.email_verified,
                created_at: user.created_at,
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