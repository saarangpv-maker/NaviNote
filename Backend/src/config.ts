// Server configuration from the environment. The API key is kept apart
// from everything else so the rest of the config can never carry it.
import { z } from "zod";

const flag = z.enum(["true", "false"]).transform((value) => value === "true");

const EnvSchema = z.object({
  OPENAI_API_KEY: z.string().optional(),
  ASTRA_MODEL: z.string().trim().min(1).default("gpt-6-astra"),
  ASTRA_ENABLED: flag.default(true),
  ASTRA_DAILY_CAP: z.coerce.number().int().min(0).max(100_000).default(300),
  /// Banknote photos per UTC day (they cost more than text).
  ASTRA_IMAGE_DAILY_CAP: z.coerce.number().int().min(0).max(100_000).default(100),
  ASTRA_HOST: z.string().trim().min(1).default("127.0.0.1"),
  ASTRA_PORT: z.coerce.number().int().min(0).max(65_535).default(8787),
  ASTRA_REQUIRE_APP_ATTEST: flag.default(false),
});

export interface Config {
  model: string;
  enabled: boolean;
  dailyCap: number;
  imageDailyCap: number;
  host: string;
  port: number;
  /** Server-side timeout for one model call. */
  modelTimeoutMs: number;
  /** Server-side timeout for one banknote photo. */
  imageTimeoutMs: number;
}

export class ConfigError extends Error {}

/// Returns the config and, separately, the API key. Refuses to start when
/// Astra is enabled without a key, or when App Attest is required (it is
/// designed but not implemented, so it must never look enforced).
export function loadConfig(env: NodeJS.ProcessEnv): { config: Config; apiKey: string | null } {
  const parsed = EnvSchema.safeParse(env);
  if (!parsed.success) {
    // Name the variables only; never echo values.
    const names = [...new Set(parsed.error.issues.map((issue) => issue.path.join(".")))].join(", ");
    throw new ConfigError(`Invalid configuration: ${names}`);
  }
  const values = parsed.data;
  if (values.ASTRA_REQUIRE_APP_ATTEST) {
    throw new ConfigError("ASTRA_REQUIRE_APP_ATTEST=true, but App Attest verification is not implemented yet.");
  }
  const apiKey = values.OPENAI_API_KEY?.trim() ?? "";
  if (values.ASTRA_ENABLED && apiKey === "") {
    throw new ConfigError("OPENAI_API_KEY is not set. Put it in Backend/.env (see .env.example), or set ASTRA_ENABLED=false.");
  }
  return {
    config: {
      model: values.ASTRA_MODEL,
      enabled: values.ASTRA_ENABLED,
      dailyCap: values.ASTRA_DAILY_CAP,
      imageDailyCap: values.ASTRA_IMAGE_DAILY_CAP,
      host: values.ASTRA_HOST,
      port: values.ASTRA_PORT,
      modelTimeoutMs: 8000,
      imageTimeoutMs: 20_000,
    },
    apiKey: apiKey === "" ? null : apiKey,
  };
}
