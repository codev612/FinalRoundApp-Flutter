import { MongoClient, ObjectId } from 'mongodb';
import crypto from 'crypto';
// MongoDB connection - read from env at runtime
const getMongoUri = () => {
    const uri = process.env.MONGODB_URI?.trim();
    if (!uri) {
        console.warn('WARNING: MONGODB_URI environment variable not set! Using default: mongodb://localhost:27017');
        console.warn('Make sure MONGODB_URI is set in your .env file in the project root or server directory');
        return 'mongodb://localhost:27017';
    }
    // Hide credentials in log but show that URI was loaded
    const safeUri = uri.replace(/(mongodb:\/\/[^:]+:)([^@]+)@/, '$1***@');
    console.log(`MongoDB URI loaded from environment (${safeUri})`);
    return uri;
};
const getDbName = () => {
    return process.env.MONGODB_DB_NAME || 'hearnow';
};
let client = null;
let db = null;
let usersCollection = null;
let sessionsCollection = null;
let modeConfigsCollection = null;
let customModesCollection = null;
let questionTemplatesCollection = null;
// Initialize MongoDB connection
export const connectDB = async () => {
    try {
        if (!client) {
            const mongoUri = getMongoUri();
            const dbName = getDbName();
            client = new MongoClient(mongoUri);
            await client.connect();
            console.log(`Connected to MongoDB (database: ${dbName})`);
        }
        if (!db) {
            db = client.db(getDbName());
        }
        if (!usersCollection) {
            usersCollection = db.collection('users');
            // Create indexes
            await usersCollection.createIndex({ email: 1 }, { unique: true });
            await usersCollection.createIndex({ verification_token: 1 });
            await usersCollection.createIndex({ verification_code: 1 });
            await usersCollection.createIndex({ reset_token: 1 });
            await usersCollection.createIndex({ 'verification_token_expires': 1 });
            await usersCollection.createIndex({ 'verification_code_expires': 1 });
            await usersCollection.createIndex({ reset_code: 1 });
            await usersCollection.createIndex({ 'reset_token_expires': 1 });
            await usersCollection.createIndex({ 'reset_code_expires': 1 });
        }
        if (!sessionsCollection) {
            sessionsCollection = db.collection('meeting_sessions');
            // Create indexes
            await sessionsCollection.createIndex({ userId: 1 });
            await sessionsCollection.createIndex({ createdAt: -1 });
            await sessionsCollection.createIndex({ updatedAt: -1 });
        }
        if (!modeConfigsCollection) {
            modeConfigsCollection = db.collection('mode_configs');
            await modeConfigsCollection.createIndex({ userId: 1 }, { unique: true });
        }
        if (!customModesCollection) {
            customModesCollection = db.collection('custom_modes');
            await customModesCollection.createIndex({ userId: 1 }, { unique: true });
        }
        if (!questionTemplatesCollection) {
            questionTemplatesCollection = db.collection('question_templates');
            await questionTemplatesCollection.createIndex({ userId: 1 }, { unique: true });
        }
        // Usage tracking collections (indexes only; collection handles are created on demand)
        try {
            await db.collection('api_usage').createIndex({ userId: 1, timestamp: -1 });
        }
        catch (_) { }
        try {
            await db.collection('transcription_usage').createIndex({ userId: 1, timestamp: -1 });
        }
        catch (_) { }
    }
    catch (error) {
        console.error('MongoDB connection error:', error);
        throw error;
    }
};
// Get users collection (ensure connection is established)
const getUsersCollection = () => {
    if (!usersCollection) {
        throw new Error('Database not connected. Call connectDB() first.');
    }
    return usersCollection;
};
// Get sessions collection (ensure connection is established)
export const getSessionsCollection = () => {
    if (!sessionsCollection) {
        throw new Error('Database not connected. Call connectDB() first.');
    }
    return sessionsCollection;
};
const getModeConfigsCollection = () => {
    if (!modeConfigsCollection) {
        throw new Error('Database not connected. Call connectDB() first.');
    }
    return modeConfigsCollection;
};
const getCustomModesCollection = () => {
    if (!customModesCollection) {
        throw new Error('Database not connected. Call connectDB() first.');
    }
    return customModesCollection;
};
const getQuestionTemplatesCollection = () => {
    if (!questionTemplatesCollection) {
        throw new Error('Database not connected. Call connectDB() first.');
    }
    return questionTemplatesCollection;
};
// Helper function to convert MongoDB user to API format
const toUser = (doc) => {
    if (!doc)
        return undefined;
    return {
        ...doc,
        id: doc._id?.toString(),
    };
};
// Helper function to convert to PublicUser
const toPublicUser = (doc) => {
    if (!doc)
        return undefined;
    return {
        id: doc._id?.toString() || '',
        email: doc.email,
        name: doc.name || '',
        email_verified: doc.email_verified,
        created_at: doc.created_at,
    };
};
// Helper function to format session for API response
const formatSessionForApi = (session) => {
    const formatDate = (date) => {
        if (!date)
            return null;
        if (date instanceof Date)
            return date.toISOString();
        if (typeof date === 'string')
            return date;
        return null;
    };
    return {
        id: session._id?.toString() || session.id,
        title: session.title,
        createdAt: formatDate(session.createdAt),
        updatedAt: formatDate(session.updatedAt),
        bubbles: session.bubbles.map((b) => ({
            source: b.source,
            text: b.text,
            timestamp: formatDate(b.timestamp),
            isDraft: b.isDraft,
        })),
        summary: session.summary,
        insights: session.insights,
        questions: session.questions,
        modeKey: session.modeKey || 'general', // Default to 'general' if not set
        metadata: session.metadata || {},
    };
};
// Helper functions
export const generateToken = () => {
    return crypto.randomBytes(32).toString('hex');
};
// Generate 6-digit verification code
export const generateVerificationCode = () => {
    return Math.floor(100000 + Math.random() * 900000).toString();
};
export const setVerificationToken = async (userId, token, expiresInHours = 24) => {
    const expiresAt = Date.now() + expiresInHours * 60 * 60 * 1000;
    const collection = getUsersCollection();
    await collection.updateOne({ _id: new ObjectId(userId) }, {
        $set: {
            verification_token: token,
            verification_token_expires: expiresAt,
            updated_at: Date.now(),
        },
    });
};
// Set 6-digit verification code
export const setVerificationCode = async (userId, code, expiresInMinutes = 10) => {
    const expiresAt = Date.now() + expiresInMinutes * 60 * 1000;
    const collection = getUsersCollection();
    await collection.updateOne({ _id: new ObjectId(userId) }, {
        $set: {
            verification_code: code,
            verification_code_expires: expiresAt,
            updated_at: Date.now(),
        },
    });
};
// Get user by verification code
export const getUserByVerificationCode = async (code) => {
    const collection = getUsersCollection();
    const user = await collection.findOne({
        verification_code: code,
        verification_code_expires: { $gt: Date.now() },
    });
    return toUser(user);
};
export const setResetToken = async (userId, token, expiresInHours = 1) => {
    const expiresAt = Date.now() + expiresInHours * 60 * 60 * 1000;
    const collection = getUsersCollection();
    await collection.updateOne({ _id: new ObjectId(userId) }, {
        $set: {
            reset_token: token,
            reset_token_expires: expiresAt,
            updated_at: Date.now(),
        },
    });
};
// Set reset code (6-digit code for password reset)
export const setResetCode = async (userId, code, expiresInMinutes = 10) => {
    const expiresAt = Date.now() + expiresInMinutes * 60 * 1000;
    const collection = getUsersCollection();
    await collection.updateOne({ _id: new ObjectId(userId) }, {
        $set: {
            reset_code: code,
            reset_code_expires: expiresAt,
            updated_at: Date.now(),
        },
    });
};
export const clearVerificationToken = async (userId) => {
    const collection = getUsersCollection();
    await collection.updateOne({ _id: new ObjectId(userId) }, {
        $set: {
            verification_token: null,
            verification_token_expires: null,
            updated_at: Date.now(),
        },
    });
};
export const clearResetToken = async (userId) => {
    const collection = getUsersCollection();
    await collection.updateOne({ _id: new ObjectId(userId) }, {
        $set: {
            reset_token: null,
            reset_token_expires: null,
            reset_code: null,
            reset_code_expires: null,
            updated_at: Date.now(),
        },
    });
};
export const markEmailVerified = async (userId) => {
    const collection = getUsersCollection();
    await collection.updateOne({ _id: new ObjectId(userId) }, {
        $set: {
            email_verified: true,
            verification_token: null,
            verification_token_expires: null,
            verification_code: null,
            verification_code_expires: null,
            updated_at: Date.now(),
        },
    });
};
// User operations
export const createUser = async (email, name, passwordHash) => {
    const code = generateVerificationCode();
    const codeExpiresAt = Date.now() + 10 * 60 * 1000; // 10 minutes
    const now = Date.now();
    const userDoc = {
        email,
        name,
        plan: 'free',
        plan_updated_at: now,
        password_hash: passwordHash,
        email_verified: false,
        verification_code: code,
        verification_code_expires: codeExpiresAt,
        verification_token: code, // Store code as token for backward compatibility with legacy endpoints
        verification_token_expires: codeExpiresAt, // Same expiration as code
        reset_token: null,
        reset_token_expires: null,
        reset_code: null,
        reset_code_expires: null,
        pending_email: null,
        current_email_code: null,
        current_email_code_expires: null,
        new_email_code: null,
        new_email_code_expires: null,
        created_at: now,
        updated_at: now,
    };
    const collection = getUsersCollection();
    const result = await collection.insertOne(userDoc);
    return {
        id: result.insertedId.toString(),
        email,
        verification_token: code, // Return code as token for backward compatibility
        verification_code: code,
    };
};
export const getUserByEmail = async (email) => {
    const collection = getUsersCollection();
    const user = await collection.findOne({ email });
    return toUser(user);
};
export const getUserById = async (id) => {
    const collection = getUsersCollection();
    const user = await collection.findOne({ _id: new ObjectId(id) });
    return toPublicUser(user);
};
export const getUserByIdFull = async (id) => {
    const collection = getUsersCollection();
    const user = await collection.findOne({ _id: new ObjectId(id) });
    return toUser(user);
};
export const getUserByVerificationToken = async (token) => {
    const collection = getUsersCollection();
    const user = await collection.findOne({
        verification_token: token,
        verification_token_expires: { $gt: Date.now() },
    });
    return toUser(user);
};
export const getUserByResetToken = async (token) => {
    const collection = getUsersCollection();
    const user = await collection.findOne({
        reset_token: token,
        reset_token_expires: { $gt: Date.now() },
    });
    return toUser(user);
};
// Get user by reset code
export const getUserByResetCode = async (code) => {
    const collection = getUsersCollection();
    const user = await collection.findOne({
        reset_code: code,
        reset_code_expires: { $gt: Date.now() },
    });
    return toUser(user);
};
export const updatePassword = async (userId, passwordHash) => {
    const collection = getUsersCollection();
    const result = await collection.updateOne({ _id: new ObjectId(userId) }, {
        $set: {
            password_hash: passwordHash,
            reset_token: null,
            reset_token_expires: null,
            reset_code: null,
            reset_code_expires: null,
            updated_at: Date.now(),
        },
    });
    if (result.matchedCount === 0) {
        throw new Error(`User not found: ${userId}`);
    }
    if (result.modifiedCount === 0) {
        console.warn(`[updatePassword] No document modified for user ${userId} - password may already be the same`);
    }
    console.log(`[updatePassword] Password updated for user ${userId}, matched: ${result.matchedCount}, modified: ${result.modifiedCount}`);
};
export const updateUserName = async (userId, name) => {
    const collection = getUsersCollection();
    await collection.updateOne({ _id: new ObjectId(userId) }, {
        $set: {
            name,
            updated_at: Date.now(),
        },
    });
};
export const updateUserEmail = async (userId, email) => {
    const collection = getUsersCollection();
    await collection.updateOne({ _id: new ObjectId(userId) }, {
        $set: {
            email,
            email_verified: false, // Email change requires re-verification
            verification_code: null,
            verification_code_expires: null,
            verification_token: null,
            verification_token_expires: null,
            updated_at: Date.now(),
        },
    });
};
export const setPendingEmailChange = async (userId, newEmail, currentEmailCode) => {
    const collection = getUsersCollection();
    const expiresAt = Date.now() + 10 * 60 * 1000; // 10 minutes
    await collection.updateOne({ _id: new ObjectId(userId) }, {
        $set: {
            pending_email: newEmail,
            current_email_code: currentEmailCode,
            current_email_code_expires: expiresAt,
            new_email_code: null, // Will be set after current email is verified
            new_email_code_expires: null,
            updated_at: Date.now(),
        },
    });
};
export const verifyCurrentEmailForChange = async (userId, currentEmailCode) => {
    const collection = getUsersCollection();
    const user = await collection.findOne({ _id: new ObjectId(userId) });
    if (!user)
        return false;
    const now = Date.now();
    const currentCodeValid = user.current_email_code === currentEmailCode &&
        user.current_email_code_expires &&
        user.current_email_code_expires > now;
    if (!currentCodeValid || !user.pending_email) {
        return false;
    }
    // Mark current email as verified (step 1 complete)
    // Don't change email yet - wait for new email verification
    await collection.updateOne({ _id: new ObjectId(userId) }, {
        $set: {
            current_email_code: null, // Clear current code
            current_email_code_expires: null,
            updated_at: Date.now(),
        },
    });
    return true;
};
export const setNewEmailCode = async (userId, newEmailCode) => {
    const collection = getUsersCollection();
    const expiresAt = Date.now() + 10 * 60 * 1000; // 10 minutes
    await collection.updateOne({ _id: new ObjectId(userId) }, {
        $set: {
            new_email_code: newEmailCode,
            new_email_code_expires: expiresAt,
            updated_at: Date.now(),
        },
    });
};
export const verifyNewEmailForChange = async (userId, newEmailCode) => {
    const collection = getUsersCollection();
    const user = await collection.findOne({ _id: new ObjectId(userId) });
    if (!user)
        return false;
    const now = Date.now();
    const newCodeValid = user.new_email_code === newEmailCode &&
        user.new_email_code_expires &&
        user.new_email_code_expires > now;
    // Check that current email was already verified (no current_email_code means step 1 was done)
    const currentEmailVerified = !user.current_email_code;
    if (!newCodeValid || !currentEmailVerified || !user.pending_email) {
        return false;
    }
    // Update email and clear pending change
    // Mark as verified since user has proven access to both emails
    await collection.updateOne({ _id: new ObjectId(userId) }, {
        $set: {
            email: user.pending_email,
            email_verified: true, // Verified since user confirmed both email codes
            pending_email: null,
            current_email_code: null,
            current_email_code_expires: null,
            new_email_code: null,
            new_email_code_expires: null,
            verification_code: null,
            verification_code_expires: null,
            updated_at: Date.now(),
        },
    });
    return true;
};
export const clearPendingEmailChange = async (userId) => {
    const collection = getUsersCollection();
    await collection.updateOne({ _id: new ObjectId(userId) }, {
        $set: {
            pending_email: null,
            current_email_code: null,
            current_email_code_expires: null,
            new_email_code: null,
            new_email_code_expires: null,
            updated_at: Date.now(),
        },
    });
};
// Meeting Session operations
export const createMeetingSession = async (session) => {
    const collection = getSessionsCollection();
    const result = await collection.insertOne(session);
    return result.insertedId.toString();
};
export const getMeetingSession = async (sessionId, userId) => {
    const collection = getSessionsCollection();
    const session = await collection.findOne({
        _id: new ObjectId(sessionId),
        userId,
    });
    if (!session)
        return null;
    return formatSessionForApi(session);
};
export const updateMeetingSession = async (sessionId, userId, updates) => {
    const collection = getSessionsCollection();
    const result = await collection.updateOne({ _id: new ObjectId(sessionId), userId }, {
        $set: {
            ...updates,
            updatedAt: new Date(),
        },
    });
    return result.matchedCount > 0;
};
export const listMeetingSessions = async (userId, options) => {
    const collection = getSessionsCollection();
    // Build query filter
    const filter = { userId };
    if (options?.search) {
        // Search in title (case-insensitive)
        filter.title = { $regex: options.search, $options: 'i' };
    }
    // Get total count for pagination
    const total = await collection.countDocuments(filter);
    // Build query with pagination
    let query = collection.find(filter).sort({ updatedAt: -1, createdAt: -1 });
    if (options?.skip !== undefined) {
        query = query.skip(options.skip);
    }
    if (options?.limit !== undefined) {
        query = query.limit(options.limit);
    }
    const sessions = await query.toArray();
    return {
        sessions: sessions.map((s) => formatSessionForApi(s)),
        total,
    };
};
export const deleteMeetingSession = async (sessionId, userId) => {
    const collection = getSessionsCollection();
    const result = await collection.deleteOne({
        _id: new ObjectId(sessionId),
        userId,
    });
    return result.deletedCount > 0;
};
// Mode configs (built-in modes: realTimePrompt, notesTemplate per mode name)
export const getModeConfigs = async (userId) => {
    const collection = getModeConfigsCollection();
    const doc = await collection.findOne({ userId });
    if (!doc || !doc.configs || Object.keys(doc.configs).length === 0) {
        return null;
    }
    return doc.configs;
};
export const saveModeConfig = async (userId, modeName, config) => {
    const collection = getModeConfigsCollection();
    await collection.updateOne({ userId }, { $set: { [`configs.${modeName}`]: config } }, { upsert: true });
};
// Custom modes (user-created, e.g. from templates)
export const getCustomModes = async (userId) => {
    const collection = getCustomModesCollection();
    const doc = await collection.findOne({ userId });
    return doc?.modes ?? [];
};
export const saveCustomModes = async (userId, modes) => {
    const collection = getCustomModesCollection();
    await collection.updateOne({ userId }, { $set: { modes } }, { upsert: true });
};
export const deleteCustomMode = async (userId, modeId) => {
    const collection = getCustomModesCollection();
    const doc = await collection.findOne({ userId });
    const modes = doc?.modes ?? [];
    console.log('[RemoveMode] db deleteCustomMode', { userId, modeId, beforeCount: modes.length, modeIds: modes.map((m) => m.id) });
    const next = modes.filter((m) => String(m.id) !== String(modeId));
    const removed = modes.length - next.length;
    console.log('[RemoveMode] db after filter', { nextCount: next.length, removed });
    const result = await collection.updateOne({ userId }, { $set: { modes: next } }, { upsert: true });
    console.log('[RemoveMode] db updateOne result', {
        acknowledged: result.acknowledged,
        matchedCount: result.matchedCount,
        modifiedCount: result.modifiedCount,
        upsertedCount: result.upsertedCount,
        upsertedId: result.upsertedId?.toString(),
        collection: collection.collectionName,
    });
    const docAfter = await collection.findOne({ userId });
    const modesAfter = docAfter?.modes ?? [];
    console.log('[RemoveMode] db read-after-write', { count: modesAfter.length, modeIds: modesAfter.map((m) => m.id), stillHasDeletedId: modesAfter.some((m) => String(m.id) === String(modeId)) });
};
// Question templates
export const getQuestionTemplates = async (userId) => {
    const collection = getQuestionTemplatesCollection();
    console.log('[DB] getQuestionTemplates: userId=', userId);
    const doc = await collection.findOne({ userId });
    const templates = doc?.templates ?? [];
    console.log('[DB] getQuestionTemplates: found', templates.length, 'templates');
    return templates;
};
export const saveQuestionTemplates = async (userId, templates) => {
    const collection = getQuestionTemplatesCollection();
    console.log('[DB] saveQuestionTemplates: userId=', userId, 'count=', templates.length);
    const result = await collection.updateOne({ userId }, { $set: { templates } }, { upsert: true });
    console.log('[DB] saveQuestionTemplates result:', {
        acknowledged: result.acknowledged,
        matchedCount: result.matchedCount,
        modifiedCount: result.modifiedCount,
        upsertedCount: result.upsertedCount,
    });
};
export const deleteQuestionTemplate = async (userId, templateId) => {
    const collection = getQuestionTemplatesCollection();
    const doc = await collection.findOne({ userId });
    const templates = doc?.templates ?? [];
    const next = templates.filter((t) => String(t.id) !== String(templateId));
    await collection.updateOne({ userId }, { $set: { templates: next } }, { upsert: true });
};
// Close database connection
export const closeDB = async () => {
    if (client) {
        await client.close();
        client = null;
        db = null;
        usersCollection = null;
        sessionsCollection = null;
        modeConfigsCollection = null;
        customModesCollection = null;
        questionTemplatesCollection = null;
        console.log('MongoDB connection closed');
    }
};
export const getApiUsageCollection = (db) => {
    return db.collection('api_usage');
};
export const saveApiUsage = async (userId, model, usage, mode, sessionId) => {
    await connectDB();
    const currentDb = db;
    if (!currentDb)
        throw new Error('Database not connected');
    const collection = getApiUsageCollection(currentDb);
    await collection.insertOne({
        userId,
        model,
        promptTokens: usage.prompt_tokens,
        completionTokens: usage.completion_tokens,
        totalTokens: usage.total_tokens,
        mode,
        timestamp: new Date(),
        sessionId,
    });
};
export const getUserApiUsage = async (userId, startDate, endDate) => {
    await connectDB();
    const currentDb = db;
    if (!currentDb)
        throw new Error('Database not connected');
    const collection = getApiUsageCollection(currentDb);
    const query = { userId };
    if (startDate || endDate) {
        query.timestamp = {};
        if (startDate)
            query.timestamp.$gte = startDate;
        if (endDate)
            query.timestamp.$lte = endDate;
    }
    return collection.find(query).sort({ timestamp: -1 }).toArray();
};
export const getUserApiUsageStats = async (userId, startDate, endDate) => {
    const usage = await getUserApiUsage(userId, startDate, endDate);
    const stats = {
        totalRequests: usage.length,
        totalTokens: 0,
        totalPromptTokens: 0,
        totalCompletionTokens: 0,
        byModel: {},
        byMode: {},
    };
    for (const record of usage) {
        stats.totalTokens += record.totalTokens;
        stats.totalPromptTokens += record.promptTokens;
        stats.totalCompletionTokens += record.completionTokens;
        if (!stats.byModel[record.model]) {
            stats.byModel[record.model] = { requests: 0, tokens: 0 };
        }
        stats.byModel[record.model].requests++;
        stats.byModel[record.model].tokens += record.totalTokens;
        if (!stats.byMode[record.mode]) {
            stats.byMode[record.mode] = { requests: 0, tokens: 0 };
        }
        stats.byMode[record.mode].requests++;
        stats.byMode[record.mode].tokens += record.totalTokens;
    }
    return stats;
};
export const saveTranscriptionUsage = async (userId, durationMs, sessionId) => {
    await connectDB();
    const currentDb = db;
    if (!currentDb)
        throw new Error('Database not connected');
    await currentDb.collection('transcription_usage').insertOne({
        userId,
        durationMs,
        timestamp: new Date(),
        sessionId,
    });
};
export const getTranscriptionUsageMsForPeriod = async (userId, start, end) => {
    await connectDB();
    const currentDb = db;
    if (!currentDb)
        throw new Error('Database not connected');
    const coll = currentDb.collection('transcription_usage');
    const rows = await coll
        .aggregate([
        { $match: { userId, timestamp: { $gte: start, $lt: end } } },
        { $group: { _id: null, totalMs: { $sum: '$durationMs' } } },
        { $project: { _id: 0, totalMs: 1 } },
    ])
        .toArray();
    return rows[0]?.totalMs ?? 0;
};
export const setUserPlan = async (userId, plan) => {
    const collection = getUsersCollection();
    await collection.updateOne({ _id: new ObjectId(userId) }, { $set: { plan, plan_updated_at: Date.now(), updated_at: Date.now() } });
};
export default { connectDB, closeDB, getUsersCollection };
//# sourceMappingURL=database.js.map