import { connectDB, closeDB, createUser, getUserByEmail, markEmailVerified } from './database.js';
import { hashPassword } from './auth.js';
import dotenv from 'dotenv';
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
    dotenv.config();
    if (fs.existsSync('.env')) {
        console.log('✓ Loaded .env from current working directory');
    }
    else {
        console.log('⚠ No .env file found - using environment variables and defaults');
    }
}
async function seedUser() {
    try {
        // Connect to database
        await connectDB();
        console.log('Connected to database');
        const email = 'mikeyb612@proton.me';
        const name = 'Mikey';
        const password = '123456789';
        // Check if user already exists
        const existingUser = await getUserByEmail(email);
        if (existingUser) {
            console.log(`User with email ${email} already exists. Skipping seed.`);
            await closeDB();
            process.exit(0);
        }
        // Hash password
        const passwordHash = await hashPassword(password);
        console.log('Password hashed');
        // Create user
        const user = await createUser(email, name, passwordHash);
        console.log(`User created with ID: ${user.id}`);
        // Mark email as verified so user can sign in immediately
        await markEmailVerified(user.id);
        console.log('Email marked as verified');
        console.log('\n✅ Seed user created successfully!');
        console.log(`   Email: ${email}`);
        console.log(`   Password: ${password}`);
        console.log(`   Email verified: true\n`);
        await closeDB();
        process.exit(0);
    }
    catch (error) {
        console.error('Error seeding user:', error);
        await closeDB();
        process.exit(1);
    }
}
seedUser();
//# sourceMappingURL=seed.js.map