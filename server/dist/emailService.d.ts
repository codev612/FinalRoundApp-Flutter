export declare function initializeMailgun(): void;
export declare const sendVerificationEmail: (email: string, code: string) => Promise<boolean>;
export declare const sendPasswordResetEmail: (email: string, code: string) => Promise<boolean>;
export declare const sendProfileChangeAlert: (email: string, changes: {
    nameChanged?: boolean;
    emailChanged?: boolean;
    passwordChanged?: boolean;
    oldName?: string;
    newName?: string;
    oldEmail?: string;
    newEmail?: string;
}) => Promise<boolean>;
export declare const sendLoginSecurityCodeEmail: (email: string, code: string) => Promise<boolean>;
//# sourceMappingURL=emailService.d.ts.map