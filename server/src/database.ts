import { MongoClient, Db, Collection, ObjectId } from 'mongodb';
import crypto from 'crypto';

// User type definition
export interface User {
  _id?: ObjectId;
  id?: string; // For backward compatibility, will be _id.toString()
  email: string;
  name: string;
  // Pricing tier
  plan?: 'free' | 'pro' | 'pro_plus';
  plan_updated_at?: number;
  password_hash: string;
  email_verified: boolean;
  verification_code: string | null; // 6-digit code
  verification_code_expires: number | null;
  verification_token: string | null; // Keep for backward compatibility
  verification_token_expires: number | null;
  reset_token: string | null;
  reset_token_expires: number | null;
  reset_code: string | null; // 6-digit code for password reset
  reset_code_expires: number | null;
  // Email change verification
  pending_email: string | null; // New email waiting for verification
  current_email_code: string | null; // Code sent to current email
  current_email_code_expires: number | null;
  new_email_code: string | null; // Code sent to new email
  new_email_code_expires: number | null;
  created_at: number;
  updated_at: number;
}

export interface PublicUser {
  id: string;
  email: string;
  name: string;
  email_verified: boolean;
  created_at: number;
}

export interface CreateUserResult {
  id: string;
  email: string;
  verification_token: string; // Actually contains the 6-digit code
  verification_code: string; // 6-digit code
}

// MongoDB connection - read from env at runtime
const getMongoUri = (): string => {
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

const getDbName = (): string => {
  return process.env.MONGODB_DB_NAME || 'hearnow';
};

// Meeting Session type definition
export interface MeetingSession {
  _id?: ObjectId;
  id?: string; // For backward compatibility, will be _id.toString()
  userId: string; // User who owns this session
  title: string;
  createdAt: Date | string;
  updatedAt?: Date | string | null;
  bubbles: Array<{
    source: string;
    text: string;
    timestamp: Date | string;
    isDraft: boolean;
  }>;
  summary?: string | null;
  insights?: string | null;
  questions?: string | null;
  modeKey?: string; // Mode key: built-in enum name (e.g. "general") or "custom:{id}" for custom modes
  metadata?: Record<string, any>;
}

// Mode config per built-in mode (keyed by mode name, e.g. 'general', 'meeting')
export interface ModeConfigEntry {
  realTimePrompt: string;
  notesTemplate: string;
}

// One document per user storing all built-in mode configs
export interface ModeConfigsDoc {
  _id?: ObjectId;
  userId: string;
  configs: Record<string, ModeConfigEntry>;
}

// User-created modes (from "add from template" or "add custom")
export interface CustomModeEntry {
  id: string;
  label: string;
  iconCodePoint: number;
  realTimePrompt: string;
  notesTemplate: string;
}

export interface CustomModesDoc {
  _id?: ObjectId;
  userId: string;
  modes: CustomModeEntry[];
}

export interface QuestionTemplateEntry {
  id: string;
  question: string;
}

export interface QuestionTemplatesDoc {
  _id?: ObjectId;
  userId: string;
  templates: QuestionTemplateEntry[];
}

let client: MongoClient | null = null;
let db: Db | null = null;
let usersCollection: Collection<User> | null = null;
let sessionsCollection: Collection<MeetingSession> | null = null;
let modeConfigsCollection: Collection<ModeConfigsDoc> | null = null;
let customModesCollection: Collection<CustomModesDoc> | null = null;
let questionTemplatesCollection: Collection<QuestionTemplatesDoc> | null = null;

// Initialize MongoDB connection
export const connectDB = async (): Promise<void> => {
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
      usersCollection = db.collection<User>('users');
      
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
      sessionsCollection = db.collection<MeetingSession>('meeting_sessions');
      
      // Create indexes
      await sessionsCollection.createIndex({ userId: 1 });
      await sessionsCollection.createIndex({ createdAt: -1 });
      await sessionsCollection.createIndex({ updatedAt: -1 });
    }

    if (!modeConfigsCollection) {
      modeConfigsCollection = db.collection<ModeConfigsDoc>('mode_configs');
      await modeConfigsCollection.createIndex({ userId: 1 }, { unique: true });
    }

    if (!customModesCollection) {
      customModesCollection = db.collection<CustomModesDoc>('custom_modes');
      await customModesCollection.createIndex({ userId: 1 }, { unique: true });
    }

    if (!questionTemplatesCollection) {
      questionTemplatesCollection = db.collection<QuestionTemplatesDoc>('question_templates');
      await questionTemplatesCollection.createIndex({ userId: 1 }, { unique: true });
    }

    // Usage tracking collections (indexes only; collection handles are created on demand)
    try {
      await db.collection('api_usage').createIndex({ userId: 1, timestamp: -1 });
    } catch (_) {}
    try {
      await db.collection('transcription_usage').createIndex({ userId: 1, timestamp: -1 });
    } catch (_) {}
  } catch (error) {
    console.error('MongoDB connection error:', error);
    throw error;
  }
};

