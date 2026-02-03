import express from 'express';
import { WebSocketServer } from 'ws';
import { createClient, LiveTranscriptionEvents } from '@deepgram/sdk';
import OpenAI from 'openai';
import dotenv from 'dotenv';
import cors from 'cors';
import { createServer } from 'http';
import authRoutes from './routes/auth.js';
import paypalRoutes from './routes/paypal.js';
import { authenticate, verifyToken } from './auth.js';
import { registerWebSocketForSession } from './sessionBus.js';
import { connectDB, closeDB, createMeetingSession, getMeetingSession, updateMeetingSession, listMeetingSessions, deleteMeetingSession, getModeConfigs, saveModeConfig, getCustomModes, saveCustomModes, deleteCustomMode, getQuestionTemplates, saveQuestionTemplates, deleteQuestionTemplate, saveApiUsage, getUserApiUsage, getUserApiUsageStats, getUserDailyAiTokenUsage, getUserDailyAiTokenUsageByModel, getUserByIdFull, saveTranscriptionUsage, getTranscriptionUsageMsForPeriod, validateAuthSessionAndMaybeTouch, } from './database.js';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import fs from 'fs';
const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
// Load .env file - try server directory first, then parent directory (project root)
const serverEnvPath = join(__dirname, '../.env');
const parentEnvPath = join(__dirname, '../../.env');
if (fs.existsSync(serverEnvPath)) {
    dotenv.config({ path: serverEnvPath });
    console.log('✓ Loaded .env from server directory');
}
else if (fs.existsSync(parentEnvPath)) {
    dotenv.config({ path: parentEnvPath });
    console.log('✓ Loaded .env from project root');
}
else {
    // Try default location (current working directory)
    dotenv.config();
    if (fs.existsSync('.env')) {
        console.log('✓ Loaded .env from current working directory');
    }
    else {
        console.log('⚠ No .env file found - using environment variables and defaults');
    }
}
// Initialize MongoDB connection
connectDB().catch((error) => {
    console.error('Failed to connect to MongoDB:', error);
    process.exit(1);
});
// Import and initialize email service after dotenv is loaded
import { initializeMailgun } from './emailService.js';
initializeMailgun();
const app = express();
const PORT = Number(process.env.PORT) || 3000;
// Middleware
app.use(cors());
// Increase JSON body limit to support screenshot (base64) payloads.
app.use(express.json({ limit: '8mb' }));
// Serve static files from public directory
const publicDir = join(__dirname, '../public');
app.use(express.static(publicDir));
// Simple website routes (clean URLs)
const servePublicHtml = (relativePath) => (_req, res) => {
    return res.sendFile(join(publicDir, relativePath));
};
app.get('/', servePublicHtml('index.html'));
app.get('/dashboard', servePublicHtml('dashboard.html'));
app.get('/auth/signin', servePublicHtml('auth/signin.html'));
app.get('/auth/signup', servePublicHtml('auth/signup.html'));
app.get('/auth/forgot-password', servePublicHtml('auth/forgot-password.html'));
app.get('/auth/reset-password', servePublicHtml('auth/reset-password.html'));
app.get('/auth/security-check', servePublicHtml('auth/security-check.html'));
// Health check endpoint
app.get('/health', (_req, res) => {
    res.json({ status: 'ok', message: 'FinalRoundApp backend is running' });
});
// Authentication routes
app.use('/api/auth', authRoutes);
app.use('/api/billing/paypal', paypalRoutes);
// Meeting Session API endpoints (protected)
app.post('/api/sessions', authenticate, async (req, res) => {
    try {
        const userId = req.user.userId;
        const { title, createdAt, updatedAt, bubbles, summary, insights, questions, mode, modeKey, metadata } = req.body;
        if (!title || !createdAt) {
            return res.status(400).json({ error: 'Missing required fields: title, createdAt' });
        }
        const session = {
            userId,
            title: String(title),
            createdAt: new Date(createdAt),
            updatedAt: updatedAt ? new Date(updatedAt) : null,
            bubbles: Array.isArray(bubbles) ? bubbles.map((b) => ({
                source: String(b.source ?? 'unknown'),
                text: String(b.text ?? ''),
                timestamp: new Date(b.timestamp),
                isDraft: Boolean(b.isDraft ?? false),
            })) : [],
            summary: summary ? String(summary) : null,
            insights: insights ? String(insights) : null,
            questions: questions ? String(questions) : null,
            modeKey: modeKey ? String(modeKey) : (mode ? String(mode) : 'general'), // Support both 'mode' and 'modeKey' for backward compatibility
            metadata: metadata && typeof metadata === 'object' ? metadata : {},
        };
        const sessionId = await createMeetingSession(session);
        const savedSession = await getMeetingSession(sessionId, userId);
        return res.status(201).json(savedSession);
    }
    catch (error) {
        console.error('Error creating session:', error);
        return res.status(500).json({ error: error.message || 'Failed to create session' });
    }
});
app.get('/api/sessions', authenticate, async (req, res) => {
    try {
        const userId = req.user.userId;
        // Parse pagination and search parameters
        const limit = req.query.limit ? parseInt(req.query.limit, 10) : undefined;
        const skip = req.query.skip ? parseInt(req.query.skip, 10) : undefined;
        const search = req.query.search;
        const result = await listMeetingSessions(userId, {
            limit,
            skip,
            search,
        });
        return res.json({
            sessions: result.sessions,
            total: result.total,
            limit: limit,
            skip: skip,
        });
    }
    catch (error) {
        console.error('Error listing sessions:', error);
        return res.status(500).json({ error: error.message || 'Failed to list sessions' });
    }
});
app.get('/api/sessions/:id', authenticate, async (req, res) => {
    try {
        const userId = req.user.userId;
        const sessionId = req.params.id;
        const session = await getMeetingSession(sessionId, userId);
        if (!session) {
            return res.status(404).json({ error: 'Session not found' });
        }
        return res.json(session);
    }
    catch (error) {
        console.error('Error getting session:', error);
        return res.status(500).json({ error: error.message || 'Failed to get session' });
    }
});
app.put('/api/sessions/:id', authenticate, async (req, res) => {
    try {
        const userId = req.user.userId;
        const sessionId = req.params.id;
        const { title, createdAt, updatedAt, bubbles, summary, insights, questions, mode, modeKey, metadata } = req.body;
        // Check if sessionId is a valid MongoDB ObjectId
        const isValidObjectId = /^[0-9a-fA-F]{24}$/.test(sessionId);
        if (!isValidObjectId) {
            // If not a valid ObjectId, treat as new session creation
            if (!title || !createdAt) {
                return res.status(400).json({ error: 'Missing required fields: title, createdAt' });
            }
            const session = {
                userId,
                title: String(title),
                createdAt: new Date(createdAt),
                updatedAt: updatedAt ? new Date(updatedAt) : null,
                bubbles: Array.isArray(bubbles) ? bubbles.map((b) => ({
                    source: String(b.source ?? 'unknown'),
                    text: String(b.text ?? ''),
                    timestamp: new Date(b.timestamp),
                    isDraft: Boolean(b.isDraft ?? false),
                })) : [],
                summary: summary ? String(summary) : null,
                insights: insights ? String(insights) : null,
                questions: questions ? String(questions) : null,
                modeKey: modeKey ? String(modeKey) : (mode ? String(mode) : 'general'), // Support both 'mode' and 'modeKey' for backward compatibility
                metadata: metadata && typeof metadata === 'object' ? metadata : {},
            };
            const newSessionId = await createMeetingSession(session);
            const savedSession = await getMeetingSession(newSessionId, userId);
            return res.status(201).json(savedSession);
        }
        // Valid ObjectId, try to update
        const updates = {};
        if (title !== undefined)
            updates.title = String(title);
        if (updatedAt !== undefined)
            updates.updatedAt = new Date(updatedAt);
        if (bubbles !== undefined) {
            updates.bubbles = Array.isArray(bubbles) ? bubbles.map((b) => ({
                source: String(b.source ?? 'unknown'),
                text: String(b.text ?? ''),
                timestamp: new Date(b.timestamp),
                isDraft: Boolean(b.isDraft ?? false),
            })) : [];
        }
        if (summary !== undefined)
            updates.summary = summary ? String(summary) : null;
        if (insights !== undefined)
            updates.insights = insights ? String(insights) : null;
        if (questions !== undefined)
            updates.questions = questions ? String(questions) : null;
        if (modeKey !== undefined)
            updates.modeKey = modeKey ? String(modeKey) : 'general';
        else if (mode !== undefined)
            updates.modeKey = mode ? String(mode) : 'general'; // Support both 'mode' and 'modeKey' for backward compatibility
        if (metadata !== undefined)
            updates.metadata = metadata && typeof metadata === 'object' ? metadata : {};
        const success = await updateMeetingSession(sessionId, userId, updates);
        if (!success) {
            return res.status(404).json({ error: 'Session not found' });
        }
        const updatedSession = await getMeetingSession(sessionId, userId);
        if (!updatedSession) {
            return res.status(404).json({ error: 'Session not found' });
        }
        return res.json(updatedSession);
    }
    catch (error) {
        console.error('Error updating session:', error);
        return res.status(500).json({ error: error.message || 'Failed to update session' });
    }
});
app.delete('/api/sessions/:id', authenticate, async (req, res) => {
    try {
        const userId = req.user.userId;
        const sessionId = req.params.id;
        const success = await deleteMeetingSession(sessionId, userId);
        if (!success) {
            return res.status(404).json({ error: 'Session not found' });
        }
        return res.status(204).send();
    }
    catch (error) {
        console.error('Error deleting session:', error);
        return res.status(500).json({ error: error.message || 'Failed to delete session' });
    }
});
// Mode configs API (built-in modes: realTimePrompt, notesTemplate per mode)
app.get('/api/mode-configs', authenticate, async (req, res) => {
    try {
        const userId = req.user.userId;
        const configs = await getModeConfigs(userId);
        if (!configs) {
            return res.status(404).json({ error: 'No mode configs stored yet' });
        }
        return res.json(configs);
    }
    catch (error) {
        console.error('Error getting mode configs:', error);
        return res.status(500).json({ error: error.message || 'Failed to get mode configs' });
    }
});
app.put('/api/mode-configs/:modeName', authenticate, async (req, res) => {
    try {
        const userId = req.user.userId;
        const modeName = req.params.modeName;
        const { realTimePrompt, notesTemplate } = req.body ?? {};
        if (!modeName) {
            return res.status(400).json({ error: 'Missing mode name' });
        }
        const config = {
            realTimePrompt: typeof realTimePrompt === 'string' ? realTimePrompt : '',
            notesTemplate: typeof notesTemplate === 'string' ? notesTemplate : '',
        };
        await saveModeConfig(userId, modeName, config);
        return res.status(200).json({ mode: modeName, ...config });
    }
    catch (error) {
        console.error('Error saving mode config:', error);
        return res.status(500).json({ error: error.message || 'Failed to save mode config' });
    }
});
// Custom modes (add from template, add custom)
app.get('/api/custom-mode-configs', authenticate, async (req, res) => {
    try {
        const userId = req.user.userId;
        const modes = await getCustomModes(userId);
        return res.json(modes);
    }
    catch (error) {
        console.error('Error getting custom modes:', error);
        return res.status(500).json({ error: error.message || 'Failed to get custom modes' });
    }
});
app.put('/api/custom-mode-configs', authenticate, async (req, res) => {
    try {
        const userId = req.user.userId;
        const body = req.body;
        if (!Array.isArray(body)) {
            return res.status(400).json({ error: 'Body must be an array of custom modes' });
        }
        const modes = body.map((m) => ({
            id: String(m?.id ?? ''),
            label: String(m?.label ?? ''),
            iconCodePoint: Number(m?.iconCodePoint) || 0x2605,
            realTimePrompt: String(m?.realTimePrompt ?? ''),
            notesTemplate: String(m?.notesTemplate ?? ''),
        }));
        await saveCustomModes(userId, modes);
        return res.status(200).json(modes);
    }
    catch (error) {
        console.error('Error saving custom modes:', error);
        return res.status(500).json({ error: error.message || 'Failed to save custom modes' });
    }
});
app.delete('/api/custom-mode-configs/:id', authenticate, async (req, res) => {
    try {
        const userId = req.user.userId;
        const modeId = req.params.id;
        console.log('[RemoveMode] DELETE /api/custom-mode-configs/:id hit', { userId, modeId });
        if (!modeId) {
            console.log('[RemoveMode] 400 mode id missing');
            return res.status(400).json({ error: 'Mode id is required' });
        }
        await deleteCustomMode(userId, modeId);
        console.log('[RemoveMode] deleteCustomMode(userId, modeId) completed');
        return res.status(200).json({ ok: true });
    }
    catch (error) {
        console.error('[RemoveMode] Error deleting custom mode:', error);
        return res.status(500).json({ error: error.message || 'Failed to delete custom mode' });
    }
});
// Question templates endpoints
app.get('/api/question-templates', authenticate, async (req, res) => {
    try {
        const userId = req.user.userId;
        console.log('[QuestionTemplates] GET request from userId:', userId);
        const templates = await getQuestionTemplates(userId);
        console.log('[QuestionTemplates] Returning', templates.length, 'templates');
        return res.json(templates);
    }
    catch (error) {
        console.error('Error getting question templates:', error);
        return res.status(500).json({ error: error.message || 'Failed to get question templates' });
    }
});
app.put('/api/question-templates', authenticate, async (req, res) => {
    try {
        const userId = req.user.userId;
        const body = req.body;
        console.log('[QuestionTemplates] PUT request from userId:', userId, 'body:', JSON.stringify(body));
        if (!Array.isArray(body)) {
            console.log('[QuestionTemplates] Invalid body - not an array');
            return res.status(400).json({ error: 'Body must be an array of question templates' });
        }
        const templates = body.map((t) => ({
            id: String(t?.id ?? ''),
            question: String(t?.question ?? ''),
        }));
        console.log('[QuestionTemplates] Saving', templates.length, 'templates to DB');
        await saveQuestionTemplates(userId, templates);
        console.log('[QuestionTemplates] Successfully saved templates');
        return res.status(200).json(templates);
    }
    catch (error) {
        console.error('[QuestionTemplates] Error saving question templates:', error);
        return res.status(500).json({ error: error.message || 'Failed to save question templates' });
    }
});
app.delete('/api/question-templates/:id', authenticate, async (req, res) => {
    try {
        const userId = req.user.userId;
        const templateId = req.params.id;
        if (!templateId) {
            return res.status(400).json({ error: 'Template id is required' });
        }
        await deleteQuestionTemplate(userId, templateId);
        return res.status(200).json({ ok: true });
    }
    catch (error) {
        console.error('Error deleting question template:', error);
        return res.status(500).json({ error: error.message || 'Failed to delete question template' });
    }
});
// API Usage endpoints (protected)
app.get('/api/usage', authenticate, async (req, res) => {
    try {
        const userId = req.user.userId;
        const startDate = req.query.startDate ? new Date(req.query.startDate) : undefined;
        const endDate = req.query.endDate ? new Date(req.query.endDate) : undefined;
        const stats = await getUserApiUsageStats(userId, startDate, endDate);
        return res.json(stats);
    }
    catch (error) {
        console.error('Error fetching API usage:', error);
        return res.status(500).json({ error: error.message || 'Failed to fetch API usage' });
    }
});
app.get('/api/usage/details', authenticate, async (req, res) => {
    try {
        const userId = req.user.userId;
        const startDate = req.query.startDate ? new Date(req.query.startDate) : undefined;
        const endDate = req.query.endDate ? new Date(req.query.endDate) : undefined;
        const limit = req.query.limit ? parseInt(req.query.limit, 10) : 100;
        const usage = await getUserApiUsage(userId, startDate, endDate);
        const limited = usage.slice(0, limit);
        return res.json({
            usage: limited.map(u => ({
                id: u._id?.toString(),
                model: u.model,
                promptTokens: u.promptTokens,
                completionTokens: u.completionTokens,
                totalTokens: u.totalTokens,
                mode: u.mode,
                timestamp: u.timestamp,
                sessionId: u.sessionId,
            })),
            total: usage.length,
        });
    }
    catch (error) {
        console.error('Error fetching API usage details:', error);
        return res.status(500).json({ error: error.message || 'Failed to fetch API usage details' });
    }
});
// Billing / pricing endpoints (protected)
app.get('/api/billing/me', authenticate, async (req, res) => {
    try {
        const userId = req.user.userId;
        const user = await getUserByIdFull(userId);
        const plan = normalizePlan(user?.plan);
        const ent = planEntitlements(plan);
        const { start, end } = getCurrentBillingPeriodUtc();
        const usedMs = await getTranscriptionUsageMsForPeriod(userId, start, end);
        const usedMinutes = Math.floor(usedMs / 60000);
        const limitMinutes = ent.transcriptionMinutesPerMonth;
        const remainingMinutes = Math.max(0, limitMinutes - usedMinutes);
        const usageStats = await getUserApiUsageStats(userId, start, end);
        const aiLimitTokens = ent.aiTokensPerMonth;
        const aiUsedTokens = usageStats.totalTokens ?? 0;
        const aiRemainingTokens = Math.max(0, aiLimitTokens - aiUsedTokens);
        const aiLimitRequests = ent.aiRequestsPerMonth;
        const aiUsedRequests = usageStats.totalRequests ?? 0;
        const aiRemainingRequests = typeof aiLimitRequests === 'number'
            ? Math.max(0, aiLimitRequests - aiUsedRequests)
            : undefined;
        // Per-model metering (monthly)
        const byModelUsage = usageStats.byModel ?? {};
        const modelKeys = new Set([
            ...Object.keys(byModelUsage),
            ...ent.allowedModels,
        ]);
        const perModelCaps = ent.aiTokensPerMonthByModel;
        const byModel = {};
        for (const m of modelKeys) {
            const usedTokens = byModelUsage[m]?.tokens ?? 0;
            const requests = byModelUsage[m]?.requests ?? 0;
            const limitTokens = perModelCaps?.[m];
            byModel[m] = {
                usedTokens,
                requests,
                ...(typeof limitTokens === 'number'
                    ? { limitTokens, remainingTokens: Math.max(0, limitTokens - usedTokens) }
                    : {}),
            };
        }
        return res.json({
            user: {
                name: user?.name || '',
                email: user?.email || (req.user?.email || ''),
            },
            plan: ent.plan,
            billingPeriod: {
                start: start.toISOString(),
                end: end.toISOString(),
            },
            transcription: {
                limitMinutes,
                usedMinutes,
                remainingMinutes,
            },
            ai: {
                canUseSummary: ent.canUseSummary,
                allowedModels: ent.allowedModels,
                limitTokens: aiLimitTokens,
                usedTokens: aiUsedTokens,
                remainingTokens: aiRemainingTokens,
                limitRequests: aiLimitRequests,
                usedRequests: aiUsedRequests,
                ...(aiRemainingRequests === undefined ? {} : { remainingRequests: aiRemainingRequests }),
                byModel,
            },
        });
    }
    catch (error) {
        console.error('Error fetching billing info:', error);
        return res.status(500).json({ error: error.message || 'Failed to fetch billing info' });
    }
});
app.get('/api/billing/ai-daily-tokens', authenticate, async (req, res) => {
    try {
        const userId = req.user.userId;
        const { start, end } = getCurrentBillingPeriodUtc();
        const parseYmdToUtcDayStart = (s) => {
            const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s.trim());
            if (!m)
                return null;
            const y = parseInt(m[1], 10);
            const mo = parseInt(m[2], 10);
            const d = parseInt(m[3], 10);
            if (!Number.isFinite(y) || !Number.isFinite(mo) || !Number.isFinite(d))
                return null;
            if (mo < 1 || mo > 12)
                return null;
            if (d < 1 || d > 31)
                return null;
            const dt = new Date(Date.UTC(y, mo - 1, d, 0, 0, 0, 0));
            // Guard against invalid dates like 2026-02-31 rolling over.
            if (dt.getUTCFullYear() !== y || (dt.getUTCMonth() + 1) !== mo || dt.getUTCDate() !== d)
                return null;
            return dt;
        };
        const daysParam = req.query?.days;
        const parsedDays = typeof daysParam === 'string' ? parseInt(daysParam, 10) : NaN;
        const rangeDays = Number.isFinite(parsedDays) ? parsedDays : undefined;
        const startParam = req.query?.start;
        const endParam = req.query?.end;
        const startStr = typeof startParam === 'string' ? startParam : null;
        const endStr = typeof endParam === 'string' ? endParam : null;
        const customStartDayUtc = startStr ? parseYmdToUtcDayStart(startStr) : null;
        const customEndDayUtc = endStr ? parseYmdToUtcDayStart(endStr) : null;
        const hasCustomRange = !!(customStartDayUtc && customEndDayUtc && customStartDayUtc <= customEndDayUtc);
        const now = new Date();
        const hasDays = !hasCustomRange && typeof rangeDays === 'number' && rangeDays > 0;
        // When days=N is provided, return EXACTLY N daily buckets ending today (UTC),
        // clamping the DB query to the billing period but still returning 0-filled days
        // for dates outside the billing window.
        // If custom range is provided, return buckets for exactly that [start..end] (inclusive).
        // If days is omitted, return the full billing period (including future 0-days).
        const rangeEnd = hasCustomRange ? now : (hasDays ? (now < end ? now : end) : end);
        const endDayUtc = hasCustomRange
            ? customEndDayUtc
            : new Date(Date.UTC(rangeEnd.getUTCFullYear(), rangeEnd.getUTCMonth(), rangeEnd.getUTCDate(), 0, 0, 0, 0));
        let fillStartDayUtc = start;
        if (hasCustomRange) {
            fillStartDayUtc = customStartDayUtc;
        }
        else if (hasDays) {
            fillStartDayUtc = new Date(endDayUtc);
            fillStartDayUtc.setUTCDate(fillStartDayUtc.getUTCDate() - (rangeDays - 1));
        }
        const queryStart = hasCustomRange
            ? fillStartDayUtc
            : ((hasDays ? (fillStartDayUtc < start ? start : fillStartDayUtc) : start));
        // For custom range: query up to end-of-day inclusive for the selected end date.
        // Clamp to "now" so we don't query future timestamps.
        const customEndInclusive = hasCustomRange
            ? new Date(Date.UTC(endDayUtc.getUTCFullYear(), endDayUtc.getUTCMonth(), endDayUtc.getUTCDate(), 23, 59, 59, 999))
            : null;
        const queryEnd = hasCustomRange
            ? new Date(Math.min(now.getTime(), customEndInclusive.getTime()))
            : rangeEnd;
        const rows = await getUserDailyAiTokenUsage(userId, queryStart, queryEnd);
        const byDay = new Map(rows.map((r) => [r.date, r.tokens]));
        const days = [];
        // Fill missing days with 0 so the chart is stable.
        const cur = new Date(Date.UTC((hasCustomRange || hasDays ? fillStartDayUtc : start).getUTCFullYear(), (hasCustomRange || hasDays ? fillStartDayUtc : start).getUTCMonth(), (hasCustomRange || hasDays ? fillStartDayUtc : start).getUTCDate(), 0, 0, 0, 0));
        const endDay = (hasCustomRange || hasDays)
            ? endDayUtc
            : new Date(Date.UTC(end.getUTCFullYear(), end.getUTCMonth(), end.getUTCDate(), 0, 0, 0, 0));
        // If custom/days range is provided, include endDay itself.
        // If no range is provided (full period), keep end exclusive (endDay is the first day of next period).
        while ((hasCustomRange || hasDays) ? (cur <= endDay) : (cur < endDay)) {
            const y = cur.getUTCFullYear();
            const m = String(cur.getUTCMonth() + 1).padStart(2, '0');
            const d = String(cur.getUTCDate()).padStart(2, '0');
            const key = `${y}-${m}-${d}`;
            days.push({ date: key, tokens: byDay.get(key) ?? 0 });
            cur.setUTCDate(cur.getUTCDate() + 1);
        }
        return res.json({
            billingPeriod: { start: start.toISOString(), end: end.toISOString() },
            range: {
                start: ((hasCustomRange || hasDays) ? fillStartDayUtc : start).toISOString(),
                end: hasCustomRange ? endDayUtc.toISOString() : rangeEnd.toISOString(),
                days: hasDays ? (rangeDays ?? null) : null,
                ...(hasCustomRange ? { custom: { start: startStr, end: endStr } } : {}),
            },
            days,
        });
    }
    catch (error) {
        console.error('Error fetching daily AI token usage:', error);
        return res.status(500).json({ error: error.message || 'Failed to fetch daily AI token usage' });
    }
});
app.get('/api/billing/ai-daily-tokens-by-model', authenticate, async (req, res) => {
    try {
        const userId = req.user.userId;
        const { start, end } = getCurrentBillingPeriodUtc();
        const parseYmdToUtcDayStart = (s) => {
            const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s.trim());
            if (!m)
                return null;
            const y = parseInt(m[1], 10);
            const mo = parseInt(m[2], 10);
            const d = parseInt(m[3], 10);
            if (!Number.isFinite(y) || !Number.isFinite(mo) || !Number.isFinite(d))
                return null;
            if (mo < 1 || mo > 12)
                return null;
            if (d < 1 || d > 31)
                return null;
            const dt = new Date(Date.UTC(y, mo - 1, d, 0, 0, 0, 0));
            if (dt.getUTCFullYear() !== y || (dt.getUTCMonth() + 1) !== mo || dt.getUTCDate() !== d)
                return null;
            return dt;
        };
        const startParam = req.query?.start;
        const endParam = req.query?.end;
        const startStr = typeof startParam === 'string' ? startParam : null;
        const endStr = typeof endParam === 'string' ? endParam : null;
        const customStartDayUtc = startStr ? parseYmdToUtcDayStart(startStr) : null;
        const customEndDayUtc = endStr ? parseYmdToUtcDayStart(endStr) : null;
        if (!customStartDayUtc || !customEndDayUtc || customStartDayUtc > customEndDayUtc) {
            return res.status(400).json({ error: 'start and end (YYYY-MM-DD) are required' });
        }
        const now = new Date();
        const endInclusive = new Date(Date.UTC(customEndDayUtc.getUTCFullYear(), customEndDayUtc.getUTCMonth(), customEndDayUtc.getUTCDate(), 23, 59, 59, 999));
        const queryEnd = new Date(Math.min(now.getTime(), endInclusive.getTime()));
        const rows = await getUserDailyAiTokenUsageByModel(userId, customStartDayUtc, queryEnd);
        // Build model set + totals.
        const totalsByModel = new Map();
        for (const r of rows) {
            const model = r.model || 'unknown';
            totalsByModel.set(model, (totalsByModel.get(model) ?? 0) + (r.tokens ?? 0));
        }
        const models = Array.from(totalsByModel.entries())
            .sort((a, b) => (b[1] - a[1]) || a[0].localeCompare(b[0]))
            .map(([m]) => m);
        // Index by day -> model -> tokens
        const byDay = new Map();
        for (const r of rows) {
            const day = r.date;
            if (!day)
                continue;
            const model = r.model || 'unknown';
            let m = byDay.get(day);
            if (!m) {
                m = new Map();
                byDay.set(day, m);
            }
            m.set(model, (m.get(model) ?? 0) + (r.tokens ?? 0));
        }
        const days = [];
        const cur = new Date(Date.UTC(customStartDayUtc.getUTCFullYear(), customStartDayUtc.getUTCMonth(), customStartDayUtc.getUTCDate(), 0, 0, 0, 0));
        const endDay = new Date(Date.UTC(customEndDayUtc.getUTCFullYear(), customEndDayUtc.getUTCMonth(), customEndDayUtc.getUTCDate(), 0, 0, 0, 0));
        while (cur <= endDay) {
            const y = cur.getUTCFullYear();
            const m2 = String(cur.getUTCMonth() + 1).padStart(2, '0');
            const d2 = String(cur.getUTCDate()).padStart(2, '0');
            const key = `${y}-${m2}-${d2}`;
            const modelMap = byDay.get(key);
            const byModelObj = {};
            let totalTokens = 0;
            for (const model of models) {
                const v = modelMap?.get(model) ?? 0;
                byModelObj[model] = v;
                totalTokens += v;
            }
            days.push({ date: key, totalTokens, byModel: byModelObj });
            cur.setUTCDate(cur.getUTCDate() + 1);
        }
        const totalTokens = days.reduce((sum, d) => sum + (d.totalTokens || 0), 0);
        const totalsByModelObj = {};
        for (const model of models) {
            totalsByModelObj[model] = totalsByModel.get(model) ?? 0;
        }
        return res.json({
            billingPeriod: { start: start.toISOString(), end: end.toISOString() },
            range: { start: customStartDayUtc.toISOString(), end: customEndDayUtc.toISOString(), custom: { start: startStr, end: endStr } },
            models,
            totalsByModel: totalsByModelObj,
            totalTokens,
            days,
        });
    }
    catch (error) {
        console.error('Error fetching daily AI token usage by model:', error);
        return res.status(500).json({ error: error.message || 'Failed to fetch daily AI token usage by model' });
    }
});
app.get('/api/billing/invoices', authenticate, async (_req, res) => {
    // Placeholder until a real billing provider is wired.
    // Shape: { invoices: [{ id, date, description, status, amountCents, currency, invoiceUrl? }] }
    return res.json({ invoices: [] });
});
app.post('/api/billing/transcription-usage', authenticate, async (req, res) => {
    try {
        const userId = req.user.userId;
        const { durationMs, sessionId } = req.body ?? {};
        const ms = typeof durationMs === 'number' ? durationMs : parseInt(String(durationMs ?? '0'), 10);
        if (!Number.isFinite(ms) || ms <= 0) {
            return res.status(400).json({ error: 'durationMs must be a positive number' });
        }
        // Cap to 8 hours per event to prevent accidental abuse.
        if (ms > 8 * 60 * 60 * 1000) {
            return res.status(400).json({ error: 'durationMs too large' });
        }
        await saveTranscriptionUsage(userId, ms, typeof sessionId === 'string' ? sessionId : undefined);
        return res.json({ ok: true });
    }
    catch (error) {
        console.error('Error saving transcription usage:', error);
        return res.status(500).json({ error: error.message || 'Failed to save transcription usage' });
    }
});
const openai = process.env.OPENAI_API_KEY
    ? new OpenAI({ apiKey: process.env.OPENAI_API_KEY })
    : null;
