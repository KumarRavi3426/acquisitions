import 'dotenv/config';

const isLocal = (process.env.DATABASE_URL || '').includes('localhost') ||
                (process.env.DATABASE_URL || '').includes('127.0.0.1');

export default {
  schema: './src/models/*.js',
  out: './drizzle',
  dialect: 'postgresql',
  driver: isLocal ? 'pg' : undefined,
  dbCredentials: {
    url: process.env.DATABASE_URL,
  },
};