// Get users collection (ensure connection is established)
const getUsersCollection = (): Collection<User> => {
  if (!usersCollection) {
    throw new Error('Database not connected. Call connectDB() first.');
  }
  return usersCollection;
};

// Get sessions collection (ensure connection is established)
export const getSessionsCollection = (): Collection<MeetingSession> => {
  if (!sessionsCollection) {
    throw new Error('Database not connected. Call connectDB() first.');
  }
  return sessionsCollection;
};

const getModeConfigsCollection = (): Collection<ModeConfigsDoc> => {
  if (!modeConfigsCollection) {
    throw new Error('Database not connected. Call connectDB() first.');
  }
  return modeConfigsCollection;
};

const getCustomModesCollection = (): Collection<CustomModesDoc> => {
  if (!customModesCollection) {
    throw new Error('Database not connected. Call connectDB() first.');
  }
  return customModesCollection;
};

const getQuestionTemplatesCollection = (): Collection<QuestionTemplatesDoc> => {
  if (!questionTemplatesCollection) {
    throw new Error('Database not connected. Call connectDB() first.');
  }
  return questionTemplatesCollection;
};

// Helper function to convert MongoDB user to API format
const toUser = (doc: User | null): User | undefined => {
  if (!doc) return undefined;
  return {
    ...doc,
    id: doc._id?.toString(),
  };
};

// Helper function to convert to PublicUser
const toPublicUser = (doc: User | null): PublicUser | undefined => {
  if (!doc) return undefined;
  return {
    id: doc._id?.toString() || '',
    email: doc.email,
    name: doc.name || '',
    email_verified: doc.email_verified,
    created_at: doc.created_at,
  };
};

