import { Db, Collection, ObjectId } from 'mongodb';
export interface User {
    _id?: ObjectId;
    id?: string;
    email: string;
    name: string;
    plan?: 'free' | 'pro' | 'pro_plus';
    plan_updated_at?: number;
    password_hash: string;
    email_verified: boolean;
    verification_code: string | null;
    verification_code_expires: number | null;
    verification_token: string | null;
    verification_token_expires: number | null;
    reset_token: string | null;
    reset_token_expires: number | null;
    reset_code: string | null;
    reset_code_expires: number | null;
    pending_email: string | null;
    current_email_code: string | null;
    current_email_code_expires: number | null;
    new_email_code: string | null;
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
    verification_token: string;
    verification_code: string;
}
export interface MeetingSession {
    _id?: ObjectId;
    id?: string;
    userId: string;
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
    modeKey?: string;
    metadata?: Record<string, any>;
}
export interface ModeConfigEntry {
    realTimePrompt: string;
    notesTemplate: string;
}
export interface ModeConfigsDoc {
    _id?: ObjectId;
    userId: string;
    configs: Record<string, ModeConfigEntry>;
}
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
export declare const connectDB: () => Promise<void>;
export declare const getSessionsCollection: () => Collection<MeetingSession>;
export declare const generateToken: () => string;
export declare const generateVerificationCode: () => string;
export declare const setVerificationToken: (userId: string, token: string, expiresInHours?: number) => Promise<void>;
export declare const setVerificationCode: (userId: string, code: string, expiresInMinutes?: number) => Promise<void>;
export declare const getUserByVerificationCode: (code: string) => Promise<User | undefined>;
export declare const setResetToken: (userId: string, token: string, expiresInHours?: number) => Promise<void>;
export declare const setResetCode: (userId: string, code: string, expiresInMinutes?: number) => Promise<void>;
export declare const clearVerificationToken: (userId: string) => Promise<void>;
export declare const clearResetToken: (userId: string) => Promise<void>;
export declare const markEmailVerified: (userId: string) => Promise<void>;
export declare const createUser: (email: string, name: string, passwordHash: string) => Promise<CreateUserResult>;
export declare const getUserByEmail: (email: string) => Promise<User | undefined>;
export declare const getUserById: (id: string) => Promise<PublicUser | undefined>;
export declare const getUserByIdFull: (id: string) => Promise<User | undefined>;
export declare const getUserByVerificationToken: (token: string) => Promise<User | undefined>;
export declare const getUserByResetToken: (token: string) => Promise<User | undefined>;
export declare const getUserByResetCode: (code: string) => Promise<User | undefined>;
export declare const updatePassword: (userId: string, passwordHash: string) => Promise<void>;
export declare const updateUserName: (userId: string, name: string) => Promise<void>;
export declare const updateUserEmail: (userId: string, email: string) => Promise<void>;
export declare const setPendingEmailChange: (userId: string, newEmail: string, currentEmailCode: string) => Promise<void>;
export declare const verifyCurrentEmailForChange: (userId: string, currentEmailCode: string) => Promise<boolean>;
export declare const setNewEmailCode: (userId: string, newEmailCode: string) => Promise<void>;
export declare const verifyNewEmailForChange: (userId: string, newEmailCode: string) => Promise<boolean>;
export declare const clearPendingEmailChange: (userId: string) => Promise<void>;
export declare const createMeetingSession: (session: Omit<MeetingSession, "_id" | "id">) => Promise<string>;
export declare const getMeetingSession: (sessionId: string, userId: string) => Promise<any | null>;
export declare const updateMeetingSession: (sessionId: string, userId: string, updates: Partial<Omit<MeetingSession, "_id" | "id" | "userId" | "createdAt">>) => Promise<boolean>;
export declare const listMeetingSessions: (userId: string, options?: {
    limit?: number;
    skip?: number;
    search?: string;
}) => Promise<{
    sessions: any[];
    total: number;
}>;
export declare const deleteMeetingSession: (sessionId: string, userId: string) => Promise<boolean>;
export declare const getModeConfigs: (userId: string) => Promise<Record<string, ModeConfigEntry> | null>;
export declare const saveModeConfig: (userId: string, modeName: string, config: ModeConfigEntry) => Promise<void>;
export declare const getCustomModes: (userId: string) => Promise<CustomModeEntry[]>;
export declare const saveCustomModes: (userId: string, modes: CustomModeEntry[]) => Promise<void>;
export declare const deleteCustomMode: (userId: string, modeId: string) => Promise<void>;
export declare const getQuestionTemplates: (userId: string) => Promise<QuestionTemplateEntry[]>;
export declare const saveQuestionTemplates: (userId: string, templates: QuestionTemplateEntry[]) => Promise<void>;
export declare const deleteQuestionTemplate: (userId: string, templateId: string) => Promise<void>;
export declare const closeDB: () => Promise<void>;
export interface ApiUsage {
    _id?: ObjectId;
    userId: string;
    model: string;
    promptTokens: number;
    completionTokens: number;
    totalTokens: number;
    mode: string;
    timestamp: Date;
    sessionId?: string;
}
export declare const getApiUsageCollection: (db: Db) => Collection<ApiUsage>;
export declare const saveApiUsage: (userId: string, model: string, usage: {
    prompt_tokens: number;
    completion_tokens: number;
    total_tokens: number;
}, mode: string, sessionId?: string) => Promise<void>;
export declare const getUserApiUsage: (userId: string, startDate?: Date, endDate?: Date) => Promise<ApiUsage[]>;
export declare const getUserApiUsageStats: (userId: string, startDate?: Date, endDate?: Date) => Promise<{
    totalRequests: number;
    totalTokens: number;
    totalPromptTokens: number;
    totalCompletionTokens: number;
    byModel: Record<string, {
        requests: number;
        tokens: number;
    }>;
    byMode: Record<string, {
        requests: number;
        tokens: number;
    }>;
}>;
export interface TranscriptionUsage {
    _id?: ObjectId;
    userId: string;
    durationMs: number;
    timestamp: Date;
    sessionId?: string;
}
export declare const saveTranscriptionUsage: (userId: string, durationMs: number, sessionId?: string) => Promise<void>;
export declare const getTranscriptionUsageMsForPeriod: (userId: string, start: Date, end: Date) => Promise<number>;
export declare const setUserPlan: (userId: string, plan: "free" | "pro" | "pro_plus") => Promise<void>;
declare const _default: {
    connectDB: () => Promise<void>;
    closeDB: () => Promise<void>;
    getUsersCollection: () => Collection<User>;
};
export default _default;
//# sourceMappingURL=database.d.ts.map