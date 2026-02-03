import { MongoClient, Db, Collection, ObjectId } from 'mongodb';
import crypto from 'crypto';

// User type definition
export interface User {
  _id?: ObjectId;
  id?: string; // For backward compatibility, will be _id.toString()
  email: string;
  name: string;
  // Billing provider metadata (optional)
  paypal?: {
    subscriptionId: string;
    planId: string;
    status: string;
    subscriberEmail?: string | null;
    nextBillingTime?: string | null; // ISO string if available
    createdAt?: number;
    updatedAt?: number;
  };
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

export interface AuthSession {
  _id?: ObjectId;
  id?: string; // _id.toString()
  userId: string;
  createdAt: Date;
  lastSeenAt: Date;
  clientType: 'web' | 'desktop' | 'mobile' | 'unknown';
  platform: 'windows' | 'mac' | 'linux' | 'android' | 'ios' | 'unknown';
  deviceId?: string | null;
  locationKey?: string | null;
  userAgent: string;
  ip: string;
  revokedAt: Date | null;
}

export interface TrustedDevice {
  _id?: ObjectId;
  id?: string;
  userId: string;
  deviceId: string;
  firstSeenAt: Date;
  lastSeenAt: Date;
  lastLocationKey: string | null;
  lastIp: string | null;
  lastUserAgent: string | null;
  clientType: AuthSession['clientType'];
  platform: AuthSession['platform'];
}

export interface LoginChallenge {
  _id?: ObjectId;
  id?: string;
  userId: string;
  email: string;
  code: string;
  createdAt: Date;
  expiresAt: Date;
  usedAt: Date | null;
  attempts: number;
  // Context for the pending sign-in
  deviceId: string;
  locationKey: string | null;
  clientType: AuthSession['clientType'];
  platform: AuthSession['platform'];
  userAgent: string;
  ip: string;
}

let client: MongoClient | null = null;
let db: Db | null = null;
let usersCollection: Collection<User> | null = null;
let sessionsCollection: Collection<MeetingSession> | null = null;
let modeConfigsCollection: Collection<ModeConfigsDoc> | null = null;
let customModesCollection: Collection<CustomModesDoc> | null = null;
let questionTemplatesCollection: Collection<QuestionTemplatesDoc> | null = null;
let authSessionsCollection: Collection<AuthSession> | null = null;
let trustedDevicesCollection: Collection<TrustedDevice> | null = null;
let loginChallengesCollection: Collection<LoginChallenge> | null = null;

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
      await usersCollection.createIndex({ 'paypal.subscriptionId': 1 });
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

    if (!authSessionsCollection) {
      authSessionsCollection = db.collection<AuthSession>('auth_sessions');
      await authSessionsCollection.createIndex({ userId: 1, revokedAt: 1, lastSeenAt: -1 });
      await authSessionsCollection.createIndex({ userId: 1, createdAt: -1 });
    }

    if (!trustedDevicesCollection) {
      trustedDevicesCollection = db.collection<TrustedDevice>('trusted_devices');
      await trustedDevicesCollection.createIndex({ userId: 1, deviceId: 1 }, { unique: true });
      await trustedDevicesCollection.createIndex({ userId: 1, lastSeenAt: -1 });
    }