// Helper function to format session for API response
const formatSessionForApi = (session: MeetingSession): any => {
  const formatDate = (date: Date | string | undefined | null): string | null => {
    if (!date) return null;
    if (date instanceof Date) return date.toISOString();
    if (typeof date === 'string') return date;
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
export const generateToken = (): string => {
  return crypto.randomBytes(32).toString('hex');
};

// Generate 6-digit verification code
export const generateVerificationCode = (): string => {
  return Math.floor(100000 + Math.random() * 900000).toString();
};

export const setVerificationToken = async (userId: string, token: string, expiresInHours: number = 24): Promise<void> => {
  const expiresAt = Date.now() + expiresInHours * 60 * 60 * 1000;
  const collection = getUsersCollection();
  await collection.updateOne(
    { _id: new ObjectId(userId) },
    {
      $set: {
        verification_token: token,
        verification_token_expires: expiresAt,
        updated_at: Date.now(),
      },
    }
  );
};

// Set 6-digit verification code
export const setVerificationCode = async (userId: string, code: string, expiresInMinutes: number = 10): Promise<void> => {
  const expiresAt = Date.now() + expiresInMinutes * 60 * 1000;
  const collection = getUsersCollection();
  await collection.updateOne(
    { _id: new ObjectId(userId) },
    {
      $set: {
        verification_code: code,
        verification_code_expires: expiresAt,
        updated_at: Date.now(),
      },
    }
  );
};

// Get user by verification code
export const getUserByVerificationCode = async (code: string): Promise<User | undefined> => {
  const collection = getUsersCollection();
  const user = await collection.findOne<User>({
    verification_code: code,
    verification_code_expires: { $gt: Date.now() },
  });
  return toUser(user);
};

export const setResetToken = async (userId: string, token: string, expiresInHours: number = 1): Promise<void> => {
  const expiresAt = Date.now() + expiresInHours * 60 * 60 * 1000;
  const collection = getUsersCollection();
  await collection.updateOne(
    { _id: new ObjectId(userId) },
    {
      $set: {
        reset_token: token,
        reset_token_expires: expiresAt,
        updated_at: Date.now(),
      },
    }
  );
};

// Set reset code (6-digit code for password reset)
export const setResetCode = async (userId: string, code: string, expiresInMinutes: number = 10): Promise<void> => {
  const expiresAt = Date.now() + expiresInMinutes * 60 * 1000;
  const collection = getUsersCollection();
  await collection.updateOne(
    { _id: new ObjectId(userId) },
    {
      $set: {
        reset_code: code,
        reset_code_expires: expiresAt,
        updated_at: Date.now(),
      },
    }
  );
};

export const clearVerificationToken = async (userId: string): Promise<void> => {
  const collection = getUsersCollection();
  await collection.updateOne(
    { _id: new ObjectId(userId) },
    {
      $set: {
        verification_token: null,
        verification_token_expires: null,
        updated_at: Date.now(),
      },
    }
  );
};

export const clearResetToken = async (userId: string): Promise<void> => {
  const collection = getUsersCollection();
  await collection.updateOne(
    { _id: new ObjectId(userId) },
    {
      $set: {
        reset_token: null,
        reset_token_expires: null,
        reset_code: null,
        reset_code_expires: null,
        updated_at: Date.now(),
      },
    }
  );
};

export const markEmailVerified = async (userId: string): Promise<void> => {
  const collection = getUsersCollection();
  await collection.updateOne(
    { _id: new ObjectId(userId) },
    {
      $set: {
        email_verified: true,
        verification_token: null,
        verification_token_expires: null,
        verification_code: null,
        verification_code_expires: null,
        updated_at: Date.now(),
      },
    }
  );
};

// User operations
export const createUser = async (email: string, name: string, passwordHash: string): Promise<CreateUserResult> => {
  const code = generateVerificationCode();
  const codeExpiresAt = Date.now() + 10 * 60 * 1000; // 10 minutes
  const now = Date.now();

  const userDoc: Omit<User, '_id' | 'id'> = {
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
  const result = await collection.insertOne(userDoc as Omit<User, '_id'>);

  return {
    id: result.insertedId.toString(),
    email,
    verification_token: code, // Return code as token for backward compatibility
    verification_code: code,
  };
};

export const getUserByEmail = async (email: string): Promise<User | undefined> => {
  const collection = getUsersCollection();
  const user = await collection.findOne({ email });
  return toUser(user);
};

export const getUserById = async (id: string): Promise<PublicUser | undefined> => {
  const collection = getUsersCollection();
  const user = await collection.findOne({ _id: new ObjectId(id) });
  return toPublicUser(user);
};

export const getUserByIdFull = async (id: string): Promise<User | undefined> => {
  const collection = getUsersCollection();
  const user = await collection.findOne({ _id: new ObjectId(id) });
  return toUser(user);
};

export const getUserByVerificationToken = async (token: string): Promise<User | undefined> => {
  const collection = getUsersCollection();
  const user = await collection.findOne({
    verification_token: token,
    verification_token_expires: { $gt: Date.now() },
  });
  return toUser(user);
};

export const getUserByResetToken = async (token: string): Promise<User | undefined> => {
  const collection = getUsersCollection();
  const user = await collection.findOne({
    reset_token: token,
    reset_token_expires: { $gt: Date.now() },
  });
  return toUser(user);
};

// Get user by reset code
export const getUserByResetCode = async (code: string): Promise<User | undefined> => {
  const collection = getUsersCollection();
  const user = await collection.findOne({
    reset_code: code,
    reset_code_expires: { $gt: Date.now() },
  });
  return toUser(user);
};

export const updatePassword = async (userId: string, passwordHash: string): Promise<void> => {
  const collection = getUsersCollection();
  const result = await collection.updateOne(
    { _id: new ObjectId(userId) },
    {
      $set: {
        password_hash: passwordHash,
        reset_token: null,
        reset_token_expires: null,
        reset_code: null,
        reset_code_expires: null,
        updated_at: Date.now(),
      },
    }
  );
  
  if (result.matchedCount === 0) {
    throw new Error(`User not found: ${userId}`);
  }
  
  if (result.modifiedCount === 0) {
    console.warn(`[updatePassword] No document modified for user ${userId} - password may already be the same`);
  }
  
  console.log(`[updatePassword] Password updated for user ${userId}, matched: ${result.matchedCount}, modified: ${result.modifiedCount}`);
};

export const updateUserName = async (userId: string, name: string): Promise<void> => {
  const collection = getUsersCollection();
  await collection.updateOne(
    { _id: new ObjectId(userId) },
    {
      $set: {
        name,
        updated_at: Date.now(),
      },
    }
  );
};

export const updateUserEmail = async (userId: string, email: string): Promise<void> => {
  const collection = getUsersCollection();
  await collection.updateOne(
    { _id: new ObjectId(userId) },
    {
      $set: {
        email,
        email_verified: false, // Email change requires re-verification
        verification_code: null,
        verification_code_expires: null,
        verification_token: null,
        verification_token_expires: null,
        updated_at: Date.now(),
      },
    }
  );
};

export const setPendingEmailChange = async (
  userId: string,
  newEmail: string,
  currentEmailCode: string
): Promise<void> => {
  const collection = getUsersCollection();
  const expiresAt = Date.now() + 10 * 60 * 1000; // 10 minutes
  await collection.updateOne(
    { _id: new ObjectId(userId) },
    {
      $set: {
        pending_email: newEmail,
        current_email_code: currentEmailCode,
        current_email_code_expires: expiresAt,
        new_email_code: null, // Will be set after current email is verified
        new_email_code_expires: null,
        updated_at: Date.now(),
      },
    }
  );
};

export const verifyCurrentEmailForChange = async (
  userId: string,
  currentEmailCode: string
): Promise<boolean> => {
  const collection = getUsersCollection();
  const user = await collection.findOne({ _id: new ObjectId(userId) });
  
  if (!user) return false;
  
  const now = Date.now();
  const currentCodeValid = 
    user.current_email_code === currentEmailCode &&
    user.current_email_code_expires &&
    user.current_email_code_expires > now;
  
  if (!currentCodeValid || !user.pending_email) {
    return false;
  }
  
  // Mark current email as verified (step 1 complete)
  // Don't change email yet - wait for new email verification
  await collection.updateOne(
    { _id: new ObjectId(userId) },
    {
      $set: {
        current_email_code: null, // Clear current code
        current_email_code_expires: null,
        updated_at: Date.now(),
      },
    }
  );
  
  return true;
};

export const setNewEmailCode = async (
  userId: string,
  newEmailCode: string
): Promise<void> => {
  const collection = getUsersCollection();
  const expiresAt = Date.now() + 10 * 60 * 1000; // 10 minutes
  await collection.updateOne(
    { _id: new ObjectId(userId) },
    {
      $set: {
        new_email_code: newEmailCode,
        new_email_code_expires: expiresAt,
        updated_at: Date.now(),
      },
    }
  );
};

export const verifyNewEmailForChange = async (
  userId: string,
  newEmailCode: string
): Promise<boolean> => {
  const collection = getUsersCollection();
  const user = await collection.findOne({ _id: new ObjectId(userId) });
  
  if (!user) return false;
  
  const now = Date.now();
  const newCodeValid =
    user.new_email_code === newEmailCode &&
    user.new_email_code_expires &&
    user.new_email_code_expires > now;
  
  // Check that current email was already verified (no current_email_code means step 1 was done)
  const currentEmailVerified = !user.current_email_code;
  
  if (!newCodeValid || !currentEmailVerified || !user.pending_email) {
    return false;
  }
  
  // Update email and clear pending change
  // Mark as verified since user has proven access to both emails
  await collection.updateOne(
    { _id: new ObjectId(userId) },
    {
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
    }
  );
  
  return true;
};

export const clearPendingEmailChange = async (userId: string): Promise<void> => {
  const collection = getUsersCollection();
  await collection.updateOne(
    { _id: new ObjectId(userId) },
    {
      $set: {
        pending_email: null,
        current_email_code: null,
        current_email_code_expires: null,
        new_email_code: null,
        new_email_code_expires: null,
        updated_at: Date.now(),
      },
    }
  );
};

// Meeting Session operations
export const createMeetingSession = async (session: Omit<MeetingSession, '_id' | 'id'>): Promise<string> => {
  const collection = getSessionsCollection();
  const result = await collection.insertOne(session as Omit<MeetingSession, '_id'>);
  return result.insertedId.toString();
};

export const getMeetingSession = async (sessionId: string, userId: string): Promise<any | null> => {
  const collection = getSessionsCollection();
  const session = await collection.findOne({
    _id: new ObjectId(sessionId),
    userId,
  });
  if (!session) return null;
  return formatSessionForApi(session);
};

export const updateMeetingSession = async (
  sessionId: string,
  userId: string,
  updates: Partial<Omit<MeetingSession, '_id' | 'id' | 'userId' | 'createdAt'>>
): Promise<boolean> => {
  const collection = getSessionsCollection();
  const result = await collection.updateOne(
    { _id: new ObjectId(sessionId), userId },
    {
      $set: {
        ...updates,
        updatedAt: new Date(),
      },
    }
  );
  return result.matchedCount > 0;
};

export const listMeetingSessions = async (
  userId: string,
  options?: {
    limit?: number;
    skip?: number;
    search?: string;
  }
): Promise<{ sessions: any[]; total: number }> => {
  const collection = getSessionsCollection();
  
  // Build query filter
  const filter: any = { userId };
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

export const deleteMeetingSession = async (sessionId: string, userId: string): Promise<boolean> => {
  const collection = getSessionsCollection();
  const result = await collection.deleteOne({
    _id: new ObjectId(sessionId),
    userId,
  });
  return result.deletedCount > 0;
};

// Mode configs (built-in modes: realTimePrompt, notesTemplate per mode name)
export const getModeConfigs = async (userId: string): Promise<Record<string, ModeConfigEntry> | null> => {
  const collection = getModeConfigsCollection();
  const doc = await collection.findOne({ userId });
  if (!doc || !doc.configs || Object.keys(doc.configs).length === 0) {
    return null;
  }
  return doc.configs;
};

export const saveModeConfig = async (
  userId: string,
  modeName: string,
  config: ModeConfigEntry
): Promise<void> => {
  const collection = getModeConfigsCollection();
  await collection.updateOne(
    { userId },
    { $set: { [`configs.${modeName}`]: config } },
    { upsert: true }
  );
};

// Custom modes (user-created, e.g. from templates)
export const getCustomModes = async (userId: string): Promise<CustomModeEntry[]> => {
  const collection = getCustomModesCollection();
  const doc = await collection.findOne({ userId });
  return doc?.modes ?? [];
};

export const saveCustomModes = async (userId: string, modes: CustomModeEntry[]): Promise<void> => {
  const collection = getCustomModesCollection();
  await collection.updateOne(
    { userId },
    { $set: { modes } },
    { upsert: true }
  );
};

export const deleteCustomMode = async (userId: string, modeId: string): Promise<void> => {
  const collection = getCustomModesCollection();
  const doc = await collection.findOne({ userId });
  const modes = doc?.modes ?? [];
  console.log('[RemoveMode] db deleteCustomMode', { userId, modeId, beforeCount: modes.length, modeIds: modes.map((m: CustomModeEntry) => m.id) });
  const next = modes.filter((m) => String(m.id) !== String(modeId));
  const removed = modes.length - next.length;
  console.log('[RemoveMode] db after filter', { nextCount: next.length, removed });
  const result = await collection.updateOne(
    { userId },
    { $set: { modes: next } },
    { upsert: true }
  );
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
  console.log('[RemoveMode] db read-after-write', { count: modesAfter.length, modeIds: modesAfter.map((m: CustomModeEntry) => m.id), stillHasDeletedId: modesAfter.some((m: CustomModeEntry) => String(m.id) === String(modeId)) });
};

// Question templates
export const getQuestionTemplates = async (userId: string): Promise<QuestionTemplateEntry[]> => {
  const collection = getQuestionTemplatesCollection();
  console.log('[DB] getQuestionTemplates: userId=', userId);
  const doc = await collection.findOne({ userId });
  const templates = doc?.templates ?? [];
  console.log('[DB] getQuestionTemplates: found', templates.length, 'templates');
  return templates;
};

export const saveQuestionTemplates = async (userId: string, templates: QuestionTemplateEntry[]): Promise<void> => {
  const collection = getQuestionTemplatesCollection();
  console.log('[DB] saveQuestionTemplates: userId=', userId, 'count=', templates.length);
  const result = await collection.updateOne(
    { userId },
    { $set: { templates } },
    { upsert: true }
  );
  console.log('[DB] saveQuestionTemplates result:', {
    acknowledged: result.acknowledged,
    matchedCount: result.matchedCount,
    modifiedCount: result.modifiedCount,
    upsertedCount: result.upsertedCount,
  });
};

export const deleteQuestionTemplate = async (userId: string, templateId: string): Promise<void> => {
  const collection = getQuestionTemplatesCollection();
  const doc = await collection.findOne({ userId });
  const templates = doc?.templates ?? [];
  const next = templates.filter((t) => String(t.id) !== String(templateId));
  await collection.updateOne(
    { userId },
    { $set: { templates: next } },
    { upsert: true }
  );
};

// Close database connection
export const closeDB = async (): Promise<void> => {
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

// API Usage Tracking
export interface ApiUsage {
  _id?: ObjectId;
  userId: string;
  model: string;
  promptTokens: number;
  completionTokens: number;
  totalTokens: number;
  mode: string; // 'reply', 'summary', 'insights', 'questions'
  timestamp: Date;
  sessionId?: string; // Optional: link to meeting session
}

export const getApiUsageCollection = (db: Db): Collection<ApiUsage> => {
  return db.collection<ApiUsage>('api_usage');
};

export const saveApiUsage = async (
  userId: string,
  model: string,
  usage: { prompt_tokens: number; completion_tokens: number; total_tokens: number },
  mode: string,
  sessionId?: string
): Promise<void> => {
  await connectDB();
  const currentDb = db;
  if (!currentDb) throw new Error('Database not connected');
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

export const getUserApiUsage = async (
  userId: string,
  startDate?: Date,
  endDate?: Date
): Promise<ApiUsage[]> => {
  await connectDB();
  const currentDb = db;
  if (!currentDb) throw new Error('Database not connected');
  const collection = getApiUsageCollection(currentDb);
  
  const query: any = { userId };
  if (startDate || endDate) {
    query.timestamp = {};
    if (startDate) query.timestamp.$gte = startDate;
    if (endDate) query.timestamp.$lte = endDate;
  }
  
  return collection.find(query).sort({ timestamp: -1 }).toArray();
};

export const getUserApiUsageStats = async (
  userId: string,
  startDate?: Date,
  endDate?: Date
): Promise<{
  totalRequests: number;
  totalTokens: number;
  totalPromptTokens: number;
  totalCompletionTokens: number;
  byModel: Record<string, { requests: number; tokens: number }>;
  byMode: Record<string, { requests: number; tokens: number }>;
}> => {
  const usage = await getUserApiUsage(userId, startDate, endDate);
  
  const stats = {
    totalRequests: usage.length,
    totalTokens: 0,
    totalPromptTokens: 0,
    totalCompletionTokens: 0,
    byModel: {} as Record<string, { requests: number; tokens: number }>,
    byMode: {} as Record<string, { requests: number; tokens: number }>,
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

// Transcription usage tracking (for pricing tiers / minute limits)
export interface TranscriptionUsage {
  _id?: ObjectId;
  userId: string;
  durationMs: number;
  timestamp: Date;
  sessionId?: string;
}

export const saveTranscriptionUsage = async (
  userId: string,
  durationMs: number,
  sessionId?: string
): Promise<void> => {
  await connectDB();
  const currentDb = db;
  if (!currentDb) throw new Error('Database not connected');
  await currentDb.collection<TranscriptionUsage>('transcription_usage').insertOne({
    userId,
    durationMs,
    timestamp: new Date(),
    sessionId,
  });
};

export const getTranscriptionUsageMsForPeriod = async (
  userId: string,
  start: Date,
  end: Date
): Promise<number> => {
  await connectDB();
  const currentDb = db;
  if (!currentDb) throw new Error('Database not connected');
  const coll = currentDb.collection<TranscriptionUsage>('transcription_usage');
  const rows = await coll
    .aggregate<{ totalMs: number }>([
      { $match: { userId, timestamp: { $gte: start, $lt: end } } },
      { $group: { _id: null, totalMs: { $sum: '$durationMs' } } },
      { $project: { _id: 0, totalMs: 1 } },
    ])
    .toArray();
  return rows[0]?.totalMs ?? 0;
};

export const setUserPlan = async (userId: string, plan: 'free' | 'pro' | 'pro_plus'): Promise<void> => {
  const collection = getUsersCollection();
  await collection.updateOne(
    { _id: new ObjectId(userId) },
    { $set: { plan, plan_updated_at: Date.now(), updated_at: Date.now() } }
  );
};

export default { connectDB, closeDB, getUsersCollection };
