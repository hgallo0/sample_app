import { AuthTypes, Connector, IpAddressTypes } from "@google-cloud/cloud-sql-connector";
import pg from "pg";

const PROJECT_ID = process.env.PROJECT_ID;
const REGION = process.env.REGION;
const INSTANCE_NAME = process.env.INSTANCE_NAME ?? "rps-postgres";
const DB_NAME = process.env.DB_NAME ?? "prospects";
// Service account email with ".gserviceaccount.com" stripped - Cloud SQL's
// IAM auth convention, matches infra/output.tf's db_iam_user output.
const DB_IAM_USER = process.env.DB_IAM_USER;

async function createPool(): Promise<pg.Pool> {
  if (!PROJECT_ID || !REGION || !DB_IAM_USER) {
    // Local dev: docker-compose Postgres, plain connection string.
    return new pg.Pool({ connectionString: process.env.DATABASE_URL });
  }

  // Cloud Run: no password anywhere - the connector mints short-lived OAuth
  // tokens using this service's own runtime service account identity.
  const connector = new Connector();
  const clientOpts = await connector.getOptions({
    instanceConnectionName: `${PROJECT_ID}:${REGION}:${INSTANCE_NAME}`,
    ipType: IpAddressTypes.PRIVATE,
    authType: AuthTypes.IAM,
  });
  return new pg.Pool({
    ...clientOpts,
    user: DB_IAM_USER,
    database: DB_NAME,
    max: 5,
  });
}

export const pool = await createPool();
