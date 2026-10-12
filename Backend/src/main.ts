// Entry point: `npm start` (loads Backend/.env if present).
import OpenAI from "openai";
import { notImplementedVerifier } from "./attestation.ts";
import { ConfigError, loadConfig } from "./config.ts";
import { standardLimits } from "./limits.ts";
import { createLogger } from "./log.ts";
import { OpenAIAstraModel, type AstraModel } from "./model.ts";
import { OpenAIBanknoteModel } from "./banknote.ts";
import { createAstraServer } from "./server.ts";

const log = createLogger();

let loaded: ReturnType<typeof loadConfig>;
try {
  loaded = loadConfig(process.env);
} catch (error) {
  process.stderr.write(`${error instanceof ConfigError ? error.message : "Invalid configuration."}\n`);
  process.exit(1);
}
const { config, apiKey } = loaded;

// With Astra switched off there is no key and no client; every request
// gets the fixed "disabled" error.
const client = apiKey === null ? null : new OpenAI({ apiKey, maxRetries: 0 });
const model: AstraModel =
  client === null
    ? { respond: () => Promise.reject(new Error("disabled")) }
    : new OpenAIAstraModel(client, config.model);

const server = createAstraServer(
  {
    config,
    model,
    limits: standardLimits(config.dailyCap, Date.now, config.imageDailyCap),
    attestation: notImplementedVerifier,
    ...(client === null ? {} : { banknoteModel: new OpenAIBanknoteModel(client, config.model) }),
  },
  log,
);

server.listen(config.port, config.host, () => {
  log({ event: "startup" });
  process.stdout.write(
    `NaviNote Astra backend listening on http://${config.host}:${config.port} ` +
      `(Astra ${config.enabled ? "enabled" : "disabled"}; App Attest not implemented)\n`,
  );
});

const shutdown = () => {
  log({ event: "shutdown" });
  server.close(() => process.exit(0));
};
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
