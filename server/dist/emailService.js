import FormData from 'form-data';
import Mailgun from 'mailgun.js';
// Read environment variables (will be re-read when initializeMailgun is called)
let MAILGUN_API_KEY = '';
let DOMAIN = '';
let FROM_EMAIL = '';
let MAILGUN_URL;
// Initialize Mailgun client
let mg = null;
// Function to initialize Mailgun (called after dotenv is loaded)
export function initializeMailgun() {
    // Re-read environment variables
    MAILGUN_API_KEY = process.env.MAILGUN_API_KEY || '';
    DOMAIN = process.env.MAILGUN_DOMAIN || '';
    FROM_EMAIL = process.env.MAILGUN_FROM_EMAIL || `noreply@${DOMAIN}`;
    MAILGUN_URL = process.env.MAILGUN_URL;
    // Debug: Log environment variable status (without exposing sensitive data)
    if (MAILGUN_API_KEY) {
        console.log('✓ MAILGUN_API_KEY is set (length: ' + MAILGUN_API_KEY.length + ')');
    }
    else {
        console.warn('⚠ MAILGUN_API_KEY is not set');
    }
    if (DOMAIN) {
        console.log('✓ MAILGUN_DOMAIN is set: ' + DOMAIN);
    }
    else {
        console.warn('⚠ MAILGUN_DOMAIN is not set');
    }
    // Initialize Mailgun client only if API key is provided
    if (MAILGUN_API_KEY && DOMAIN) {
        try {
            const mailgun = new Mailgun(FormData);
            const clientOptions = {
                username: 'api',
                key: MAILGUN_API_KEY,
            };
            // Add EU endpoint if specified
            if (MAILGUN_URL) {
                clientOptions.url = MAILGUN_URL;
            }
            mg = mailgun.client(clientOptions);
            console.log('✓ Mailgun initialized successfully');
            console.log(`  Domain: ${DOMAIN}`);
            console.log(`  From Email: ${FROM_EMAIL}`);
            if (MAILGUN_URL) {
                console.log(`  Endpoint: ${MAILGUN_URL}`);
            }
        }
        catch (error) {
            console.error('✗ Failed to initialize Mailgun client:', error);
        }
    }
    else {
        console.warn('⚠ Mailgun not configured:');
        if (!MAILGUN_API_KEY)
            console.warn('  - MAILGUN_API_KEY is missing');
        if (!DOMAIN)
            console.warn('  - MAILGUN_DOMAIN is missing');
        console.warn('  Verification codes will be logged to console in development mode');
    }
}
// Initialize on module load (will be re-initialized after dotenv loads)
initializeMailgun();
// Send verification email with 6-digit code
export const sendVerificationEmail = async (email, code) => {
    if (!mg || !MAILGUN_API_KEY || !DOMAIN) {
        // Don't log here - let the caller handle the message
        return false;
    }
    const messageData = {
        from: FROM_EMAIL,
        to: email,
        subject: 'Verify your FinalRound account',
        html: `
      <!DOCTYPE html>
      <html>
        <head>
          <style>
            body { font-family: Arial, sans-serif; line-height: 1.6; color: #333; }
            .container { max-width: 600px; margin: 0 auto; padding: 20px; }
            .code-box { 
              display: inline-block; 
              padding: 20px 30px; 
              background-color: #f8f9fa; 
              border: 2px solid #007bff; 
              border-radius: 8px; 
              font-size: 32px; 
              font-weight: bold; 
              letter-spacing: 8px; 
              color: #007bff; 
              margin: 20px 0; 
              text-align: center;
            }
          </style>
        </head>
        <body>
          <div class="container">
            <h1>Welcome to FinalRound!</h1>
            <p>Thank you for signing up. Please verify your email address using the code below:</p>
            <div class="code-box">${code}</div>
            <p>Enter this code in the app to complete your registration.</p>
            <p>This code will expire in 10 minutes.</p>
            <p>If you didn't create an account, please ignore this email.</p>
          </div>
        </body>
      </html>
    `,
        text: `
      Welcome to FinalRound!
      
      Thank you for signing up. Please verify your email address using this code:
      
      ${code}
      
      Enter this code in the app to complete your registration.
      
      This code will expire in 10 minutes.
      
      If you didn't create an account, please ignore this email.
    `,
    };
    try {
        const data = await mg.messages.create(DOMAIN, messageData);
        console.log(`✓ Verification email sent to ${email}`);
        console.log(`  Code: ${code}`);
        console.log(`  Message ID: ${data.id || 'N/A'}`);
        return true;
    }
    catch (error) {
        console.error('✗ Error sending verification email:', error);
        if (error.message) {
            console.error(`  Error message: ${error.message}`);
        }
        return false;
    }
};
// Send password reset email
export const sendPasswordResetEmail = async (email, code) => {
    if (!mg || !MAILGUN_API_KEY || !DOMAIN) {
        console.warn('Mailgun not configured. Skipping email send.');
        return false;
    }
    const messageData = {
        from: FROM_EMAIL,
        to: email,
        subject: 'Reset your FinalRound password',
        html: `
      <!DOCTYPE html>
      <html>
        <head>
          <style>
            body { font-family: Arial, sans-serif; line-height: 1.6; color: #333; }
            .container { max-width: 600px; margin: 0 auto; padding: 20px; }
            .code-box { display: inline-block; padding: 16px 24px; background-color: #f5f5f5; border: 2px solid #333; border-radius: 8px; font-size: 24px; font-weight: bold; letter-spacing: 4px; margin: 20px 0; font-family: monospace; }
            .button { display: inline-block; padding: 12px 24px; background-color: #dc3545; color: white; text-decoration: none; border-radius: 5px; margin: 20px 0; }
            .button:hover { background-color: #c82333; }
          </style>
        </head>
        <body>
          <div class="container">
            <h1>Password Reset Request</h1>
            <p>You requested to reset your FinalRound password. Use the code below to reset it:</p>
            <div style="text-align: center;">
              <div class="code-box">${code}</div>
            </div>
            <p>Enter this code in the app to reset your password. This code will expire in 10 minutes.</p>
            <p>If you didn't request a password reset, please ignore this email.</p>
          </div>
        </body>
      </html>
    `,
        text: `
      Password Reset Request
      
      You requested to reset your FinalRound password. Use the code below to reset it:
      
      ${code}
      
      Enter this code in the app to reset your password. This code will expire in 10 minutes.
      
      If you didn't request a password reset, please ignore this email.
    `,
    };
    try {
        const data = await mg.messages.create(DOMAIN, messageData);
        console.log(`✓ Password reset email sent to ${email}`);
        console.log(`  Message ID: ${data.id || 'N/A'}`);
        return true;
    }
    catch (error) {
        console.error('✗ Error sending password reset email:', error);
        if (error.message) {
            console.error(`  Error message: ${error.message}`);
        }
        return false;
    }
};
// Send profile change alert email
export const sendProfileChangeAlert = async (email, changes) => {
    if (!mg || !MAILGUN_API_KEY || !DOMAIN) {
        console.warn('Mailgun not configured. Skipping profile change alert email.');
        return false;
    }
    const changeList = [];
    if (changes.nameChanged && changes.oldName && changes.newName) {
        changeList.push(`Name: "${changes.oldName}" → "${changes.newName}"`);
    }
    if (changes.emailChanged && changes.oldEmail && changes.newEmail) {
        changeList.push(`Email: "${changes.oldEmail}" → "${changes.newEmail}"`);
    }
    if (changes.passwordChanged) {
        changeList.push('Password: Changed');
    }
    if (changeList.length === 0) {
        return false; // No changes to report
    }
    const changesHtml = changeList.map(change => `<li>${change}</li>`).join('\n');
    const changesText = changeList.join('\n');
    const messageData = {
        from: FROM_EMAIL,
        to: email,
        subject: 'Your FinalRound profile has been updated',
        html: `
      <!DOCTYPE html>
      <html>
        <head>
          <style>
            body { font-family: Arial, sans-serif; line-height: 1.6; color: #333; }
            .container { max-width: 600px; margin: 0 auto; padding: 20px; }
            .alert-box { 
              background-color: #fff3cd; 
              border: 1px solid #ffc107; 
              border-radius: 5px; 
              padding: 15px; 
              margin: 20px 0; 
            }
            .changes-list { margin: 15px 0; padding-left: 20px; }
            .warning { color: #856404; font-weight: bold; }
          </style>
        </head>
        <body>
          <div class="container">
            <h1>Profile Update Alert</h1>
            <p>Your FinalRound account profile has been updated:</p>
            <div class="alert-box">
              <ul class="changes-list">
                ${changesHtml}
              </ul>
            </div>
            <p class="warning">⚠️ If you didn't make these changes, please contact support immediately.</p>
            <p>This is an automated notification to keep you informed about changes to your account.</p>
          </div>
        </body>
      </html>
    `,
        text: `
      Profile Update Alert
      
      Your FinalRound account profile has been updated:
      
      ${changesText}
      
      ⚠️ If you didn't make these changes, please contact support immediately.
      
      This is an automated notification to keep you informed about changes to your account.
    `,
    };
    try {
        const data = await mg.messages.create(DOMAIN, messageData);
        console.log(`✓ Profile change alert email sent to ${email}`);
        console.log(`  Message ID: ${data.id || 'N/A'}`);
        return true;
    }
    catch (error) {
        console.error('✗ Error sending profile change alert email:', error);
        if (error.message) {
            console.error(`  Error message: ${error.message}`);
        }
        return false;
    }
};
// Send login security code email (new device/location)
export const sendLoginSecurityCodeEmail = async (email, code) => {
    if (!mg || !MAILGUN_API_KEY || !DOMAIN) {
        return false;
    }
    const messageData = {
        from: FROM_EMAIL,
        to: email,
        subject: 'FinalRound security code',
        html: `
      <!DOCTYPE html>
      <html>
        <head>
          <style>
            body { font-family: Arial, sans-serif; line-height: 1.6; color: #333; }
            .container { max-width: 600px; margin: 0 auto; padding: 20px; }
            .code-box {
              display: inline-block;
              padding: 16px 24px;
              background-color: #f5f5f5;
              border: 2px solid #8b5cf6;
              border-radius: 10px;
              font-size: 28px;
              font-weight: 900;
              letter-spacing: 6px;
              margin: 16px 0;
              font-family: monospace;
              color: #4c1d95;
            }
          </style>
        </head>
        <body>
          <div class="container">
            <h1>Security check</h1>
            <p>We detected a new device or a location change. Use this code to finish signing in:</p>
            <div class="code-box">${code}</div>
            <p>This code expires in 10 minutes.</p>
            <p>If you didn’t try to sign in, you should change your password.</p>
          </div>
        </body>
      </html>
    `,
        text: `
Security check

We detected a new device or a location change. Use this code to finish signing in:

${code}

This code expires in 10 minutes.
If you didn’t try to sign in, you should change your password.
    `,
    };
    try {
        await mg.messages.create(DOMAIN, messageData);
        console.log(`✓ Login security code sent to ${email}`);
        return true;
    }
    catch (error) {
        console.error('✗ Error sending login security code:', error);
        return false;
    }
};
//# sourceMappingURL=emailService.js.map