    if (!loginChallengesCollection) {
      loginChallengesCollection = db.collection<LoginChallenge>('login_challenges');
      await loginChallengesCollection.createIndex({ userId: 1, createdAt: -1 });
      await loginChallengesCollection.createIndex({ expiresAt: 1 });
      await loginChallengesCollection.createIndex({ usedAt: 1 });
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

const getAuthSessionsCollection = (): Collection<AuthSession> => {
  if (!authSessionsCollection) {
    throw new Error('Database not connected. Call connectDB() first.');
  }
  return authSessionsCollection;
};

const getTrustedDevicesCollection = (): Collection<TrustedDevice> => {
  if (!trustedDevicesCollection) {
    throw new Error('Database not connected. Call connectDB() first.');
  }
  return trustedDevicesCollection;
};

const getLoginChallengesCollection = (): Collection<LoginChallenge> => {
  if (!loginChallengesCollection) {
    throw new Error('Database not connected. Call connectDB() first.');
  }
  return loginChallengesCollection;
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

  // Defensive: some legacy/bad documents may have bubbles saved as an object/map.
  // Normalize to an array so clients don't crash while parsing.
  const rawBubbles: any = (session as any).bubbles;
  const bubblesArray: any[] = Array.isArray(rawBubbles)
    ? rawBubbles
    : rawBubbles && typeof rawBubbles === 'object'
      ? Object.values(rawBubbles)
      : [];

  return {
    id: session._id?.toString() || session.id,
    title: session.title,
    createdAt: formatDate(session.createdAt),
    updatedAt: formatDate(session.updatedAt),
    bubbles: bubblesArray.map((b: any) => ({
      source: String(b?.source ?? 'unknown'),
      text: String(b?.text ?? ''),
      timestamp: formatDate(b?.timestamp ?? null),
      isDraft: Boolean(b?.isDraft ?? false),
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

export const setUserPayPalSubscription = async (
  userId: string,
  data: {
    subscriptionId: string;
    planId: string;
    status: string;
    plan: 'free' | 'pro' | 'pro_plus';
    subscriberEmail?: string | null;
    nextBillingTime?: string | null;
  }
): Promise<void> => {
  const collection = getUsersCollection();
  const now = Date.now();
  const existing = await collection.findOne({ _id: new ObjectId(userId) });
  const createdAt = (existing as any)?.paypal?.createdAt ?? now;

  await collection.updateOne(
    { _id: new ObjectId(userId) },
    {
      $set: {
        plan: data.plan,
        plan_updated_at: now,
        paypal: {
          subscriptionId: data.subscriptionId,
          planId: data.planId,
          status: data.status,
          subscriberEmail: data.subscriberEmail ?? null,
          nextBillingTime: data.nextBillingTime ?? null,
          createdAt,
          updatedAt: now,
        },
        updated_at: now,
      },
    }
  );
};

export const updatePayPalSubscriptionStatusBySubscriptionId = async (
  subscriptionId: string,
  status: string,
  plan?: 'free' | 'pro' | 'pro_plus',
  nextBillingTime?: string | null
): Promise<void> => {
  const collection = getUsersCollection();
  const now = Date.now();
  const setObj: any = {
    'paypal.status': status,
    'paypal.updatedAt': now,
    updated_at: now,
  };
  if (typeof nextBillingTime !== 'undefined') setObj['paypal.nextBillingTime'] = nextBillingTime;
  if (plan) {
    setObj.plan = plan;
    setObj.plan_updated_at = now;
  }
  await collection.updateOne(
    { 'paypal.subscriptionId': subscriptionId } as any,
    { $set: setObj }
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
    authSessionsCollection = null;
    trustedDevicesCollection = null;
    loginChallengesCollection = null;
    console.log('MongoDB connection closed');
  }
};

// Auth sessions (web/app sign-ins)
const toAuthSession = (doc: AuthSession | null): AuthSession | undefined => {
  if (!doc) return undefined;
  return { ...doc, id: doc._id?.toString() };
};

export const createAuthSession = async (
  userId: string,
  clientType: AuthSession['clientType'],
  platform: AuthSession['platform'],
  userAgent: string,
  ip: string,
  deviceId?: string | null,
  locationKey?: string | null
): Promise<string> => {
  await connectDB();
  const collection = getAuthSessionsCollection();
  const now = new Date();
  const doc: Omit<AuthSession, '_id' | 'id'> = {
    userId,
    createdAt: now,
    lastSeenAt: now,
    clientType,
    platform,
    deviceId: deviceId ?? null,
    locationKey: locationKey ?? null,
    userAgent: String(userAgent || ''),
    ip: String(ip || ''),
    revokedAt: null,
  };
  const result = await collection.insertOne(doc as any);
  return result.insertedId.toString();
};

export const touchAuthSession = async (userId: string, sessionId: string): Promise<boolean> => {
  await connectDB();
  const collection = getAuthSessionsCollection();
  if (!ObjectId.isValid(sessionId)) return false;
  const _id = new ObjectId(sessionId);
  const res = await collection.updateOne(
    { _id, userId, revokedAt: null },
    { $set: { lastSeenAt: new Date() } },
  );
  return res.matchedCount > 0;
};

// Validate that a session exists and is not revoked.
// Also updates lastSeenAt at most once per minTouchMs to avoid write-amplification.
export const validateAuthSessionAndMaybeTouch = async (
  userId: string,
  sessionId: string,
  minTouchMs: number = 60_000
): Promise<boolean> => {
  await connectDB();
  const collection = getAuthSessionsCollection();
  if (!ObjectId.isValid(sessionId)) return false;
  const _id = new ObjectId(sessionId);

  const doc = await collection.findOne(
    { _id, userId, revokedAt: null },
    { projection: { lastSeenAt: 1 } }
  );
  if (!doc) return false;

  const lastSeen = doc.lastSeenAt instanceof Date ? doc.lastSeenAt : null;
  const now = new Date();
  const shouldTouch = !lastSeen || (now.getTime() - lastSeen.getTime() >= minTouchMs);
  if (shouldTouch) {
    try {
      await collection.updateOne(
        { _id, userId, revokedAt: null },
        { $set: { lastSeenAt: now } },
      );
    } catch (_) {}
  }

  return true;
};

export const countAuthSessions = async (userId: string): Promise<number> => {
  await connectDB();
  const collection = getAuthSessionsCollection();
  return await collection.countDocuments({ userId });
};

export const listAuthSessions = async (
  userId: string,
  opts?: { limit?: number; skip?: number }
): Promise<AuthSession[]> => {
  await connectDB();
  const collection = getAuthSessionsCollection();
  const rawLimit = typeof opts?.limit === 'number' ? opts!.limit! : 50;
  const rawSkip = typeof opts?.skip === 'number' ? opts!.skip! : 0;
  const limit = Math.max(1, Math.min(200, Math.floor(rawLimit)));
  const skip = Math.max(0, Math.floor(rawSkip));

  const rows = await collection
    .find({ userId })
    .sort({ lastSeenAt: -1, createdAt: -1 })
    .skip(skip)
    .limit(limit)
    .toArray();
  return rows.map((r) => toAuthSession(r)!).filter(Boolean);
};

export const revokeAuthSession = async (userId: string, sessionId: string): Promise<boolean> => {
  await connectDB();
  const collection = getAuthSessionsCollection();
  if (!ObjectId.isValid(sessionId)) return false;
  const _id = new ObjectId(sessionId);
  const res = await collection.updateOne(
    { _id, userId, revokedAt: null },
    { $set: { revokedAt: new Date() } },
  );
  return res.matchedCount > 0;
};

export const revokeOtherAuthSessions = async (userId: string, keepSessionId: string | null): Promise<number> => {
  await connectDB();
  const collection = getAuthSessionsCollection();
  const filter: any = { userId, revokedAt: null };
  if (keepSessionId && ObjectId.isValid(keepSessionId)) {
    filter._id = { $ne: new ObjectId(keepSessionId) };
  }
  const res = await collection.updateMany(filter, { $set: { revokedAt: new Date() } });
  return res.modifiedCount ?? 0;
};

const toTrustedDevice = (doc: TrustedDevice | null): TrustedDevice | undefined => {
  if (!doc) return undefined;
  return { ...doc, id: doc._id?.toString() };
};

export const getTrustedDevice = async (userId: string, deviceId: string): Promise<TrustedDevice | null> => {
  await connectDB();
  const col = getTrustedDevicesCollection();
  const doc = await col.findOne({ userId, deviceId: String(deviceId) });
  return doc ? (toTrustedDevice(doc) as TrustedDevice) : null;
};

export const countTrustedDevices = async (userId: string): Promise<number> => {
  await connectDB();
  const col = getTrustedDevicesCollection();
  return await col.countDocuments({ userId });
};

export const upsertTrustedDeviceOnLogin = async (params: {
  userId: string;
  deviceId: string;
  clientType: AuthSession['clientType'];
  platform: AuthSession['platform'];
  locationKey: string | null;
  ip: string;
  userAgent: string;
}): Promise<void> => {
  await connectDB();
  const col = getTrustedDevicesCollection();
  const now = new Date();
  await col.updateOne(
    { userId: params.userId, deviceId: String(params.deviceId) },
    {
      $setOnInsert: {
        userId: params.userId,
        deviceId: String(params.deviceId),
        firstSeenAt: now,
      },
      $set: {
        lastSeenAt: now,
        lastLocationKey: params.locationKey ?? null,
        lastIp: String(params.ip || '') || null,
        lastUserAgent: String(params.userAgent || '') || null,
        clientType: params.clientType,
        platform: params.platform,
      },
    },
    { upsert: true }
  );
};

const toLoginChallenge = (doc: LoginChallenge | null): LoginChallenge | undefined => {
  if (!doc) return undefined;
  return { ...doc, id: doc._id?.toString() };
};

export const createLoginChallenge = async (params: {
  userId: string;
  email: string;
  deviceId: string;
  locationKey: string | null;
  clientType: AuthSession['clientType'];
  platform: AuthSession['platform'];
  userAgent: string;
  ip: string;
  code: string;
  expiresAt: Date;
}): Promise<LoginChallenge> => {
  await connectDB();
  const col = getLoginChallengesCollection();
  const now = new Date();
  const doc: Omit<LoginChallenge, '_id' | 'id'> = {
    userId: params.userId,
    email: params.email,
    code: params.code,
    createdAt: now,
    expiresAt: params.expiresAt,
    usedAt: null,
    attempts: 0,
    deviceId: String(params.deviceId),
    locationKey: params.locationKey ?? null,
    clientType: params.clientType,
    platform: params.platform,
    userAgent: String(params.userAgent || ''),
    ip: String(params.ip || ''),
  };
  const result = await col.insertOne(doc as any);
  const saved = await col.findOne({ _id: result.insertedId });
  return toLoginChallenge(saved as any)! as LoginChallenge;
};

export const getLoginChallengeById = async (id: string): Promise<LoginChallenge | null> => {
  await connectDB();
  const col = getLoginChallengesCollection();
  if (!ObjectId.isValid(id)) return null;
  const doc = await col.findOne({ _id: new ObjectId(id) } as any);
  return doc ? (toLoginChallenge(doc) as LoginChallenge) : null;
};

export const incrementLoginChallengeAttempts = async (id: string): Promise<void> => {
  await connectDB();
  const col = getLoginChallengesCollection();
  if (!ObjectId.isValid(id)) return;
  await col.updateOne({ _id: new ObjectId(id) } as any, { $inc: { attempts: 1 } });
};

export const markLoginChallengeUsed = async (id: string): Promise<void> => {
  await connectDB();
  const col = getLoginChallengesCollection();
  if (!ObjectId.isValid(id)) return;
  await col.updateOne({ _id: new ObjectId(id) } as any, { $set: { usedAt: new Date() } });
};

export const deleteUserAccount = async (userId: string): Promise<void> => {
  await connectDB();
  const currentDb = db;
  if (!currentDb) throw new Error('Database not connected');

  // Delete user record (ObjectId key) + all userId-keyed related docs.
  if (ObjectId.isValid(userId)) {
    await getUsersCollection().deleteOne({ _id: new ObjectId(userId) } as any);
  } else {
    // Fall back (shouldn't happen) - remove any user doc with matching id string.
    await getUsersCollection().deleteMany({ id: userId } as any);
  }

  await currentDb.collection('meeting_sessions').deleteMany({ userId });
  await currentDb.collection('mode_configs').deleteMany({ userId });
  await currentDb.collection('custom_modes').deleteMany({ userId });
  await currentDb.collection('question_templates').deleteMany({ userId });
  await currentDb.collection('auth_sessions').deleteMany({ userId });
  await currentDb.collection('trusted_devices').deleteMany({ userId });
  await currentDb.collection('login_challenges').deleteMany({ userId });
  await currentDb.collection('api_usage').deleteMany({ userId });
  await currentDb.collection('transcription_usage').deleteMany({ userId });
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

export const getUserDailyAiTokenUsage = async (
  userId: string,
  startDate: Date,
  endDate: Date
): Promise<Array<{ date: string; tokens: number }>> => {
  await connectDB();
  const currentDb = db;
  if (!currentDb) throw new Error('Database not connected');
  const collection = getApiUsageCollection(currentDb);

  const pipeline: any[] = [
    {
      $match: {
        userId,
        timestamp: { $gte: startDate, $lte: endDate },
      },
    },
    {
      $project: {
        day: {
          $dateToString: {
            format: '%Y-%m-%d',
            date: '$timestamp',
            timezone: 'UTC',
          },
        },
        totalTokens: 1,
      },
    },
    {
      $group: {
        _id: '$day',
        tokens: { $sum: '$totalTokens' },
      },
    },
    { $sort: { _id: 1 } },
  ];

  const rows = await collection.aggregate(pipeline).toArray();
  return rows.map((r: any) => ({ date: String(r._id), tokens: Number(r.tokens ?? 0) }));
};

export const getUserDailyAiTokenUsageByModel = async (
  userId: string,
  startDate: Date,
  endDate: Date
): Promise<Array<{ date: string; model: string; tokens: number }>> => {
  await connectDB();
  const currentDb = db;
  if (!currentDb) throw new Error('Database not connected');
  const collection = getApiUsageCollection(currentDb);

  const pipeline: any[] = [
    {
      $match: {
        userId,
        timestamp: { $gte: startDate, $lte: endDate },
      },
    },
    {
      $project: {
        day: {
          $dateToString: {
            format: '%Y-%m-%d',
            date: '$timestamp',
            timezone: 'UTC',
          },
        },
        model: 1,
        totalTokens: 1,
      },
    },
    {
      $group: {
        _id: { day: '$day', model: '$model' },
        tokens: { $sum: '$totalTokens' },
      },
    },
    { $sort: { '_id.day': 1, '_id.model': 1 } },
  ];

  const rows = await collection.aggregate(pipeline).toArray();
  return rows.map((r: any) => ({
    date: String(r?._id?.day ?? ''),
    model: String(r?._id?.model ?? ''),
    tokens: Number(r.tokens ?? 0),
  }));
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