const normalizePlan = (p) => {
    if (p === 'pro' || p === 'pro_plus')
        return p;
    // Backward/alternate naming
    if (p === 'business' || p === 'proplus' || p === 'pro+')
        return 'pro_plus';
    return 'free';
};
const planEntitlements = (plan) => {
    switch (plan) {
        case 'pro_plus':
            return {
                plan,
                transcriptionMinutesPerMonth: 6000,
                aiTokensPerMonth: 2_000_000,
                aiRequestsPerMonth: 20_000,
                // Per-model token caps (monthly). These sum to aiTokensPerMonth.
                aiTokensPerMonthByModel: {
                    'gpt-5.2': 600_000,
                    'gpt-5': 500_000,
                    'gpt-5.1': 300_000,
                    'gpt-4.1': 250_000,
                    'gpt-4.1-mini': 200_000,
                    'gpt-4o': 75_000,
                    'gpt-4o-mini': 75_000,
                },
                canUseSummary: true,
                allowedModels: ['gpt-5.2', 'gpt-5', 'gpt-5.1', 'gpt-4.1', 'gpt-4.1-mini', 'gpt-4o', 'gpt-4o-mini'],
            };
        case 'pro':
            return {
                plan,
                transcriptionMinutesPerMonth: 1500,
                aiTokensPerMonth: 500_000,
                aiRequestsPerMonth: 5_000,
                // Per-model token caps (monthly). These sum to aiTokensPerMonth.
                aiTokensPerMonthByModel: {
                    'gpt-5': 200_000,
                    'gpt-5.1': 100_000,
                    'gpt-4.1': 75_000,
                    'gpt-4.1-mini': 75_000,
                    'gpt-4o': 25_000,
                    'gpt-4o-mini': 25_000,
                },
                canUseSummary: true,
                allowedModels: ['gpt-5', 'gpt-5.1', 'gpt-4.1', 'gpt-4.1-mini', 'gpt-4o', 'gpt-4o-mini'],
            };
        case 'free':
        default:
            return {
                plan: 'free',
                transcriptionMinutesPerMonth: 600,
                aiTokensPerMonth: 50_000,
                aiRequestsPerMonth: 200,
                // Per-model token caps (monthly). These sum to aiTokensPerMonth.
                aiTokensPerMonthByModel: {
                    'gpt-4.1-mini': 40_000,
                    'gpt-4.1': 10_000,
                },
                canUseSummary: false,
                allowedModels: ['gpt-4.1-mini', 'gpt-4.1'],
            };
    }
};
const getCurrentBillingPeriodUtc = () => {
    const now = new Date();
    const start = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1, 0, 0, 0, 0));
    const end = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1, 0, 0, 0, 0));
    return { start, end };
};
const isAutoModelRequested = (m) => {
    return typeof m === 'string' && m.trim().toLowerCase() === 'auto';
};
const checkMonthlyAiBudgetsOrThrow = (stats, ent, model) => {
    // Global monthly token cap
    const usedTokens = stats.totalTokens ?? 0;
    const tokenLimit = ent.aiTokensPerMonth ?? 0;
    if (typeof tokenLimit === 'number' && tokenLimit > 0 && usedTokens >= tokenLimit) {
        const err = new Error('AI token limit reached for this month. Upgrade your plan to continue.');
        err.statusCode = 402;
        throw err;
    }
    // Global monthly request cap
    const usedRequests = stats.totalRequests ?? 0;
    const reqLimit = ent.aiRequestsPerMonth;
    if (typeof reqLimit === 'number' && reqLimit > 0 && usedRequests >= reqLimit) {
        const err = new Error('AI request limit reached for this month. Upgrade your plan to continue.');
        err.statusCode = 402;
        throw err;
    }
    // Optional per-model token cap
    const modelKey = typeof model === 'string' ? model.trim() : '';
    const perModelCaps = ent.aiTokensPerMonthByModel;
    if (modelKey && perModelCaps && typeof perModelCaps[modelKey] === 'number') {
        const modelLimit = perModelCaps[modelKey];
        const usedByModel = stats.byModel?.[modelKey]?.tokens ?? 0;
        if (modelLimit > 0 && usedByModel >= modelLimit) {
            const err = new Error(`AI token limit reached for model "${modelKey}" this month. Upgrade your plan to continue.`);
            err.statusCode = 402;
            throw err;
        }
    }
};
const preferredModelsForAuto = (plan, requestMode) => {
    const mode = requestMode; // 'reply' | 'summary' | 'insights' | 'questions'
    if (plan === 'pro_plus') {
        if (mode === 'reply')
            return ['gpt-5.2', 'gpt-5', 'gpt-5.1', 'gpt-4.1', 'gpt-4.1-mini', 'gpt-4o-mini', 'gpt-4o'];
        if (mode === 'summary' || mode === 'insights')
            return ['gpt-5.2', 'gpt-5', 'gpt-5.1', 'gpt-4.1'];
        if (mode === 'questions')
            return ['gpt-4.1-mini', 'gpt-4.1', 'gpt-5.1', 'gpt-5'];
    }
    if (plan === 'pro') {
        if (mode === 'reply')
            return ['gpt-5.1', 'gpt-5', 'gpt-4.1', 'gpt-4.1-mini', 'gpt-4o-mini', 'gpt-4o'];
        if (mode === 'summary' || mode === 'insights')
            return ['gpt-5.1', 'gpt-5', 'gpt-4.1'];
        if (mode === 'questions')
            return ['gpt-4.1-mini', 'gpt-4.1', 'gpt-5.1', 'gpt-5'];
    }
    // free
    if (mode === 'reply')
        return ['gpt-4.1-mini', 'gpt-4.1'];
    return ['gpt-4.1-mini', 'gpt-4.1'];
};
const pickAutoModel = (opts) => {
    const { planTier, ent, requestMode, stats } = opts;
    const allowed = Array.isArray(ent.allowedModels) ? ent.allowedModels : [];
    const perModelCaps = ent.aiTokensPerMonthByModel;
    const candidates = [
        ...preferredModelsForAuto(planTier, requestMode),
        ...allowed,
    ];
    const seen = new Set();
    for (const c of candidates) {
        const m = String(c || '').trim();
        if (!m)
            continue;
        if (seen.has(m))
            continue;
        seen.add(m);
        if (!allowed.includes(m))
            continue;
        // If this model has a cap and it's exhausted, skip it.
        const cap = perModelCaps?.[m];
        if (typeof cap === 'number' && cap > 0) {
            const usedByModel = stats.byModel?.[m]?.tokens ?? 0;
            if (usedByModel >= cap)
                continue;
        }
        return m;
    }
    // Fallback: first allowed model (if any)
    if (allowed.length > 0)
        return allowed[0];
    throw Object.assign(new Error('No models available for this plan.'), { statusCode: 403 });
};
// In-memory rate limiting + concurrency guards (per-user)
// NOTE: This resets when the server restarts. Good enough for MVP.
const aiRateLimitState = new Map();
const aiInFlightByUser = new Map();
let aiRateLimitCleanupCounter = 0;
const aiRateLimitsForPlan = (plan) => {
    switch (plan) {
        case 'pro_plus':
            return { maxPerMinute: 120, maxConcurrent: 3 };
        case 'pro':
            return { maxPerMinute: 60, maxConcurrent: 2 };
        case 'free':
        default:
            return { maxPerMinute: 10, maxConcurrent: 1 };
    }
};
const checkAndConsumeAiRateLimit = (userId, plan) => {
    const { maxPerMinute } = aiRateLimitsForPlan(plan);
    const windowMs = 60_000;
    const now = Date.now();
    const state = aiRateLimitState.get(userId) ?? { windowStartMs: now, count: 0 };
    if (now - state.windowStartMs >= windowMs) {
        state.windowStartMs = now;
        state.count = 0;
    }
    if (state.count >= maxPerMinute) {
        const retryAfterMs = Math.max(0, windowMs - (now - state.windowStartMs));
        return { allowed: false, retryAfterMs };
    }
    state.count += 1;
    aiRateLimitState.set(userId, state);
    // occasional cleanup to avoid unbounded growth
    aiRateLimitCleanupCounter++;
    if (aiRateLimitCleanupCounter % 500 === 0 && aiRateLimitState.size > 2000) {
        const cutoff = now - 5 * windowMs;
        for (const [k, v] of aiRateLimitState.entries()) {
            if (v.windowStartMs < cutoff)
                aiRateLimitState.delete(k);
        }
    }
    return { allowed: true, retryAfterMs: 0 };
};
const acquireAiConcurrency = (userId, plan) => {
    const { maxConcurrent } = aiRateLimitsForPlan(plan);
    const current = aiInFlightByUser.get(userId) ?? 0;
    if (current >= maxConcurrent) {
        const err = new Error('Too many concurrent AI requests. Please wait and try again.');
        err.statusCode = 429;
        throw err;
    }
    aiInFlightByUser.set(userId, current + 1);
    return () => {
        const c = aiInFlightByUser.get(userId) ?? 0;
        const next = c - 1;
        if (next <= 0)
            aiInFlightByUser.delete(userId);
        else
            aiInFlightByUser.set(userId, next);
    };
};
// AI response endpoint (protected)
// Accepts a short transcript history and returns a single assistant reply.
app.post('/ai/respond', authenticate, async (req, res) => {
    try {
        if (!openai) {
            return res.status(500).json({
                error: 'OpenAI API key not configured. Set OPENAI_API_KEY in backend .env',
            });
        }
        const { turns, mode, question, systemPrompt: providedSystemPrompt, model: requestedModel, imagePngBase64 } = req.body ?? {};
        if (!Array.isArray(turns)) {
            return res.status(400).json({ error: 'Missing turns[]' });
        }
        const questionText = typeof question === 'string' ? question.trim() : '';
        if (questionText.length > 800) {
            return res.status(400).json({ error: 'Question too long (max 800 chars)' });
        }
        const screenshotBase64 = typeof imagePngBase64 === 'string' ? imagePngBase64.trim() : '';
        const hasScreenshot = screenshotBase64.length > 0;
        // Safety cap; overall request cap enforced by express.json({limit}).
        if (screenshotBase64.length > 6_000_000) {
            return res.status(400).json({ error: 'Screenshot too large' });
        }
        // Allow empty turns if a question is provided
        if (turns.length === 0 && questionText.length === 0 && !hasScreenshot) {
            return res.status(400).json({ error: 'Missing turns[] or question' });
        }
        // Basic size limits to avoid accidental huge payloads.
        if (turns.length > 100) {
            return res.status(400).json({ error: 'Too many turns (max 100)' });
        }
        const normalized = turns
            .map((t) => ({
            source: String(t?.source ?? 'unknown'),
            text: String(t?.text ?? '').trim(),
        }))
            .filter((t) => t.text.length > 0);
        // Allow empty normalized turns if a question is provided
        if (normalized.length === 0 && questionText.length === 0) {
            return res.status(400).json({ error: 'All turns were empty and no question provided' });
        }
        const totalChars = normalized.reduce((sum, t) => sum + t.text.length, 0);
        if (totalChars > 12000) {
            return res.status(400).json({ error: 'Turns too long (max 12000 chars total)' });
        }
        const requestMode = ['summary', 'insights', 'questions'].includes(mode) ? mode : 'reply';
        let systemPrompt;
        let userPrompt;
        const historyText = normalized
            .map((t) => {
            const label = t.source.toLowerCase() === 'mic' ? 'MIC' : t.source.toLowerCase() === 'system' ? 'SYSTEM' : t.source.toUpperCase();
            return `${label}: ${t.text}`;
        })
            .join('\n');
        switch (requestMode) {
            case 'summary':
                // Use provided system prompt if available (for notes template), otherwise use default
                if (typeof providedSystemPrompt === 'string' && providedSystemPrompt.trim().length > 0) {
                    systemPrompt = providedSystemPrompt;
                }
                else {
                    systemPrompt = 'You are FinalRound, a meeting assistant. Summarize the meeting conversation so far into concise bullet points. Include key topics discussed, participant responses, and any notable points. If action items or follow-ups exist, list them separately.';
                }
                if (historyText.length > 0) {
                    userPrompt = `Meeting transcript:\n${historyText}\n\nProvide a concise summary of this meeting.`;
                }
                else {
                    userPrompt = 'No transcript available yet. Please wait for the meeting to begin.';
                }
                break;
            case 'insights':
                systemPrompt = 'You are FinalRound, a meeting assistant. Analyze the meeting transcript and provide key insights about the participants and discussion. Focus on strengths, areas of concern, communication style, technical knowledge, cultural fit, and overall assessment. Be objective and specific.';
                if (historyText.length > 0) {
                    userPrompt = `Meeting transcript:\n${historyText}\n\nProvide key insights about this meeting and participants.`;
                }
                else {
                    userPrompt = 'No transcript available yet. Please wait for the meeting to begin.';
                }
                break;
            case 'questions':
                systemPrompt = 'You are FinalRound, a meeting assistant. Based on the meeting transcript so far, suggest 3-5 relevant follow-up questions or discussion points. Consider what has been discussed, what gaps exist, and what would help move the conversation forward. Format as a numbered list.';
                if (historyText.length > 0) {
                    userPrompt = `Meeting transcript:\n${historyText}\n\nSuggest relevant follow-up questions or discussion points for this meeting.`;
                }
                else {
                    userPrompt = 'No transcript available yet. Please wait for the meeting to begin.';
                }
                break;
            default: // 'reply'
                // Use provided system prompt or default
                const providedPrompt = typeof providedSystemPrompt === 'string' && providedSystemPrompt.trim().length > 0
                    ? providedSystemPrompt.trim()
                    : 'You are FinalRound, a meeting assistant. Reply helpfully and concisely to what was said. If the user asks a question, answer it. If the transcript is incomplete, ask one clarifying question.';
                // Enhance prompt to request concise, formatted responses
                const enhancedPrompt = `${providedPrompt}\n\nIMPORTANT: Keep responses concise and easy to scan. Use formatting to highlight key points:\n- Use **bold** for main answers or key takeaways\n- Use bullet points (•) for tips or action items\n- Keep paragraphs short (2-3 sentences max)\n- Lead with the most important information first`;
                systemPrompt = enhancedPrompt;
                if (historyText.length > 0) {
                    userPrompt = `Conversation transcript (most recent last):\n${historyText}\n\nUser question (optional): ${questionText || '(none)'}\n\nWrite your assistant reply.`;
                }
                else if (questionText.length > 0) {
                    userPrompt = `User question: ${questionText}\n\nWrite your assistant reply.`;
                }
                else {
                    userPrompt = 'No transcript or question provided. Please provide a question or wait for the conversation to begin.';
                }
                break;
        }
        const userId = req.user.userId;
        const user = await getUserByIdFull(userId);
        const plan = normalizePlan(user?.plan);
        const ent = planEntitlements(plan);
        const modelText = typeof requestedModel === 'string' ? requestedModel.trim() : '';
        if (modelText.length > 80) {
            return res.status(400).json({ error: 'Model name too long' });
        }
        const { start: periodStart, end: periodEnd } = getCurrentBillingPeriodUtc();
        const monthlyStats = await getUserApiUsageStats(userId, periodStart, periodEnd);
        // Auto model selection: choose best allowed model for plan + mode, with cap-aware fallback.
        let model = modelText.length > 0 ? modelText : (process.env.OPENAI_MODEL || 'gpt-4o-mini');
        if (isAutoModelRequested(model) || model.trim().length === 0) {
            model = pickAutoModel({ planTier: plan, ent, requestMode, stats: monthlyStats });
        }
        // If screenshot is present, ensure we use a vision-capable model (and allowed for plan).
        if (hasScreenshot) {
            const visionCandidates = ['gpt-4.1-mini', 'gpt-4.1', 'gpt-4o-mini', 'gpt-4o', 'gpt-5.2', 'gpt-5.1', 'gpt-5'];
            if (!visionCandidates.includes(model)) {
                const fallback = visionCandidates.find((m) => ent.allowedModels.includes(m));
                if (!fallback) {
                    return res.status(403).json({ error: 'No vision-capable model available for your plan.' });
                }
                model = fallback;
            }
        }
        if (!ent.allowedModels.includes(model)) {
            return res.status(403).json({ error: `Model not allowed for plan: ${ent.plan}` });
        }
        // Free plan cannot use summary/insights/questions
        if (!ent.canUseSummary && requestMode !== 'reply') {
            return res.status(403).json({ error: 'Upgrade required for summaries' });
        }
        // Rate limit (per user, per minute)
        const rl = checkAndConsumeAiRateLimit(userId, plan);
        if (!rl.allowed) {
            return res.status(429).json({ error: 'Rate limit exceeded. Please wait and try again.' });
        }
        // Monthly AI token budget (Cursor-like quota)
        try {
            checkMonthlyAiBudgetsOrThrow(monthlyStats, ent, model);
        }
        catch (e) {
            const status = typeof e?.statusCode === 'number' ? e.statusCode : 402;
            return res.status(status).json({ error: e?.message ?? 'AI token limit reached' });
        }
        // Concurrency limit (per user)
        let releaseConcurrency = null;
        try {
            releaseConcurrency = acquireAiConcurrency(userId, plan);
        }
        catch (e) {
            const status = typeof e?.statusCode === 'number' ? e.statusCode : 429;
            return res.status(status).json({ error: e?.message ?? 'Too many concurrent requests' });
        }
        const maxTokens = requestMode === 'insights' ? 600 : requestMode === 'questions' ? 300 : 400;
        try {
            const userMessage = hasScreenshot
                ? {
                    role: 'user',
                    content: [
                        { type: 'text', text: userPrompt },
                        { type: 'image_url', image_url: { url: `data:image/png;base64,${screenshotBase64}` } },
                    ],
                }
                : { role: 'user', content: userPrompt };
            const completion = await openai.chat.completions.create({
                model,
                messages: [
                    { role: 'system', content: systemPrompt },
                    userMessage,
                ],
                max_completion_tokens: maxTokens,
                temperature: 0.2,
                user: userId, // Track usage per user
            });
            const text = completion?.choices?.[0]?.message?.content ?? '';
            // Capture and store usage
            if (completion.usage) {
                try {
                    const sessionId = req.body.sessionId;
                    await saveApiUsage(userId, model, {
                        prompt_tokens: completion.usage.prompt_tokens,
                        completion_tokens: completion.usage.completion_tokens,
                        total_tokens: completion.usage.total_tokens,
                    }, requestMode, sessionId);
                }
                catch (usageError) {
                    // Log but don't fail the request if usage tracking fails
                    console.error('Failed to save API usage:', usageError);
                }
            }
            return res.json({ text });
        }
        finally {
            try {
                releaseConcurrency?.();
            }
            catch (_) { }
        }
    }
    catch (error) {
        console.error('AI respond error:', error);
        const status = typeof error?.status === 'number' ? error.status : 500;
        const message = error?.error?.message ||
            error?.message ||
            'Failed to generate AI response';
        return res.status(status).json({ error: message });
    }
});
// Create HTTP server
const server = createServer(app);
// Create WebSocket servers (we route upgrades manually so multiple WS endpoints
// can coexist safely on the same HTTP server).
const wss = new WebSocketServer({ noServer: true });
const aiWss = new WebSocketServer({ noServer: true });
server.on('upgrade', async (req, socket, head) => {
    try {
        if (!req.url || !req.headers.host) {
            socket.destroy();
            return;
        }
        const url = new URL(req.url, `http://${req.headers.host}`);
        const pathname = url.pathname;
        // Extract token from query string or Authorization header
        const token = url.searchParams.get('token') ||
            req.headers.authorization?.replace('Bearer ', '');
        // Verify token for WebSocket connections
        if (token) {
            const decoded = verifyToken(token);
            if (!decoded) {
                socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
                socket.destroy();
                return;
            }
            const sid = decoded?.sid;
            if (typeof sid === 'string' && sid.length > 0) {
                const ok = await validateAuthSessionAndMaybeTouch(decoded.userId, sid, 60_000);
                if (!ok) {
                    socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
                    socket.destroy();
                    return;
                }
            }
            req.user = decoded;
        }
        else {
            // Require authentication for WebSocket connections
            socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
            socket.destroy();
            return;
        }
        if (pathname === '/listen') {
            wss.handleUpgrade(req, socket, head, (ws) => {
                const authWs = ws;
                authWs.user = req.user;
                wss.emit('connection', authWs, req);
            });
            return;
        }
        if (pathname === '/ai') {
            aiWss.handleUpgrade(req, socket, head, (ws) => {
                const authWs = ws;
                authWs.user = req.user;
                aiWss.emit('connection', authWs, req);
            });
            return;
        }
        socket.destroy();
    }
    catch (error) {
        console.error('WebSocket upgrade error:', error);
        socket.destroy();
    }
});
// Deepgram client
const deepgram = createClient(process.env.DEEPGRAM_API_KEY || '');
wss.on('connection', (ws) => {
    console.log('Client connected');
    {
        const authWs = ws;
        const sid = authWs.user?.sid;
        if (typeof sid === 'string' && sid.length > 0) {
            registerWebSocketForSession(sid, ws);
        }
    }
    let deepgramMic = null;
    let deepgramSystem = null;
    const startDeepgram = (source) => {
        const live = deepgram.listen.live({
            model: 'nova-3',
            language: 'en',
            smart_format: true,
            punctuate: true,
            interim_results: true,
            encoding: 'linear16',
            sample_rate: 16000,
        });
        live.on(LiveTranscriptionEvents.Open, () => {
            console.log(`Deepgram connection opened (${source})`);
            ws.send(JSON.stringify({ type: 'status', message: `ready:${source}` }));
        });
        live.on(LiveTranscriptionEvents.Transcript, (data) => {
            const transcript = data.channel?.alternatives?.[0]?.transcript;
            if (transcript) {
                const isFinal = data.is_final === true;
                const isInterim = data.is_final === false;
                // Ensure source is correctly preserved from closure
                const transcriptSource = source; // Use closure variable to ensure correct source
                console.log(`[DEBUG] Sending transcript from ${transcriptSource} connection: "${transcript.substring(0, 50)}..."`);
                ws.send(JSON.stringify({
                    type: 'transcript',
                    source: transcriptSource,
                    text: transcript,
                    is_final: isFinal,
                    is_interim: isInterim,
                    confidence: data.channel.alternatives[0].confidence || 0,
                }));
            }
        });
        live.on(LiveTranscriptionEvents.Error, (error) => {
            console.error(`Deepgram error (${source}):`, error);
            ws.send(JSON.stringify({
                type: 'error',
                message: error.message || `Deepgram error (${source})`,
            }));
        });
        live.on(LiveTranscriptionEvents.Close, () => {
            console.log(`Deepgram connection closed (${source})`);
            if (source === 'mic')
                deepgramMic = null;
            if (source === 'system')
                deepgramSystem = null;
        });
        return live;
    };
    // Handle incoming messages from client
    ws.on('message', async (message) => {
        try {
            // ws can deliver Buffer; convert to string before JSON.parse.
            const text = typeof message === 'string' ? message : message.toString('utf8');
            let data;
            try {
                data = JSON.parse(text);
            }
            catch (_) {
                // We only support JSON messages from the Flutter client.
                return;
            }
            console.log('WS /listen message:', data?.type, data?.source ? `source=${data.source}` : '');
            if (data.type === 'start') {
                // Check if API key is set
                if (!process.env.DEEPGRAM_API_KEY) {
                    console.error('Deepgram API key not configured');
                    ws.send(JSON.stringify({
                        type: 'error',
                        message: 'Server error: Deepgram API key not configured. Please set DEEPGRAM_API_KEY in .env file'
                    }));
                    return;
                }
                // Initialize Deepgram live connections (mic + system)
                console.log('Starting Deepgram connections (mic + system)...');
                try {
                    if (deepgramMic) {
                        deepgramMic.finish();
                        deepgramMic = null;
                    }
                    if (deepgramSystem) {
                        deepgramSystem.finish();
                        deepgramSystem = null;
                    }
                    deepgramMic = startDeepgram('mic');
                    deepgramSystem = startDeepgram('system');
                }
                catch (error) {
                    console.error('Failed to start Deepgram connection:', error);
                    ws.send(JSON.stringify({ type: 'error', message: 'Failed to connect to Deepgram: ' + (error.message || 'Unknown error') }));
                    deepgramMic = null;
                    deepgramSystem = null;
                }
            }
            else if (data.type === 'audio') {
                // Validate and normalize source - must be exactly 'system' or 'mic'
                const receivedSource = String(data.source || '').toLowerCase().trim();
                // Strict validation - reject if source is not exactly 'system' or 'mic'
                if (receivedSource !== 'system' && receivedSource !== 'mic') {
                    console.error(`[ERROR] Invalid source received: "${data.source}", rejecting audio`);
                    return;
                }
                const source = receivedSource; // Use normalized source directly
                // Auto-initialize Deepgram connection if not already started
                if (source === 'mic' && !deepgramMic) {
                    console.log('[DEBUG] Auto-initializing deepgramMic connection (audio received before start)');
                    try {
                        if (!process.env.DEEPGRAM_API_KEY) {
                            console.error('Deepgram API key not configured');
                            ws.send(JSON.stringify({
                                type: 'error',
                                message: 'Server error: Deepgram API key not configured. Please set DEEPGRAM_API_KEY in .env file'
                            }));
                            return;
                        }
                        deepgramMic = startDeepgram('mic');
                    }
                    catch (error) {
                        console.error('Failed to auto-start Deepgram mic connection:', error);
                        ws.send(JSON.stringify({ type: 'error', message: 'Failed to initialize mic transcription: ' + (error.message || 'Unknown error') }));
                        return;
                    }
                }
                if (source === 'system' && !deepgramSystem) {
                    console.log('[DEBUG] Auto-initializing deepgramSystem connection (audio received before start)');
                    try {
                        if (!process.env.DEEPGRAM_API_KEY) {
                            console.error('Deepgram API key not configured');
                            ws.send(JSON.stringify({
                                type: 'error',
                                message: 'Server error: Deepgram API key not configured. Please set DEEPGRAM_API_KEY in .env file'
                            }));
                            return;
                        }
                        deepgramSystem = startDeepgram('system');
                    }
                    catch (error) {
                        console.error('Failed to auto-start Deepgram system connection:', error);
                        ws.send(JSON.stringify({ type: 'error', message: 'Failed to initialize system transcription: ' + (error.message || 'Unknown error') }));
                        return;
                    }
                }
                // Debug logging with explicit checks
                if (source === 'system') {
                    console.log(`[DEBUG] Routing SYSTEM audio - deepgramSystem available: ${!!deepgramSystem}, deepgramMic available: ${!!deepgramMic}`);
                    if (!deepgramSystem) {
                        console.error(`[ERROR] System audio received but deepgramSystem is not available!`);
                        return;
                    }
                }
                else if (source === 'mic') {
                    console.log(`[DEBUG] Routing MIC audio - deepgramMic available: ${!!deepgramMic}, deepgramSystem available: ${!!deepgramSystem}`);
                    if (!deepgramMic) {
                        console.error(`[ERROR] Mic audio received but deepgramMic is not available!`);
                        return;
                    }
                }
                // Explicit routing - ensure we use the correct connection
                let target;
                if (source === 'system') {
                    target = deepgramSystem;
                }
                else {
                    target = deepgramMic;
                }
                if (!target) {
                    console.error(`[ERROR] No Deepgram connection available for source: ${source} (received: "${data.source}")`);
                    return;
                }
                // Forward audio data to Deepgram (per-source session)
                try {
                    const audioBuffer = Buffer.from(data.audio, 'base64');
                    console.log(`[DEBUG] Sending ${source} audio to ${source === 'system' ? 'deepgramSystem' : 'deepgramMic'} (${audioBuffer.length} bytes)`);
                    target.send(audioBuffer);
                }
                catch (error) {
                    console.error(`[ERROR] Error sending audio to Deepgram (${source}):`, error);
                    ws.send(JSON.stringify({ type: 'error', message: 'Error processing audio' }));
                }
            }
            else if (data.type === 'stop') {
                // Close Deepgram connections
                console.log('Stopping transcription (mic + system)...');
                if (deepgramMic) {
                    deepgramMic.finish();
                    deepgramMic = null;
                }
                if (deepgramSystem) {
                    deepgramSystem.finish();
                    deepgramSystem = null;
                }
                ws.send(JSON.stringify({ type: 'status', message: 'stopped' }));
            }
        }
        catch (error) {
            console.error('Error processing message:', error);
            try {
                ws.send(JSON.stringify({ type: 'error', message: error?.message ?? 'Server error' }));
            }
            catch (_) { }
        }
    });
    ws.on('close', (code, reason) => {
        console.log('Client disconnected', { code, reason: reason?.toString?.() ?? '' });
        if (deepgramMic)
            deepgramMic.finish();
        if (deepgramSystem)
            deepgramSystem.finish();
    });
    ws.on('error', (error) => {
        console.error('WebSocket error:', error);
    });
});
// AI WebSocket server (streams tokens to the client)
aiWss.on('connection', (ws) => {
    console.log('AI client connected');
    {
        const authWs = ws;
        const sid = authWs.user?.sid;
        if (typeof sid === 'string' && sid.length > 0) {
            registerWebSocketForSession(sid, ws);
        }
    }
    // Only allow one in-flight request per socket for simplicity.
    let currentRequestId = null;
    let cancelled = false;
    const send = (obj) => {
        try {
            ws.send(JSON.stringify(obj));
        }
        catch (_) { }
    };
    ws.on('message', async (message) => {
        try {
            let data;
            try {
                const text = typeof message === 'string' ? message : message.toString('utf8');
                data = JSON.parse(text);
            }
            catch (_) {
                return;
            }
            if (data?.type === 'ai_cancel') {
                if (typeof data.requestId === 'string' && data.requestId === currentRequestId) {
                    cancelled = true;
                }
                return;
            }
            if (data?.type !== 'ai_request')
                return;
            if (!openai) {
                return send({
                    type: 'ai_error',
                    requestId: data.requestId ?? null,
                    status: 500,
                    message: 'OpenAI API key not configured. Set OPENAI_API_KEY in backend .env',
                });
            }
            const requestId = typeof data.requestId === 'string' && data.requestId.length > 0
                ? data.requestId
                : String(Date.now());
            // Cancel any existing request for this socket.
            currentRequestId = requestId;
            cancelled = false;
            const { turns, mode, question, systemPrompt: providedSystemPrompt, model: requestedModel } = data ?? {};
            if (!Array.isArray(turns)) {
                return send({ type: 'ai_error', requestId, status: 400, message: 'Missing turns[]' });
            }
            const questionText = typeof question === 'string' ? question.trim() : '';
            if (questionText.length > 800) {
                return send({ type: 'ai_error', requestId, status: 400, message: 'Question too long (max 800 chars)' });
            }
            // Allow empty turns if a question is provided
            if (turns.length === 0 && questionText.length === 0) {
                return send({ type: 'ai_error', requestId, status: 400, message: 'Missing turns[] or question' });
            }
            if (turns.length > 100) {
                return send({ type: 'ai_error', requestId, status: 400, message: 'Too many turns (max 100)' });
            }
            const normalized = turns
                .map((t) => ({
                source: String(t?.source ?? 'unknown'),
                text: String(t?.text ?? '').trim(),
            }))
                .filter((t) => t.text.length > 0);
            // Allow empty normalized turns if a question is provided
            if (normalized.length === 0 && questionText.length === 0) {
                return send({ type: 'ai_error', requestId, status: 400, message: 'All turns were empty and no question provided' });
            }
            const totalChars = normalized.reduce((sum, t) => sum + t.text.length, 0);
            if (totalChars > 12000) {
                return send({ type: 'ai_error', requestId, status: 400, message: 'Turns too long (max 12000 chars total)' });
            }
            const requestMode = ['summary', 'insights', 'questions'].includes(mode) ? mode : 'reply';
            let systemPrompt;
            let userPrompt;
            const historyText = normalized
                .map((t) => {
                const label = t.source.toLowerCase() === 'mic'
                    ? 'MIC'
                    : t.source.toLowerCase() === 'system'
                        ? 'SYSTEM'
                        : t.source.toUpperCase();
                return `${label}: ${t.text}`;
            })
                .join('\n');
            switch (requestMode) {
                case 'summary':
                    // Use provided system prompt if available (for notes template), otherwise use default
                    if (typeof providedSystemPrompt === 'string' && providedSystemPrompt.trim().length > 0) {
                        systemPrompt = providedSystemPrompt;
                    }
                    else {
                        systemPrompt =
                            'You are HearNow, a meeting assistant. Summarize the meeting conversation so far into concise bullet points. Include key topics discussed, participant responses, and any notable points. If action items or follow-ups exist, list them separately.';
                    }
                    if (historyText.length > 0) {
                        userPrompt = `Meeting transcript:\n${historyText}\n\nProvide a concise summary of this meeting.`;
                    }
                    else {
                        userPrompt = 'No transcript available yet. Please wait for the meeting to begin.';
                    }
                    break;
                case 'insights':
                    systemPrompt =
                        'You are HearNow, a meeting assistant. Analyze the meeting transcript and provide key insights about the participants and discussion. Focus on strengths, areas of concern, communication style, technical knowledge, cultural fit, and overall assessment. Be objective and specific.';
                    if (historyText.length > 0) {
                        userPrompt = `Meeting transcript:\n${historyText}\n\nProvide key insights about this meeting and participants.`;
                    }
                    else {
                        userPrompt = 'No transcript available yet. Please wait for the meeting to begin.';
                    }
                    break;
                case 'questions':
                    systemPrompt =
                        'You are HearNow, a meeting assistant. Based on the meeting transcript so far, suggest 3-5 relevant follow-up questions or discussion points. Consider what has been discussed, what gaps exist, and what would help move the conversation forward. Format as a numbered list.';
                    if (historyText.length > 0) {
                        userPrompt = `Meeting transcript:\n${historyText}\n\nSuggest relevant follow-up questions or discussion points for this meeting.`;
                    }
                    else {
                        userPrompt = 'No transcript available yet. Please wait for the meeting to begin.';
                    }
                    break;
                default:
                    // Use provided system prompt or default
                    const providedPrompt = typeof providedSystemPrompt === 'string' && providedSystemPrompt.trim().length > 0
                        ? providedSystemPrompt.trim()
                        : 'You are HearNow, a meeting assistant. Reply helpfully and concisely to what was said. If the user asks a question, answer it. If the transcript is incomplete, ask one clarifying question.';
                    // Enhance prompt to request concise, formatted responses
                    const enhancedPrompt = `${providedPrompt}\n\nIMPORTANT: Keep responses concise and easy to scan. Use formatting to highlight key points:\n- Use **bold** for main answers or key takeaways\n- Use bullet points (•) for tips or action items\n- Keep paragraphs short (2-3 sentences max)\n- Lead with the most important information first`;
                    systemPrompt = enhancedPrompt;
                    if (historyText.length > 0) {
                        userPrompt = `Conversation transcript (most recent last):\n${historyText}\n\nUser question (optional): ${questionText || '(none)'}\n\nWrite your assistant reply.`;
                    }
                    else if (questionText.length > 0) {
                        userPrompt = `User question: ${questionText}\n\nWrite your assistant reply.`;
                    }
                    else {
                        userPrompt = 'No transcript or question provided. Please provide a question or wait for the conversation to begin.';
                    }
                    break;
            }
            const modelText = typeof requestedModel === 'string' ? requestedModel.trim() : '';
            if (modelText.length > 80) {
                return send({ type: 'ai_error', requestId, status: 400, message: 'Model name too long' });
            }
            let model = modelText.length > 0 ? modelText : (process.env.OPENAI_MODEL || 'gpt-4o-mini');
            const maxTokens = requestMode === 'insights' ? 600 : requestMode === 'questions' ? 300 : 400;
            const authWs = ws;
            const userId = authWs.user?.userId ?? '';
            // Enforce pricing tier entitlements + quota/rate/concurrency
            let planTier = 'free';
            let ent = planEntitlements(planTier);
            let monthlyStats = null;
            try {
                const user = userId ? await getUserByIdFull(userId) : undefined;
                planTier = normalizePlan(user?.plan);
                ent = planEntitlements(planTier);
                const { start: periodStart, end: periodEnd } = getCurrentBillingPeriodUtc();
                monthlyStats = await getUserApiUsageStats(userId, periodStart, periodEnd);
                if (isAutoModelRequested(model) || model.trim().length === 0) {
                    model = pickAutoModel({ planTier, ent, requestMode, stats: monthlyStats });
                }
                if (!ent.allowedModels.includes(model)) {
                    return send({ type: 'ai_error', requestId, status: 403, message: `Model not allowed for plan: ${ent.plan}` });
                }
                if (!ent.canUseSummary && requestMode !== 'reply') {
                    return send({ type: 'ai_error', requestId, status: 403, message: 'Upgrade required for summaries' });
                }
            }
            catch (_) {
                // If billing lookup fails, default behavior continues (server-side OpenAI may still reject).
            }
            if (!userId) {
                return send({ type: 'ai_error', requestId, status: 401, message: 'Unauthorized' });
            }
            // Rate limit (per user, per minute)
            const rl = checkAndConsumeAiRateLimit(userId, planTier);
            if (!rl.allowed) {
                return send({ type: 'ai_error', requestId, status: 429, message: 'Rate limit exceeded. Please wait and try again.' });
            }
            // Monthly AI token budget (global + optional per-model)
            try {
                if (!monthlyStats) {
                    const { start: periodStart, end: periodEnd } = getCurrentBillingPeriodUtc();
                    monthlyStats = await getUserApiUsageStats(userId, periodStart, periodEnd);
                }
                checkMonthlyAiBudgetsOrThrow(monthlyStats, ent, model);
            }
            catch (e) {
                const status = typeof e?.statusCode === 'number' ? e.statusCode : 402;
                return send({ type: 'ai_error', requestId, status, message: e?.message ?? 'AI token limit reached' });
            }
            // Concurrency limit (per user)
            let releaseConcurrency = null;
            try {
                releaseConcurrency = acquireAiConcurrency(userId, planTier);
            }
            catch (e) {
                const status = typeof e?.statusCode === 'number' ? e.statusCode : 429;
                return send({ type: 'ai_error', requestId, status, message: e?.message ?? 'Too many concurrent requests' });
            }
            send({ type: 'ai_start', requestId });
            let fullText = '';
            let usage = null;
            try {
                const stream = await openai.chat.completions.create({
                    model,
                    messages: [
                        { role: 'system', content: systemPrompt },
                        { role: 'user', content: userPrompt },
                    ],
                    max_completion_tokens: maxTokens,
                    temperature: 0.2,
                    stream: true,
                    stream_options: { include_usage: true }, // Include usage in final chunk
                    user: userId, // Track usage per user
                });
                for await (const part of stream) {
                    if (cancelled || currentRequestId !== requestId)
                        break;
                    // Check for usage in the final chunk
                    if (part.usage) {
                        usage = {
                            prompt_tokens: part.usage.prompt_tokens,
                            completion_tokens: part.usage.completion_tokens,
                            total_tokens: part.usage.total_tokens,
                        };
                    }
                    const delta = part?.choices?.[0]?.delta?.content ?? '';
                    if (delta) {
                        fullText += delta;
                        send({ type: 'ai_delta', requestId, delta });
                    }
                }
                // Save usage if available
                if (usage && userId) {
                    try {
                        const sessionId = data.sessionId;
                        await saveApiUsage(userId, model, usage, requestMode, sessionId);
                    }
                    catch (usageError) {
                        // Log but don't fail the request if usage tracking fails
                        console.error('Failed to save API usage:', usageError);
                    }
                }
                if (cancelled || currentRequestId !== requestId) {
                    return send({ type: 'ai_done', requestId, cancelled: true, text: fullText });
                }
                return send({ type: 'ai_done', requestId, cancelled: false, text: fullText });
            }
            catch (error) {
                console.error('AI WS error:', error);
                const status = typeof error?.status === 'number' ? error.status : 500;
                const msg = error?.error?.message || error?.message || 'Failed to generate AI response';
                return send({ type: 'ai_error', requestId, status, message: msg });
            }
            finally {
                try {
                    releaseConcurrency?.();
                }
                catch (_) { }
            }
        }
        catch (error) {
            console.error('AI WS message error:', error);
            try {
                ws.send(JSON.stringify({ type: 'ai_error', requestId: null, status: 500, message: 'Internal error' }));
            }
            catch (_) { }
        }
    });
    ws.on('close', () => {
        console.log('AI client disconnected');
    });
    ws.on('error', (error) => {
        console.error('AI WebSocket error:', error);
    });
});
server.listen(PORT, () => {
    console.log(`Server running on port ${PORT}`);
    console.log(`WebSocket endpoint: ws://localhost:${PORT}/listen`);
    console.log(`AI WebSocket endpoint: ws://localhost:${PORT}/ai`);
    console.log(`Frontend available at: http://localhost:${PORT}`);
    if (!process.env.DEEPGRAM_API_KEY) {
        console.warn('WARNING: DEEPGRAM_API_KEY environment variable not set!');
    }
    if (!process.env.OPENAI_API_KEY) {
        console.warn('WARNING: OPENAI_API_KEY environment variable not set!');
    }
    // Check MongoDB URI (database.ts will handle the warning)
    const mongoUri = process.env.MONGODB_URI;
    if (mongoUri) {
        console.log(`MongoDB URI configured: ${mongoUri.replace(/\/\/.*@/, '//***:***@')}`); // Hide credentials
    }
});
// Graceful shutdown
process.on('SIGINT', async () => {
    console.log('\nShutting down gracefully...');
    await closeDB();
    process.exit(0);
});
process.on('SIGTERM', async () => {
    console.log('\nShutting down gracefully...');
    await closeDB();
    process.exit(0);
});
//# sourceMappingURL=server.js.map